import uuid
from datetime import datetime, timezone, timedelta
from typing import Optional
from sqlalchemy import select, func, and_, delete
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload
from fastapi import HTTPException, status
from app.models.user import User
from app.models.note import Note, NoteVersion, ContentType
from app.models.notebook import Notebook
from app.models.tag import Tag, NoteTag
from app.schemas.note import NoteCreate, NoteUpdate


def _uuid_or_error(value, detail: str, code: int) -> uuid.UUID:
    """Coerce a wire id to a UUID or raise, so a malformed id is a clean
    4xx instead of a 500 from Postgres trying to cast a non-UUID string."""
    try:
        return uuid.UUID(str(value))
    except (ValueError, TypeError):
        raise HTTPException(status_code=code, detail=detail)


class NoteService:

    # Autosaves within this window fold into the latest snapshot instead of
    # spawning a new version each time; history is capped per note.
    _VERSION_COALESCE_WINDOW = timedelta(minutes=10)
    _MAX_VERSIONS = 50

    async def list_notes(
        self,
        db: AsyncSession,
        user: User,
        notebook_id: Optional[str] = None,
        tag_id: Optional[str] = None,
        is_archived: bool = False,
        is_deleted: bool = False,
        search: Optional[str] = None,
        page: int = 1,
        page_size: int = 50,
    ) -> dict:
        """List notes with filtering and pagination."""
        conditions = [
            Note.user_id == user.id,
            Note.is_archived == is_archived,
            Note.is_deleted == is_deleted,
        ]
        if notebook_id:
            conditions.append(Note.notebook_id == _uuid_or_error(
                notebook_id, "Invalid notebook_id", status.HTTP_400_BAD_REQUEST))
        if search:
            # Escape LIKE metacharacters so a literal % or _ in the query isn't
            # treated as a wildcard (e.g. searching "50%" matches only "50%").
            like = "%" + search.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
            conditions.append(
                Note.title.ilike(like, escape="\\") | Note.content.ilike(like, escape="\\")
            )

        query = select(Note).where(and_(*conditions))

        if tag_id:
            query = query.join(NoteTag).where(NoteTag.tag_id == _uuid_or_error(
                tag_id, "Invalid tag_id", status.HTTP_400_BAD_REQUEST))

        # Total count
        count_query = select(func.count()).select_from(query.subquery())
        total = (await db.execute(count_query)).scalar() or 0

        # Paginated fetch
        offset = (page - 1) * page_size
        query = query.options(
            # Load tags for each listed note, but NOT versions/files: the note
            # list never shows history or attachments, and eager-loading full
            # version history for every note was a large, needless payload.
            # Note.versions is lazy="noload", so it serializes as [] here.
            selectinload(Note.tags).selectinload(NoteTag.tag),
        ).order_by(
            # Note.id is a stable tiebreaker: without it, notes sharing an
            # updated_at have no defined order across pages, so one can appear on
            # two pages (or be skipped) while paginating.
            Note.is_pinned.desc(), Note.updated_at.desc(), Note.id.desc()
        ).offset(offset).limit(page_size)

        result = await db.execute(query)
        notes = result.scalars().unique().all()

        return {
            "notes": notes,
            "total": total,
            "page": page,
            "page_size": page_size,
        }

    async def get_note(self, db: AsyncSession, user: User, note_id: str) -> Note:
        """Get a single note with tags and versions.

        Readable by the owner and by anyone it (or its notebook) is shared
        with. The trash stays private: a tombstoned note is 404 for grantees.
        """
        note, _role = await self.get_note_with_role(db, user, note_id)
        return note

    async def get_note_with_role(self, db: AsyncSession, user: User, note_id: str) -> tuple[Note, str]:
        from app.services.share_service import share_service

        note_uuid = _uuid_or_error(note_id, "Note not found", status.HTTP_404_NOT_FOUND)
        result = await db.execute(
            select(Note)
            .where(Note.id == note_uuid)
            .options(selectinload(Note.tags).selectinload(NoteTag.tag), selectinload(Note.versions))
        )
        note = result.scalar_one_or_none()
        role = await share_service.note_role(db, user, note) if note else None
        if note is None or role is None or (note.is_deleted and role != "owner"):
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Note not found")
        return note, role

    async def create_note(self, db: AsyncSession, user: User, data: NoteCreate) -> Note:
        """Create a new note."""
        notebook_uuid = await self._owned_notebook_uuid(db, user, data.notebook_id)

        note = Note(
            id=uuid.uuid4(),
            user_id=user.id,
            notebook_id=notebook_uuid,
            title=data.title,
            content=data.content,
            content_type=data.content_type,
            edited_at=datetime.now(timezone.utc),
        )
        db.add(note)
        await db.flush()

        # Create initial version
        version = NoteVersion(
            id=uuid.uuid4(),
            note_id=note.id,
            title=note.title,
            content=note.content,
            content_type=note.content_type,
            version_number=1,
        )
        db.add(version)

        # Attach tags
        if data.tag_ids:
            await self._sync_tags(db, user, note.id, data.tag_ids)

        await db.flush()
        # Expire ONLY the versions collection (not the whole object — expiring the
        # id would force a sync lazy-reload on the str(note.id) access below and
        # raise MissingGreenlet). get_note then re-selects with
        # selectinload(versions), which repopulates it with the freshly-seeded
        # version. A db.refresh() here would instead resolve versions via its
        # mapper default (noload), mark the collection loaded-but-empty, and the
        # selectinload would treat it as "already loaded" and drop the version.
        db.expire(note, ["versions"])

        return await self.get_note(db, user, str(note.id))

    # Fields only the owner may change: they express how the owner organizes
    # their own account. Editors on a shared note may change content only.
    _OWNER_ONLY_FIELDS = ("notebook_id", "is_pinned", "is_archived", "tag_ids")

    async def update_note(self, db: AsyncSession, user: User, note_id: str, data: NoteUpdate) -> Note:
        """Update an existing note. Creates a new version on content change.

        Owners have full control. Share grantees with the `editor` role may
        edit content fields (title/content/content_type); `viewer`s and any
        attempt by a non-owner to touch organizational fields get 403.
        """
        note, role = await self.get_note_with_role(db, user, note_id)
        if role == "viewer":
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN,
                                detail="You have view-only access to this note")
        if role == "editor":
            touched = [f for f in self._OWNER_ONLY_FIELDS if f in data.model_fields_set]
            if touched:
                raise HTTPException(
                    status_code=status.HTTP_403_FORBIDDEN,
                    detail=f"Only the note's owner can change: {', '.join(touched)}",
                )

        content_changed = False
        update_fields = {}

        if data.title is not None and data.title != note.title:
            update_fields["title"] = data.title
            content_changed = True
        if data.content is not None and data.content != note.content:
            update_fields["content"] = data.content
            content_changed = True
        if data.content_type is not None and data.content_type != note.content_type:
            update_fields["content_type"] = data.content_type
            content_changed = True
        # `model_fields_set` distinguishes an omitted field (leave unchanged)
        # from an explicit null/"" (detach the note from its notebook).
        if "notebook_id" in data.model_fields_set:
            update_fields["notebook_id"] = await self._owned_notebook_uuid(db, user, data.notebook_id)
        if data.is_pinned is not None:
            update_fields["is_pinned"] = data.is_pinned
        if data.is_archived is not None:
            update_fields["is_archived"] = data.is_archived
            if data.is_archived:
                update_fields["is_pinned"] = False
        if data.tag_ids is not None:
            await self._sync_tags(db, user, note.id, data.tag_ids)

        if update_fields:
            update_fields["updated_at"] = datetime.now(timezone.utc)
            # Track edit time separately so offline sync LWW compares like-for-like.
            if content_changed:
                update_fields["edited_at"] = update_fields["updated_at"]
            for key, value in update_fields.items():
                setattr(note, key, value)

        # Snapshot a version when content changes — but coalesce rapid autosaves
        # (e.g. a 30s client debounce) into the latest snapshot within a short
        # window, and cap history depth, so a long editing session can't spawn
        # hundreds of versions and bloat the table.
        if content_changed:
            now = datetime.now(timezone.utc)
            latest = (await db.execute(
                select(NoteVersion)
                .where(NoteVersion.note_id == note.id)
                .order_by(NoteVersion.version_number.desc())
                .limit(1)
            )).scalar_one_or_none()

            if (
                latest is not None
                and latest.created_at is not None
                and (now - latest.created_at) <= self._VERSION_COALESCE_WINDOW
            ):
                # Fold this autosave into the most recent snapshot.
                latest.title = note.title
                latest.content = note.content
                latest.content_type = note.content_type
                latest.created_at = now
            else:
                db.add(NoteVersion(
                    id=uuid.uuid4(),
                    note_id=note.id,
                    title=note.title,
                    content=note.content,
                    content_type=note.content_type,
                    version_number=(latest.version_number if latest else 0) + 1,
                ))
                await db.flush()
                await self._prune_versions(db, note.id)

        await db.flush()
        # Expire only the versions collection so the following get_note re-selects
        # it with selectinload and reflects any newly-added snapshot. It is
        # already loaded here (get_note was called at the top of this method), so
        # without the expire the selectinload would see it "already loaded" and
        # the new version would be missing from the response.
        db.expire(note, ["versions"])

        return await self.get_note(db, user, note_id)

    async def _prune_versions(self, db: AsyncSession, note_id: uuid.UUID) -> None:
        """Keep only the most recent `_MAX_VERSIONS` snapshots for a note."""
        stale_ids = (await db.execute(
            select(NoteVersion.id)
            .where(NoteVersion.note_id == note_id)
            .order_by(NoteVersion.version_number.desc())
            .offset(self._MAX_VERSIONS)
        )).scalars().all()
        if stale_ids:
            await db.execute(
                delete(NoteVersion)
                .where(NoteVersion.id.in_(stale_ids))
                .execution_options(synchronize_session=False)
            )

    async def delete_note(self, db: AsyncSession, user: User, note_id: str) -> None:
        """Soft-delete a note. Owner only — the trash is the owner's space."""
        note, role = await self.get_note_with_role(db, user, note_id)
        if role != "owner":
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN,
                                detail="Only the note's owner can delete it")
        note.is_deleted = True
        note.is_archived = False
        note.deleted_at = datetime.now(timezone.utc)
        await db.flush()

    async def restore_note(self, db: AsyncSession, user: User, note_id: str) -> Note:
        """Restore a soft-deleted note."""
        note = await self._get_note_raw(db, user, note_id)
        if not note or not note.is_deleted:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Deleted note not found")
        note.is_deleted = False
        note.deleted_at = None
        note.updated_at = datetime.now(timezone.utc)
        await db.flush()
        return await self.get_note(db, user, note_id)

    @staticmethod
    async def _owned_notebook_uuid(db: AsyncSession, user: User, notebook_id_str) -> Optional[uuid.UUID]:
        """Return the UUID of a notebook the user owns, or raise 404.

        Empty/None → None (note has no notebook). A malformed, unknown, or
        other-user's id raises 404 instead of surfacing a 500 (FK violation or
        bad-UUID cast) and instead of silently linking to a foreign notebook.
        """
        if not notebook_id_str:
            return None
        try:
            nb_uuid = uuid.UUID(str(notebook_id_str))
        except (ValueError, TypeError):
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Notebook not found")
        ok = (await db.execute(
            select(Notebook.id).where(
                Notebook.id == nb_uuid, Notebook.user_id == user.id, Notebook.is_deleted == False  # noqa: E712
            )
        )).scalar_one_or_none()
        if ok is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Notebook not found")
        return nb_uuid

    async def _get_note_raw(self, db: AsyncSession, user: User, note_id: str) -> Optional[Note]:
        note_uuid = _uuid_or_error(note_id, "Deleted note not found", status.HTTP_404_NOT_FOUND)
        result = await db.execute(select(Note).where(Note.id == note_uuid, Note.user_id == user.id))
        return result.scalar_one_or_none()

    async def _sync_tags(self, db: AsyncSession, user: User, note_id: uuid.UUID, tag_ids: list[str]) -> None:
        """Replace all tags on a note with the caller's *own* tags.

        Only tag ids that belong to this user (and aren't tombstoned) are
        linked; unknown or other-users' ids are ignored rather than inserted.
        This prevents both a cross-user tag leak and a 500 from a foreign-key
        violation on a non-existent tag id.
        """
        # Delete existing links
        existing_tags = (await db.execute(select(NoteTag).where(NoteTag.note_id == note_id))).scalars().all()
        for et in existing_tags:
            await db.delete(et)

        requested: list[uuid.UUID] = []
        for tag_id_str in tag_ids:
            try:
                requested.append(uuid.UUID(str(tag_id_str)))
            except (ValueError, TypeError):
                continue
        if not requested:
            return

        valid_ids = set((await db.execute(
            select(Tag.id).where(
                Tag.id.in_(requested),
                Tag.user_id == user.id,
                Tag.is_deleted == False,  # noqa: E712
            )
        )).scalars())

        seen: set[uuid.UUID] = set()
        for tag_uuid in requested:
            if tag_uuid in valid_ids and tag_uuid not in seen:
                seen.add(tag_uuid)
                db.add(NoteTag(note_id=note_id, tag_id=tag_uuid))


note_service = NoteService()