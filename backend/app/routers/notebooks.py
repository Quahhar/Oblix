import uuid
from collections import defaultdict
from datetime import datetime, timezone
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from app.database import get_db
from app.models.notebook import Notebook
from app.schemas.notebook import NotebookCreate, NotebookUpdate, NotebookResponse
from app.utils.auth_dependency import get_current_user
from app.models.user import User

router = APIRouter(prefix="/notebooks", tags=["notebooks"])


def _serialize(nb: Notebook, children=None) -> NotebookResponse:
    """Build a response WITHOUT touching lazy relationships (which would trigger
    async lazy-loads and 500 during serialization)."""
    return NotebookResponse(
        id=nb.id,
        user_id=nb.user_id,
        name=nb.name,
        parent_id=nb.parent_id,
        sort_order=nb.sort_order,
        is_deleted=nb.is_deleted,
        created_at=nb.created_at,
        updated_at=nb.updated_at,
        children=children or [],
    )


async def _resolve_parent(db: AsyncSession, user: User, parent_id_str, this_id=None):
    """Validate a proposed parent_id. Returns a UUID or None; raises on bad input.

    Guards against: malformed id, an unknown or another user's parent,
    self-parenting, and cycles (parenting a notebook under its own descendant).
    """
    if not parent_id_str:
        return None
    try:
        parent_uuid = uuid.UUID(str(parent_id_str))
    except (ValueError, TypeError):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid parent_id")
    if this_id is not None and parent_uuid == this_id:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="A notebook cannot be its own parent")

    rows = (await db.execute(
        select(Notebook.id, Notebook.parent_id).where(
            Notebook.user_id == user.id, Notebook.is_deleted == False  # noqa: E712
        )
    )).all()
    parents = {r[0]: r[1] for r in rows}
    if parent_uuid not in parents:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Parent notebook not found")

    if this_id is not None:
        cursor, seen = parent_uuid, set()
        while cursor is not None and cursor not in seen:
            if cursor == this_id:
                raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST,
                                    detail="Cannot move a notebook under its own descendant")
            seen.add(cursor)
            cursor = parents.get(cursor)
    return parent_uuid


@router.get("", response_model=list[NotebookResponse])
async def list_notebooks(
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    result = await db.execute(
        select(Notebook)
        .where(Notebook.user_id == current_user.id, Notebook.is_deleted == False)  # noqa: E712
        .order_by(Notebook.sort_order, Notebook.name)
    )
    all_notebooks = list(result.scalars().all())
    ids = {nb.id for nb in all_notebooks}

    by_parent: dict = defaultdict(list)
    for nb in all_notebooks:
        by_parent[nb.parent_id].append(nb)

    emitted: set = set()

    def build(nb: Notebook, path: set) -> NotebookResponse:
        path = path | {nb.id}
        emitted.add(nb.id)
        kids = [build(c, path) for c in by_parent.get(nb.id, []) if c.id not in path]
        return _serialize(nb, kids)

    # Roots = top-level notebooks PLUS any whose parent is missing/deleted, so a
    # notebook can never silently vanish from the tree when its parent is gone.
    roots = [nb for nb in all_notebooks if nb.parent_id is None or nb.parent_id not in ids]
    tree = [build(nb, set()) for nb in roots]

    # A notebook reachable from no root is trapped in a parent cycle (A→B→A).
    # The REST API forbids cycles, but a sync push sets parent_id without that
    # check, so one can still slip in. Surface any un-emitted notebook as a root
    # (breaking the cycle at that node) rather than letting it disappear — same
    # "a notebook never vanishes" guarantee the orphan handling above provides.
    for nb in all_notebooks:
        if nb.id not in emitted:
            tree.append(build(nb, set()))
    return tree


@router.post("", response_model=NotebookResponse, status_code=201)
async def create_notebook(
    data: NotebookCreate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    parent_uuid = await _resolve_parent(db, current_user, data.parent_id)
    nb = Notebook(
        id=uuid.uuid4(),
        user_id=current_user.id,
        name=data.name,
        parent_id=parent_uuid,
        sort_order=data.sort_order,
    )
    db.add(nb)
    await db.flush()
    await db.refresh(nb)
    return _serialize(nb)


@router.put("/{notebook_id}", response_model=NotebookResponse)
async def update_notebook(
    notebook_id: str,
    data: NotebookUpdate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    try:
        nb_uuid = uuid.UUID(notebook_id)
    except (ValueError, TypeError):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Notebook not found")
    nb = (await db.execute(
        select(Notebook).where(
            Notebook.id == nb_uuid, Notebook.user_id == current_user.id, Notebook.is_deleted == False  # noqa: E712
        )
    )).scalar_one_or_none()
    if not nb:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Notebook not found")

    if data.name is not None:
        nb.name = data.name
    # Omitted = leave unchanged; explicit null/"" = move to top level.
    if "parent_id" in data.model_fields_set:
        nb.parent_id = await _resolve_parent(db, current_user, data.parent_id, this_id=nb.id)
    if data.sort_order is not None:
        nb.sort_order = data.sort_order

    await db.flush()
    await db.refresh(nb)
    return _serialize(nb)


@router.delete("/{notebook_id}", status_code=204)
async def delete_notebook(
    notebook_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    try:
        nb_uuid = uuid.UUID(notebook_id)
    except (ValueError, TypeError):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Notebook not found")
    nb = (await db.execute(
        select(Notebook).where(
            Notebook.id == nb_uuid, Notebook.user_id == current_user.id, Notebook.is_deleted == False  # noqa: E712
        )
    )).scalar_one_or_none()
    if not nb:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Notebook not found")

    nb.is_deleted = True
    nb.deleted_at = datetime.now(timezone.utc)
    await db.flush()
