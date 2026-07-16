"""Create the tasks and shares tables.

Tasks: standalone or note-attached to-dos, tombstoned and synced offline like
notes (edited_at drives LWW). Shares: per-entity access grants (note/notebook →
grantee user, viewer/editor role); entity_id is polymorphic so there is no FK
to the target — same pattern as sync_log.

Enum types are imported from the models and pre-created with
create_type=False on the columns (see 0001: letting create_table auto-create
them double-creates the type and aborts the migration).

Revision ID: 0005_tasks_and_shares
Revises: 0004_note_edited_at
Create Date: 2026-07-16
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

from app.models.share import ShareEntityType, ShareRole

revision: str = "0005_tasks_and_shares"
down_revision: Union[str, None] = "0004_note_edited_at"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _uuid():
    return postgresql.UUID(as_uuid=True)


def _ts(name, **kw):
    return sa.Column(name, sa.DateTime(timezone=True), **kw)


NOW = sa.text("now()")


def upgrade() -> None:
    bind = op.get_bind()

    share_entity_type = sa.Enum(ShareEntityType, name="shareentitytype")
    share_role = sa.Enum(ShareRole, name="sharerole")
    share_entity_type.create(bind, checkfirst=True)
    share_role.create(bind, checkfirst=True)

    entity_type_col = sa.Enum(
        ShareEntityType, name="shareentitytype", create_type=False
    )
    role_col = sa.Enum(ShareRole, name="sharerole", create_type=False)

    # --- tasks ---
    op.create_table(
        "tasks",
        sa.Column("id", _uuid(), primary_key=True),
        sa.Column("user_id", _uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("note_id", _uuid(), sa.ForeignKey("notes.id", ondelete="SET NULL"), nullable=True),
        sa.Column("title", sa.String(500), nullable=False),
        sa.Column("description", sa.Text(), nullable=False, server_default=""),
        sa.Column("is_completed", sa.Boolean(), nullable=False, server_default=sa.false()),
        _ts("completed_at", nullable=True),
        _ts("due_date", nullable=True),
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("is_deleted", sa.Boolean(), nullable=False, server_default=sa.false()),
        _ts("created_at", server_default=NOW),
        _ts("updated_at", server_default=NOW),
        _ts("edited_at", nullable=True),
        _ts("deleted_at", nullable=True),
    )
    op.create_index("ix_tasks_user_id", "tasks", ["user_id"])
    op.create_index("ix_tasks_note_id", "tasks", ["note_id"])
    op.create_index("ix_tasks_is_completed", "tasks", ["is_completed"])
    op.create_index("ix_tasks_due_date", "tasks", ["due_date"])
    op.create_index("ix_tasks_is_deleted", "tasks", ["is_deleted"])

    # --- shares ---
    op.create_table(
        "shares",
        sa.Column("id", _uuid(), primary_key=True),
        sa.Column("entity_type", entity_type_col, nullable=False),
        sa.Column("entity_id", _uuid(), nullable=False),
        sa.Column("owner_id", _uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("grantee_id", _uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("role", role_col, nullable=False),
        _ts("created_at", server_default=NOW),
        _ts("updated_at", server_default=NOW),
        sa.UniqueConstraint("entity_type", "entity_id", "grantee_id", name="uq_share_entity_grantee"),
    )
    op.create_index("ix_shares_owner_id", "shares", ["owner_id"])
    op.create_index("ix_shares_grantee_id", "shares", ["grantee_id"])
    op.create_index("ix_shares_entity", "shares", ["entity_type", "entity_id"])


def downgrade() -> None:
    op.drop_table("shares")
    op.drop_table("tasks")

    bind = op.get_bind()
    sa.Enum(name="sharerole").drop(bind, checkfirst=True)
    sa.Enum(name="shareentitytype").drop(bind, checkfirst=True)
