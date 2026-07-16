"""Add 'TASK' to the entitytype enum (sync_log.entity_type).

The Python EntityType enum gained TASK with the tasks feature, but Postgres
enums only learn new labels via ALTER TYPE — without this, logging a task
change into sync_log raises InvalidTextRepresentationError and the push 500s.

IF NOT EXISTS makes it idempotent. Postgres 12+ allows ADD VALUE inside a
transaction as long as the new label isn't used in the same transaction
(it isn't — sync_log rows arrive at request time, not during migration).

Revision ID: 0006_entitytype_task
Revises: 0005_tasks_and_shares
Create Date: 2026-07-16
"""
from typing import Sequence, Union

from alembic import op

revision: str = "0006_entitytype_task"
down_revision: Union[str, None] = "0005_tasks_and_shares"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute("ALTER TYPE entitytype ADD VALUE IF NOT EXISTS 'TASK'")


def downgrade() -> None:
    # Postgres cannot drop an enum label; removing it would require rebuilding
    # the type and every column using it. Deliberately a no-op.
    pass
