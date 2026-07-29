import uuid
from datetime import datetime
from sqlalchemy import String, DateTime, Boolean, func, true, Index
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship
from app.database import Base


class User(Base):
    __tablename__ = "users"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    email: Mapped[str] = mapped_column(String(255), nullable=False, index=True)
    hashed_password: Mapped[str | None] = mapped_column(String(255), nullable=True)
    display_name: Mapped[str] = mapped_column(String(128), nullable=False)
    google_id: Mapped[str | None] = mapped_column(
        String(255), nullable=True, index=True, unique=True
    )
    is_active: Mapped[bool] = mapped_column(
        Boolean, default=True, server_default=true(), nullable=False
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False)
    __table_args__ = (
        Index("uq_users_email_lower", func.lower(email), unique=True),
    )

    # Relationships.
    # These are NOT eager-loaded: a User is loaded on every authenticated request
    # (get_current_user), and eager-loading here would pull all of the user's
    # notes/notebooks/tags/files each time. They're queried directly instead.
    # lazy="raise" turns any accidental `user.notes`-style access into a loud
    # error rather than a silent N+1; passive_deletes=True lets the database's
    # ON DELETE CASCADE handle deletion without loading children into Python.
    notebooks: Mapped[list["Notebook"]] = relationship("Notebook", back_populates="user", lazy="raise", passive_deletes=True, cascade="all, delete-orphan")
    notes: Mapped[list["Note"]] = relationship("Note", back_populates="user", lazy="raise", passive_deletes=True, cascade="all, delete-orphan")
    tags: Mapped[list["Tag"]] = relationship("Tag", back_populates="user", lazy="raise", passive_deletes=True, cascade="all, delete-orphan")
    files: Mapped[list["File"]] = relationship("File", back_populates="user", lazy="raise", passive_deletes=True, cascade="all, delete-orphan")
    sync_logs: Mapped[list["SyncLog"]] = relationship("SyncLog", back_populates="user", lazy="raise", passive_deletes=True, cascade="all, delete-orphan")
    sessions: Mapped[list["Session"]] = relationship("Session", back_populates="user", lazy="raise", passive_deletes=True, cascade="all, delete-orphan")
    tasks: Mapped[list["Task"]] = relationship("Task", back_populates="user", lazy="raise", passive_deletes=True, cascade="all, delete-orphan")

    def __repr__(self) -> str:
        return f"<User {self.email}>"
