from fastapi import APIRouter, Depends, UploadFile, File as FastAPIFile, Query
from fastapi.responses import FileResponse
from sqlalchemy.ext.asyncio import AsyncSession
from typing import Optional
from app.database import get_db
from app.schemas.file import FileResponse
from app.services.file_service import file_service
from app.utils.auth_dependency import get_current_user
from app.utils.storage import storage
from app.models.user import User

router = APIRouter(prefix="/files", tags=["files"])


@router.get("", response_model=list[FileResponse])
async def list_files(
    note_id: Optional[str] = Query(None),
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    files = await file_service.list_files(db, current_user, note_id=note_id)
    return files


@router.post("/upload", response_model=FileResponse, status_code=201)
async def upload_file(
    file: UploadFile = FastAPIFile(...),
    note_id: Optional[str] = Query(None),
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    file_record = await file_service.upload_file(db, current_user, file, note_id=note_id)
    return file_record


@router.get("/{file_id}", response_model=FileResponse)
async def get_file_metadata(
    file_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    file_record = await file_service.get_file(db, current_user, file_id)
    return file_record


@router.get("/{file_id}/download")
async def download_file(
    file_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    file_record = await file_service.get_file(db, current_user, file_id)
    file_path = await storage.download_path(file_record.storage_path)
    return FileResponse(
        path=str(file_path),
        filename=file_record.original_name,
        media_type=file_record.mime_type,
    )


@router.delete("/{file_id}", status_code=204)
async def delete_file(
    file_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    await file_service.delete_file(db, current_user, file_id)