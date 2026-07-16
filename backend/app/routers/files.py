import uuid
from fastapi import APIRouter, Depends, UploadFile, File as FastAPIFile, Query, HTTPException, status
from fastapi.responses import FileResponse as FileDownloadResponse
from sqlalchemy.ext.asyncio import AsyncSession
from typing import Optional
from app.database import get_db
from app.schemas.file import FileResponse
from app.services.file_service import file_service
from app.utils.auth_dependency import get_current_user
from app.utils.storage import storage
from app.models.user import User

router = APIRouter(prefix="/files", tags=["files"])


def _parse_note_id(note_id: Optional[str]) -> Optional[uuid.UUID]:
    """Coerce the note_id query param.

    Absent or empty -> no filter (the client sends `?note_id=` to mean "all
    files"; that must not 422). A present-but-malformed id -> 422 rather than a
    500 from the DB casting a non-UUID string.
    """
    if not note_id:
        return None
    try:
        return uuid.UUID(note_id)
    except ValueError:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="note_id must be a valid UUID",
        )


@router.get("", response_model=list[FileResponse])
async def list_files(
    note_id: Optional[str] = Query(None),
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    files = await file_service.list_files(db, current_user, note_id=_parse_note_id(note_id))
    return files


@router.post("/upload", response_model=FileResponse, status_code=201)
async def upload_file(
    file: UploadFile = FastAPIFile(...),
    note_id: Optional[str] = Query(None),
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    file_record = await file_service.upload_file(db, current_user, file, note_id=_parse_note_id(note_id))
    return file_record


@router.get("/{file_id}", response_model=FileResponse)
async def get_file_metadata(
    file_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    file_record = await file_service.get_readable_file(db, current_user, file_id)
    return file_record


@router.get("/{file_id}/download")
async def download_file(
    file_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    file_record = await file_service.get_readable_file(db, current_user, file_id)
    try:
        file_path = await storage.download_path(file_record.storage_path)
    except FileNotFoundError:
        # Metadata exists but the blob is gone — report it as missing rather
        # than surfacing an uncaught 500.
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="File data not found")
    return FileDownloadResponse(
        path=str(file_path),
        filename=file_record.original_name,
        media_type=file_record.mime_type,
        # Never let a browser sniff user-uploaded bytes into an executable type.
        headers={"X-Content-Type-Options": "nosniff"},
    )


@router.delete("/{file_id}", status_code=204)
async def delete_file(
    file_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    await file_service.delete_file(db, current_user, file_id)