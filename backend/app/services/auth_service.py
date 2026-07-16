import uuid
from datetime import datetime, timezone, timedelta
from typing import Optional
from sqlalchemy import select, update, func
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from fastapi import HTTPException, status
from starlette.concurrency import run_in_threadpool
from app.config import settings
from app.models.user import User
from app.models.session import Session
from app.schemas.auth import UserRegister, ProfileUpdate
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
            "access_token": create_access_token(str(user.id), str(session.id)),
            "refresh_token": create_refresh_token(str(user.id), str(session.id), session.expires_at),
            "token_type": "bearer",
        }

    async def register(self, db: AsyncSession, data: UserRegister, device_id: Optional[str] = None) -> dict:
        """Register a new user with email/password."""
        # Normalize to lower-case so casing can't create duplicate accounts.
        email = data.email.strip().lower()
        result = await db.execute(select(User).where(func.lower(User.email) == email))
        if result.scalars().first():
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email already registered")

        # bcrypt is CPU-bound (~100ms by design); run it off the event loop so
        # one signup can't stall every in-flight request.
        hashed = await run_in_threadpool(hash_password, data.password)
        user = User(
            id=uuid.uuid4(),
            email=email,
            hashed_password=hashed,
            display_name=data.display_name,
        )
        db.add(user)
        try:
            await db.flush()
        except IntegrityError:
            # Lost the check-then-insert race (a concurrent request or a client
            # retry of a register that already succeeded) and hit the unique
            # email constraint. Surface the same clean 409 the pre-check gives,
            # not a 500. The session is in a failed state now, so roll back
            # before returning so get_db doesn't try to commit a poisoned tx.
            await db.rollback()
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email already registered")
        return await self._issue_tokens(db, user, device_id)

    async def login(self, db: AsyncSession, email: str, password: str, device_id: Optional[str] = None) -> dict:
        """Authenticate user with email/password."""
        email = (email or "").strip().lower()
        result = await db.execute(select(User).where(func.lower(User.email) == email))
        user = result.scalars().first()

        # Off the event loop: bcrypt verify is as expensive as hashing.
        ok = bool(user and user.hashed_password) and await run_in_threadpool(
            verify_password, password, user.hashed_password
        )
        if not ok:
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
            # verify_oauth2_token does blocking HTTP (fetching Google's certs on
            # cache miss) — keep it off the event loop.
            idinfo = await run_in_threadpool(
                g_id_token.verify_oauth2_token, id_token, requests.Request(), settings.GOOGLE_CLIENT_ID
            )
            google_id = idinfo["sub"]
            email = idinfo.get("email", "").strip().lower()
            # Google sends email_verified as a bool, but be tolerant of the
            # string form ("true") some token variants use.
            ev = idinfo.get("email_verified")
            email_verified = ev is True or str(ev).lower() == "true"
            # `.get("name") or ...` (not `.get("name", default)`): Google may send
            # the key present-but-null (e.g. no profile scope), and display_name
            # is NOT NULL — a None here would 500 the first Google sign-in.
            display_name = idinfo.get("name") or (email.split("@")[0] if email else None) or "User"
        except Exception:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid Google ID token")

        if not email:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Google account has no email")

        # Match on google_id first, then email. Two separate lookups (instead of
        # an OR + scalar_one_or_none) so that a google-id user and a *different*
        # email user both matching cannot raise MultipleResultsFound → 500.
        user = (await db.execute(select(User).where(User.google_id == google_id))).scalars().first()
        if user is None:
            # No prior sign-in with this exact Google identity (`sub`). Both of the
            # remaining paths — linking onto an existing same-email account, or
            # creating a fresh account — TRUST the email address. Google lets
            # anyone create an account with an arbitrary, unverified email, so
            # without this gate an attacker could assert a victim's email and take
            # over their existing password account (or squat a new one under it).
            # A returning google_id user above is unaffected: `sub` is proof enough.
            if not email_verified:
                raise HTTPException(
                    status_code=status.HTTP_401_UNAUTHORIZED,
                    detail="Google email is not verified",
                )
            user = (await db.execute(select(User).where(func.lower(User.email) == email))).scalars().first()

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
            # A rotated (revoked) token was replayed. This is EITHER a benign
            # client retry (the rotation response was lost on a flaky network, so
            # the client re-sent the same refresh token) OR real token theft.
            # Telling them apart matters: nuking every session on a dropped
            # response logs the user out of all their devices for no reason.
            #
            # Benign retry ⇢ the replay lands within a short grace window and the
            # successor session we minted is still unused. In that case re-hand
            # the successor's tokens (idempotent — the client ends up with the
            # pair it should have received). Anything else — a stale replay, or a
            # successor that has itself already been rotated (a real fork) — is
            # treated as reuse and revokes the whole family.
            grace = timedelta(seconds=settings.REFRESH_REUSE_GRACE_SECONDS)
            successor = None
            if session.replaced_by is not None and session.revoked_at > now - grace:
                successor = (await db.execute(
                    select(Session).where(Session.id == session.replaced_by)
                )).scalar_one_or_none()
            if successor is not None and successor.revoked_at is None and successor.expires_at > now:
                return {
                    "access_token": create_access_token(str(session.user_id), str(successor.id)),
                    "refresh_token": create_refresh_token(
                        str(session.user_id), str(successor.id), successor.expires_at
                    ),
                    "token_type": "bearer",
                }
            # Commit before raising: get_db() rolls back on any exception, which
            # would otherwise silently undo this security-critical revocation.
            await self._revoke_all(db, session.user_id)
            await db.commit()
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Refresh token reuse detected")
        if session.expires_at <= now:
            session.revoked_at = now
            await db.commit()
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
            "access_token": create_access_token(str(user.id), str(new_session.id)),
            "refresh_token": create_refresh_token(str(user.id), str(new_session.id), new_session.expires_at),
            "token_type": "bearer",
        }

    async def change_password(
        self,
        db: AsyncSession,
        user: User,
        current_password: str,
        new_password: str,
        device_id: Optional[str] = None,
    ) -> dict:
        """Verify the current password, set the new one, and revoke every session.

        Revoking all sessions is the point: if the user is changing their
        password because it leaked, any device holding stolen tokens is cut off.
        The caller gets a fresh pair so *this* device stays signed in.
        """
        if not user.hashed_password:
            # Google-only account: there is no password to change.
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="This account uses Google sign-in and has no password",
            )
        ok = await run_in_threadpool(verify_password, current_password, user.hashed_password)
        if not ok:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Current password is incorrect",
            )
        user.hashed_password = await run_in_threadpool(hash_password, new_password)
        await self._revoke_all(db, user.id)
        return await self._issue_tokens(db, user, device_id)

    async def update_profile(self, db: AsyncSession, user: User, data: ProfileUpdate) -> User:
        """Update mutable profile fields (currently just display_name)."""
        if "display_name" in data.model_fields_set and data.display_name is not None:
            name = data.display_name.strip()
            if not name:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail="display_name cannot be blank",
                )
            user.display_name = name
        await db.flush()
        return user

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
