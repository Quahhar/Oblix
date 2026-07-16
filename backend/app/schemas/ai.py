import uuid
from typing import Literal, Optional
from pydantic import BaseModel


class SummarizeRequest(BaseModel):
    note_id: str
    style: Literal["short", "detailed", "bullets"] = "short"


class SummarizeResponse(BaseModel):
    note_id: uuid.UUID
    summary: str
    model: str


class AIStatusResponse(BaseModel):
    # Lets the client show/hide AI UI without a failed call.
    enabled: bool
    model: Optional[str] = None
