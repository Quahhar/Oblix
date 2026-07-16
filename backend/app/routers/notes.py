from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession
from typing import Optional
from app.database import get_db
from app.schemas.note import NoteCreate, NoteUpdate, NoteResponse, NoteListResponse
from app.services.note_service import note_service
from app.utils.auth_dependency import get_current_user
from app.models.user import User

router = APIRouter(prefix="/notes", tags=["notes"])


@router.get("", response_model=NoteListResponse)
async def list_notes(
    notebook_id: Optional[str] = Query(None),
    tag_id: Optional[str] = Query(None),
    is_archived: bool = Query(False),
    is_deleted: bool = Query(False),
    search: Optional[str] = Query(None),
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=200),
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    result = await note_service.list_notes(
        db, current_user,
        notebook_id=notebook_id,
        tag_id=tag_id,
        is_archived=is_archived,
        is_deleted=is_deleted,
        search=search,
        page=page,
        page_size=page_size,
    )
    return result


@router.post("", response_model=NoteResponse, status_code=201)
async def create_note(
    data: NoteCreate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    note = await note_service.create_note(db, current_user, data)
    return note


@router.get("/{note_id}", response_model=NoteResponse)
async def get_note(
    note_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    note = await note_service.get_note(db, current_user, note_id)
    return note


@router.put("/{note_id}", response_model=NoteResponse)
async def update_note(
    note_id: str,
    data: NoteUpdate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    note = await note_service.update_note(db, current_user, note_id, data)
    return note


@router.delete("/{note_id}", status_code=204)
async def delete_note(
    note_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    await note_service.delete_note(db, current_user, note_id)


@router.post("/{note_id}/restore", response_model=NoteResponse)
async def restore_note(
    note_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    note = await note_service.restore_note(db, current_user, note_id)
    return note