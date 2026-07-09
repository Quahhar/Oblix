from pydantic import BaseModel, Field
from typing import Optional


class FileResponse(BaseModel):
    id: str
    user_id: str
    note_id: Optional[str] = None
    filename: str
    original_name: str
    mime_type: str
    size_bytes: int
    storage_path: str
    is_deleted: bool
    created_at: str
    updated_at: str

    model_config = {"from_attributes": True}