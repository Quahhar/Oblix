"""Repair duplicate/cross-owner data and align schema invariants.

Revision ID: 0007_production_hardening
Revises: 0006_entitytype_task
Create Date: 2026-07-29
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op


revision: str = "0007_production_hardening"
down_revision: Union[str, None] = "0006_entitytype_task"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _deduplicate_users(bind) -> None:
    groups = bind.execute(
        sa.text(
            """
            SELECT lower(email) AS normalized_email,
                   array_agg(id ORDER BY created_at, id) AS ids
            FROM users
            GROUP BY lower(email)
            HAVING count(*) > 1
            """
        )
    ).mappings()

    owned_tables = (
        "notebooks",
        "notes",
        "tags",
        "files",
        "sync_log",
        "tasks",
    )
    for group in groups:
        winner, *losers = group["ids"]
        for loser in losers:
            # Tokens contain the original user id, so sessions cannot safely be
            # reassigned. Invalidate only the merged-away account's sessions.
            bind.execute(
                sa.text("DELETE FROM sessions WHERE user_id = :loser"),
                {"loser": loser},
            )

            # A merge can turn a grant into a self-share or duplicate a grant
            # the winning account already has. Remove those before reassigning.
            bind.execute(
                sa.text(
                    """
                    DELETE FROM shares
                    WHERE (owner_id = :winner AND grantee_id = :loser)
                       OR (owner_id = :loser AND grantee_id = :winner)
                       OR owner_id = grantee_id
                    """
                ),
                {"winner": winner, "loser": loser},
            )
            bind.execute(
                sa.text(
                    """
                    DELETE FROM shares losing
                    USING shares kept
                    WHERE losing.grantee_id = :loser
                      AND kept.grantee_id = :winner
                      AND losing.entity_type = kept.entity_type
                      AND losing.entity_id = kept.entity_id
                    """
                ),
                {"winner": winner, "loser": loser},
            )
            bind.execute(
                sa.text("UPDATE shares SET owner_id = :winner WHERE owner_id = :loser"),
                {"winner": winner, "loser": loser},
            )
            bind.execute(
                sa.text("UPDATE shares SET grantee_id = :winner WHERE grantee_id = :loser"),
                {"winner": winner, "loser": loser},
            )
            for table in owned_tables:
                bind.execute(
                    sa.text(
                        f"UPDATE {table} SET user_id = :winner WHERE user_id = :loser"
                    ),
                    {"winner": winner, "loser": loser},
                )
            bind.execute(
                sa.text("DELETE FROM users WHERE id = :loser"),
                {"loser": loser},
            )

    bind.execute(sa.text("UPDATE users SET email = lower(btrim(email))"))


def _deduplicate_tags(bind) -> None:
    groups = bind.execute(
        sa.text(
            """
            SELECT user_id, name,
                   array_agg(
                       id ORDER BY is_deleted ASC, created_at ASC, id ASC
                   ) AS ids
            FROM tags
            GROUP BY user_id, name
            HAVING count(*) > 1
            """
        )
    ).mappings()

    for group in groups:
        winner, *losers = group["ids"]
        for loser in losers:
            bind.execute(
                sa.text(
                    """
                    INSERT INTO note_tags (note_id, tag_id)
                    SELECT note_id, :winner
                    FROM note_tags
                    WHERE tag_id = :loser
                    ON CONFLICT DO NOTHING
                    """
                ),
                {"winner": winner, "loser": loser},
            )
            bind.execute(
                sa.text("DELETE FROM tags WHERE id = :loser"),
                {"loser": loser},
            )


def upgrade() -> None:
    bind = op.get_bind()

    _deduplicate_users(bind)
    _deduplicate_tags(bind)

    # Association rows must never expose one user's tag name through another
    # user's note response.
    bind.execute(
        sa.text(
            """
            DELETE FROM note_tags nt
            USING notes n, tags t
            WHERE nt.note_id = n.id
              AND nt.tag_id = t.id
              AND n.user_id <> t.user_id
            """
        )
    )

    op.drop_index("ix_users_email", table_name="users")
    op.create_index("ix_users_email", "users", ["email"], unique=False)
    op.create_index(
        "uq_users_email_lower",
        "users",
        [sa.text("lower(email)")],
        unique=True,
    )
    op.create_unique_constraint(
        "uq_tags_user_name", "tags", ["user_id", "name"]
    )

    bind.execute(
        sa.text(
            """
            UPDATE sessions s
            SET replaced_by = NULL
            WHERE replaced_by IS NOT NULL
              AND NOT EXISTS (
                  SELECT 1 FROM sessions replacement
                  WHERE replacement.id = s.replaced_by
              )
            """
        )
    )
    op.create_foreign_key(
        "fk_sessions_replaced_by_sessions",
        "sessions",
        "sessions",
        ["replaced_by"],
        ["id"],
        ondelete="SET NULL",
    )

    for table, columns in {
        "users": ("created_at", "updated_at"),
        "notebooks": ("created_at", "updated_at"),
        "notes": ("created_at", "updated_at"),
        "note_versions": ("created_at",),
        "tags": ("created_at", "updated_at"),
        "files": ("created_at", "updated_at"),
        "sessions": ("created_at",),
        "sync_log": ("timestamp",),
        "tasks": ("created_at", "updated_at"),
        "shares": ("created_at", "updated_at"),
    }.items():
        for column in columns:
            op.alter_column(
                table,
                column,
                existing_type=sa.DateTime(timezone=True),
                nullable=False,
            )


def downgrade() -> None:
    for table, columns in {
        "users": ("created_at", "updated_at"),
        "notebooks": ("created_at", "updated_at"),
        "notes": ("created_at", "updated_at"),
        "note_versions": ("created_at",),
        "tags": ("created_at", "updated_at"),
        "files": ("created_at", "updated_at"),
        "sessions": ("created_at",),
        "sync_log": ("timestamp",),
        "tasks": ("created_at", "updated_at"),
        "shares": ("created_at", "updated_at"),
    }.items():
        for column in columns:
            op.alter_column(
                table,
                column,
                existing_type=sa.DateTime(timezone=True),
                nullable=True,
            )

    op.drop_constraint(
        "fk_sessions_replaced_by_sessions", "sessions", type_="foreignkey"
    )
    op.drop_constraint("uq_tags_user_name", "tags", type_="unique")
    op.drop_index("uq_users_email_lower", table_name="users")
    op.drop_index("ix_users_email", table_name="users")
    op.create_index("ix_users_email", "users", ["email"], unique=True)
