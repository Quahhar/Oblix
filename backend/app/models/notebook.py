import uuid
from datetime import datetime
from sqlalchemy import String, Integer, Boolean, DateTime, ForeignKey, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship
from app.database import Base


class Notebook(Base):
    __tablename__ = "notebooks"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    parent_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("notebooks.id", ondelete="SET NULL"), nullable=True, index=True)
    sort_order: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    is_deleted: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    # Relationships
    user: Mapped["User"] = relationship("User", back_populates="notebooks")
    # notes/children are deliberately NOT eager-loaded. They used to be
    # lazy="selectin", which auto-loaded every note in a notebook (and,
    # recursively, every child notebook) on ANY notebook query — even though
    # list_notebooks builds the whole tree from one flat SELECT and never walks
    # these relationships. lazy="raise" turns any accidental access into a loud
    # error instead of a silent fan-out of extra queries.
    notes: Mapped[list["Note"]] = relationship("Note", back_populates="notebook", lazy="raise")
    parent: Mapped["Notebook | None"] = relationship("Notebook", remote_side="Notebook.id", back_populates="children")
    children: Mapped[list["Notebook"]] = relationship("Notebook", back_populates="parent", lazy="raise", cascade="all, delete-orphan")

    def __repr__(self) -> str:
        return f"<Notebook {self.name}>"