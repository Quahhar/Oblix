from fastapi import APIRouter, Depends, status
from sqlalchemy.ext.asyncio import AsyncSession
from app.database import get_db
from app.schemas.auth import (
    UserRegister,
    UserLogin,
    GoogleAuthRequest,
    TokenResponse,
    RefreshRequest,
    LogoutRequest,
    UserResponse,
)
from app.services.auth_service import auth_service
from app.utils.auth_dependency import get_current_user
from app.models.user import User

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/register", response_model=TokenResponse, status_code=201)
async def register(data: UserRegister, db: AsyncSession = Depends(get_db)):
    return await auth_service.register(db, data, device_id=data.device_id)


@router.post("/login", response_model=TokenResponse)
async def login(data: UserLogin, db: AsyncSession = Depends(get_db)):
    return await auth_service.login(db, data.email, data.password, device_id=data.device_id)


@router.post("/google", response_model=TokenResponse)
async def google_login(data: GoogleAuthRequest, db: AsyncSession = Depends(get_db)):
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


@router.get("/me", response_model=UserResponse)
async def get_me(current_user: User = Depends(get_current_user)):
    return UserResponse(
        id=str(current_user.id),
        email=current_user.email,
        display_name=current_user.display_name,
        is_active=current_user.is_active,
        created_at=current_user.created_at.isoformat(),
    )
