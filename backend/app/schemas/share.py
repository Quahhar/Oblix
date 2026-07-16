import uuid
from datetime import datetime
from typing import Literal, Optional
from pydantic import BaseModel, EmailStr


class ShareCreate(BaseModel):
    entity_type: Literal["note", "notebook"]
    entity_id: str
    email: EmailStr  # the grantee, looked up by (lower-cased) account email
    role: Literal["viewer", "editor"] = "viewer"


class ShareRoleUpdate(BaseModel):
    role: Literal["viewer", "editor"]


class ShareResponse(BaseModel):
    """A grant the caller has issued (owner's view of a share)."""
    id: uuid.UUID
    entity_type: str
    entity_id: uuid.UUID
    role: str
    grantee_email: str
    grantee_display_name: str
    created_at: datetime


class SharedWithMeItem(BaseModel):
    """One thing another user shared with the caller, with a display snapshot."""
    share_id: uuid.UUID
    entity_type: str
    entity_id: uuid.UUID
    role: str
    owner_email: str
    owner_display_name: str
    # Snapshot for list rendering: the note title or notebook name.
    name: str
    updated_at: datetime
    # Notes only: the notebook share that granted access has this None.
    content_type: Optional[str] = None
