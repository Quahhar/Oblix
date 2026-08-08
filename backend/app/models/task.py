import uuid
from datetime import datetime
from sqlalchemy import String, Integer, Boolean, DateTime, ForeignKey, Text, func, false, text, Index
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship
from app.database import Base


class Task(Base):
    """A task whose mutable fields are independent LWW CRDT registers."""

    __tablename__ = "tasks"
    __table_args__ = (
        Index("ix_tasks_user_updated_cursor", "user_id", "updated_at", "id"),
        Index(
            "ix_tasks_user_list",
            "user_id",
            "is_deleted",
            "is_completed",
            "due_date",
            "sort_order",
            "created_at",
            "id",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    note_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("notes.id", ondelete="SET NULL"), nullable=True, index=True)
    title: Mapped[str] = mapped_column(String(500), nullable=False)
    description: Mapped[str] = mapped_column(Text, default="", server_default=text("''"), nullable=False)
    is_completed: Mapped[bool] = mapped_column(Boolean, default=False, server_default=false(), nullable=False, index=True)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    due_date: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True, index=True)
    sort_order: Mapped[int] = mapped_column(Integer, default=0, server_default=text("0"), nullable=False)
    is_deleted: Mapped[bool] = mapped_column(Boolean, default=False, server_default=false(), nullable=False, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False)
    # Maximum observed field clock, retained for compatibility and cursors.
    edited_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    field_clocks: Mapped[dict] = mapped_column(
        JSONB, default=dict, server_default=text("'{}'::jsonb"), nullable=False
    )
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    user: Mapped["User"] = relationship("User", back_populates="tasks")

    def __repr__(self) -> str:
        return f"<Task {self.title}>"
