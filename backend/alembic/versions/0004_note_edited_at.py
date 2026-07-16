"""Add notes.edited_at for sync last-write-wins comparison.

Separate from updated_at (the server-controlled sync cursor): edited_at holds
the client's own last-edit time so conflict resolution compares edit-time vs
edit-time. Nullable — existing rows fall back to updated_at until first edited.

Revision ID: 0004_note_edited_at
Revises: 0003_file_size_bigint
Create Date: 2026-07-13
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0004_note_edited_at"
down_revision: Union[str, None] = "0003_file_size_bigint"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "notes",
        sa.Column("edited_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("notes", "edited_at")
