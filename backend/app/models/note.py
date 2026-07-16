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
    # The client's own last-edit time, used ONLY for sync last-write-wins
    # comparison. Kept separate from updated_at (which is the server-controlled
    # sync cursor) so conflict resolution compares edit-time-vs-edit-time and a
    # note synced later can't wrongly lose to one that was edited earlier.
    edited_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    # Relationships
    user: Mapped["User"] = relationship("User", back_populates="notes")
    notebook: Mapped["Notebook | None"] = relationship("Notebook", back_populates="notes")
    # versions/files are deliberately NOT eager-loaded. They used to be
    # lazy="selectin", which auto-loaded the FULL version history (up to
    # _MAX_VERSIONS snapshots, each carrying the entire note body) and every
    # attachment on EVERY note query — including the note-list screen and every
    # sync pull, neither of which uses them. That bloated those responses badly.
    #   versions -> "noload": accessing it returns [] (so the list/get response
    #     still carries a "versions" key, unchanged on the wire) UNLESS a query
    #     opts in via selectinload(Note.versions) — get_note does, for history.
    #   files -> "raise": nothing serializes note.files except the .oblix export,
    #     which loads it explicitly; raising turns any accidental access into a
    #     loud error instead of a silent per-note extra query.
    versions: Mapped[list["NoteVersion"]] = relationship("NoteVersion", back_populates="note", lazy="noload", cascade="all, delete-orphan", order_by="NoteVersion.version_number")
    tags: Mapped[list["NoteTag"]] = relationship("NoteTag", back_populates="note", lazy="selectin", cascade="all, delete-orphan")
    files: Mapped[list["File"]] = relationship("File", back_populates="note", lazy="raise")

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