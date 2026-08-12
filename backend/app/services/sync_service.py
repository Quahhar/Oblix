import uuid
import json
import base64
from datetime import datetime, timezone, timedelta
from typing import Optional
from sqlalchemy import select, delete, and_, or_, exists, literal, union_all, inspect as sa_inspect
from sqlalchemy.orm import joinedload, selectinload
from sqlalchemy.ext.asyncio import AsyncSession
from app.models.user import User
from app.models.note import Note, ContentType
from app.models.notebook import Notebook
from app.models.tag import Tag, NoteTag
from app.models.file import File
from app.models.task import Task
from app.models.sync import SyncLog, EntityType, SyncAction
from app.models.collaboration import CollaborationOperation
from app.schemas.sync import SyncChangeItem
from app.services.task_crdt import (
    NOTEBOOK_CRDT_FIELDS,
    NOTE_CRDT_FIELDS,
    TASK_CRDT_FIELDS,
    initial_field_clocks,
    serialize_clock,
    winning_fields,
)


def _coerce_content_type(value) -> ContentType:
    """Accept an enum, its value ('plain') or its name ('PLAIN'); default PLAIN."""
    if isinstance(value, ContentType):
        return value
    if isinstance(value, str):
        try:
            return ContentType(value)
        except ValueError:
            try:
                return ContentType[value.upper()]
            except KeyError:
                return ContentType.PLAIN
    return ContentType.PLAIN


def _parse_ts(value: Optional[str]) -> Optional[datetime]:
    """Parse an ISO-8601 timestamp into a timezone-aware UTC datetime, or None.

    Accepts both '...Z' and '...+00:00' forms. Naive timestamps are assumed UTC.
    """
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def _clean_labels(value) -> list[str]:
    """Normalize an incoming label list.

    Labels are denormalized names, exactly as notes denormalize their tags, so
    an untrusted client list is bounded and de-duplicated here rather than
    trusted into the row. Case is preserved — a label is shown to the user —
    but duplicates that differ only in case are collapsed.
    """
    if not isinstance(value, list):
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
        if len(labels) >= 32:
            break
    return labels


def _client_ts(value: Optional[str], now: Optional[datetime] = None) -> Optional[datetime]:
    """Parse a client timestamp and cap unreasonable clock skew.

    A client several years in the future must not permanently win last-write-
    wins conflict resolution. Allow five minutes for normal device skew, then
    use the server clock. Past timestamps remain meaningful for offline edits.
    """
    parsed = _parse_ts(value)
    if parsed is None:
        return None
    server_now = now or datetime.now(timezone.utc)
    if parsed > server_now + timedelta(minutes=5):
        return server_now
    return parsed


def _encode_cursor(ts_iso: str, entity_id: str) -> str:
    """Opaque pagination cursor pointing at the last returned (updated_at, id)."""
    return base64.urlsafe_b64encode(
        json.dumps({"t": ts_iso, "i": entity_id}).encode()
    ).decode()


def _decode_cursor(cursor: str):
    """Decode a cursor to (datetime, uuid), or None if it's malformed (then the
    read simply falls back to the `since` floor rather than erroring)."""
    try:
        d = json.loads(base64.urlsafe_b64decode(cursor.encode()).decode())
        return _parse_ts(d["t"]), uuid.UUID(d["i"])
    except Exception:
        return None


class SyncService:

    async def push_changes(
        self,
        db: AsyncSession,
        user: User,
        changes: list[SyncChangeItem],
        last_sync_at: Optional[str] = None,
    ) -> dict:
        """Process incoming changes from a client.

        Each change is applied inside its own SAVEPOINT so that a single failing
        change (e.g. an integrity error) is rolled back on its own without
        poisoning the whole batch or the changes already applied.
        """
        applied: list[str] = []
        conflicts: list[dict] = []
        # Capture the cursor the client should adopt next, BEFORE mutating rows,
        # so a concurrent write landing mid-request isn't skipped next sync.
        server_time = datetime.now(timezone.utc).isoformat()

        for change in changes:
            try:
                async with db.begin_nested():  # SAVEPOINT per change
                    result = await self._apply_change(db, user, change)
                    if result.get("conflict"):
                        # No DB mutation to keep; raise to unwind the savepoint cleanly.
                        raise _ConflictError(result)
            except _ConflictError as ce:
                r = ce.result
                conflicts.append({
                    "entity_type": change.entity_type,
                    "entity_id": change.entity_id,
                    "server_data": r.get("server_data", {}),
                    "client_data": change.data,
                    "reason": r.get("reason", "Conflict"),
                })
                continue
            except Exception:  # noqa: BLE001 - report per-change failure, keep going
                # Don't leak internal error text (SQL/driver detail) to clients.
                conflicts.append({
                    "entity_type": change.entity_type,
                    "entity_id": change.entity_id,
                    "server_data": {},
                    "client_data": change.data,
                    "reason": "Failed to apply change",
                })
                continue

            applied.append(change.entity_id)
            db.add(SyncLog(
                id=uuid.uuid4(),
                user_id=user.id,
                entity_type=EntityType(change.entity_type),
                entity_id=uuid.UUID(change.entity_id),
                action=SyncAction(change.action),
                device_id=change.device_id,
            ))

        await db.flush()

        # Return everything that changed since the client's last sync so the
        # push response alone is enough to catch the client up (it need not pull
        # separately right after).
        server_changes = await self._get_changes_since(
            db,
            user,
            last_sync_at,
            # A single indexed probe identifies the entity types that changed.
            # An idle cycle stops there; a typical note edit then hydrates only
            # notes instead of querying all five entity tables.
            probe_changed_types=True,
        )

        return {
            "applied": applied,
            "conflicts": conflicts,
            "server_changes": server_changes,
            "server_time": server_time,
        }

    async def pull_changes(
        self,
        db: AsyncSession,
        user: User,
        since: Optional[str] = None,
        entity_types: Optional[list[str]] = None,
        limit: Optional[int] = None,
        cursor: Optional[str] = None,
    ) -> dict:
        """Return changes since a given timestamp.

        server_time is captured BEFORE reading rows so the client can safely use
        it as the next cursor without a race window dropping concurrent writes.

        Pagination is opt-in: without `limit` this returns every change (the
        original behaviour). With `limit` it returns at most that many changes
        plus `has_more`/`next_cursor`, so a first sync of a large account can be
        pulled in bounded pages instead of one giant response.
        """
        server_time = datetime.now(timezone.utc).isoformat()
        if limit is None:
            changes = await self._get_changes_since(
                db, user, since, entity_types, probe_changed_types=True
            )
            return {"changes": changes, "server_time": server_time,
                    "has_more": False, "next_cursor": None}
        changes, has_more, next_cursor = await self._get_changes_page(
            db, user, since, entity_types, limit, cursor
        )
        return {"changes": changes, "server_time": server_time,
                "has_more": has_more, "next_cursor": next_cursor}

    async def _apply_change(self, db: AsyncSession, user: User, change: SyncChangeItem) -> dict:
        """Apply a single sync change. Returns conflict info if applicable."""
        entity_type = change.entity_type

        if entity_type == "note":
            return await self._apply_note_change(db, user, change.entity_id, change)
        elif entity_type == "notebook":
            return await self._apply_notebook_change(db, user, change.entity_id, change)
        elif entity_type == "tag":
            return await self._apply_tag_change(db, user, change.entity_id, change)
        elif entity_type == "file":
            return await self._apply_file_change(db, user, change.entity_id, change)
        elif entity_type == "task":
            return await self._apply_task_change(db, user, change.entity_id, change)
        else:
            return {"conflict": True, "reason": f"Unknown entity type: {entity_type}"}

    async def _apply_note_change(self, db: AsyncSession, user: User, entity_id: str, change: SyncChangeItem) -> dict:
        existing = await self._get_note_with_tags(db, user, entity_id)
        client_data = change.data
        client_ts = _client_ts(change.timestamp)
        now = datetime.now(timezone.utc)
        device_id = str(change.device_id or "")[:255]

        if change.action == "create":
            if existing and not existing.is_deleted:
                return {"conflict": True, "server_data": self._note_to_dict(existing),
                        "reason": "Note already exists on server"}
            if existing and existing.is_deleted:
                changed = await self._merge_note_fields(
                    db,
                    user,
                    existing,
                    {**client_data, "is_deleted": False},
                    change.timestamp,
                    device_id,
                    now,
                )
                if changed:
                    existing.updated_at = now
                return {}
            note = Note(
                id=uuid.UUID(entity_id),
                user_id=user.id,
            )
            await self._apply_note_fields(db, user, note, client_data, set(client_data))
            # Preserve the note's real creation time (it was created offline on
            # the client); otherwise func.now() stamps it with the sync time and
            # the note shows "created today" on every other device. Stamp
            # updated_at on the server clock so it lines up with the sync cursor.
            created = _client_ts(client_data.get("created_at"))
            if created is not None:
                note.created_at = created
            note.updated_at = now
            note.edited_at = client_ts or created or now
            note.field_clocks = initial_field_clocks(
                note.edited_at, device_id, NOTE_CRDT_FIELDS
            )
            db.add(note)
            await self._apply_note_tags(db, user, note, client_data)
            return {}

        elif change.action == "update":
            if not existing:
                return {"conflict": True, "reason": "Note not found on server"}
            restore_only = (
                existing.is_deleted
                and client_data.get("is_deleted") is False
                and not any(
                    field in client_data
                    for field in NOTE_CRDT_FIELDS
                    if field != "is_deleted"
                )
            )
            payload = {
                key: value
                for key, value in client_data.items()
                if key != "is_deleted" or restore_only
            }
            changed = await self._merge_note_fields(
                db, user, existing, payload, change.timestamp, device_id, now
            )
            if changed:
                existing.updated_at = now
            return {}

        elif change.action == "delete":
            if existing:
                changed = await self._merge_note_fields(
                    db,
                    user,
                    existing,
                    {
                        "is_deleted": True,
                        "is_archived": False,
                        "field_clocks": client_data.get("field_clocks", {}),
                    },
                    change.timestamp,
                    device_id,
                    now,
                )
                if changed:
                    existing.updated_at = now
            return {}

        return {"conflict": True, "reason": f"Unknown action: {change.action}"}

    @staticmethod
    async def _owned_notebook_id(db: AsyncSession, user: User, raw) -> Optional[uuid.UUID]:
        """Coerce a client-supplied notebook/parent id to a UUID the user owns.

        Sync push bypasses REST validation, so a hostile or buggy client can
        send another user's notebook id, a random UUID, or garbage. Any of
        those degrade to None (unfiled / top level) instead of failing the
        change or creating a cross-tenant reference. Deliberately does NOT
        filter is_deleted: a tombstoned notebook may be resurrected by another
        device later in the same batch or a later sync.
        """
        if not raw:
            return None
        try:
            nb_id = uuid.UUID(str(raw))
        except (ValueError, TypeError):
            return None
        owned = (await db.execute(
            select(Notebook.id).where(Notebook.id == nb_id, Notebook.user_id == user.id)
        )).scalar_one_or_none()
        return owned

    async def _safe_notebook_parent(
        self,
        db: AsyncSession,
        user: User,
        raw,
        this_id: uuid.UUID,
    ) -> Optional[uuid.UUID]:
        """Resolve an owned parent and reject self/descendant cycles."""
        parent_id = await self._owned_notebook_id(db, user, raw)
        if parent_id is None or parent_id == this_id:
            return None

        rows = (
            await db.execute(
                select(Notebook.id, Notebook.parent_id).where(
                    Notebook.user_id == user.id
                )
            )
        ).all()
        parents = {row[0]: row[1] for row in rows}
        cursor = parent_id
        seen: set[uuid.UUID] = set()
        while cursor is not None:
            if cursor == this_id or cursor in seen:
                return None
            seen.add(cursor)
            cursor = parents.get(cursor)
        return parent_id

    async def _apply_note_fields(
        self, db: AsyncSession, user: User, note: Note,
        client_data: dict, fields: set[str]
    ) -> None:
        replaces_ot_baseline = sa_inspect(note).persistent and (
            ("title" in fields and client_data["title"] != note.title)
            or ("content" in fields and client_data["content"] != note.content)
        )
        if replaces_ot_baseline:
            await db.execute(
                delete(CollaborationOperation).where(
                    CollaborationOperation.note_id == note.id
                )
            )
            note.collab_revision = 0
            note.collab_epoch = uuid.uuid4()
        for key in ("title", "content", "is_pinned", "is_archived"):
            if key in fields:
                setattr(note, key, client_data[key])
        if "content_type" in fields:
            note.content_type = _coerce_content_type(client_data["content_type"])
        if "notebook_id" in fields:
            note.notebook_id = await self._owned_notebook_id(db, user, client_data["notebook_id"])
        if "is_deleted" in fields:
            note.is_deleted = bool(client_data["is_deleted"])
            note.deleted_at = datetime.now(timezone.utc) if note.is_deleted else None

    async def _merge_note_fields(
        self, db: AsyncSession, user: User, note: Note, client_data: dict,
        envelope_timestamp: str, device_id: str, now: datetime,
    ) -> set[str]:
        winners = winning_fields(
            note.field_clocks,
            client_data,
            current_fallback_timestamp=note.edited_at or note.updated_at,
            incoming_fallback_timestamp=envelope_timestamp,
            incoming_device_id=device_id,
            now=now,
            fields=NOTE_CRDT_FIELDS,
        )
        if not winners:
            return set()
        await self._apply_note_fields(db, user, note, client_data, set(winners))
        if "tags" in winners:
            await self._apply_note_tags(db, user, note, client_data)
        clocks = dict(note.field_clocks or {})
        for field, stamp in winners.items():
            clocks[field] = serialize_clock(stamp)
        note.field_clocks = clocks
        newest = max(stamp[0] for stamp in winners.values())
        note.edited_at = max(filter(None, (note.edited_at, newest)))
        return set(winners)

    async def _apply_note_tags(self, db: AsyncSession, user: User, note: Note, client_data: dict) -> None:
        """Replace a note's tag links with the names the client sent.

        Clients send `tags` as a list of names (strings); server payloads use
        [{"name": ...}] — accept both. Missing tags are created; tombstoned
        ones are resurrected. Absent `tags` key means "unchanged".
        """
        if "tags" not in client_data:
            return
        names: list[str] = []
        for raw in client_data["tags"] or []:
            name = raw.get("name") if isinstance(raw, dict) else raw
            if isinstance(name, str) and name.strip():
                if name.strip() not in names:
                    names.append(name.strip())

        tags: list[Tag] = []
        if names:
            result = await db.execute(
                select(Tag).where(Tag.user_id == user.id, Tag.name.in_(names))
            )
            by_name = {t.name: t for t in result.scalars().all()}
            for name in names:
                tag = by_name.get(name)
                if tag is None:
                    tag = Tag(id=uuid.uuid4(), user_id=user.id, name=name)
                    db.add(tag)
                elif tag.is_deleted:
                    tag.is_deleted = False
                    tag.deleted_at = None
                    tag.updated_at = datetime.now(timezone.utc)
                tags.append(tag)

        # Reconcile the association rows directly — never assign note.tags:
        # that would lazy-load the collection, which raises greenlet_spawn
        # errors under the async engine (the tag SELECT above autoflushes the
        # pending note, making it persistent before the assignment).
        existing_ids = set(
            (
                await db.execute(
                    select(NoteTag.tag_id).where(NoteTag.note_id == note.id)
                )
            ).scalars()
        )
        desired_ids = {t.id for t in tags}
        to_remove = existing_ids - desired_ids
        if to_remove:
            await db.execute(
                delete(NoteTag)
                .where(NoteTag.note_id == note.id, NoteTag.tag_id.in_(to_remove))
                .execution_options(synchronize_session=False)
            )
        for t in tags:
            if t.id not in existing_ids:
                db.add(NoteTag(note_id=note.id, tag_id=t.id))

    async def _apply_notebook_change(self, db: AsyncSession, user: User, entity_id: str, change: SyncChangeItem) -> dict:
        existing = await self._get_one(db, Notebook, user, entity_id)
        client_data = change.data
        client_ts = _client_ts(change.timestamp)
        now = datetime.now(timezone.utc)
        device_id = str(change.device_id or "")[:255]

        if change.action == "create":
            if existing and not existing.is_deleted:
                return {}  # idempotent: already there
            if existing and existing.is_deleted:
                changed = await self._merge_notebook_fields(
                    db, user, existing, {**client_data, "is_deleted": False},
                    change.timestamp, device_id, now
                )
                if changed:
                    existing.updated_at = now
                return {}
            target = Notebook(id=uuid.UUID(entity_id), user_id=user.id)
            await self._apply_notebook_values(
                db, user, target, client_data, set(client_data)
            )
            created = _client_ts(client_data.get("created_at"))
            if created is not None:
                target.created_at = created
            target.updated_at = now
            target.field_clocks = initial_field_clocks(
                client_ts or created or now, device_id, NOTEBOOK_CRDT_FIELDS
            )
            db.add(target)
            return {}

        elif change.action == "update":
            if not existing:
                return {"conflict": True, "reason": "Notebook not found on server"}
            payload = {key: value for key, value in client_data.items()
                       if key != "is_deleted"}
            changed = await self._merge_notebook_fields(
                db, user, existing, payload, change.timestamp, device_id, now
            )
            if changed:
                existing.updated_at = now
            return {}

        elif change.action == "delete":
            if existing:
                changed = await self._merge_notebook_fields(
                    db, user, existing,
                    {"is_deleted": True,
                     "field_clocks": client_data.get("field_clocks", {})},
                    change.timestamp, device_id, now
                )
                if changed:
                    existing.updated_at = now
            return {}

        return {}

    async def _apply_notebook_values(
        self, db: AsyncSession, user: User, notebook: Notebook,
        client_data: dict, fields: set[str]
    ) -> None:
        if "name" in fields:
            notebook.name = str(client_data["name"] or "New Notebook")[:255]
        if "sort_order" in fields:
            notebook.sort_order = int(client_data["sort_order"])
        if "parent_id" in fields:
            notebook.parent_id = await self._safe_notebook_parent(
                db, user, client_data["parent_id"], notebook.id
            )
        if "is_deleted" in fields:
            notebook.is_deleted = bool(client_data["is_deleted"])
            notebook.deleted_at = (
                datetime.now(timezone.utc) if notebook.is_deleted else None
            )

    async def _merge_notebook_fields(
        self, db: AsyncSession, user: User, notebook: Notebook,
        client_data: dict, envelope_timestamp: str,
        device_id: str, now: datetime,
    ) -> set[str]:
        winners = winning_fields(
            notebook.field_clocks,
            client_data,
            current_fallback_timestamp=notebook.updated_at,
            incoming_fallback_timestamp=envelope_timestamp,
            incoming_device_id=device_id,
            now=now,
            fields=NOTEBOOK_CRDT_FIELDS,
        )
        if not winners:
            return set()
        await self._apply_notebook_values(
            db, user, notebook, client_data, set(winners)
        )
        clocks = dict(notebook.field_clocks or {})
        for field, stamp in winners.items():
            clocks[field] = serialize_clock(stamp)
        notebook.field_clocks = clocks
        return set(winners)

    async def _apply_tag_change(self, db: AsyncSession, user: User, entity_id: str, change: SyncChangeItem) -> dict:
        existing = await self._get_one(db, Tag, user, entity_id)
        client_data = change.data

        if change.action == "create":
            if existing:
                existing.name = client_data.get("name", existing.name)
                if existing.is_deleted:
                    existing.is_deleted = False
                    existing.deleted_at = None
                existing.updated_at = datetime.now(timezone.utc)
                return {}
            tag = Tag(id=uuid.UUID(entity_id), user_id=user.id, name=client_data.get("name", "New Tag"))
            created = _client_ts(client_data.get("created_at"))
            if created is not None:
                tag.created_at = created
            tag.updated_at = datetime.now(timezone.utc)
            db.add(tag)
            return {}

        elif change.action == "update":
            if existing and "name" in client_data:
                existing.name = client_data["name"]
                existing.updated_at = datetime.now(timezone.utc)
            return {}

        elif change.action == "delete":
            # Tombstone instead of hard delete so other devices learn about the
            # deletion through their next pull.
            if existing and not existing.is_deleted:
                existing.is_deleted = True
                existing.deleted_at = datetime.now(timezone.utc)
                existing.updated_at = datetime.now(timezone.utc)
            return {}

        return {}

    async def _apply_task_change(self, db: AsyncSession, user: User, entity_id: str, change: SyncChangeItem) -> dict:
        existing = await self._get_one(db, Task, user, entity_id)
        client_data = change.data
        client_ts = _client_ts(change.timestamp)
        now = datetime.now(timezone.utc)
        device_id = str(change.device_id or "")[:255]

        if change.action == "create":
            if existing and not existing.is_deleted:
                return {"conflict": True, "server_data": self._task_to_dict(existing),
                        "reason": "Task already exists on server"}
            if existing and existing.is_deleted:
                payload = {**client_data, "is_deleted": False}
                changed = await self._merge_task_fields(
                    db, user, existing, payload, change.timestamp, device_id, now
                )
                if changed:
                    existing.updated_at = now
                return {}
            created = _client_ts(client_data.get("created_at"))
            edit_time = client_ts or created or now
            task = Task(id=uuid.UUID(entity_id), user_id=user.id, title="Untitled task")
            await self._apply_task_values(
                db,
                user,
                task,
                client_data,
                set(client_data),
                {field: edit_time for field in TASK_CRDT_FIELDS},
            )
            if created is not None:
                task.created_at = created
            task.updated_at = now
            task.edited_at = edit_time
            task.field_clocks = initial_field_clocks(edit_time, device_id)
            db.add(task)
            return {}

        elif change.action == "update":
            if not existing:
                return {"conflict": True, "reason": "Task not found on server"}
            # Normal edits never implicitly resurrect a remotely deleted task.
            payload = {key: value for key, value in client_data.items()
                       if key != "is_deleted"}
            changed = await self._merge_task_fields(
                db, user, existing, payload, change.timestamp, device_id, now
            )
            if changed:
                existing.updated_at = now
            return {}

        elif change.action == "delete":
            if existing:
                changed = await self._merge_task_fields(
                    db,
                    user,
                    existing,
                    {"is_deleted": True,
                     "field_clocks": client_data.get("field_clocks", {})},
                    change.timestamp,
                    device_id,
                    now,
                )
                if changed:
                    existing.updated_at = now
            return {}

        return {"conflict": True, "reason": f"Unknown action: {change.action}"}

    async def _apply_task_values(
        self,
        db: AsyncSession,
        user: User,
        task: Task,
        client_data: dict,
        fields: set[str],
        field_times: Optional[dict[str, datetime]] = None,
    ) -> None:
        if "title" in fields:
            title = str(client_data["title"] or "").strip()
            task.title = title[:500] if title else "Untitled task"
        if "description" in fields:
            task.description = str(client_data["description"] or "")
        if "sort_order" in fields:
            try:
                task.sort_order = int(client_data["sort_order"])
            except (ValueError, TypeError):
                pass
        if "is_completed" in fields:
            completed = bool(client_data["is_completed"])
            task.is_completed = completed
            supplied = _parse_ts(client_data.get("completed_at"))
            task.completed_at = (
                (field_times or {}).get("is_completed") or supplied
            ) if completed else None
        if "due_date" in fields:
            # null/garbage clears; a valid ISO timestamp sets.
            task.due_date = _parse_ts(client_data["due_date"])
            # Carried by the due_date register, so it can never contradict it.
            task.due_has_time = bool(client_data.get("due_has_time")) and task.due_date is not None
        if "note_id" in fields:
            task.note_id = await self._owned_note_id(db, user, client_data["note_id"])
        if "priority" in fields:
            try:
                task.priority = max(0, min(3, int(client_data["priority"])))
            except (ValueError, TypeError):
                pass
        if "labels" in fields:
            task.labels = _clean_labels(client_data["labels"])
        if "recurrence" in fields:
            raw = client_data["recurrence"]
            task.recurrence = str(raw)[:200] if raw else None
        if "reminder_at" in fields:
            task.reminder_at = _parse_ts(client_data["reminder_at"])
        if "reminder_lead_minutes" in fields:
            raw = client_data["reminder_lead_minutes"]
            try:
                # Four weeks of lead is far past anything a person means.
                task.reminder_lead_minutes = (
                    max(0, min(40_320, int(raw))) if raw is not None else None
                )
            except (ValueError, TypeError):
                task.reminder_lead_minutes = None
        if "notebook_id" in fields:
            task.notebook_id = await self._owned_notebook_id(db, user, client_data["notebook_id"])
        if "parent_id" in fields:
            task.parent_id = await self._owned_parent_task_id(
                db, user, task.id, client_data["parent_id"]
            )
        if "is_deleted" in fields:
            task.is_deleted = bool(client_data["is_deleted"])
            task.deleted_at = (
                (field_times or {}).get("is_deleted") if task.is_deleted else None
            )

    async def _merge_task_fields(
        self,
        db: AsyncSession,
        user: User,
        task: Task,
        client_data: dict,
        envelope_timestamp: str,
        device_id: str,
        now: datetime,
    ) -> set[str]:
        winners = winning_fields(
            task.field_clocks,
            client_data,
            current_fallback_timestamp=task.edited_at or task.updated_at,
            incoming_fallback_timestamp=envelope_timestamp,
            incoming_device_id=device_id,
            now=now,
        )
        if not winners:
            return set()
        await self._apply_task_values(
            db,
            user,
            task,
            client_data,
            set(winners),
            {field: stamp[0] for field, stamp in winners.items()},
        )
        clocks = dict(task.field_clocks or {})
        for field, stamp in winners.items():
            clocks[field] = serialize_clock(stamp)
        task.field_clocks = clocks
        newest = max(stamp[0] for stamp in winners.values())
        task.edited_at = max(filter(None, (task.edited_at, newest)))
        return set(winners)

    @staticmethod
    async def _owned_note_id(db: AsyncSession, user: User, raw) -> Optional[uuid.UUID]:
        """Same defensive coercion as _owned_notebook_id, for task→note links."""
        if not raw:
            return None
        try:
            n_id = uuid.UUID(str(raw))
        except (ValueError, TypeError):
            return None
        return (await db.execute(
            select(Note.id).where(Note.id == n_id, Note.user_id == user.id)
        )).scalar_one_or_none()

    @staticmethod
    async def _owned_notebook_id(db: AsyncSession, user: User, raw) -> Optional[uuid.UUID]:
        """The notebook a task is filed under, for task→notebook links.

        An unknown or foreign id unfiles the task instead of raising: a sync
        push is a batch, and one stale reference must not fail the batch.
        """
        if not raw:
            return None
        try:
            nb_id = uuid.UUID(str(raw))
        except (ValueError, TypeError):
            return None
        return (await db.execute(
            select(Notebook.id).where(Notebook.id == nb_id, Notebook.user_id == user.id)
        )).scalar_one_or_none()

    async def _owned_parent_task_id(
        self, db: AsyncSession, user: User, task_id, raw
    ) -> Optional[uuid.UUID]:
        """The parent of a subtask.

        Refuses a task's own id and any ancestor that would close a loop. A
        cycle here is not a cosmetic problem: the client walks the tree to
        render indentation and to roll progress up, and either walk would spin
        forever. Depth is also capped, because a chain thousands deep costs a
        query per level on every push.
        """
        if not raw:
            return None
        try:
            parent_id = uuid.UUID(str(raw))
        except (ValueError, TypeError):
            return None
        if task_id is not None and parent_id == task_id:
            return None

        cursor: Optional[uuid.UUID] = parent_id
        for _ in range(32):
            if cursor is None:
                # Walked off the top without meeting ourselves: the link is safe.
                return parent_id
            if task_id is not None and cursor == task_id:
                return None
            row = (await db.execute(
                select(Task.parent_id).where(Task.id == cursor, Task.user_id == user.id)
            )).one_or_none()
            if row is None:
                # Unknown or someone else's task: leave the subtask top-level.
                return None
            cursor = row[0]
        return None

    async def _apply_file_change(self, db: AsyncSession, user: User, entity_id: str, change: SyncChangeItem) -> dict:
        # Files are created via the multipart upload endpoint, not via sync push
        # (the binary can't travel in a JSON change). Sync only relinks/deletes.
        existing = await self._get_one(db, File, user, entity_id)
        client_data = change.data

        if change.action == "update":
            if existing and "note_id" in client_data:
                raw = client_data["note_id"]
                if not raw:
                    existing.note_id = None
                    existing.updated_at = datetime.now(timezone.utc)
                else:
                    try:
                        target_note_id = uuid.UUID(str(raw))
                    except (ValueError, TypeError):
                        return {}
                    # Only relink to a note the caller actually owns; ignore
                    # foreign/unknown note ids rather than creating a dangling ref.
                    owned = (await db.execute(
                        select(Note.id).where(Note.id == target_note_id, Note.user_id == user.id)
                    )).scalar_one_or_none()
                    if owned:
                        existing.note_id = target_note_id
                        existing.updated_at = datetime.now(timezone.utc)
            return {}

        elif change.action == "delete":
            if existing and not existing.is_deleted:
                existing.is_deleted = True
                existing.deleted_at = datetime.now(timezone.utc)
                existing.updated_at = datetime.now(timezone.utc)
            return {}

        return {}

    # ---- change-dict builders (shared by the full and paginated readers) ----

    def _note_change(self, note: Note) -> dict:
        return {
            "entity_type": "note",
            "entity_id": str(note.id),
            "action": "delete" if note.is_deleted else "update",
            "data": self._note_to_dict(note),
            "timestamp": note.updated_at.isoformat(),
        }

    @staticmethod
    def _notebook_change(nb: Notebook) -> dict:
        return {
            "entity_type": "notebook",
            "entity_id": str(nb.id),
            "action": "delete" if nb.is_deleted else "update",
            "data": {
                "id": str(nb.id),
                "user_id": str(nb.user_id),
                "name": nb.name,
                "parent_id": str(nb.parent_id) if nb.parent_id else None,
                "sort_order": nb.sort_order,
                "is_deleted": nb.is_deleted,
                "created_at": nb.created_at.isoformat(),
                "updated_at": nb.updated_at.isoformat(),
                "field_clocks": nb.field_clocks or {},
            },
            "timestamp": nb.updated_at.isoformat(),
        }

    @staticmethod
    def _tag_change(tag: Tag) -> dict:
        return {
            "entity_type": "tag",
            "entity_id": str(tag.id),
            "action": "delete" if tag.is_deleted else "update",
            "data": {
                "id": str(tag.id),
                "user_id": str(tag.user_id),
                "name": tag.name,
                "is_deleted": tag.is_deleted,
                "created_at": tag.created_at.isoformat(),
                "updated_at": tag.updated_at.isoformat(),
            },
            "timestamp": tag.updated_at.isoformat(),
        }

    @staticmethod
    def _file_change(f: File) -> dict:
        return {
            "entity_type": "file",
            "entity_id": str(f.id),
            "action": "delete" if f.is_deleted else "update",
            "data": {
                "id": str(f.id),
                "filename": f.filename,
                "original_name": f.original_name,
                "mime_type": f.mime_type,
                "size_bytes": f.size_bytes,
                "note_id": str(f.note_id) if f.note_id else None,
                "is_deleted": f.is_deleted,
                "updated_at": f.updated_at.isoformat(),
            },
            "timestamp": f.updated_at.isoformat(),
        }

    @staticmethod
    def _task_change(t: Task) -> dict:
        return {
            "entity_type": "task",
            "entity_id": str(t.id),
            "action": "delete" if t.is_deleted else "update",
            "data": SyncService._task_to_dict(t),
            "timestamp": t.updated_at.isoformat(),
        }

    def _type_specs(self, target_types):
        """(name, model, change-builder, query-options) for the requested types."""
        specs = [
            ("note", Note, self._note_change, (joinedload(Note.tags).joinedload(NoteTag.tag),)),
            ("notebook", Notebook, self._notebook_change, ()),
            ("tag", Tag, self._tag_change, ()),
            ("file", File, self._file_change, ()),
            ("task", Task, self._task_change, ()),
        ]
        return [s for s in specs if s[0] in target_types]

    async def _get_changes_since(
        self, db: AsyncSession, user: User, since: Optional[str] = None,
        entity_types: Optional[list[str]] = None,
        *, probe_changed_types: bool = False,
    ) -> list[dict]:
        """Build list of changed entities since timestamp (inclusive).

        The `since` filter is inclusive (>=) so a row touched at exactly the
        cursor time is never skipped; clients upsert idempotently so re-seeing a
        row is harmless.
        """
        changes: list[dict] = []
        target_types = entity_types or ["note", "notebook", "tag", "file", "task"]
        since_dt = _parse_ts(since)
        specs = self._type_specs(target_types)

        # One UNION-of-EXISTS query tells us exactly which entity tables need
        # hydration. Most background polls stop here; a typical note-only edit
        # turns the old five ORM queries into one probe plus one note query.
        if probe_changed_types and since_dt is not None:
            changed_types = await self._changed_types_since(db, user, since_dt, specs)
            if not changed_types:
                return changes
            specs = [spec for spec in specs if spec[0] in changed_types]

        for _name, model, builder, opts in specs:
            q = select(model).where(model.user_id == user.id)
            for opt in opts:
                q = q.options(opt)
            if since_dt is not None:
                q = q.where(model.updated_at >= since_dt)
            for row in (await db.execute(q)).scalars().unique().all():
                changes.append(builder(row))

        return changes

    @staticmethod
    async def _changed_types_since(
        db, user: User, since_dt: datetime, specs
    ) -> set[str]:
        probes = [
            select(literal(name)).where(
                exists(
                    select(model.id).where(
                        model.user_id == user.id,
                        model.updated_at >= since_dt,
                    )
                )
            )
            for name, model, _builder, _opts in specs
        ]
        if not probes:
            return set()
        result = await db.execute(union_all(*probes))
        return set(result.scalars().all())

    async def _get_changes_page(
        self, db: AsyncSession, user: User, since: Optional[str],
        entity_types: Optional[list[str]], limit: int, cursor: Optional[str],
    ) -> tuple[list[dict], bool, Optional[str]]:
        """Paginated read: at most `limit` changes ordered by (updated_at, id),
        plus has_more and an opaque next_cursor. Each per-type query is capped so
        one huge table can't pull an unbounded result set into memory."""
        target_types = entity_types or ["note", "notebook", "tag", "file", "task"]
        since_dt = _parse_ts(since)
        cur = _decode_cursor(cursor) if cursor else None

        merged: list[tuple] = []  # (updated_at, entity_uuid, change_dict)
        for _name, model, builder, opts in self._type_specs(target_types):
            q = select(model).where(model.user_id == user.id)
            for opt in opts:
                q = q.options(opt)
            if cur is not None:
                cdt, cid = cur
                # Strictly after the cursor position in (updated_at, id) order.
                q = q.where(or_(model.updated_at > cdt,
                                and_(model.updated_at == cdt, model.id > cid)))
            elif since_dt is not None:
                q = q.where(model.updated_at >= since_dt)
            q = q.order_by(model.updated_at.asc(), model.id.asc()).limit(limit + 1)
            for row in (await db.execute(q)).scalars().unique().all():
                merged.append((row.updated_at, row.id, builder(row)))

        # Global order across all types; uuid sorts by int, matching the DB's
        # ordering of the id column, so the cursor and this slice agree.
        merged.sort(key=lambda t: (t[0], t[1]))
        page = merged[:limit]
        has_more = len(merged) > limit
        next_cursor = None
        if has_more and page:
            last_dt, last_id, _ = page[-1]
            next_cursor = _encode_cursor(last_dt.isoformat(), str(last_id))
        return [c for _, _, c in page], has_more, next_cursor

    @staticmethod
    async def _get_one(db: AsyncSession, model, user: User, entity_id: str):
        result = await db.execute(
            select(model).where(model.id == entity_id, model.user_id == user.id)
        )
        return result.scalar_one_or_none()

    @staticmethod
    async def _get_note_with_tags(db: AsyncSession, user: User, entity_id: str) -> Optional[Note]:
        result = await db.execute(
            select(Note)
            .where(Note.id == entity_id, Note.user_id == user.id)
            .options(selectinload(Note.tags).selectinload(NoteTag.tag))
            .with_for_update()
        )
        return result.scalar_one_or_none()

    @staticmethod
    def _note_to_dict(note: Note) -> dict:
        return {
            "id": str(note.id),
            "user_id": str(note.user_id),
            "title": note.title,
            "content": note.content,
            "content_type": note.content_type.value if hasattr(note.content_type, "value") else str(note.content_type),
            "notebook_id": str(note.notebook_id) if note.notebook_id else None,
            "is_pinned": note.is_pinned,
            "is_archived": note.is_archived,
            "is_deleted": note.is_deleted,
            "created_at": note.created_at.isoformat(),
            "updated_at": note.updated_at.isoformat(),
            # The LWW basis. Clients must merge by this (fallback updated_at),
            # not by updated_at alone: updated_at is the server APPLY time, so
            # an older edit synced later would otherwise clobber a newer local
            # edit until the next push round-trips.
            "edited_at": note.edited_at.isoformat() if note.edited_at else None,
            "field_clocks": note.field_clocks or {},
            "tags": SyncService._loaded_tag_names(note),
        }

    @staticmethod
    def _task_to_dict(task: Task) -> dict:
        return {
            "id": str(task.id),
            "user_id": str(task.user_id),
            "note_id": str(task.note_id) if task.note_id else None,
            "title": task.title,
            "description": task.description,
            "is_completed": task.is_completed,
            "completed_at": task.completed_at.isoformat() if task.completed_at else None,
            "due_date": task.due_date.isoformat() if task.due_date else None,
            "due_has_time": task.due_has_time,
            "priority": task.priority,
            "labels": task.labels or [],
            "recurrence": task.recurrence,
            "reminder_at": task.reminder_at.isoformat() if task.reminder_at else None,
            "reminder_lead_minutes": task.reminder_lead_minutes,
            "notebook_id": str(task.notebook_id) if task.notebook_id else None,
            "parent_id": str(task.parent_id) if task.parent_id else None,
            "sort_order": task.sort_order,
            "is_deleted": task.is_deleted,
            "created_at": task.created_at.isoformat(),
            "updated_at": task.updated_at.isoformat(),
            # LWW basis, same contract as notes.
            "edited_at": task.edited_at.isoformat() if task.edited_at else None,
            "field_clocks": task.field_clocks or {},
        }

    @staticmethod
    def _loaded_tag_names(note: Note) -> list[dict]:
        """Tag names, but only if the relationship is already loaded.

        Guards against triggering a lazy load in async context (which would
        raise MissingGreenlet).
        """
        if "tags" in sa_inspect(note).unloaded:
            return []
        names: list[dict] = []
        for nt in note.tags:
            # Skip tombstoned tags: a deleted tag's name must not resurface on
            # other devices through the note payloads in a sync pull.
            if "tag" not in sa_inspect(nt).unloaded and nt.tag is not None and not nt.tag.is_deleted:
                names.append({"name": nt.tag.name})
        return names


class _ConflictError(Exception):
    """Internal signal to unwind a per-change SAVEPOINT when a change conflicts."""

    def __init__(self, result: dict):
        self.result = result
        super().__init__(result.get("reason", "Conflict"))


sync_service = SyncService()
