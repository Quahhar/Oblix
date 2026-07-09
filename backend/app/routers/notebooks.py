from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload
from app.database import get_db
from app.models.notebook import Notebook
from app.schemas.notebook import NotebookCreate, NotebookUpdate, NotebookResponse
from app.utils.auth_dependency import get_current_user
from app.models.user import User
from fastapi import HTTPException, status

router = APIRouter(prefix="/notebooks", tags=["notebooks"])


@router.get("", response_model=list[NotebookResponse])
async def list_notebooks(
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    result = await db.execute(
        select(Notebook)
        .where(Notebook.user_id == current_user.id, Notebook.is_deleted == False, Notebook.parent_id == None)
        .options(selectinload(Notebook.children))
        .order_by(Notebook.sort_order, Notebook.name)
    )
    notebooks = result.scalars().unique().all()
    return notebooks


@router.post("", response_model=NotebookResponse, status_code=201)
async def create_notebook(
    data: NotebookCreate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    import uuid
    nb = Notebook(
        id=uuid.uuid4(),
        user_id=current_user.id,
        name=data.name,
        parent_id=uuid.UUID(data.parent_id) if data.parent_id else None,
        sort_order=data.sort_order,
    )
    db.add(nb)
    await db.flush()
    await db.refresh(nb)
    return nb


@router.put("/{notebook_id}", response_model=NotebookResponse)
async def update_notebook(
    notebook_id: str,
    data: NotebookUpdate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    import uuid
    result = await db.execute(
        select(Notebook).where(Notebook.id == notebook_id, Notebook.user_id == current_user.id, Notebook.is_deleted == False)
    )
    nb = result.scalar_one_or_none()
    if not nb:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Notebook not found")

    if data.name is not None:
        nb.name = data.name
    if data.parent_id is not None:
        nb.parent_id = uuid.UUID(data.parent_id) if data.parent_id else None
    if data.sort_order is not None:
        nb.sort_order = data.sort_order

    await db.flush()
    await db.refresh(nb)
    return nb


@router.delete("/{notebook_id}", status_code=204)
async def delete_notebook(
    notebook_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    result = await db.execute(
        select(Notebook).where(Notebook.id == notebook_id, Notebook.user_id == current_user.id, Notebook.is_deleted == False)
    )
    nb = result.scalar_one_or_none()
    if not nb:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Notebook not found")

    nb.is_deleted = True
    nb.deleted_at = None  # will be set by DB default
    from datetime import datetime, timezone
    nb.deleted_at = datetime.now(timezone.utc)
    await db.flush()