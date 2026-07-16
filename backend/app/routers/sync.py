from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession
from typing import Optional
from app.database import get_db
from app.schemas.sync import SyncPushRequest, SyncPushResponse, SyncPullResponse
from app.services.sync_service import sync_service
from app.utils.auth_dependency import get_current_user
from app.models.user import User

router = APIRouter(prefix="/sync", tags=["sync"])


@router.post("/push", response_model=SyncPushResponse)
async def push_changes(
    data: SyncPushRequest,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    result = await sync_service.push_changes(db, current_user, data.changes, data.last_sync_at)
    return result


@router.get("/pull", response_model=SyncPullResponse)
async def pull_changes(
    since: Optional[str] = None,
    entity_types: Optional[str] = None,
    limit: Optional[int] = Query(None, ge=1, le=1000),
    cursor: Optional[str] = None,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    # Pagination is opt-in: omit `limit` for the original "everything" response;
    # pass `limit` (and the returned `next_cursor`) to page a large first sync.
    types_list = entity_types.split(",") if entity_types else None
    result = await sync_service.pull_changes(db, current_user, since, types_list, limit, cursor)
    return result