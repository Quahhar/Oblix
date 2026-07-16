"""Request/response shapes for note import & export.

The .oblix archive format itself (manifest.json / notes.json) is defined in
app/services/transfer_service.py — these are just the API envelopes.
"""
import uuid
from pydantic import BaseModel, Field


class ImportSummary(BaseModel):
    """Result of importing an .enex or .oblix file."""
    notebook_id: uuid.UUID | None = None
    imported_notes: int = 0
    imported_tags: int = 0
    imported_files: int = 0
    skipped_files: int = 0
    skipped_notes: int = 0
    warnings: list[str] = Field(default_factory=list)
