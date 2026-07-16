import uuid
import json
import base64
from datetime import datetime, timezone
from typing import Optional
from sqlalchemy import select, delete, and_, or_, inspect as sa_inspect
from sqlalchemy.orm import selectinload
from sqlalchemy.ext.asyncio import AsyncSession
from app.models.user import User
from app.models.note import Note, NoteVersion, ContentType
from app.models.notebook import Notebook
from app.models.tag import Tag, NoteTag
from app.models.file import File
from app.models.task import Task
from app.models.sync import SyncLog, EntityType, SyncAction
from app.schemas.sync import SyncChangeItem


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
        server_changes = await self._get_changes_since(db, user, last_sync_at)

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
            changes = await self._get_changes_since(db, user, since, entity_types)
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
        client_ts = _parse_ts(change.timestamp)

        if change.action == "create":
            if existing and not existing.is_deleted:
                return {"conflict": True, "server_data": self._note_to_dict(existing),
                        "reason": "Note already exists on server"}
            if existing and existing.is_deleted:
                # Resurrect the soft-deleted row instead of inserting a duplicate PK.
                await self._apply_note_fields(db, user, existing, client_data)
                await self._apply_note_tags(db, user, existing, client_data)
                existing.is_deleted = False
                existing.deleted_at = None
                now = datetime.now(timezone.utc)
                existing.edited_at = client_ts or now
                existing.updated_at = now
                return {}
            note = Note(
                id=uuid.UUID(entity_id),
                user_id=user.id,
            )
            await self._apply_note_fields(db, user, note, client_data)
            # Preserve the note's real creation time (it was created offline on
            # the client); otherwise func.now() stamps it with the sync time and
            # the note shows "created today" on every other device. Stamp
            # updated_at on the server clock so it lines up with the sync cursor.
            created = _parse_ts(client_data.get("created_at"))
            if created is not None:
                note.created_at = created
            note.updated_at = datetime.now(timezone.utc)
            note.edited_at = client_ts or created or note.updated_at
            db.add(note)
            await self._apply_note_tags(db, user, note, client_data)
            return {}

        elif change.action == "update":
            if not existing or existing.is_deleted:
                return {"conflict": True, "reason": "Note not found on server"}
            # Last-write-wins by EDIT time, not server apply time: compare the
            # incoming edit against the last recorded edit (edited_at), falling
            # back to updated_at for rows that predate edited_at. Otherwise a
            # note that merely synced later could beat one edited more recently.
            basis = existing.edited_at or existing.updated_at
            if client_ts is not None and basis is not None and basis > client_ts:
                return {"conflict": True, "server_data": self._note_to_dict(existing),
                        "reason": "Server version is newer"}
            await self._apply_note_fields(db, user, existing, client_data)
            await self._apply_note_tags(db, user, existing, client_data)
            now = datetime.now(timezone.utc)
            existing.edited_at = client_ts or now
            existing.updated_at = now
            return {}

        elif change.action == "delete":
            if existing and not existing.is_deleted:
                now = datetime.now(timezone.utc)
                existing.is_deleted = True
                existing.is_archived = False
                existing.deleted_at = now
                existing.updated_at = now
                # A delete is an edit for LWW purposes: without this, the
                # tombstone would carry the note's last content-edit time and
                # lose merges against devices that edited just before the
                # delete, resurrecting the note there.
                existing.edited_at = client_ts or now
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

    async def _apply_note_fields(self, db: AsyncSession, user: User, note: Note, client_data: dict) -> None:
        for key in ("title", "content", "is_pinned", "is_archived"):
            if key in client_data:
                setattr(note, key, client_data[key])
        if "content_type" in client_data:
            note.content_type = _coerce_content_type(client_data["content_type"])
        if "notebook_id" in client_data:
            note.notebook_id = await self._owned_notebook_id(db, user, client_data["notebook_id"])

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
        client_ts = _parse_ts(change.timestamp)

        if change.action == "create":
            if existing and not existing.is_deleted:
                return {}  # idempotent: already there
            if existing and existing.is_deleted:
                existing.is_deleted = False
                existing.deleted_at = None
            target = existing or Notebook(id=uuid.UUID(entity_id), user_id=user.id)
            target.name = client_data.get("name", "New Notebook")
            parent_id = await self._owned_notebook_id(db, user, client_data.get("parent_id"))
            if parent_id == target.id:
                parent_id = None  # a notebook can't be its own parent
            target.parent_id = parent_id
            if "sort_order" in client_data:
                target.sort_order = client_data["sort_order"]
            target.updated_at = datetime.now(timezone.utc)
            if existing is None:
                created = _parse_ts(client_data.get("created_at"))
                if created is not None:
                    target.created_at = created
                db.add(target)
            return {}

        elif change.action == "update":
            if not existing:
                return {"conflict": True, "reason": "Notebook not found on server"}
            if client_ts is not None and existing.updated_at > client_ts:
                return {"conflict": True, "reason": "Server version is newer"}
            for key in ("name", "sort_order"):
                if key in client_data:
                    setattr(existing, key, client_data[key])
            if "parent_id" in client_data:
                parent_id = await self._owned_notebook_id(db, user, client_data["parent_id"])
                if parent_id == existing.id:
                    parent_id = None  # a notebook can't be its own parent
                existing.parent_id = parent_id
            existing.updated_at = datetime.now(timezone.utc)
            return {}

        elif change.action == "delete":
            if existing and not existing.is_deleted:
                existing.is_deleted = True
                existing.deleted_at = datetime.now(timezone.utc)
                existing.updated_at = datetime.now(timezone.utc)
            return {}

        return {}

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
            created = _parse_ts(client_data.get("created_at"))
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
        client_ts = _parse_ts(change.timestamp)

        if change.action == "create":
            if existing and not existing.is_deleted:
                return {"conflict": True, "server_data": self._task_to_dict(existing),
                        "reason": "Task already exists on server"}
            if existing and existing.is_deleted:
                await self._apply_task_fields(db, user, existing, client_data)
                existing.is_deleted = False
                existing.deleted_at = None
                now = datetime.now(timezone.utc)
                existing.edited_at = client_ts or now
                existing.updated_at = now
                return {}
            task = Task(id=uuid.UUID(entity_id), user_id=user.id, title="Untitled task")
            await self._apply_task_fields(db, user, task, client_data)
            created = _parse_ts(client_data.get("created_at"))
            if created is not None:
                task.created_at = created
            task.updated_at = datetime.now(timezone.utc)
            task.edited_at = client_ts or created or task.updated_at
            db.add(task)
            return {}

        elif change.action == "update":
            if not existing or existing.is_deleted:
                return {"conflict": True, "reason": "Task not found on server"}
            basis = existing.edited_at or existing.updated_at
            if client_ts is not None and basis is not None and basis > client_ts:
                return {"conflict": True, "server_data": self._task_to_dict(existing),
                        "reason": "Server version is newer"}
            await self._apply_task_fields(db, user, existing, client_data)
            now = datetime.now(timezone.utc)
            existing.edited_at = client_ts or now
            existing.updated_at = now
            return {}

        elif change.action == "delete":
            if existing and not existing.is_deleted:
                existing.is_deleted = True
                existing.deleted_at = datetime.now(timezone.utc)
                existing.updated_at = datetime.now(timezone.utc)
            return {}

        return {"conflict": True, "reason": f"Unknown action: {change.action}"}

    async def _apply_task_fields(self, db: AsyncSession, user: User, task: Task, client_data: dict) -> None:
        if "title" in client_data:
            title = str(client_data["title"] or "").strip()
            task.title = title[:500] if title else "Untitled task"
        if "description" in client_data:
            task.description = str(client_data["description"] or "")
        if "sort_order" in client_data:
            try:
                task.sort_order = int(client_data["sort_order"])
            except (ValueError, TypeError):
                pass
        if "is_completed" in client_data:
            completed = bool(client_data["is_completed"])
            if completed != task.is_completed:
                task.is_completed = completed
                task.completed_at = datetime.now(timezone.utc) if completed else None
        if "due_date" in client_data:
            # null/garbage clears; a valid ISO timestamp sets.
            task.due_date = _parse_ts(client_data["due_date"])
        if "note_id" in client_data:
            task.note_id = await self._owned_note_id(db, user, client_data["note_id"])

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

    def _type_specs(self, target_types):
        """(name, model, change-builder, query-options) for the requested types."""
        specs = [
            ("note", Note, self._note_change, (selectinload(Note.tags).selectinload(NoteTag.tag),)),
            ("notebook", Notebook, self._notebook_change, ()),
            ("tag", Tag, self._tag_change, ()),
            ("file", File, self._file_change, ()),
        ]
        return [s for s in specs if s[0] in target_types]

    async def _get_changes_since(
        self, db: AsyncSession, user: User, since: Optional[str] = None,
        entity_types: Optional[list[str]] = None,
    ) -> list[dict]:
        """Build list of changed entities since timestamp (inclusive).

        The `since` filter is inclusive (>=) so a row touched at exactly the
        cursor time is never skipped; clients upsert idempotently so re-seeing a
        row is harmless.
        """
        changes: list[dict] = []
        target_types = entity_types or ["note", "notebook", "tag", "file"]
        since_dt = _parse_ts(since)

        for _name, model, builder, opts in self._type_specs(target_types):
            q = select(model).where(model.user_id == user.id)
            for opt in opts:
                q = q.options(opt)
            if since_dt is not None:
                q = q.where(model.updated_at >= since_dt)
            for row in (await db.execute(q)).scalars().unique().all():
                changes.append(builder(row))

        return changes

    async def _get_changes_page(
        self, db: AsyncSession, user: User, since: Optional[str],
        entity_types: Optional[list[str]], limit: int, cursor: Optional[str],
    ) -> tuple[list[dict], bool, Optional[str]]:
        """Paginated read: at most `limit` changes ordered by (updated_at, id),
        plus has_more and an opaque next_cursor. Each per-type query is capped so
        one huge table can't pull an unbounded result set into memory."""
        target_types = entity_types or ["note", "notebook", "tag", "file"]
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
            "tags": SyncService._loaded_tag_names(note),
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
