import uuid
from datetime import datetime, timezone
from typing import Optional

from fastapi import HTTPException, status
from sqlalchemy import select, func, and_
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.user import User
from app.models.note import Note
from app.models.notebook import Notebook
from app.models.task import Task
from app.schemas.task import TaskCreate, TaskUpdate
from app.services.task_crdt import initial_field_clocks, serialize_clock


# A chain deeper than this costs a query per level to validate and is far past
# anything a person builds on purpose.
_MAX_SUBTASK_DEPTH = 32


def _clean_labels(value: Optional[list[str]]) -> list[str]:
    """Trim, bound and de-duplicate label names, preserving display case."""
    if not value:
        return []
    seen: set[str] = set()
    labels: list[str] = []
    for entry in value:
        if not isinstance(entry, str):
            continue
        name = entry.strip()[:64]
        if not name:
            continue
        key = name.casefold()
        if key in seen:
            continue
        seen.add(key)
        labels.append(name)
    return labels


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
        offset = (page - 1) * page_size
        count_query = select(func.count()).select_from(base.subquery())
        rows = (await db.execute(
            base.add_columns(func.count().over().label("_total")).order_by(
                # Open tasks first; then by due date (undated last), manual
                # order, and finally id as the stable pagination tiebreaker.
                Task.is_completed.asc(),
                Task.due_date.asc().nulls_last(),
                Task.sort_order.asc(),
                Task.created_at.asc(),
                Task.id.asc(),
            ).offset(offset).limit(page_size)
        )).all()
        tasks = [row[0] for row in rows]
        if rows:
            total = int(rows[0][1])
        elif offset:
            total = int((await db.execute(count_query)).scalar() or 0)
        else:
            total = 0
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
        now = datetime.now(timezone.utc)
        task_id = uuid.uuid4()
        due_date = _aware(data.due_date)
        task = Task(
            id=task_id,
            user_id=user.id,
            note_id=await self._owned_note_uuid(db, user, data.note_id),
            notebook_id=await self._owned_notebook_uuid(db, user, data.notebook_id),
            parent_id=await self._owned_parent_uuid(db, user, task_id, data.parent_id),
            title=data.title,
            description=data.description,
            due_date=due_date,
            # A time of day is only meaningful with a date to attach it to.
            due_has_time=bool(data.due_has_time) and due_date is not None,
            priority=data.priority,
            labels=_clean_labels(data.labels),
            recurrence=data.recurrence or None,
            reminder_at=_aware(data.reminder_at),
            reminder_lead_minutes=data.reminder_lead_minutes,
            sort_order=data.sort_order,
            edited_at=now,
            field_clocks=initial_field_clocks(now, "server"),
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

        changed_fields: set[str] = set()
        if data.title is not None and data.title != task.title:
            task.title = data.title
            changed_fields.add("title")
        if data.description is not None and data.description != task.description:
            task.description = data.description
            changed_fields.add("description")
        # Explicit null clears; omitted leaves unchanged (same contract as notes).
        if "note_id" in data.model_fields_set:
            task.note_id = await self._owned_note_uuid(db, user, data.note_id)
            changed_fields.add("note_id")
        if "due_date" in data.model_fields_set:
            task.due_date = _aware(data.due_date)
            # due_has_time rides inside the due_date register, so setting a
            # date without saying anything about time clears the flag rather
            # than leaving a stale "5pm" attached to an all-day task.
            requested_time = (
                data.due_has_time
                if "due_has_time" in data.model_fields_set
                else task.due_has_time
            )
            task.due_has_time = bool(requested_time) and task.due_date is not None
            changed_fields.add("due_date")
        elif "due_has_time" in data.model_fields_set:
            task.due_has_time = bool(data.due_has_time) and task.due_date is not None
            changed_fields.add("due_date")
        if "notebook_id" in data.model_fields_set:
            task.notebook_id = await self._owned_notebook_uuid(db, user, data.notebook_id)
            changed_fields.add("notebook_id")
        if "parent_id" in data.model_fields_set:
            task.parent_id = await self._owned_parent_uuid(db, user, task.id, data.parent_id)
            changed_fields.add("parent_id")
        if data.priority is not None and data.priority != task.priority:
            task.priority = data.priority
            changed_fields.add("priority")
        if data.labels is not None:
            cleaned = _clean_labels(data.labels)
            if cleaned != (task.labels or []):
                task.labels = cleaned
                changed_fields.add("labels")
        if "recurrence" in data.model_fields_set:
            task.recurrence = data.recurrence or None
            changed_fields.add("recurrence")
        if "reminder_at" in data.model_fields_set:
            task.reminder_at = _aware(data.reminder_at)
            changed_fields.add("reminder_at")
        if "reminder_lead_minutes" in data.model_fields_set:
            task.reminder_lead_minutes = data.reminder_lead_minutes
            changed_fields.add("reminder_lead_minutes")
        if data.is_completed is not None and data.is_completed != task.is_completed:
            task.is_completed = data.is_completed
            task.completed_at = datetime.now(timezone.utc) if data.is_completed else None
            changed_fields.add("is_completed")
        if data.sort_order is not None and data.sort_order != task.sort_order:
            task.sort_order = data.sort_order
            changed_fields.add("sort_order")

        if changed_fields:
            now = datetime.now(timezone.utc)
            task.updated_at = now
            task.edited_at = now
            clocks = dict(task.field_clocks or {})
            for field in changed_fields:
                clocks[field] = serialize_clock((now, "server"))
            task.field_clocks = clocks
            await db.flush()
        return task

    async def delete_task(self, db: AsyncSession, user: User, task_id: str) -> None:
        task = await self.get_task(db, user, task_id)
        if not task.is_deleted:
            now = datetime.now(timezone.utc)
            task.is_deleted = True
            task.deleted_at = now
            task.updated_at = now
            task.edited_at = now
            task.field_clocks = {
                **(task.field_clocks or {}),
                "is_deleted": serialize_clock((now, "server")),
            }
            await db.flush()

    async def restore_task(self, db: AsyncSession, user: User, task_id: str) -> Task:
        task = await self.get_task(db, user, task_id)
        if not task.is_deleted:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Deleted task not found")
        task.is_deleted = False
        task.deleted_at = None
        now = datetime.now(timezone.utc)
        task.updated_at = now
        task.edited_at = now
        task.field_clocks = {
            **(task.field_clocks or {}),
            "is_deleted": serialize_clock((now, "server")),
        }
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

    @staticmethod
    async def _owned_notebook_uuid(db: AsyncSession, user: User, notebook_id_str) -> Optional[uuid.UUID]:
        """The notebook a task is filed under. Empty/None → unfiled.

        Tasks reuse the notebook tree rather than introducing a second
        hierarchy, so the same ownership rules apply as for notes.
        """
        if not notebook_id_str:
            return None
        nb_uuid = _uuid_or_404(notebook_id_str, "Notebook not found")
        ok = (await db.execute(
            select(Notebook.id).where(
                Notebook.id == nb_uuid,
                Notebook.user_id == user.id,
                Notebook.is_deleted == False,  # noqa: E712
            )
        )).scalar_one_or_none()
        if ok is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Notebook not found")
        return nb_uuid

    @staticmethod
    async def _owned_parent_uuid(
        db: AsyncSession, user: User, task_id: uuid.UUID, parent_id_str
    ) -> Optional[uuid.UUID]:
        """The parent of a subtask. Empty/None → top level.

        A task cannot be its own parent, nor descend from itself. The client
        walks this tree to indent rows and roll subtask progress up, so a cycle
        would hang the UI rather than merely look wrong.
        """
        if not parent_id_str:
            return None
        parent_uuid = _uuid_or_404(parent_id_str, "Parent task not found")
        if parent_uuid == task_id:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="A task cannot be its own parent",
            )

        cursor: Optional[uuid.UUID] = parent_uuid
        for _ in range(_MAX_SUBTASK_DEPTH):
            if cursor is None:
                return parent_uuid
            if cursor == task_id:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail="That would make the task a descendant of itself",
                )
            row = (await db.execute(
                select(Task.parent_id).where(
                    Task.id == cursor,
                    Task.user_id == user.id,
                    Task.is_deleted == False,  # noqa: E712
                )
            )).one_or_none()
            if row is None:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND, detail="Parent task not found"
                )
            cursor = row[0]
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="Subtask nesting is too deep"
        )


task_service = TaskService()
