"""Add per-field CRDT clocks for notes, notebooks, and tasks.

Revision ID: 0009_task_field_crdt
Revises: 0008_realtime_collaboration
Create Date: 2026-08-08
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql


revision: str = "0009_task_field_crdt"
down_revision: Union[str, None] = "0008_realtime_collaboration"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    for table in ("notes", "notebooks", "tasks"):
        op.add_column(
            table,
            sa.Column(
                "field_clocks",
                postgresql.JSONB(astext_type=sa.Text()),
                server_default=sa.text("'{}'::jsonb"),
                nullable=False,
            ),
        )
    # Give every legacy field its old whole-row LWW timestamp. Subsequent edits
    # can then advance only the field they actually changed.
    op.execute(
        sa.text(
            """
            UPDATE tasks
            SET field_clocks = jsonb_build_object(
                'title', jsonb_build_object('timestamp', COALESCE(edited_at, updated_at), 'device_id', 'legacy'),
                'description', jsonb_build_object('timestamp', COALESCE(edited_at, updated_at), 'device_id', 'legacy'),
                'note_id', jsonb_build_object('timestamp', COALESCE(edited_at, updated_at), 'device_id', 'legacy'),
                'due_date', jsonb_build_object('timestamp', COALESCE(edited_at, updated_at), 'device_id', 'legacy'),
                'sort_order', jsonb_build_object('timestamp', COALESCE(edited_at, updated_at), 'device_id', 'legacy'),
                'is_completed', jsonb_build_object('timestamp', COALESCE(edited_at, updated_at), 'device_id', 'legacy'),
                'is_deleted', jsonb_build_object('timestamp', COALESCE(edited_at, updated_at), 'device_id', 'legacy')
            )
            """
        )
    )
    op.execute(
        sa.text(
            """
            UPDATE notes
            SET field_clocks = jsonb_build_object(
                'title', jsonb_build_object('timestamp', COALESCE(edited_at, updated_at), 'device_id', 'legacy'),
                'content', jsonb_build_object('timestamp', COALESCE(edited_at, updated_at), 'device_id', 'legacy'),
                'content_type', jsonb_build_object('timestamp', COALESCE(edited_at, updated_at), 'device_id', 'legacy'),
                'notebook_id', jsonb_build_object('timestamp', COALESCE(edited_at, updated_at), 'device_id', 'legacy'),
                'is_pinned', jsonb_build_object('timestamp', COALESCE(edited_at, updated_at), 'device_id', 'legacy'),
                'is_archived', jsonb_build_object('timestamp', COALESCE(edited_at, updated_at), 'device_id', 'legacy'),
                'tags', jsonb_build_object('timestamp', COALESCE(edited_at, updated_at), 'device_id', 'legacy'),
                'is_deleted', jsonb_build_object('timestamp', COALESCE(edited_at, updated_at), 'device_id', 'legacy')
            )
            """
        )
    )
    op.execute(
        sa.text(
            """
            UPDATE notebooks
            SET field_clocks = jsonb_build_object(
                'name', jsonb_build_object('timestamp', updated_at, 'device_id', 'legacy'),
                'parent_id', jsonb_build_object('timestamp', updated_at, 'device_id', 'legacy'),
                'sort_order', jsonb_build_object('timestamp', updated_at, 'device_id', 'legacy'),
                'is_deleted', jsonb_build_object('timestamp', updated_at, 'device_id', 'legacy')
            )
            """
        )
    )


def downgrade() -> None:
    for table in ("tasks", "notebooks", "notes"):
        op.drop_column(table, "field_clocks")
