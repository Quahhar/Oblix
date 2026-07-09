import uuid
from datetime import datetime, timezone
from typing import Optional
from sqlalchemy import select, func, and_
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload
from fastapi import HTTPException, status
from app.models.user import User
from app.models.note import Note, NoteVersion, ContentType
from app.models.notebook import Notebook
from app.models.tag import Tag, NoteTag
from app.schemas.note import NoteCreate, NoteUpdate


class NoteService:

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
            conditions.append(Note.notebook_id == notebook_id)
        if search:
            conditions.append(Note.title.ilike(f"%{search}%") | Note.content.ilike(f"%{search}%"))

        query = select(Note).where(and_(*conditions))

        if tag_id:
            query = query.join(NoteTag).where(NoteTag.tag_id == tag_id)

        # Total count
        count_query = select(func.count()).select_from(query.subquery())
        total = (await db.execute(count_query)).scalar() or 0

        # Paginated fetch
        offset = (page - 1) * page_size
        query = query.options(
            selectinload(Note.tags).selectinload(NoteTag.tag),
            selectinload(Note.versions),
        ).order_by(
            Note.is_pinned.desc(), Note.updated_at.desc()
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
        """Get a single note with tags and versions."""
        result = await db.execute(
            select(Note)
            .where(Note.id == note_id, Note.user_id == user.id)
            .options(selectinload(Note.tags).selectinload(NoteTag.tag), selectinload(Note.versions))
        )
        note = result.scalar_one_or_none()
        if not note:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Note not found")
        return note

    async def create_note(self, db: AsyncSession, user: User, data: NoteCreate) -> Note:
        """Create a new note."""
        if data.notebook_id:
            nb_result = await db.execute(
                select(Notebook).where(Notebook.id == data.notebook_id, Notebook.user_id == user.id, Notebook.is_deleted == False)
            )
            if not nb_result.scalar_one_or_none():
                raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Notebook not found")

        note = Note(
            id=uuid.uuid4(),
            user_id=user.id,
            notebook_id=uuid.UUID(data.notebook_id) if data.notebook_id else None,
            title=data.title,
            content=data.content,
            content_type=data.content_type,
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
            await self._sync_tags(db, note.id, data.tag_ids)

        await db.flush()
        await db.refresh(note)

        return await self.get_note(db, user, str(note.id))

    async def update_note(self, db: AsyncSession, user: User, note_id: str, data: NoteUpdate) -> Note:
        """Update an existing note. Creates a new version on content change."""
        note = await self.get_note(db, user, note_id)

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
        if data.notebook_id is not None:
            update_fields["notebook_id"] = uuid.UUID(data.notebook_id) if data.notebook_id else None
        if data.is_pinned is not None:
            update_fields["is_pinned"] = data.is_pinned
        if data.is_archived is not None:
            update_fields["is_archived"] = data.is_archived
            if data.is_archived:
                update_fields["is_pinned"] = False
        if data.tag_ids is not None:
            await self._sync_tags(db, note.id, data.tag_ids)

        if update_fields:
            update_fields["updated_at"] = datetime.now(timezone.utc)
            for key, value in update_fields.items():
                setattr(note, key, value)

        # Create a new version if content changed
        if content_changed:
            max_version = (await db.execute(
                select(func.max(NoteVersion.version_number)).where(NoteVersion.note_id == note.id)
            )).scalar() or 0

            version = NoteVersion(
                id=uuid.uuid4(),
                note_id=note.id,
                title=note.title,
                content=note.content,
                content_type=note.content_type,
                version_number=max_version + 1,
            )
            db.add(version)

        await db.flush()
        await db.refresh(note)

        return await self.get_note(db, user, note_id)

    async def delete_note(self, db: AsyncSession, user: User, note_id: str) -> None:
        """Soft-delete a note."""
        note = await self.get_note(db, user, note_id)
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

    async def _get_note_raw(self, db: AsyncSession, user: User, note_id: str) -> Optional[Note]:
        result = await db.execute(select(Note).where(Note.id == note_id, Note.user_id == user.id))
        return result.scalar_one_or_none()

    async def _sync_tags(self, db: AsyncSession, note_id: uuid.UUID, tag_ids: list[str]) -> None:
        """Replace all tags on a note."""
        # Delete existing
        existing_tags = (await db.execute(select(NoteTag).where(NoteTag.note_id == note_id))).scalars().all()
        for et in existing_tags:
            await db.delete(et)

        # Add new
        for tag_id_str in tag_ids:
            try:
                tag_uuid = uuid.UUID(tag_id_str)
            except ValueError:
                continue
            note_tag = NoteTag(note_id=note_id, tag_id=tag_uuid)
            db.add(note_tag)


note_service = NoteService()