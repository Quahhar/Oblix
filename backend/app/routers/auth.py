from fastapi import APIRouter, Depends, Request, status
from sqlalchemy.ext.asyncio import AsyncSession
from app.database import get_db
from app.schemas.auth import (
    UserRegister,
    UserLogin,
    GoogleAuthRequest,
    TokenResponse,
    RefreshRequest,
    LogoutRequest,
    ChangePasswordRequest,
    ProfileUpdate,
    UserResponse,
)
from app.services.auth_service import auth_service
from app.utils.auth_dependency import get_current_user
from app.utils.rate_limit import client_ip, login_limiter, register_limiter, google_limiter
from app.models.user import User

router = APIRouter(prefix="/auth", tags=["auth"])


def _user_response(user: User) -> UserResponse:
    return UserResponse(
        id=str(user.id),
        email=user.email,
        display_name=user.display_name,
        is_active=user.is_active,
        created_at=user.created_at.isoformat(),
    )


@router.post("/register", response_model=TokenResponse, status_code=201)
async def register(data: UserRegister, request: Request, db: AsyncSession = Depends(get_db)):
    register_limiter.check(client_ip(request))
    return await auth_service.register(db, data, device_id=data.device_id)


@router.post("/login", response_model=TokenResponse)
async def login(data: UserLogin, request: Request, db: AsyncSession = Depends(get_db)):
    # Keyed per (client, email) so an attacker can't brute-force one account,
    # and can't lock a victim out from a different IP either.
    login_limiter.check(f"{client_ip(request)}|{data.email.lower()}")
    return await auth_service.login(db, data.email, data.password, device_id=data.device_id)


@router.post("/google", response_model=TokenResponse)
async def google_login(data: GoogleAuthRequest, request: Request, db: AsyncSession = Depends(get_db)):
    google_limiter.check(client_ip(request))
    return await auth_service.google_auth(db, data.id_token, device_id=data.device_id)


@router.post("/refresh", response_model=TokenResponse)
async def refresh(data: RefreshRequest, db: AsyncSession = Depends(get_db)):
    return await auth_service.refresh_token(db, data.refresh_token)


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(data: LogoutRequest, db: AsyncSession = Depends(get_db)):
    """Revoke the session behind this refresh token (this device only)."""
    await auth_service.logout(db, data.refresh_token)


@router.post("/logout-all", status_code=status.HTTP_204_NO_CONTENT)
async def logout_all(
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Sign out of all devices by revoking every session for the user."""
    await auth_service.logout_all(db, current_user)


@router.post("/change-password", response_model=TokenResponse)
async def change_password(
    data: ChangePasswordRequest,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Change the password; revokes every session and returns a fresh token pair."""
    return await auth_service.change_password(
        db, current_user, data.current_password, data.new_password, device_id=data.device_id
    )


@router.get("/me", response_model=UserResponse)
async def get_me(current_user: User = Depends(get_current_user)):
    return _user_response(current_user)


@router.put("/me", response_model=UserResponse)
async def update_me(
    data: ProfileUpdate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    user = await auth_service.update_profile(db, current_user, data)
    return _user_response(user)
