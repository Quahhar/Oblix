from datetime import datetime, timedelta, timezone
from typing import Optional
import jwt
from jwt import InvalidTokenError
from passlib.context import CryptContext
from app.config import settings

# bcrypt silently ignores password bytes after byte 72. bcrypt_sha256
# pre-hashes first, preserving the full password while still using bcrypt as
# the work factor. Keep plain bcrypt verification for existing accounts; every
# newly set password uses bcrypt_sha256.
pwd_context = CryptContext(
    schemes=["bcrypt_sha256", "bcrypt"],
    deprecated=["bcrypt"],
)


def hash_password(password: str) -> str:
    return pwd_context.hash(password)


def verify_password(plain_password: str, hashed_password: str) -> bool:
    return pwd_context.verify(plain_password, hashed_password)


def verify_and_update_password(
    plain_password: str, hashed_password: str
) -> tuple[bool, Optional[str]]:
    """Verify and return an upgraded hash for legacy bcrypt credentials."""
    return pwd_context.verify_and_update(plain_password, hashed_password)


def create_access_token(user_id: str, session_id: str, expires_delta: Optional[timedelta] = None) -> str:
    # Bind the access token to its session (jti) so revoking the session
    # (logout / logout-all / refresh rotation) also invalidates this token.
    to_encode = {"sub": str(user_id), "type": "access", "jti": str(session_id)}
    expire = datetime.now(timezone.utc) + (expires_delta or timedelta(minutes=settings.ACCESS_TOKEN_EXPIRE_MINUTES))
    to_encode["exp"] = expire
    return jwt.encode(to_encode, settings.SECRET_KEY, algorithm=settings.ALGORITHM)


def refresh_token_expiry() -> datetime:
    """Absolute expiry for a newly issued refresh token."""
    return datetime.now(timezone.utc) + timedelta(days=settings.REFRESH_TOKEN_EXPIRE_DAYS)


def create_refresh_token(user_id: str, jti: str, expires_at: datetime) -> str:
    """Create a refresh token bound to a server-side session (`jti`).

    The token is only trusted while its matching Session row is unrevoked and
    unexpired, so refresh tokens can be revoked and rotated server-side.
    """
    to_encode = {"sub": str(user_id), "type": "refresh", "jti": str(jti), "exp": expires_at}
    return jwt.encode(to_encode, settings.SECRET_KEY, algorithm=settings.ALGORITHM)


def decode_token(token: str) -> Optional[dict]:
    try:
        payload = jwt.decode(token, settings.SECRET_KEY, algorithms=[settings.ALGORITHM])
        return payload
    except InvalidTokenError:
        return None


def verify_access_token(token: str) -> Optional[str]:
    """Returns user_id if valid access token, else None."""
    payload = decode_token(token)
    if payload is None or payload.get("type") != "access":
        return None
    return payload.get("sub")
