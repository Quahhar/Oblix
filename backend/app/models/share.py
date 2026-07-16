import uuid
from datetime import datetime
from enum import Enum as PyEnum
from sqlalchemy import DateTime, ForeignKey, Enum, func, UniqueConstraint, Index
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column
from app.database import Base


class ShareEntityType(str, PyEnum):
    NOTE = "note"
    NOTEBOOK = "notebook"


class ShareRole(str, PyEnum):
    VIEWER = "viewer"
    EDITOR = "editor"


class Share(Base):
    """A grant of access to one note or notebook, from its owner to another user.

    entity_id is polymorphic (a note id or a notebook id, per entity_type), so
    there is no FK to the target — same pattern as sync_log. Notes/notebooks are
    soft-deleted anyway, so FK cascades would almost never fire; shares to
    tombstoned entities are filtered out at read time instead. Sharing a
    notebook grants access to the notes currently filed in it (not to child
    notebooks — the grant does not recurse).
    """

    __tablename__ = "shares"
    __table_args__ = (
        UniqueConstraint("entity_type", "entity_id", "grantee_id", name="uq_share_entity_grantee"),
        Index("ix_shares_entity", "entity_type", "entity_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    entity_type: Mapped[ShareEntityType] = mapped_column(Enum(ShareEntityType), nullable=False)
    entity_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    owner_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    grantee_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    role: Mapped[ShareRole] = mapped_column(Enum(ShareRole), nullable=False, default=ShareRole.VIEWER)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    def __repr__(self) -> str:
        return f"<Share {self.entity_type}:{self.entity_id} -> {self.grantee_id} ({self.role})>"
