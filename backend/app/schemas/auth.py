from typing import Optional
from pydantic import BaseModel, EmailStr, Field


class UserRegister(BaseModel):
    email: EmailStr
    password: str = Field(..., min_length=8, max_length=128)
    display_name: str = Field(..., min_length=1, max_length=128)
    device_id: Optional[str] = Field(default=None, max_length=255)


class UserLogin(BaseModel):
    email: EmailStr
    password: str
    device_id: Optional[str] = Field(default=None, max_length=255)


class GoogleAuthRequest(BaseModel):
    id_token: str = Field(..., description="Google ID token from client SDK")
    device_id: Optional[str] = Field(default=None, max_length=255)


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"


class RefreshRequest(BaseModel):
    refresh_token: str


class LogoutRequest(BaseModel):
    refresh_token: str


class UserResponse(BaseModel):
    id: str
    email: str
    display_name: str
    is_active: bool
    created_at: str

    model_config = {"from_attributes": True}