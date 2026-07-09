import uuid
from typing import Optional
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from fastapi import HTTPException, status, UploadFile
from app.models.user import User
from app.models.file import File
from app.utils.storage import storage, FileTooLargeError


class FileService:

    async def upload_file(self, db: AsyncSession, user: User, file: UploadFile, note_id: Optional[str] = None) -> File:
        """Upload a file and create its metadata record."""
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
            note_id=uuid.UUID(note_id) if note_id else None,
            filename=generated_name,
            original_name=file.filename or "untitled",
            mime_type=file.content_type or "application/octet-stream",
            size_bytes=size_bytes,
            storage_path=storage_path,
        )
        db.add(file_record)
        await db.flush()
        await db.refresh(file_record)
        return file_record

    async def get_file(self, db: AsyncSession, user: User, file_id: str) -> File:
        """Get file metadata by ID."""
        result = await db.execute(
            select(File).where(File.id == file_id, File.user_id == user.id, File.is_deleted == False)
        )
        file = result.scalar_one_or_none()
        if not file:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="File not found")
        return file

    async def list_files(self, db: AsyncSession, user: User, note_id: Optional[str] = None) -> list[File]:
        """List all files for a user, optionally filtered by note."""
        query = select(File).where(File.user_id == user.id, File.is_deleted == False)
        if note_id:
            query = query.where(File.note_id == note_id)
        result = await db.execute(query.order_by(File.created_at.desc()))
        return list(result.scalars().all())

    async def delete_file(self, db: AsyncSession, user: User, file_id: str) -> None:
        """Soft-delete a file and remove from storage."""
        file = await self.get_file(db, user, file_id)
        await storage.delete(file.storage_path)
        file.is_deleted = True
        await db.flush()


file_service = FileService()