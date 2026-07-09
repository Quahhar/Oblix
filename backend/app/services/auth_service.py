import uuid
from datetime import datetime, timezone
from typing import Optional
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession
from fastapi import HTTPException, status
from app.models.user import User
from app.models.session import Session
from app.schemas.auth import UserRegister
from app.utils.security import (
    hash_password,
    verify_password,
    create_access_token,
    create_refresh_token,
    refresh_token_expiry,
    decode_token,
)


class AuthService:

    async def _issue_tokens(self, db: AsyncSession, user: User, device_id: Optional[str] = None) -> dict:
        """Create a new session row and mint an access+refresh token pair for it."""
        session = Session(
            id=uuid.uuid4(),
            user_id=user.id,
            device_id=device_id,
            expires_at=refresh_token_expiry(),
        )
        db.add(session)
        await db.flush()
        return {
            "access_token": create_access_token(str(user.id)),
            "refresh_token": create_refresh_token(str(user.id), str(session.id), session.expires_at),
            "token_type": "bearer",
        }

    async def register(self, db: AsyncSession, data: UserRegister, device_id: Optional[str] = None) -> dict:
        """Register a new user with email/password."""
        result = await db.execute(select(User).where(User.email == data.email))
        if result.scalar_one_or_none():
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email already registered")

        user = User(
            id=uuid.uuid4(),
            email=data.email,
            hashed_password=hash_password(data.password),
            display_name=data.display_name,
        )
        db.add(user)
        await db.flush()
        return await self._issue_tokens(db, user, device_id)

    async def login(self, db: AsyncSession, email: str, password: str, device_id: Optional[str] = None) -> dict:
        """Authenticate user with email/password."""
        result = await db.execute(select(User).where(User.email == email))
        user = result.scalar_one_or_none()

        if not user or not user.hashed_password or not verify_password(password, user.hashed_password):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid email or password")

        if not user.is_active:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Account is disabled")

        return await self._issue_tokens(db, user, device_id)

    async def google_auth(self, db: AsyncSession, id_token: str, device_id: Optional[str] = None) -> dict:
        """Authenticate or register using Google ID token."""
        from google.oauth2 import id_token as g_id_token
        from google.auth.transport import requests
        from app.config import settings

        try:
            idinfo = g_id_token.verify_oauth2_token(id_token, requests.Request(), settings.GOOGLE_CLIENT_ID)
            google_id = idinfo["sub"]
            email = idinfo.get("email", "")
            display_name = idinfo.get("name", email.split("@")[0] if email else "User")
        except Exception:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid Google ID token")

        if not email:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Google account has no email")

        result = await db.execute(select(User).where((User.google_id == google_id) | (User.email == email)))
        user = result.scalar_one_or_none()

        if user:
            if not user.google_id:
                user.google_id = google_id
            user.display_name = display_name or user.display_name
        else:
            user = User(
                id=uuid.uuid4(),
                email=email,
                google_id=google_id,
                display_name=display_name,
            )
            db.add(user)

        await db.flush()
        return await self._issue_tokens(db, user, device_id)

    async def refresh_token(self, db: AsyncSession, refresh_token: str) -> dict:
        """Rotate a refresh token: validate the session, revoke it, issue a new one.

        Reuse of an already-revoked (rotated) token is treated as theft: every
        session for that user is revoked.
        """
        payload = decode_token(refresh_token)
        if not payload or payload.get("type") != "refresh" or not payload.get("jti"):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid refresh token")

        try:
            session_id = uuid.UUID(payload["jti"])
        except (ValueError, TypeError):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid refresh token")

        session = (await db.execute(select(Session).where(Session.id == session_id))).scalar_one_or_none()
        if session is None:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid refresh token")

        now = datetime.now(timezone.utc)
        if session.revoked_at is not None:
            # A rotated (revoked) token was replayed → likely stolen. Revoke the
            # whole family so neither party can keep using it.
            await self._revoke_all(db, session.user_id)
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Refresh token reuse detected")
        if session.expires_at <= now:
            session.revoked_at = now
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Refresh token expired")

        user = (await db.execute(
            select(User).where(User.id == session.user_id, User.is_active == True)  # noqa: E712
        )).scalar_one_or_none()
        if not user:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="User not found or inactive")

        # Rotate: revoke the old session and mint a new one carrying the device id.
        new_session = Session(
            id=uuid.uuid4(),
            user_id=user.id,
            device_id=session.device_id,
            expires_at=refresh_token_expiry(),
        )
        db.add(new_session)
        session.revoked_at = now
        session.replaced_by = new_session.id
        await db.flush()

        return {
            "access_token": create_access_token(str(user.id)),
            "refresh_token": create_refresh_token(str(user.id), str(new_session.id), new_session.expires_at),
            "token_type": "bearer",
        }

    async def logout(self, db: AsyncSession, refresh_token: str) -> None:
        """Revoke the session behind a refresh token. Idempotent and never errors."""
        payload = decode_token(refresh_token)
        if not payload or not payload.get("jti"):
            return
        try:
            session_id = uuid.UUID(payload["jti"])
        except (ValueError, TypeError):
            return
        session = (await db.execute(select(Session).where(Session.id == session_id))).scalar_one_or_none()
        if session and session.revoked_at is None:
            session.revoked_at = datetime.now(timezone.utc)

    async def logout_all(self, db: AsyncSession, user: User) -> None:
        """Revoke every active session for a user (sign out of all devices)."""
        await self._revoke_all(db, user.id)

    @staticmethod
    async def _revoke_all(db: AsyncSession, user_id: uuid.UUID) -> None:
        await db.execute(
            update(Session)
            .where(Session.user_id == user_id, Session.revoked_at.is_(None))
            .values(revoked_at=datetime.now(timezone.utc))
        )

    async def get_user(self, db: AsyncSession, user_id: str) -> Optional[User]:
        result = await db.execute(select(User).where(User.id == user_id))
        return result.scalar_one_or_none()


auth_service = AuthService()
