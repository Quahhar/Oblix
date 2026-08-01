"""Add the operational-transform journal for real-time collaboration.

Revision ID: 0008_realtime_collaboration
Revises: 0007_production_hardening
Create Date: 2026-07-30
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql


revision: str = "0008_realtime_collaboration"
down_revision: Union[str, None] = "0007_production_hardening"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "notes",
        sa.Column("collab_revision", sa.Integer(), server_default="0", nullable=False),
    )
    op.add_column(
        "notes",
        sa.Column(
            "collab_epoch",
            postgresql.UUID(as_uuid=True),
            nullable=True,
        ),
    )
    # Adding a volatile UUID default directly to a populated table forces a
    # table rewrite while ALTER TABLE holds its strongest lock. Add the column
    # without a default, backfill existing rows through a normal UPDATE, then
    # install the default and invariant for future inserts.
    op.execute(
        sa.text(
            "UPDATE notes SET collab_epoch = gen_random_uuid() "
            "WHERE collab_epoch IS NULL"
        )
    )
    # Validate with PostgreSQL's lighter-weight constraint-validation lock.
    # Once validated, SET NOT NULL can reuse the proof instead of rescanning
    # the whole table while it holds ACCESS EXCLUSIVE.
    op.execute(
        sa.text(
            "ALTER TABLE notes ADD CONSTRAINT "
            "ck_notes_collab_epoch_not_null "
            "CHECK (collab_epoch IS NOT NULL) NOT VALID"
        )
    )
    op.execute(
        sa.text("ALTER TABLE notes VALIDATE CONSTRAINT ck_notes_collab_epoch_not_null")
    )
    op.alter_column(
        "notes",
        "collab_epoch",
        existing_type=postgresql.UUID(as_uuid=True),
        server_default=sa.text("gen_random_uuid()"),
        nullable=False,
    )
    op.drop_constraint(
        "ck_notes_collab_epoch_not_null",
        "notes",
        type_="check",
    )
    op.create_table(
        "collaboration_operations",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("note_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("operation_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("revision", sa.Integer(), nullable=False),
        sa.Column("field", sa.String(length=16), nullable=False),
        sa.Column("delta", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("author_id", postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column("client_id", sa.String(length=100), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(["author_id"], ["users.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["note_id"], ["notes.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("note_id", "operation_id", name="uq_collab_note_operation"),
        sa.UniqueConstraint("note_id", "revision", name="uq_collab_note_revision"),
    )
    op.create_index(
        op.f("ix_collaboration_operations_note_id"),
        "collaboration_operations",
        ["note_id"],
        unique=False,
    )
    op.create_index(
        "ix_collaboration_operations_created_at",
        "collaboration_operations",
        ["created_at"],
        unique=False,
    )
    op.create_table(
        "collaboration_operation_receipts",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("note_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("operation_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(["note_id"], ["notes.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "note_id",
            "operation_id",
            name="uq_collab_receipt_note_operation",
        ),
    )
    op.create_index(
        op.f("ix_collaboration_operation_receipts_note_id"),
        "collaboration_operation_receipts",
        ["note_id"],
        unique=False,
    )
    op.create_index(
        "ix_collaboration_operation_receipts_created_at",
        "collaboration_operation_receipts",
        ["created_at"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index(
        "ix_collaboration_operation_receipts_created_at",
        table_name="collaboration_operation_receipts",
    )
    op.drop_index(
        op.f("ix_collaboration_operation_receipts_note_id"),
        table_name="collaboration_operation_receipts",
    )
    op.drop_table("collaboration_operation_receipts")
    op.drop_index(
        "ix_collaboration_operations_created_at",
        table_name="collaboration_operations",
    )
    op.drop_index(
        op.f("ix_collaboration_operations_note_id"),
        table_name="collaboration_operations",
    )
    op.drop_table("collaboration_operations")
    op.drop_column("notes", "collab_epoch")
    op.drop_column("notes", "collab_revision")
