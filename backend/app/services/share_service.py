"""Collaboration: sharing notes and notebooks with other users.

Access model
------------
- Every entity still has exactly ONE owner; a Share grants a `viewer` or
  `editor` role on one note or one notebook to one other user.
- A notebook share covers the notes currently filed in that notebook. It does
  NOT recurse into child notebooks (an explicit, simple rule the client can
  render truthfully).
- Effective role on a note = owner, else the strongest of (direct note share,
  share on its notebook). editor > viewer.
- Editors may change a note's CONTENT (title/content/content_type). Everything
  organizational — notebook, pin, archive, tags, delete/restore, sharing —
  stays owner-only: those express how the *owner* organizes their account.
- Shared content is online-only in v1: it never enters the grantee's
  /api/sync stream (sync remains strictly per-owner), so offline clients
  can't push it back as their own.
"""
import uuid
from typing import Optional

from fastapi import HTTPException, status
from sqlalchemy import select, func, or_, and_
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.user import User
from app.models.note import Note
from app.models.notebook import Notebook
from app.models.share import Share, ShareEntityType, ShareRole
from app.schemas.share import ShareCreate


def _uuid_or_404(value, detail: str) -> uuid.UUID:
    try:
        return uuid.UUID(str(value))
    except (ValueError, TypeError):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=detail)


def _strongest(roles) -> Optional[str]:
    values = {r.value if isinstance(r, ShareRole) else str(r) for r in roles if r is not None}
    if "editor" in values:
        return "editor"
    if "viewer" in values:
        return "viewer"
    return None


class ShareService:

    # ------------------------------------------------------------ access checks

    async def note_role(self, db: AsyncSession, user: User, note: Note) -> Optional[str]:
        """The caller's effective role on a note: owner/editor/viewer/None."""
        if note.user_id == user.id:
            return "owner"
        conds = [and_(Share.entity_type == ShareEntityType.NOTE, Share.entity_id == note.id)]
        if note.notebook_id is not None:
            conds.append(and_(Share.entity_type == ShareEntityType.NOTEBOOK,
                              Share.entity_id == note.notebook_id))
        roles = (await db.execute(
            select(Share.role).where(Share.grantee_id == user.id, or_(*conds))
        )).scalars().all()
        return _strongest(roles)

    async def notebook_role(self, db: AsyncSession, user: User, notebook: Notebook) -> Optional[str]:
        if notebook.user_id == user.id:
            return "owner"
        roles = (await db.execute(
            select(Share.role).where(
                Share.grantee_id == user.id,
                Share.entity_type == ShareEntityType.NOTEBOOK,
                Share.entity_id == notebook.id,
            )
        )).scalars().all()
        return _strongest(roles)

    # ------------------------------------------------------------ share CRUD

    async def create_share(self, db: AsyncSession, owner: User, data: ShareCreate) -> dict:
        entity_id = _uuid_or_404(data.entity_id, f"{data.entity_type.capitalize()} not found")

        # The target must exist, be live, and be the caller's own. (Grantees
        # cannot re-share: sharing is an owner-organizational act.)
        if data.entity_type == "note":
            target = (await db.execute(select(Note).where(
                Note.id == entity_id, Note.user_id == owner.id, Note.is_deleted == False  # noqa: E712
            ))).scalar_one_or_none()
        else:
            target = (await db.execute(select(Notebook).where(
                Notebook.id == entity_id, Notebook.user_id == owner.id, Notebook.is_deleted == False  # noqa: E712
            ))).scalar_one_or_none()
        if target is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND,
                                detail=f"{data.entity_type.capitalize()} not found")

        email = data.email.strip().lower()
        grantee = (await db.execute(
            select(User).where(func.lower(User.email) == email, User.is_active == True)  # noqa: E712
        )).scalars().first()
        if grantee is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND,
                                detail="No user with that email")
        if grantee.id == owner.id:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST,
                                detail="Cannot share with yourself")

        existing = (await db.execute(select(Share).where(
            Share.entity_type == ShareEntityType(data.entity_type),
            Share.entity_id == entity_id,
            Share.grantee_id == grantee.id,
        ))).scalar_one_or_none()
        if existing is not None:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT,
                                detail="Already shared with that user")

        share = Share(
            id=uuid.uuid4(),
            entity_type=ShareEntityType(data.entity_type),
            entity_id=entity_id,
            owner_id=owner.id,
            grantee_id=grantee.id,
            role=ShareRole(data.role),
        )
        db.add(share)
        await db.flush()
        # created_at is a server default; load it before serializing. Share has
        # no lazy relationships, so refresh is safe here (cf. notes, where it isn't).
        await db.refresh(share)
        return self._share_dict(share, grantee)

    async def list_shares(
        self, db: AsyncSession, owner: User,
        entity_type: Optional[str] = None, entity_id: Optional[str] = None,
    ) -> list[dict]:
        """Shares the caller has granted, newest first."""
        q = (select(Share, User)
             .join(User, User.id == Share.grantee_id)
             .where(Share.owner_id == owner.id)
             .order_by(Share.created_at.desc()))
        if entity_type in ("note", "notebook"):
            q = q.where(Share.entity_type == ShareEntityType(entity_type))
        if entity_id:
            q = q.where(Share.entity_id == _uuid_or_404(entity_id, "Share not found"))
        rows = (await db.execute(q)).all()
        return [self._share_dict(share, grantee) for share, grantee in rows]

    async def update_share_role(self, db: AsyncSession, owner: User, share_id: str, role: str) -> dict:
        share, grantee = await self._owned_share(db, owner, share_id)
        share.role = ShareRole(role)
        await db.flush()
        return self._share_dict(share, grantee)

    async def delete_share(self, db: AsyncSession, user: User, share_id: str) -> None:
        """Owner revokes, or the grantee leaves. Missing share → 404."""
        sid = _uuid_or_404(share_id, "Share not found")
        share = (await db.execute(select(Share).where(
            Share.id == sid,
            or_(Share.owner_id == user.id, Share.grantee_id == user.id),
        ))).scalar_one_or_none()
        if share is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Share not found")
        await db.delete(share)
        await db.flush()

    # ------------------------------------------------------------ grantee views

    async def shared_with_me(self, db: AsyncSession, user: User) -> list[dict]:
        """Everything shared with the caller, with display snapshots.

        Shares whose target has since been tombstoned are silently skipped —
        the trash is the owner's private space.
        """
        rows = (await db.execute(
            select(Share, User)
            .join(User, User.id == Share.owner_id)
            .where(Share.grantee_id == user.id)
            .order_by(Share.created_at.desc())
        )).all()

        note_ids = [s.entity_id for s, _ in rows if s.entity_type == ShareEntityType.NOTE]
        nb_ids = [s.entity_id for s, _ in rows if s.entity_type == ShareEntityType.NOTEBOOK]
        notes = {}
        notebooks = {}
        if note_ids:
            notes = {n.id: n for n in (await db.execute(select(Note).where(
                Note.id.in_(note_ids), Note.is_deleted == False  # noqa: E712
            ))).scalars()}
        if nb_ids:
            notebooks = {n.id: n for n in (await db.execute(select(Notebook).where(
                Notebook.id.in_(nb_ids), Notebook.is_deleted == False  # noqa: E712
            ))).scalars()}

        items: list[dict] = []
        for share, owner in rows:
            if share.entity_type == ShareEntityType.NOTE:
                target = notes.get(share.entity_id)
                if target is None:
                    continue
                name = target.title
                content_type = (target.content_type.value
                                if hasattr(target.content_type, "value") else str(target.content_type))
            else:
                target = notebooks.get(share.entity_id)
                if target is None:
                    continue
                name = target.name
                content_type = None
            items.append({
                "share_id": share.id,
                "entity_type": share.entity_type.value,
                "entity_id": share.entity_id,
                "role": share.role.value,
                "owner_email": owner.email,
                "owner_display_name": owner.display_name,
                "name": name,
                "updated_at": target.updated_at,
                "content_type": content_type,
            })
        return items

    async def shared_notebook_notes(
        self, db: AsyncSession, user: User, notebook_id: str,
        page: int = 1, page_size: int = 50,
    ) -> dict:
        """Notes inside a notebook the caller owns or that is shared with them.

        Grantees see the owner's live notes in that notebook (archived
        included — archiving is the owner's organization, not a privacy
        boundary the way trash is); tombstoned notes are never shown.
        """
        nb_uuid = _uuid_or_404(notebook_id, "Notebook not found")
        nb = (await db.execute(select(Notebook).where(
            Notebook.id == nb_uuid, Notebook.is_deleted == False  # noqa: E712
        ))).scalar_one_or_none()
        if nb is None or await self.notebook_role(db, user, nb) is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Notebook not found")

        base = select(Note).where(Note.notebook_id == nb.id, Note.is_deleted == False)  # noqa: E712
        total = (await db.execute(
            select(func.count()).select_from(base.subquery())
        )).scalar() or 0
        from sqlalchemy.orm import selectinload
        from app.models.tag import NoteTag
        notes = (await db.execute(
            base.options(selectinload(Note.tags).selectinload(NoteTag.tag))
            .order_by(Note.updated_at.desc(), Note.id.desc())
            .offset((page - 1) * page_size).limit(page_size)
        )).scalars().unique().all()
        return {"notes": notes, "total": total, "page": page, "page_size": page_size}

    # ------------------------------------------------------------ helpers

    async def _owned_share(self, db: AsyncSession, owner: User, share_id: str):
        sid = _uuid_or_404(share_id, "Share not found")
        row = (await db.execute(
            select(Share, User)
            .join(User, User.id == Share.grantee_id)
            .where(Share.id == sid, Share.owner_id == owner.id)
        )).first()
        if row is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Share not found")
        return row

    @staticmethod
    def _share_dict(share: Share, grantee: User) -> dict:
        return {
            "id": share.id,
            "entity_type": share.entity_type.value,
            "entity_id": share.entity_id,
            "role": share.role.value,
            "grantee_email": grantee.email,
            "grantee_display_name": grantee.display_name,
            "created_at": share.created_at,
        }


share_service = ShareService()
