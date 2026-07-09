from datetime import datetime
from pydantic import BaseModel, Field
from typing import Optional


class NotebookCreate(BaseModel):
    name: str = Field(..., min_length=1, max_length=255)
    parent_id: Optional[str] = None
    sort_order: int = Field(default=0)


class NotebookUpdate(BaseModel):
    name: Optional[str] = Field(default=None, min_length=1, max_length=255)
    parent_id: Optional[str] = None
    sort_order: Optional[int] = None


class NotebookResponse(BaseModel):
    id: str
    user_id: str
    name: str
    parent_id: Optional[str] = None
    sort_order: int
    is_deleted: bool
    created_at: str
    updated_at: str
    children: list["NotebookResponse"] = Field(default_factory=list)

    model_config = {"from_attributes": True}