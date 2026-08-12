"""Give tasks priority, lists, labels, repetition, reminders and subtasks.

Every column added here is an independent LWW CRDT register, except
``due_has_time`` which travels inside the ``due_date`` register: an all-day
task and a task due at 5pm differ in one fact, and splitting that fact across
two registers would let a sync land a time on a date that no longer wants one.

No ``field_clocks`` backfill is performed. ``task_crdt.stored_clock`` already
falls back to ``COALESCE(edited_at, updated_at)`` for a register a row has
never carried, which is exactly the right basis for a column that did not
exist until this migration ran.

Revision ID: 0011_task_power_fields
Revises: 0010_sync_query_indexes
Create Date: 2026-08-10
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql


revision: str = "0011_task_power_fields"
down_revision: Union[str, None] = "0010_sync_query_indexes"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "tasks",
        sa.Column(
            "priority",
            sa.Integer(),
            server_default=sa.text("0"),
            nullable=False,
        ),
    )
    op.add_column(
        "tasks",
        sa.Column(
            "due_has_time",
            sa.Boolean(),
            server_default=sa.false(),
            nullable=False,
        ),
    )
    op.add_column(
        "tasks",
        sa.Column(
            "labels",
            postgresql.JSONB(astext_type=sa.Text()),
            server_default=sa.text("'[]'::jsonb"),
            nullable=False,
        ),
    )
    op.add_column("tasks", sa.Column("recurrence", sa.String(length=200), nullable=True))
    op.add_column(
        "tasks",
        sa.Column("reminder_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column("tasks", sa.Column("reminder_lead_minutes", sa.Integer(), nullable=True))
    op.add_column("tasks", sa.Column("notebook_id", postgresql.UUID(as_uuid=True), nullable=True))
    op.add_column("tasks", sa.Column("parent_id", postgresql.UUID(as_uuid=True), nullable=True))

    # A task's list is a notebook, so notes and tasks share one organizing
    # tree instead of the app growing a second, parallel one. Deleting the
    # notebook unfiles the task rather than destroying it.
    op.create_foreign_key(
        "fk_tasks_notebook_id",
        "tasks",
        "notebooks",
        ["notebook_id"],
        ["id"],
        ondelete="SET NULL",
    )
    # A subtask outlives its parent as a top-level task. Losing the parent is
    # not a reason to lose the work.
    op.create_foreign_key(
        "fk_tasks_parent_id",
        "tasks",
        "tasks",
        ["parent_id"],
        ["id"],
        ondelete="SET NULL",
    )

    op.create_index("ix_tasks_notebook_id", "tasks", ["notebook_id"])
    op.create_index("ix_tasks_parent_id", "tasks", ["parent_id"])
    # The list query orders by priority before due date, so the covering index
    # has to carry it or every open list falls back to a sort.
    op.create_index(
        "ix_tasks_user_priority_list",
        "tasks",
        ["user_id", "is_deleted", "is_completed", "priority", "due_date", "sort_order"],
    )


def downgrade() -> None:
    op.drop_index("ix_tasks_user_priority_list", table_name="tasks")
    op.drop_index("ix_tasks_parent_id", table_name="tasks")
    op.drop_index("ix_tasks_notebook_id", table_name="tasks")
    op.drop_constraint("fk_tasks_parent_id", "tasks", type_="foreignkey")
    op.drop_constraint("fk_tasks_notebook_id", "tasks", type_="foreignkey")
    for column in (
        "parent_id",
        "notebook_id",
        "reminder_lead_minutes",
        "reminder_at",
        "recurrence",
        "labels",
        "due_has_time",
        "priority",
    ):
        op.drop_column("tasks", column)
