"""initial schema

Revision ID: 0001_initial
Revises:
Create Date: 2026-07-07

Creates the full baseline schema. Enum types are imported from the models so
their labels match exactly what SQLAlchemy's create_all would produce (avoiding
drift between the dev create_all path and migrated production databases).
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from app.models.note import ContentType
from app.models.sync import EntityType, SyncAction

# revision identifiers, used by Alembic.
revision: str = "0001_initial"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _uuid():
    return postgresql.UUID(as_uuid=True)


def _ts(name, **kw):
    return sa.Column(name, sa.DateTime(timezone=True), **kw)


NOW = sa.text("now()")


def upgrade() -> None:
    bind = op.get_bind()

    # Create enum types once, up front (create_type=False on the columns below
    # so table creation doesn't try to re-create them).
    content_type = sa.Enum(ContentType, name="contenttype")
    entity_type = sa.Enum(EntityType, name="entitytype")
    sync_action = sa.Enum(SyncAction, name="syncaction")
    content_type.create(bind, checkfirst=True)
    entity_type.create(bind, checkfirst=True)
    sync_action.create(bind, checkfirst=True)

    # NOTE: create_type is a postgresql.ENUM parameter — the generic sa.Enum
    # silently ignores it and would re-issue CREATE TYPE on every create_table.
    content_type_col = postgresql.ENUM(
        ContentType, name="contenttype", create_type=False
    )
    entity_type_col = postgresql.ENUM(
        EntityType, name="entitytype", create_type=False
    )
    sync_action_col = postgresql.ENUM(
        SyncAction, name="syncaction", create_type=False
    )

    # --- users ---
    op.create_table(
        "users",
        sa.Column("id", _uuid(), primary_key=True),
        sa.Column("email", sa.String(255), nullable=False),
        sa.Column("hashed_password", sa.String(255), nullable=True),
        sa.Column("display_name", sa.String(128), nullable=False),
        sa.Column("google_id", sa.String(255), nullable=True),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.true()),
        _ts("created_at", server_default=NOW),
        _ts("updated_at", server_default=NOW),
    )
    op.create_index("ix_users_email", "users", ["email"], unique=True)
    op.create_index("ix_users_google_id", "users", ["google_id"], unique=True)

    # --- notebooks ---
    op.create_table(
        "notebooks",
        sa.Column("id", _uuid(), primary_key=True),
        sa.Column("user_id", _uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.String(255), nullable=False),
        sa.Column("parent_id", _uuid(), sa.ForeignKey("notebooks.id", ondelete="SET NULL"), nullable=True),
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("is_deleted", sa.Boolean(), nullable=False, server_default=sa.false()),
        _ts("created_at", server_default=NOW),
        _ts("updated_at", server_default=NOW),
        _ts("deleted_at", nullable=True),
    )
    op.create_index("ix_notebooks_user_id", "notebooks", ["user_id"])
    op.create_index("ix_notebooks_parent_id", "notebooks", ["parent_id"])
    op.create_index("ix_notebooks_is_deleted", "notebooks", ["is_deleted"])

    # --- notes ---
    op.create_table(
        "notes",
        sa.Column("id", _uuid(), primary_key=True),
        sa.Column("user_id", _uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("notebook_id", _uuid(), sa.ForeignKey("notebooks.id", ondelete="SET NULL"), nullable=True),
        sa.Column("title", sa.String(500), nullable=False, server_default="Untitled"),
        sa.Column("content", sa.Text(), nullable=False, server_default=""),
        sa.Column("content_type", content_type_col, nullable=False),
        sa.Column("is_pinned", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("is_archived", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("is_deleted", sa.Boolean(), nullable=False, server_default=sa.false()),
        _ts("created_at", server_default=NOW),
        _ts("updated_at", server_default=NOW),
        _ts("deleted_at", nullable=True),
    )
    op.create_index("ix_notes_user_id", "notes", ["user_id"])
    op.create_index("ix_notes_notebook_id", "notes", ["notebook_id"])
    op.create_index("ix_notes_is_archived", "notes", ["is_archived"])
    op.create_index("ix_notes_is_deleted", "notes", ["is_deleted"])

    # --- note_versions ---
    op.create_table(
        "note_versions",
        sa.Column("id", _uuid(), primary_key=True),
        sa.Column("note_id", _uuid(), sa.ForeignKey("notes.id", ondelete="CASCADE"), nullable=False),
        sa.Column("title", sa.String(500), nullable=False),
        sa.Column("content", sa.Text(), nullable=False, server_default=""),
        sa.Column("content_type", content_type_col, nullable=False),
        sa.Column("version_number", sa.Integer(), nullable=False),
        _ts("created_at", server_default=NOW),
    )
    op.create_index("ix_note_versions_note_id", "note_versions", ["note_id"])

    # --- tags ---
    op.create_table(
        "tags",
        sa.Column("id", _uuid(), primary_key=True),
        sa.Column("user_id", _uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.String(128), nullable=False),
        _ts("created_at", server_default=NOW),
        _ts("updated_at", server_default=NOW),
    )
    op.create_index("ix_tags_user_id", "tags", ["user_id"])

    # --- note_tags (association) ---
    op.create_table(
        "note_tags",
        sa.Column("note_id", _uuid(), sa.ForeignKey("notes.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("tag_id", _uuid(), sa.ForeignKey("tags.id", ondelete="CASCADE"), primary_key=True),
    )

    # --- files ---
    op.create_table(
        "files",
        sa.Column("id", _uuid(), primary_key=True),
        sa.Column("user_id", _uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("note_id", _uuid(), sa.ForeignKey("notes.id", ondelete="SET NULL"), nullable=True),
        sa.Column("filename", sa.String(500), nullable=False),
        sa.Column("original_name", sa.String(500), nullable=False),
        sa.Column("mime_type", sa.String(255), nullable=False),
        sa.Column("size_bytes", sa.Integer(), nullable=False),
        sa.Column("storage_path", sa.String(1000), nullable=False),
        sa.Column("is_deleted", sa.Boolean(), nullable=False, server_default=sa.false()),
        _ts("created_at", server_default=NOW),
        _ts("updated_at", server_default=NOW),
        _ts("deleted_at", nullable=True),
    )
    op.create_index("ix_files_user_id", "files", ["user_id"])
    op.create_index("ix_files_note_id", "files", ["note_id"])
    op.create_index("ix_files_is_deleted", "files", ["is_deleted"])

    # --- sessions ---
    op.create_table(
        "sessions",
        sa.Column("id", _uuid(), primary_key=True),
        sa.Column("user_id", _uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("device_id", sa.String(255), nullable=True),
        _ts("created_at", server_default=NOW),
        _ts("expires_at", nullable=False),
        _ts("revoked_at", nullable=True),
        sa.Column("replaced_by", _uuid(), nullable=True),
    )
    op.create_index("ix_sessions_user_id", "sessions", ["user_id"])

    # --- sync_log ---
    op.create_table(
        "sync_log",
        sa.Column("id", _uuid(), primary_key=True),
        sa.Column("user_id", _uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("entity_type", entity_type_col, nullable=False),
        sa.Column("entity_id", _uuid(), nullable=False),
        sa.Column("action", sync_action_col, nullable=False),
        sa.Column("device_id", sa.String(255), nullable=True),
        _ts("timestamp", server_default=NOW),
    )
    op.create_index("ix_sync_log_user_id", "sync_log", ["user_id"])
    op.create_index("ix_sync_log_entity_type", "sync_log", ["entity_type"])
    op.create_index("ix_sync_log_entity_id", "sync_log", ["entity_id"])
    op.create_index("ix_sync_log_timestamp", "sync_log", ["timestamp"])


def downgrade() -> None:
    op.drop_table("sync_log")
    op.drop_table("sessions")
    op.drop_table("files")
    op.drop_table("note_tags")
    op.drop_table("tags")
    op.drop_table("note_versions")
    op.drop_table("notes")
    op.drop_table("notebooks")
    op.drop_table("users")

    bind = op.get_bind()
    sa.Enum(name="syncaction").drop(bind, checkfirst=True)
    sa.Enum(name="entitytype").drop(bind, checkfirst=True)
    sa.Enum(name="contenttype").drop(bind, checkfirst=True)
