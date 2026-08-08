import uuid
from datetime import datetime, timezone
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from app.database import get_db
from app.utils.security import decode_token
from app.models.user import User
from app.models.session import Session

bearer_scheme = HTTPBearer()


async def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(bearer_scheme),
    db: AsyncSession = Depends(get_db),
) -> User:
    """Validate the access token AND its backing session, then return the User.

    Verifying the session (jti) — not just the JWT signature — means logout,
    logout-all and refresh-rotation invalidate outstanding access tokens
    immediately, instead of leaving them usable until they expire.
    """
    return await authenticate_access_token(db, credentials.credentials)


async def authenticate_access_token(db: AsyncSession, token: str) -> User:
    """Shared HTTP/WebSocket access-token authentication."""
    payload = decode_token(token)
    if not payload or payload.get("type") != "access":
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid or expired token")

    user_id = payload.get("sub")
    jti = payload.get("jti")
    if not user_id or not jti:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid or expired token")

    try:
        session_id = uuid.UUID(str(jti))
        subject_id = uuid.UUID(str(user_id))
    except (ValueError, TypeError):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid or expired token")

    now = datetime.now(timezone.utc)
    # Session validity and the active user are checked in one indexed query.
    # This dependency runs on every authenticated HTTP request and WebSocket
    # admission, so avoiding the former second round trip materially reduces
    # database pressure without weakening immediate session revocation.
    user = (
        await db.execute(
            select(User)
            .join(Session, Session.user_id == User.id)
            .where(
                Session.id == session_id,
                Session.user_id == subject_id,
                Session.revoked_at.is_(None),
                Session.expires_at > now,
                User.is_active.is_(True),
            )
        )
    ).scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Session is no longer valid")

    return user
