import os
import uuid
from pathlib import Path
from typing import Optional

from fastapi import (
    APIRouter, Depends, UploadFile, File as FastAPIFile, Query, HTTPException, status,
)
from fastapi.responses import FileResponse as FileDownloadResponse
from starlette.background import BackgroundTask
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.database import get_db
from app.models.user import User
from app.models.notebook import Notebook
from app.schemas.transfer import ImportSummary
from app.services.transfer_service import transfer_service, _BadImport
from app.utils.auth_dependency import get_current_user

router = APIRouter(tags=["import-export"])


async def _read_capped(file: UploadFile) -> bytes:
    """Read an upload fully into memory, aborting past the import size cap."""
    max_bytes = settings.MAX_IMPORT_SIZE_MB * 1024 * 1024
    chunks, size = [], 0
    while chunk := await file.read(1024 * 1024):
        size += len(chunk)
        if size > max_bytes:
            raise HTTPException(
                status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                detail=f"Import exceeds the {settings.MAX_IMPORT_SIZE_MB} MB limit",
            )
        chunks.append(chunk)
    return b"".join(chunks)


@router.get("/export/oblix")
async def export_oblix(
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Download all of the caller's live notes as a portable .oblix archive."""
    tmp_path, download_name = await transfer_service.export_oblix(db, current_user)
    return FileDownloadResponse(
        path=tmp_path,
        filename=download_name,
        media_type="application/zip",
        background=BackgroundTask(os.unlink, tmp_path),
    )


@router.post("/import/oblix", response_model=ImportSummary)
async def import_oblix(
    file: UploadFile = FastAPIFile(...),
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    data = await _read_capped(file)
    try:
        return await transfer_service.import_oblix(db, current_user, data)
    except _BadImport as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.post("/import/enex", response_model=ImportSummary)
async def import_enex(
    file: UploadFile = FastAPIFile(...),
    notebook_id: Optional[uuid.UUID] = Query(
        None, description="Existing notebook to import into; a new one is created if omitted."
    ),
    notebook_name: Optional[str] = Query(
        None, description="Name for the notebook created when notebook_id is omitted."
    ),
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    target_id = await _resolve_import_notebook(db, current_user, notebook_id, notebook_name, file.filename)
    data = await _read_capped(file)
    try:
        return await transfer_service.import_enex(db, current_user, data, target_id)
    except _BadImport as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


async def _resolve_import_notebook(
    db: AsyncSession, user: User, notebook_id: Optional[uuid.UUID],
    notebook_name: Optional[str], filename: Optional[str],
) -> uuid.UUID:
    """Validate the caller's notebook, or create one to hold the import."""
    if notebook_id is not None:
        ok = (await db.execute(
            select(Notebook.id).where(
                Notebook.id == notebook_id,
                Notebook.user_id == user.id,
                Notebook.is_deleted == False,  # noqa: E712
            )
        )).scalar_one_or_none()
        if ok is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Notebook not found")
        return notebook_id

    name = (notebook_name or (Path(filename).stem if filename else None) or "Imported (Evernote)")[:255]
    nb = Notebook(id=uuid.uuid4(), user_id=user.id, name=name)
    db.add(nb)
    await db.flush()
    return nb.id
