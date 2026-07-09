import uuid
from datetime import datetime
from enum import Enum as PyEnum
from sqlalchemy import String, Integer, Boolean, DateTime, ForeignKey, Text, Enum, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship
from app.database import Base


class ContentType(str, PyEnum):
    PLAIN = "plain"
    RICH = "rich"
    MARKDOWN = "markdown"


class Note(Base):
    __tablename__ = "notes"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    notebook_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("notebooks.id", ondelete="SET NULL"), nullable=True, index=True)
    title: Mapped[str] = mapped_column(String(500), default="Untitled", nullable=False)
    content: Mapped[str] = mapped_column(Text, default="", nullable=False)
    content_type: Mapped[ContentType] = mapped_column(Enum(ContentType), default=ContentType.PLAIN, nullable=False)
    is_pinned: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    is_archived: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False, index=True)
    is_deleted: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    # Relationships
    user: Mapped["User"] = relationship("User", back_populates="notes")
    notebook: Mapped["Notebook | None"] = relationship("Notebook", back_populates="notes")
    versions: Mapped[list["NoteVersion"]] = relationship("NoteVersion", back_populates="note", lazy="selectin", cascade="all, delete-orphan", order_by="NoteVersion.version_number")
    tags: Mapped[list["NoteTag"]] = relationship("NoteTag", back_populates="note", lazy="selectin", cascade="all, delete-orphan")
    files: Mapped[list["File"]] = relationship("File", back_populates="note", lazy="selectin")

    def __repr__(self) -> str:
        return f"<Note {self.title}>"


class NoteVersion(Base):
    __tablename__ = "note_versions"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    note_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("notes.id", ondelete="CASCADE"), nullable=False, index=True)
    title: Mapped[str] = mapped_column(String(500), nullable=False)
    content: Mapped[str] = mapped_column(Text, default="", nullable=False)
    content_type: Mapped[ContentType] = mapped_column(Enum(ContentType), nullable=False)
    version_number: Mapped[int] = mapped_column(Integer, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    # Relationships
    note: Mapped["Note"] = relationship("Note", back_populates="versions")

    def __repr__(self) -> str:
        return f"<NoteVersion note={self.note_id} v{self.version_number}>"