import uuid
from datetime import datetime, timezone
from typing import Optional

from fastapi import HTTPException, status
from sqlalchemy import select, func, and_
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.user import User
from app.models.note import Note
from app.models.task import Task
from app.schemas.task import TaskCreate, TaskUpdate


def _uuid_or_404(value, detail: str) -> uuid.UUID:
    try:
        return uuid.UUID(str(value))
    except (ValueError, TypeError):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=detail)


def _aware(dt: Optional[datetime]) -> Optional[datetime]:
    """Normalize a client datetime to timezone-aware UTC (naive input = UTC);
    the column is timestamptz and asyncpg rejects naive datetimes for it."""
    if dt is not None and dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt


class TaskService:

    async def list_tasks(
        self,
        db: AsyncSession,
        user: User,
        note_id: Optional[str] = None,
        is_completed: Optional[bool] = None,
        is_deleted: bool = False,
        due_before: Optional[datetime] = None,
        page: int = 1,
        page_size: int = 100,
    ) -> dict:
        conditions = [Task.user_id == user.id, Task.is_deleted == is_deleted]
        if note_id:
            conditions.append(Task.note_id == _uuid_or_404(note_id, "Note not found"))
        if is_completed is not None:
            conditions.append(Task.is_completed == is_completed)
        if due_before is not None:
            conditions.append(Task.due_date <= _aware(due_before))

        base = select(Task).where(and_(*conditions))
        total = (await db.execute(select(func.count()).select_from(base.subquery()))).scalar() or 0
        tasks = (await db.execute(
            base.order_by(
                # Open tasks first; then by due date (undated last), manual
                # order, and finally id as the stable pagination tiebreaker.
                Task.is_completed.asc(),
                Task.due_date.asc().nulls_last(),
                Task.sort_order.asc(),
                Task.created_at.asc(),
                Task.id.asc(),
            ).offset((page - 1) * page_size).limit(page_size)
        )).scalars().all()
        return {"tasks": tasks, "total": total, "page": page, "page_size": page_size}

    async def get_task(self, db: AsyncSession, user: User, task_id: str) -> Task:
        t_uuid = _uuid_or_404(task_id, "Task not found")
        task = (await db.execute(
            select(Task).where(Task.id == t_uuid, Task.user_id == user.id)
        )).scalar_one_or_none()
        if task is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Task not found")
        return task

    async def create_task(self, db: AsyncSession, user: User, data: TaskCreate) -> Task:
        task = Task(
            id=uuid.uuid4(),
            user_id=user.id,
            note_id=await self._owned_note_uuid(db, user, data.note_id),
            title=data.title,
            description=data.description,
            due_date=_aware(data.due_date),
            sort_order=data.sort_order,
            edited_at=datetime.now(timezone.utc),
        )
        db.add(task)
        await db.flush()
        # Populate server-default timestamps for the response. Task has no lazy
        # relationships that refresh could mis-mark as loaded (cf. notes).
        await db.refresh(task)
        return task

    async def update_task(self, db: AsyncSession, user: User, task_id: str, data: TaskUpdate) -> Task:
        task = await self.get_task(db, user, task_id)
        if task.is_deleted:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Task not found")

        changed = False
        if data.title is not None and data.title != task.title:
            task.title = data.title
            changed = True
        if data.description is not None and data.description != task.description:
            task.description = data.description
            changed = True
        # Explicit null clears; omitted leaves unchanged (same contract as notes).
        if "note_id" in data.model_fields_set:
            task.note_id = await self._owned_note_uuid(db, user, data.note_id)
            changed = True
        if "due_date" in data.model_fields_set:
            task.due_date = _aware(data.due_date)
            changed = True
        if data.is_completed is not None and data.is_completed != task.is_completed:
            task.is_completed = data.is_completed
            task.completed_at = datetime.now(timezone.utc) if data.is_completed else None
            changed = True
        if data.sort_order is not None and data.sort_order != task.sort_order:
            task.sort_order = data.sort_order
            changed = True

        if changed:
            now = datetime.now(timezone.utc)
            task.updated_at = now
            task.edited_at = now
            await db.flush()
        return task

    async def delete_task(self, db: AsyncSession, user: User, task_id: str) -> None:
        task = await self.get_task(db, user, task_id)
        if not task.is_deleted:
            task.is_deleted = True
            task.deleted_at = datetime.now(timezone.utc)
            task.updated_at = datetime.now(timezone.utc)
            await db.flush()

    async def restore_task(self, db: AsyncSession, user: User, task_id: str) -> Task:
        task = await self.get_task(db, user, task_id)
        if not task.is_deleted:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Deleted task not found")
        task.is_deleted = False
        task.deleted_at = None
        task.updated_at = datetime.now(timezone.utc)
        await db.flush()
        return task

    @staticmethod
    async def _owned_note_uuid(db: AsyncSession, user: User, note_id_str) -> Optional[uuid.UUID]:
        """Empty/None → unattached. Malformed, unknown, foreign or tombstoned
        note ids raise 404 rather than 500ing on the FK or silently linking a
        task to someone else's note."""
        if not note_id_str:
            return None
        n_uuid = _uuid_or_404(note_id_str, "Note not found")
        ok = (await db.execute(
            select(Note.id).where(
                Note.id == n_uuid, Note.user_id == user.id, Note.is_deleted == False  # noqa: E712
            )
        )).scalar_one_or_none()
        if ok is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Note not found")
        return n_uuid


task_service = TaskService()
