"""Add composite indexes for sync cursors and hot list queries.

Revision ID: 0010_sync_query_indexes
Revises: 0009_task_field_crdt
Create Date: 2026-08-08
"""

from typing import Sequence, Union

from alembic import op


revision: str = "0010_sync_query_indexes"
down_revision: Union[str, None] = "0009_task_field_crdt"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    for table in ("notes", "notebooks", "tags", "files", "tasks"):
        op.create_index(
            f"ix_{table}_user_updated_cursor",
            table,
            ["user_id", "updated_at", "id"],
            unique=False,
        )

    op.create_index(
        "ix_notes_user_list",
        "notes",
        [
            "user_id",
            "is_archived",
            "is_deleted",
            "is_pinned",
            "updated_at",
            "id",
        ],
        unique=False,
    )
    op.create_index(
        "ix_tasks_user_list",
        "tasks",
        [
            "user_id",
            "is_deleted",
            "is_completed",
            "due_date",
            "sort_order",
            "created_at",
            "id",
        ],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index("ix_tasks_user_list", table_name="tasks")
    op.drop_index("ix_notes_user_list", table_name="notes")
    for table in ("tasks", "files", "tags", "notebooks", "notes"):
        op.drop_index(f"ix_{table}_user_updated_cursor", table_name=table)
