"""Tag soft delete (tombstones) so deletions propagate through sync.

Revision ID: 0002_tag_soft_delete
Revises: 0001_initial
Create Date: 2026-07-10
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0002_tag_soft_delete"
down_revision: Union[str, None] = "0001_initial"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "tags",
        sa.Column("is_deleted", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.add_column(
        "tags",
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_tags_is_deleted", "tags", ["is_deleted"])


def downgrade() -> None:
    op.drop_index("ix_tags_is_deleted", table_name="tags")
    op.drop_column("tags", "deleted_at")
    op.drop_column("tags", "is_deleted")
