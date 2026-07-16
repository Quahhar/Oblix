from typing import Optional

from fastapi import APIRouter, Depends, Query, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.models.user import User
from app.schemas.note import NoteListResponse
from app.schemas.share import ShareCreate, ShareRoleUpdate, ShareResponse, SharedWithMeItem
from app.services.share_service import share_service
from app.utils.auth_dependency import get_current_user

router = APIRouter(prefix="/shares", tags=["shares"])


@router.post("", response_model=ShareResponse, status_code=201)
async def create_share(
    data: ShareCreate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Share one of my notes or notebooks with another user, by their email."""
    return await share_service.create_share(db, current_user, data)


@router.get("", response_model=list[ShareResponse])
async def list_shares(
    entity_type: Optional[str] = Query(None, pattern="^(note|notebook)$"),
    entity_id: Optional[str] = Query(None),
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Shares I have granted (optionally for one entity)."""
    return await share_service.list_shares(db, current_user, entity_type, entity_id)


@router.get("/with-me", response_model=list[SharedWithMeItem])
async def shared_with_me(
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Everything other users have shared with me."""
    return await share_service.shared_with_me(db, current_user)


@router.get("/notebook/{notebook_id}/notes", response_model=NoteListResponse)
async def shared_notebook_notes(
    notebook_id: str,
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=200),
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """List the notes in a notebook that is shared with me (or my own)."""
    return await share_service.shared_notebook_notes(db, current_user, notebook_id, page, page_size)


@router.put("/{share_id}", response_model=ShareResponse)
async def update_share(
    share_id: str,
    data: ShareRoleUpdate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Change a grantee's role on something I shared."""
    return await share_service.update_share_role(db, current_user, share_id, data.role)


@router.delete("/{share_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_share(
    share_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Revoke a share I granted, or leave something shared with me."""
    await share_service.delete_share(db, current_user, share_id)
