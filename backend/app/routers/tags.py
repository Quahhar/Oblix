from datetime import datetime, timezone

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from app.database import get_db
from app.models.tag import Tag
from app.schemas.tag import TagCreate, TagResponse
from app.utils.auth_dependency import get_current_user
from app.models.user import User
from fastapi import HTTPException, status
import uuid

router = APIRouter(prefix="/tags", tags=["tags"])


@router.get("", response_model=list[TagResponse])
async def list_tags(
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    result = await db.execute(
        select(Tag)
        .where(Tag.user_id == current_user.id, Tag.is_deleted == False)  # noqa: E712
        .order_by(Tag.name)
    )
    tags = result.scalars().all()
    return tags


@router.post("", response_model=TagResponse, status_code=201)
async def create_tag(
    data: TagCreate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    existing_result = await db.execute(
        select(Tag).where(Tag.user_id == current_user.id, Tag.name == data.name)
    )
    existing = existing_result.scalar_one_or_none()
    if existing:
        if not existing.is_deleted:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Tag with this name already exists")
        # Reusing a tombstoned name resurrects the tag (keeps its id stable
        # for clients that still hold it).
        existing.is_deleted = False
        existing.deleted_at = None
        existing.updated_at = datetime.now(timezone.utc)
        await db.flush()
        await db.refresh(existing)
        return existing

    tag = Tag(
        id=uuid.uuid4(),
        user_id=current_user.id,
        name=data.name,
    )
    db.add(tag)
    await db.flush()
    await db.refresh(tag)
    return tag


@router.delete("/{tag_id}", status_code=204)
async def delete_tag(
    tag_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    result = await db.execute(
        select(Tag).where(Tag.id == tag_id, Tag.user_id == current_user.id)
    )
    tag = result.scalar_one_or_none()
    if not tag or tag.is_deleted:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Tag not found")

    # Tombstone so the deletion reaches other devices through sync.
    tag.is_deleted = True
    tag.deleted_at = datetime.now(timezone.utc)
    tag.updated_at = datetime.now(timezone.utc)
    await db.flush()
