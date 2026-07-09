from datetime import datetime
from pydantic import BaseModel, Field
from typing import Optional
from app.models.note import ContentType


class NoteCreate(BaseModel):
    title: str = Field(default="Untitled", max_length=500)
    content: str = Field(default="")
    content_type: ContentType = Field(default=ContentType.PLAIN)
    notebook_id: Optional[str] = None
    tag_ids: list[str] = Field(default_factory=list)


class NoteUpdate(BaseModel):
    title: Optional[str] = Field(default=None, max_length=500)
    content: Optional[str] = None
    content_type: Optional[ContentType] = None
    notebook_id: Optional[str] = None
    is_pinned: Optional[bool] = None
    is_archived: Optional[bool] = None
    tag_ids: Optional[list[str]] = None


class TagResponse(BaseModel):
    id: str
    name: str

    model_config = {"from_attributes": True}


class NoteVersionResponse(BaseModel):
    id: str
    title: str
    content: str
    content_type: str
    version_number: int
    created_at: str

    model_config = {"from_attributes": True}


class NoteResponse(BaseModel):
    id: str
    user_id: str
    notebook_id: Optional[str] = None
    title: str
    content: str
    content_type: str
    is_pinned: bool
    is_archived: bool
    is_deleted: bool
    created_at: str
    updated_at: str
    tags: list[TagResponse] = Field(default_factory=list)
    versions: list[NoteVersionResponse] = Field(default_factory=list)

    model_config = {"from_attributes": True}


class NoteListResponse(BaseModel):
    notes: list[NoteResponse]
    total: int
    page: int
    page_size: int