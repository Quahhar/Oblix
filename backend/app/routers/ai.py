import uuid

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.models.note import Note
from app.models.user import User
from app.schemas.ai import SummarizeRequest, SummarizeResponse, AIStatusResponse
from app.services.ai_service import ai_service
from app.services.share_service import share_service
from app.utils.auth_dependency import get_current_user
from app.utils.rate_limit import ai_limiter

router = APIRouter(prefix="/ai", tags=["ai"])


@router.get("/status", response_model=AIStatusResponse)
async def ai_status(current_user: User = Depends(get_current_user)):
    """Whether AI features are configured, so the client can show/hide them."""
    return AIStatusResponse(enabled=ai_service.enabled, model=ai_service.model)


@router.post("/summarize", response_model=SummarizeResponse)
async def summarize(
    data: SummarizeRequest,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Summarize a note the caller owns or that is shared with them."""
    try:
        note_uuid = uuid.UUID(data.note_id)
    except (ValueError, TypeError):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Note not found")
    note = (await db.execute(
        select(Note).where(Note.id == note_uuid, Note.is_deleted == False)  # noqa: E712
    )).scalar_one_or_none()
    if note is None or await share_service.note_role(db, current_user, note) is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Note not found")

    # Quota only after access checks, so probing can't burn a user's budget —
    # and keyed by user id: AI spend belongs to the account, not the IP.
    ai_limiter.check(f"ai|{current_user.id}")
    summary = await ai_service.summarize_note(note, data.style)
    return SummarizeResponse(note_id=note.id, summary=summary, model=ai_service.model or "")
