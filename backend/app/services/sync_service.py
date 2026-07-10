import uuid
from datetime import datetime, timezone
from typing import Optional
from sqlalchemy import select, inspect as sa_inspect
from sqlalchemy.orm import selectinload
from sqlalchemy.ext.asyncio import AsyncSession
from app.models.user import User
from app.models.note import Note, NoteVersion, ContentType
from app.models.notebook import Notebook
from app.models.tag import Tag, NoteTag
from app.models.file import File
from app.models.sync import SyncLog, EntityType, SyncAction
from app.schemas.sync import SyncChangeItem


def _coerce_content_type(value) -> ContentType:
    """Accept an enum, its value ('plain') or its name ('PLAIN'); default PLAIN."""
    if isinstance(value, ContentType):
        return value
    if isinstance(value, str):
        try:
            return ContentType(value)
        except ValueError:
            try:
                return ContentType[value.upper()]
            except KeyError:
                return ContentType.PLAIN
    return ContentType.PLAIN


def _parse_ts(value: Optional[str]) -> Optional[datetime]:
    """Parse an ISO-8601 timestamp into a timezone-aware UTC datetime, or None.

    Accepts both '...Z' and '...+00:00' forms. Naive timestamps are assumed UTC.
    """
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


class SyncService:

    async def push_changes(
        self,
        db: AsyncSession,
        user: User,
        changes: list[SyncChangeItem],
        last_sync_at: Optional[str] = None,
    ) -> dict:
        """Process incoming changes from a client.

        Each change is applied inside its own SAVEPOINT so that a single failing
        change (e.g. an integrity error) is rolled back on its own without
        poisoning the whole batch or the changes already applied.
        """
        applied: list[str] = []
        conflicts: list[dict] = []
        # Capture the cursor the client should adopt next, BEFORE mutating rows,
        # so a concurrent write landing mid-request isn't skipped next sync.
        server_time = datetime.now(timezone.utc).isoformat()

        for change in changes:
            try:
                async with db.begin_nested():  # SAVEPOINT per change
                    result = await self._apply_change(db, user, change)
                    if result.get("conflict"):
                        # No DB mutation to keep; raise to unwind the savepoint cleanly.
                        raise _ConflictError(result)
            except _ConflictError as ce:
                r = ce.result
                conflicts.append({
                    "entity_type": change.entity_type,
                    "entity_id": change.entity_id,
                    "server_data": r.get("server_data", {}),
                    "client_data": change.data,
                    "reason": r.get("reason", "Conflict"),
                })
                continue
            except Exception as e:  # noqa: BLE001 - report per-change failure, keep going
                conflicts.append({
                    "entity_type": change.entity_type,
                    "entity_id": change.entity_id,
                    "server_data": {},
                    "client_data": change.data,
                    "reason": str(e),
                })
                continue

            applied.append(change.entity_id)
            db.add(SyncLog(
                id=uuid.uuid4(),
                user_id=user.id,
                entity_type=EntityType(change.entity_type),
                entity_id=uuid.UUID(change.entity_id),
                action=SyncAction(change.action),
                device_id=change.device_id,
            ))

        await db.flush()

        # Return everything that changed since the client's last sync so the
        # push response alone is enough to catch the client up (it need not pull
        # separately right after).
        server_changes = await self._get_changes_since(db, user, last_sync_at)

        return {
            "applied": applied,
            "conflicts": conflicts,
            "server_changes": server_changes,
            "server_time": server_time,
        }

    async def pull_changes(
        self,
        db: AsyncSession,
        user: User,
        since: Optional[str] = None,
        entity_types: Optional[list[str]] = None,
    ) -> dict:
        """Return all changes since a given timestamp.

        server_time is captured BEFORE reading rows so the client can safely use
        it as the next cursor without a race window dropping concurrent writes.
        """
        server_time = datetime.now(timezone.utc).isoformat()
        changes = await self._get_changes_since(db, user, since, entity_types)
        return {
            "changes": changes,
            "server_time": server_time,
        }

    async def _apply_change(self, db: AsyncSession, user: User, change: SyncChangeItem) -> dict:
        """Apply a single sync change. Returns conflict info if applicable."""
        entity_type = change.entity_type

        if entity_type == "note":
            return await self._apply_note_change(db, user, change.entity_id, change)
        elif entity_type == "notebook":
            return await self._apply_notebook_change(db, user, change.entity_id, change)
        elif entity_type == "tag":
            return await self._apply_tag_change(db, user, change.entity_id, change)
        elif entity_type == "file":
            return await self._apply_file_change(db, user, change.entity_id, change)
        else:
            return {"conflict": True, "reason": f"Unknown entity type: {entity_type}"}

    async def _apply_note_change(self, db: AsyncSession, user: User, entity_id: str, change: SyncChangeItem) -> dict:
        existing = await self._get_note_with_tags(db, user, entity_id)
        client_data = change.data
        client_ts = _parse_ts(change.timestamp)

        if change.action == "create":
            if existing and not existing.is_deleted:
                return {"conflict": True, "server_data": self._note_to_dict(existing),
                        "reason": "Note already exists on server"}
            if existing and existing.is_deleted:
                # Resurrect the soft-deleted row instead of inserting a duplicate PK.
                self._apply_note_fields(existing, client_data)
                await self._apply_note_tags(db, user, existing, client_data)
                existing.is_deleted = False
                existing.deleted_at = None
                existing.updated_at = datetime.now(timezone.utc)
                return {}
            note = Note(
                id=uuid.UUID(entity_id),
                user_id=user.id,
            )
            self._apply_note_fields(note, client_data)
            db.add(note)
            await self._apply_note_tags(db, user, note, client_data)
            return {}

        elif change.action == "update":
            if not existing or existing.is_deleted:
                return {"conflict": True, "reason": "Note not found on server"}
            if client_ts is not None and existing.updated_at > client_ts:
                # Server has a strictly newer version → last-write-wins keeps server.
                return {"conflict": True, "server_data": self._note_to_dict(existing),
                        "reason": "Server version is newer"}
            self._apply_note_fields(existing, client_data)
            await self._apply_note_tags(db, user, existing, client_data)
            existing.updated_at = datetime.now(timezone.utc)
            return {}

        elif change.action == "delete":
            if existing and not existing.is_deleted:
                existing.is_deleted = True
                existing.is_archived = False
                existing.deleted_at = datetime.now(timezone.utc)
                existing.updated_at = datetime.now(timezone.utc)
            return {}

        return {"conflict": True, "reason": f"Unknown action: {change.action}"}

    @staticmethod
    def _apply_note_fields(note: Note, client_data: dict) -> None:
        for key in ("title", "content", "is_pinned", "is_archived"):
            if key in client_data:
                setattr(note, key, client_data[key])
        if "content_type" in client_data:
            note.content_type = _coerce_content_type(client_data["content_type"])
        if "notebook_id" in client_data:
            note.notebook_id = (
                uuid.UUID(client_data["notebook_id"]) if client_data["notebook_id"] else None
            )

    async def _apply_note_tags(self, db: AsyncSession, user: User, note: Note, client_data: dict) -> None:
        """Replace a note's tag links with the names the client sent.

        Clients send `tags` as a list of names (strings); server payloads use
        [{"name": ...}] — accept both. Missing tags are created; tombstoned
        ones are resurrected. Absent `tags` key means "unchanged".
        """
        if "tags" not in client_data:
            return
        names: list[str] = []
        for raw in client_data["tags"] or []:
            name = raw.get("name") if isinstance(raw, dict) else raw
            if isinstance(name, str) and name.strip():
                if name.strip() not in names:
                    names.append(name.strip())

        tags: list[Tag] = []
        if names:
            result = await db.execute(
                select(Tag).where(Tag.user_id == user.id, Tag.name.in_(names))
            )
            by_name = {t.name: t for t in result.scalars().all()}
            for name in names:
                tag = by_name.get(name)
                if tag is None:
                    tag = Tag(id=uuid.uuid4(), user_id=user.id, name=name)
                    db.add(tag)
                elif tag.is_deleted:
                    tag.is_deleted = False
                    tag.deleted_at = None
                    tag.updated_at = datetime.now(timezone.utc)
                tags.append(tag)

        note.tags = [NoteTag(note_id=note.id, tag_id=t.id) for t in tags]

    async def _apply_notebook_change(self, db: AsyncSession, user: User, entity_id: str, change: SyncChangeItem) -> dict:
        existing = await self._get_one(db, Notebook, user, entity_id)
        client_data = change.data
        client_ts = _parse_ts(change.timestamp)

        if change.action == "create":
            if existing and not existing.is_deleted:
                return {}  # idempotent: already there
            if existing and existing.is_deleted:
                existing.is_deleted = False
                existing.deleted_at = None
            target = existing or Notebook(id=uuid.UUID(entity_id), user_id=user.id)
            target.name = client_data.get("name", "New Notebook")
            target.parent_id = uuid.UUID(client_data["parent_id"]) if client_data.get("parent_id") else None
            if "sort_order" in client_data:
                target.sort_order = client_data["sort_order"]
            target.updated_at = datetime.now(timezone.utc)
            if existing is None:
                db.add(target)
            return {}

        elif change.action == "update":
            if not existing:
                return {"conflict": True, "reason": "Notebook not found on server"}
            if client_ts is not None and existing.updated_at > client_ts:
                return {"conflict": True, "reason": "Server version is newer"}
            for key in ("name", "sort_order"):
                if key in client_data:
                    setattr(existing, key, client_data[key])
            if "parent_id" in client_data:
                existing.parent_id = uuid.UUID(client_data["parent_id"]) if client_data["parent_id"] else None
            existing.updated_at = datetime.now(timezone.utc)
            return {}

        elif change.action == "delete":
            if existing and not existing.is_deleted:
                existing.is_deleted = True
                existing.deleted_at = datetime.now(timezone.utc)
                existing.updated_at = datetime.now(timezone.utc)
            return {}

        return {}

    async def _apply_tag_change(self, db: AsyncSession, user: User, entity_id: str, change: SyncChangeItem) -> dict:
        existing = await self._get_one(db, Tag, user, entity_id)
        client_data = change.data

        if change.action == "create":
            if existing:
                existing.name = client_data.get("name", existing.name)
                if existing.is_deleted:
                    existing.is_deleted = False
                    existing.deleted_at = None
                existing.updated_at = datetime.now(timezone.utc)
                return {}
            db.add(Tag(id=uuid.UUID(entity_id), user_id=user.id, name=client_data.get("name", "New Tag")))
            return {}

        elif change.action == "update":
            if existing and "name" in client_data:
                existing.name = client_data["name"]
                existing.updated_at = datetime.now(timezone.utc)
            return {}

        elif change.action == "delete":
            # Tombstone instead of hard delete so other devices learn about the
            # deletion through their next pull.
            if existing and not existing.is_deleted:
                existing.is_deleted = True
                existing.deleted_at = datetime.now(timezone.utc)
                existing.updated_at = datetime.now(timezone.utc)
            return {}

        return {}

    async def _apply_file_change(self, db: AsyncSession, user: User, entity_id: str, change: SyncChangeItem) -> dict:
        # Files are created via the multipart upload endpoint, not via sync push
        # (the binary can't travel in a JSON change). Sync only relinks/deletes.
        existing = await self._get_one(db, File, user, entity_id)
        client_data = change.data

        if change.action == "update":
            if existing and "note_id" in client_data:
                existing.note_id = uuid.UUID(client_data["note_id"]) if client_data["note_id"] else None
                existing.updated_at = datetime.now(timezone.utc)
            return {}

        elif change.action == "delete":
            if existing and not existing.is_deleted:
                existing.is_deleted = True
                existing.deleted_at = datetime.now(timezone.utc)
                existing.updated_at = datetime.now(timezone.utc)
            return {}

        return {}

    async def _get_changes_since(
        self, db: AsyncSession, user: User, since: Optional[str] = None,
        entity_types: Optional[list[str]] = None,
    ) -> list[dict]:
        """Build list of changed entities since timestamp (inclusive).

        The `since` filter is inclusive (>=) so a row touched at exactly the
        cursor time is never skipped; clients upsert idempotently so re-seeing a
        row is harmless.
        """
        changes: list[dict] = []
        target_types = entity_types or ["note", "notebook", "tag", "file"]
        since_dt = _parse_ts(since)

        # Notes (tags eagerly loaded so _note_to_dict can include them safely)
        if "note" in target_types:
            note_query = select(Note).where(Note.user_id == user.id).options(
                selectinload(Note.tags).selectinload(NoteTag.tag)
            )
            if since_dt is not None:
                note_query = note_query.where(Note.updated_at >= since_dt)
            note_result = await db.execute(note_query)
            for note in note_result.scalars().unique().all():
                changes.append({
                    "entity_type": "note",
                    "entity_id": str(note.id),
                    "action": "delete" if note.is_deleted else "update",
                    "data": self._note_to_dict(note),
                    "timestamp": note.updated_at.isoformat(),
                })

        # Notebooks
        if "notebook" in target_types:
            nb_query = select(Notebook).where(Notebook.user_id == user.id)
            if since_dt is not None:
                nb_query = nb_query.where(Notebook.updated_at >= since_dt)
            nb_result = await db.execute(nb_query)
            for nb in nb_result.scalars().all():
                changes.append({
                    "entity_type": "notebook",
                    "entity_id": str(nb.id),
                    "action": "delete" if nb.is_deleted else "update",
                    "data": {
                        "id": str(nb.id),
                        "user_id": str(nb.user_id),
                        "name": nb.name,
                        "parent_id": str(nb.parent_id) if nb.parent_id else None,
                        "sort_order": nb.sort_order,
                        "is_deleted": nb.is_deleted,
                        "created_at": nb.created_at.isoformat(),
                        "updated_at": nb.updated_at.isoformat(),
                    },
                    "timestamp": nb.updated_at.isoformat(),
                })

        # Tags
        if "tag" in target_types:
            tag_query = select(Tag).where(Tag.user_id == user.id)
            if since_dt is not None:
                tag_query = tag_query.where(Tag.updated_at >= since_dt)
            tag_result = await db.execute(tag_query)
            for tag in tag_result.scalars().all():
                changes.append({
                    "entity_type": "tag",
                    "entity_id": str(tag.id),
                    "action": "delete" if tag.is_deleted else "update",
                    "data": {
                        "id": str(tag.id),
                        "user_id": str(tag.user_id),
                        "name": tag.name,
                        "is_deleted": tag.is_deleted,
                        "created_at": tag.created_at.isoformat(),
                        "updated_at": tag.updated_at.isoformat(),
                    },
                    "timestamp": tag.updated_at.isoformat(),
                })

        # Files
        if "file" in target_types:
            file_query = select(File).where(File.user_id == user.id)
            if since_dt is not None:
                file_query = file_query.where(File.updated_at >= since_dt)
            file_result = await db.execute(file_query)
            for f in file_result.scalars().all():
                changes.append({
                    "entity_type": "file",
                    "entity_id": str(f.id),
                    "action": "delete" if f.is_deleted else "update",
                    "data": {
                        "id": str(f.id),
                        "filename": f.filename,
                        "original_name": f.original_name,
                        "mime_type": f.mime_type,
                        "size_bytes": f.size_bytes,
                        "note_id": str(f.note_id) if f.note_id else None,
                        "is_deleted": f.is_deleted,
                        "updated_at": f.updated_at.isoformat(),
                    },
                    "timestamp": f.updated_at.isoformat(),
                })

        return changes

    @staticmethod
    async def _get_one(db: AsyncSession, model, user: User, entity_id: str):
        result = await db.execute(
            select(model).where(model.id == entity_id, model.user_id == user.id)
        )
        return result.scalar_one_or_none()

    @staticmethod
    async def _get_note_with_tags(db: AsyncSession, user: User, entity_id: str) -> Optional[Note]:
        result = await db.execute(
            select(Note)
            .where(Note.id == entity_id, Note.user_id == user.id)
            .options(selectinload(Note.tags).selectinload(NoteTag.tag))
        )
        return result.scalar_one_or_none()

    @staticmethod
    def _note_to_dict(note: Note) -> dict:
        return {
            "id": str(note.id),
            "user_id": str(note.user_id),
            "title": note.title,
            "content": note.content,
            "content_type": note.content_type.value if hasattr(note.content_type, "value") else str(note.content_type),
            "notebook_id": str(note.notebook_id) if note.notebook_id else None,
            "is_pinned": note.is_pinned,
            "is_archived": note.is_archived,
            "is_deleted": note.is_deleted,
            "created_at": note.created_at.isoformat(),
            "updated_at": note.updated_at.isoformat(),
            "tags": SyncService._loaded_tag_names(note),
        }

    @staticmethod
    def _loaded_tag_names(note: Note) -> list[dict]:
        """Tag names, but only if the relationship is already loaded.

        Guards against triggering a lazy load in async context (which would
        raise MissingGreenlet).
        """
        if "tags" in sa_inspect(note).unloaded:
            return []
        names: list[dict] = []
        for nt in note.tags:
            if "tag" not in sa_inspect(nt).unloaded and nt.tag is not None:
                names.append({"name": nt.tag.name})
        return names


class _ConflictError(Exception):
    """Internal signal to unwind a per-change SAVEPOINT when a change conflicts."""

    def __init__(self, result: dict):
        self.result = result
        super().__init__(result.get("reason", "Conflict"))


sync_service = SyncService()
