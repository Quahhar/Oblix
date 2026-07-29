from datetime import timedelta

from passlib.context import CryptContext

from app.utils.security import (
    create_access_token,
    decode_token,
    hash_password,
    verify_password,
    verify_and_update_password,
)


def test_password_hash_preserves_bytes_after_bcrypt_limit():
    password = ("a" * 72) + "x"
    digest = hash_password(password)

    assert digest.startswith("$bcrypt-sha256$")
    assert verify_password(password, digest)
    assert not verify_password(("a" * 72) + "y", digest)


def test_existing_bcrypt_passwords_remain_valid():
    legacy = CryptContext(schemes=["bcrypt"]).hash("existing-password")

    assert verify_password("existing-password", legacy)
    verified, replacement = verify_and_update_password(
        "existing-password", legacy
    )
    assert verified
    assert replacement is not None
    assert replacement.startswith("$bcrypt-sha256$")


def test_access_token_is_session_bound():
    token = create_access_token(
        "user-id",
        "session-id",
        expires_delta=timedelta(minutes=1),
    )

    payload = decode_token(token)
    assert payload is not None
    assert payload["sub"] == "user-id"
    assert payload["jti"] == "session-id"
    assert payload["type"] == "access"
