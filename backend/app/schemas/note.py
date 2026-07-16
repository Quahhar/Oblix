import uuid
from datetime import datetime
from pydantic import BaseModel, Field, field_validator
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
    id: uuid.UUID
    name: str

    model_config = {"from_attributes": True}


class NoteVersionResponse(BaseModel):
    id: uuid.UUID
    title: str
    content: str
    content_type: str
    version_number: int
    created_at: datetime

    model_config = {"from_attributes": True}


class NoteResponse(BaseModel):
    id: uuid.UUID
    user_id: uuid.UUID
    notebook_id: Optional[uuid.UUID] = None
    title: str
    content: str
    content_type: str
    is_pinned: bool
    is_archived: bool
    is_deleted: bool
    created_at: datetime
    updated_at: datetime
    tags: list[TagResponse] = Field(default_factory=list)
    versions: list[NoteVersionResponse] = Field(default_factory=list)

    model_config = {"from_attributes": True}

    @field_validator("tags", mode="before")
    @classmethod
    def _unwrap_note_tags(cls, value):
        # Note.tags is a list of NoteTag association rows; expose the underlying
        # Tag (skipping soft-deleted ones) so it matches the TagResponse shape.
        if not value:
            return value
        unwrapped = []
        for item in value:
            tag = getattr(item, "tag", item)
            if tag is not None and not getattr(tag, "is_deleted", False):
                unwrapped.append(tag)
        return unwrapped


class NoteListResponse(BaseModel):
    notes: list[NoteResponse]
    total: int
    page: int
    page_size: int