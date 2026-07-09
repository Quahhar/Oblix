from pydantic import BaseModel, Field
from typing import Optional
from datetime import datetime
from app.models.note import ContentType


class SyncChangeItem(BaseModel):
    entity_type: str = Field(..., pattern="^(note|notebook|tag|file)$")
    entity_id: str
    action: str = Field(..., pattern="^(create|update|delete)$")
    data: dict = Field(default_factory=dict)
    device_id: Optional[str] = None
    timestamp: str  # ISO 8601


class SyncPushRequest(BaseModel):
    changes: list[SyncChangeItem]
    last_sync_at: Optional[str] = None  # ISO 8601


class SyncConflict(BaseModel):
    entity_type: str
    entity_id: str
    server_data: dict
    client_data: dict
    reason: str


class SyncPushResponse(BaseModel):
    applied: list[str]  # entity IDs successfully applied
    conflicts: list[SyncConflict]
    server_changes: list[dict]  # entities that changed since last_sync_at
    server_time: str  # cursor the client should adopt for its next sync


class SyncPullRequest(BaseModel):
    since: Optional[str] = None  # ISO 8601 timestamp
    entity_types: Optional[list[str]] = None  # filter by entity types


class SyncPullResponse(BaseModel):
    changes: list[dict]
    server_time: str  # Current server timestamp for next sync