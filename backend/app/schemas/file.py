import uuid
from datetime import datetime
from pydantic import BaseModel, Field
from typing import Optional


class FileResponse(BaseModel):
    id: uuid.UUID
    user_id: uuid.UUID
    note_id: Optional[uuid.UUID] = None
    filename: str
    original_name: str
    mime_type: str
    size_bytes: int
    # storage_path is deliberately NOT exposed: it embeds the internal layout
    # and the owner's raw user id, and the client never needs it.
    is_deleted: bool
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}