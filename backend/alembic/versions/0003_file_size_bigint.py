"""Widen files.size_bytes to BIGINT.

INTEGER caps at ~2.1 GB; raising MAX_UPLOAD_SIZE_MB past 2048 would overflow on
insert. BIGINT removes that ceiling. The int->bigint cast is safe in Postgres.

Revision ID: 0003_file_size_bigint
Revises: 0002_tag_soft_delete
Create Date: 2026-07-13
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0003_file_size_bigint"
down_revision: Union[str, None] = "0002_tag_soft_delete"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.alter_column(
        "files",
        "size_bytes",
        existing_type=sa.Integer(),
        type_=sa.BigInteger(),
        existing_nullable=False,
    )


def downgrade() -> None:
    op.alter_column(
        "files",
        "size_bytes",
        existing_type=sa.BigInteger(),
        type_=sa.Integer(),
        existing_nullable=False,
    )
