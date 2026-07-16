import uuid
from typing import Optional
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from fastapi import HTTPException, status, UploadFile
from app.models.user import User
from app.models.file import File
from app.utils.storage import storage, FileTooLargeError
from app.utils import upload_policy


class FileService:

    async def upload_file(self, db: AsyncSession, user: User, file: UploadFile, note_id: Optional[uuid.UUID] = None) -> File:
        """Upload a file and create its metadata record."""
        # Oblix is a notes app, not a file host: reject anything outside the
        # allowlist before we write a single byte to disk.
        if not upload_policy.is_allowed(file.filename, file.content_type):
            raise HTTPException(
                status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
                detail=f"Unsupported file type. {upload_policy.describe_allowed()}",
            )

        if note_id:
            from app.models.note import Note
            note_result = await db.execute(select(Note).where(Note.id == note_id, Note.user_id == user.id))
            if not note_result.scalar_one_or_none():
                raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Note not found")

        try:
            storage_path, generated_name, size_bytes = await storage.upload(str(user.id), file)
        except FileTooLargeError as e:
            raise HTTPException(
                status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, detail=str(e)
            )

        file_record = File(
            id=uuid.uuid4(),
            user_id=user.id,
            note_id=note_id,
            filename=generated_name,
            # original_name is column-capped at 500 chars; truncate so an
            # over-long name can't blow up the flush and orphan the blob.
            original_name=(file.filename or "untitled")[:500],
            mime_type=file.content_type or "application/octet-stream",
            size_bytes=size_bytes,
            storage_path=storage_path,
        )
        db.add(file_record)
        try:
            await db.flush()
        except Exception:
            # The row couldn't be persisted — don't leave the blob orphaned on
            # disk with nothing pointing at it.
            await storage.delete(storage_path)
            raise
        await db.refresh(file_record)
        return file_record

    async def get_file(self, db: AsyncSession, user: User, file_id: str) -> File:
        """Get file metadata by ID."""
        # Coerce the wire id to a UUID first: a malformed id (a stale/garbage id
        # from the client) must be a clean 404, not a 500 from Postgres failing
        # to cast a non-UUID string — same guard the notes/tags/notebooks
        # endpoints already apply.
        try:
            file_uuid = uuid.UUID(str(file_id))
        except (ValueError, TypeError):
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="File not found")
        result = await db.execute(
            select(File).where(File.id == file_uuid, File.user_id == user.id, File.is_deleted == False)  # noqa: E712
        )
        file = result.scalar_one_or_none()
        if not file:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="File not found")
        return file

    async def get_readable_file(self, db: AsyncSession, user: User, file_id: str) -> File:
        """Like get_file, but also honors collaboration: an attachment is
        readable by anyone who can read the note it's attached to. Writes
        (delete/relink) still go through the owner-only get_file."""
        from app.models.note import Note
        from app.services.share_service import share_service

        try:
            file_uuid = uuid.UUID(str(file_id))
        except (ValueError, TypeError):
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="File not found")
        file = (await db.execute(
            select(File).where(File.id == file_uuid, File.is_deleted == False)  # noqa: E712
        )).scalar_one_or_none()
        if file is not None:
            if file.user_id == user.id:
                return file
            if file.note_id is not None:
                note = (await db.execute(select(Note).where(
                    Note.id == file.note_id, Note.is_deleted == False  # noqa: E712
                ))).scalar_one_or_none()
                if note is not None and await share_service.note_role(db, user, note):
                    return file
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="File not found")

    async def list_files(self, db: AsyncSession, user: User, note_id: Optional[str] = None) -> list[File]:
        """List all files for a user, optionally filtered by note."""
        query = select(File).where(File.user_id == user.id, File.is_deleted == False)
        if note_id:
            query = query.where(File.note_id == note_id)
        result = await db.execute(query.order_by(File.created_at.desc()))
        return list(result.scalars().all())

    async def delete_file(self, db: AsyncSession, user: User, file_id: str) -> None:
        """Soft-delete a file and remove from storage.

        Mark the row deleted and commit BEFORE unlinking the blob: if we removed
        the blob first and the commit then failed, the row would still claim the
        file exists and every future download would 500 on the missing blob.
        """
        file = await self.get_file(db, user, file_id)
        from datetime import datetime, timezone
        file.is_deleted = True
        file.deleted_at = datetime.now(timezone.utc)
        storage_path = file.storage_path
        await db.flush()
        # Best-effort blob removal; the record is already the source of truth.
        await storage.delete(storage_path)


file_service = FileService()