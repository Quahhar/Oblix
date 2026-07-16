import uuid
from datetime import datetime
from typing import Optional
from pydantic import BaseModel, Field


class TaskCreate(BaseModel):
    title: str = Field(..., min_length=1, max_length=500)
    description: str = Field(default="")
    note_id: Optional[str] = None
    due_date: Optional[datetime] = None
    sort_order: int = 0


class TaskUpdate(BaseModel):
    # All optional; omitted = unchanged. note_id/due_date sent as explicit null
    # clear the link/date (model_fields_set, same contract as notes.notebook_id).
    title: Optional[str] = Field(default=None, min_length=1, max_length=500)
    description: Optional[str] = None
    note_id: Optional[str] = None
    due_date: Optional[datetime] = None
    is_completed: Optional[bool] = None
    sort_order: Optional[int] = None


class TaskResponse(BaseModel):
    id: uuid.UUID
    user_id: uuid.UUID
    note_id: Optional[uuid.UUID] = None
    title: str
    description: str
    is_completed: bool
    completed_at: Optional[datetime] = None
    due_date: Optional[datetime] = None
    sort_order: int
    is_deleted: bool
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class TaskListResponse(BaseModel):
    tasks: list[TaskResponse]
    total: int
    page: int
    page_size: int
