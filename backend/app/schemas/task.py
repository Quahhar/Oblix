import uuid
from datetime import datetime
from typing import Optional
from pydantic import BaseModel, Field


# 0 none, 1 low, 2 high, 3 urgent. Matches the client's Rust ranks.
PRIORITY_MIN = 0
PRIORITY_MAX = 3

# A repetition rule such as FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH. The client's
# Rust core owns the grammar; the API stores and returns it unchanged so an
# older server never has to understand a newer rule to sync one.
RECURRENCE_MAX_LENGTH = 200

# Four weeks. Past this a "reminder before" is not what anyone means.
REMINDER_LEAD_MAX_MINUTES = 40_320


class TaskCreate(BaseModel):
    title: str = Field(..., min_length=1, max_length=500)
    description: str = Field(default="")
    note_id: Optional[str] = None
    notebook_id: Optional[str] = None
    parent_id: Optional[str] = None
    due_date: Optional[datetime] = None
    due_has_time: bool = False
    priority: int = Field(default=PRIORITY_MIN, ge=PRIORITY_MIN, le=PRIORITY_MAX)
    labels: list[str] = Field(default_factory=list, max_length=32)
    recurrence: Optional[str] = Field(default=None, max_length=RECURRENCE_MAX_LENGTH)
    reminder_at: Optional[datetime] = None
    reminder_lead_minutes: Optional[int] = Field(
        default=None, ge=0, le=REMINDER_LEAD_MAX_MINUTES
    )
    sort_order: int = 0


class TaskUpdate(BaseModel):
    # All optional; omitted = unchanged. note_id/notebook_id/parent_id/due_date
    # sent as explicit null clear the link/date (model_fields_set, same
    # contract as notes.notebook_id).
    title: Optional[str] = Field(default=None, min_length=1, max_length=500)
    description: Optional[str] = None
    note_id: Optional[str] = None
    notebook_id: Optional[str] = None
    parent_id: Optional[str] = None
    due_date: Optional[datetime] = None
    due_has_time: Optional[bool] = None
    priority: Optional[int] = Field(default=None, ge=PRIORITY_MIN, le=PRIORITY_MAX)
    labels: Optional[list[str]] = Field(default=None, max_length=32)
    recurrence: Optional[str] = Field(default=None, max_length=RECURRENCE_MAX_LENGTH)
    reminder_at: Optional[datetime] = None
    reminder_lead_minutes: Optional[int] = Field(
        default=None, ge=0, le=REMINDER_LEAD_MAX_MINUTES
    )
    is_completed: Optional[bool] = None
    sort_order: Optional[int] = None


class TaskResponse(BaseModel):
    id: uuid.UUID
    user_id: uuid.UUID
    note_id: Optional[uuid.UUID] = None
    notebook_id: Optional[uuid.UUID] = None
    parent_id: Optional[uuid.UUID] = None
    title: str
    description: str
    is_completed: bool
    completed_at: Optional[datetime] = None
    due_date: Optional[datetime] = None
    due_has_time: bool = False
    priority: int = PRIORITY_MIN
    labels: list[str] = Field(default_factory=list)
    recurrence: Optional[str] = None
    reminder_at: Optional[datetime] = None
    reminder_lead_minutes: Optional[int] = None
    sort_order: int
    is_deleted: bool
    created_at: datetime
    updated_at: datetime
    field_clocks: dict = Field(default_factory=dict)

    model_config = {"from_attributes": True}


class TaskListResponse(BaseModel):
    tasks: list[TaskResponse]
    total: int
    page: int
    page_size: int
