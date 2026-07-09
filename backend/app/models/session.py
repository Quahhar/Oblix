import uuid
from datetime import datetime
from sqlalchemy import String, DateTime, ForeignKey, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship
from app.database import Base


class Session(Base):
    """A refresh-token session. The row id IS the token's `jti` claim.

    Access tokens stay stateless and short-lived; refresh tokens are validated
    against this table so they can be revoked (logout) and rotated (each refresh
    revokes the old row and issues a new one). A refresh token whose row is
    already revoked signals reuse of a rotated token — the whole user's sessions
    should be revoked defensively.
    """

    __tablename__ = "sessions"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    device_id: Mapped[str | None] = mapped_column(String(255), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    replaced_by: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), nullable=True)

    # Relationships
    user: Mapped["User"] = relationship("User", back_populates="sessions")

    def __repr__(self) -> str:
        return f"<Session {self.id} user={self.user_id} revoked={self.revoked_at is not None}>"
