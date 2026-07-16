import uuid
from datetime import datetime
from enum import Enum as PyEnum
from sqlalchemy import String, DateTime, ForeignKey, Enum, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship
from app.database import Base


class EntityType(str, PyEnum):
    NOTE = "note"
    NOTEBOOK = "notebook"
    TAG = "tag"
    FILE = "file"


class SyncAction(str, PyEnum):
    CREATE = "create"
    UPDATE = "update"
    DELETE = "delete"


class SyncLog(Base):
    __tablename__ = "sync_log"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    entity_type: Mapped[EntityType] = mapped_column(Enum(EntityType), nullable=False, index=True)
    entity_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False, index=True)
    action: Mapped[SyncAction] = mapped_column(Enum(SyncAction), nullable=False)
    device_id: Mapped[str | None] = mapped_column(String(255), nullable=True)
    timestamp: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)

    # Relationships
    user: Mapped["User"] = relationship("User", back_populates="sync_logs")

    def __repr__(self) -> str:
        return f"<SyncLog {self.entity_type}:{self.entity_id} {self.action}>"