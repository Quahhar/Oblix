import asyncio
import logging
import uuid
from collections import defaultdict
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from sqlalchemy import delete, or_, select
from sqlalchemy.orm import load_only, noload

from app.database import async_session_factory
from app.models.collaboration import (
    CollaborationOperation,
    CollaborationOperationReceipt,
)
from app.models.note import Note
from app.models.session import Session
from app.models.share import Share, ShareRole
from app.models.user import User
from app.services.note_service import note_service
from app.services.share_service import note_share_conditions, share_service
from app.services.text_ot import (
    InvalidDelta,
    apply_delta,
    normalize_delta,
    transform_delta,
    utf16_length,
)
from app.utils.auth_dependency import authenticate_access_token
from app.utils.security import decode_token

router = APIRouter(prefix="/collaboration", tags=["collaboration"])
logger = logging.getLogger(__name__)

_SEND_TIMEOUT_SECONDS = 5
_CLOSE_TIMEOUT_SECONDS = 2
_HELLO_TIMEOUT_SECONDS = 10
_MAX_CURSOR_OFFSET = 2_000_000
_MAX_LIVE_CONTENT_UNITS = 2_000_000
_MAX_PEERS_PER_ROOM = 64
_MAX_PEERS_PER_USER_PER_ROOM = 8
_MAX_TOTAL_PEERS = 1_024
_MAX_JOURNAL_OPERATIONS = 10_000
_MAX_TRANSFORM_DISTANCE = 256
_MAX_DISPATCH_QUEUE = 128
_MAX_EDIT_DISPATCH_BACKLOG = 96
_MAX_DISPATCH_BYTES_PER_ROOM = 16 * 1024 * 1024
_MAX_DISPATCH_BYTES_TOTAL = 64 * 1024 * 1024
_FULL_DELTA_RETENTION = timedelta(hours=24)
_OPERATION_RECEIPT_RETENTION = timedelta(days=7)
_MAINTENANCE_INTERVAL_SECONDS = 300
_MAINTENANCE_NOTE_BATCH = 100
_MAINTENANCE_RECEIPT_BATCH = 5_000
_UNSET_NOTE = object()


def _value_size_bytes(value: object) -> int:
    """Conservatively estimate retained Python/JSON memory without copying it."""
    if value is None or isinstance(value, (bool, int, float)):
        return 32
    if isinstance(value, str):
        # Four bytes per code point is a conservative upper bound for a
        # retained Python string and avoids allocating a second encoded copy.
        return 64 + (len(value) * 4)
    if isinstance(value, dict):
        return 128 + sum(
            _value_size_bytes(key) + _value_size_bytes(item)
            for key, item in value.items()
        )
    if isinstance(value, (list, tuple)):
        return 96 + sum(_value_size_bytes(item) for item in value)
    return 256


def _dispatch_message_size(message: dict, recipient_count: int) -> int:
    # Include the queue item, Event/Future, tuple, and recipient references.
    return 512 + (recipient_count * 16) + _value_size_bytes(message)


def _content_exceeds_live_limit(content: str) -> bool:
    # Reject obviously oversized input before utf16_length allocates an
    # encoded copy. The second check still catches astral characters, which
    # occupy two UTF-16 units each in Flutter/Dart editing offsets.
    return len(content) > _MAX_LIVE_CONTENT_UNITS or (
        utf16_length(content) > _MAX_LIVE_CONTENT_UNITS
    )


@dataclass(eq=False)
class Peer:
    socket: WebSocket
    user_id: str
    display_name: str
    client_id: str
    role: str
    token: str
    send_lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    edited: bool = False
    last_version_check_at: datetime | None = None


@dataclass
class DispatchItem:
    """One immutable-recipient document frame in a room's ordered queue."""

    message: dict
    recipients: tuple[Peer, ...]
    size_bytes: int
    ready: asyncio.Event = field(default_factory=asyncio.Event)
    completion: asyncio.Future[bool] = field(init=False)
    released: bool = False

    def __post_init__(self) -> None:
        self.completion = asyncio.get_running_loop().create_future()


@dataclass(frozen=True)
class PeerNotification:
    peer: Peer
    message: dict
    close_code: int | None = None
    close_reason: str | None = None


@dataclass
class AccessRefresh:
    changed: bool
    note: Note | None
    notifications: list[PeerNotification] = field(default_factory=list)


class CollaborationHub:
    """Single-worker ordered rooms; PostgreSQL remains the operation authority."""

    def __init__(self):
        self.rooms: dict[str, list[Peer]] = defaultdict(list)
        self.locks: dict[str, asyncio.Lock] = {}
        self._lock_users: dict[str, int] = {}
        self._locks_guard = asyncio.Lock()
        self._dispatch_queues: dict[str, asyncio.Queue[DispatchItem]] = {}
        self._dispatch_tasks: dict[str, asyncio.Task[None]] = {}
        self._dispatch_bytes_by_room: dict[str, int] = {}
        self._dispatch_total_bytes = 0

    @asynccontextmanager
    async def room_lock(self, note_id: str):
        """Lease one stable room lock and evict it after the room is truly idle.

        The reference is registered before waiting, so a departing holder can
        never remove a lock while another coroutine is queued on it.
        """
        async with self._locks_guard:
            lock = self.locks.get(note_id)
            if lock is None:
                lock = asyncio.Lock()
                self.locks[note_id] = lock
            self._lock_users[note_id] = self._lock_users.get(note_id, 0) + 1

        acquired = False
        try:
            await lock.acquire()
            acquired = True
            yield
        finally:
            if acquired:
                lock.release()
            async with self._locks_guard:
                remaining = self._lock_users.get(note_id, 1) - 1
                if remaining <= 0:
                    self._lock_users.pop(note_id, None)
                    if not self.rooms.get(note_id):
                        self.locks.pop(note_id, None)
                else:
                    self._lock_users[note_id] = remaining

    async def send(self, peer: Peer, message: dict) -> bool:
        try:
            async with peer.send_lock:
                await asyncio.wait_for(
                    peer.socket.send_json(message),
                    timeout=_SEND_TIMEOUT_SECONDS,
                )
            return True
        except Exception:
            return False

    def add(self, note_id: str, peer: Peer) -> None:
        self.rooms[note_id].append(peer)

    def peer_count(self) -> int:
        return sum(len(room) for room in self.rooms.values())

    def _finish_dispatch(
        self,
        note_id: str,
        item: DispatchItem,
        delivered: bool,
    ) -> None:
        if not item.released:
            item.released = True
            room_bytes = max(
                0,
                self._dispatch_bytes_by_room.get(note_id, 0) - item.size_bytes,
            )
            if room_bytes:
                self._dispatch_bytes_by_room[note_id] = room_bytes
            else:
                self._dispatch_bytes_by_room.pop(note_id, None)
            self._dispatch_total_bytes = max(
                0,
                self._dispatch_total_bytes - item.size_bytes,
            )
        if not item.completion.done():
            item.completion.set_result(delivered)

    def _drain_dispatch_queue(
        self,
        note_id: str,
        queue: asyncio.Queue[DispatchItem],
    ) -> None:
        while True:
            try:
                item = queue.get_nowait()
            except asyncio.QueueEmpty:
                break
            self._finish_dispatch(note_id, item, False)
            queue.task_done()

    def _cancel_dispatcher_locked(self, note_id: str) -> None:
        """Drop queued document frames when the final room peer leaves."""
        queue = self._dispatch_queues.pop(note_id, None)
        task = self._dispatch_tasks.pop(note_id, None)
        if queue is not None:
            self._drain_dispatch_queue(note_id, queue)
        if task is not None and not task.done() and task is not asyncio.current_task():
            task.cancel()

    def dispatch_backlog(self, note_id: str) -> int:
        queue = self._dispatch_queues.get(note_id)
        return queue.qsize() if queue is not None else 0

    def enqueue_document_locked(
        self,
        note_id: str,
        message: dict,
        *,
        recipients: tuple[Peer, ...] | None = None,
        ready: bool = False,
    ) -> DispatchItem | None:
        """Queue a frame at its database linearization point.

        The caller holds ``room_lock``. Recipients are captured now so a peer
        admitted later cannot receive a delta already represented by its
        initial snapshot. ``ready`` stays false while a transaction is open.
        """
        if recipients is None:
            recipients = tuple(self.rooms.get(note_id, ()))
        if not recipients:
            return None

        size_bytes = _dispatch_message_size(message, len(recipients))
        room_bytes = self._dispatch_bytes_by_room.get(note_id, 0)
        if (
            room_bytes + size_bytes > _MAX_DISPATCH_BYTES_PER_ROOM
            or self._dispatch_total_bytes + size_bytes > _MAX_DISPATCH_BYTES_TOTAL
        ):
            return None

        queue = self._dispatch_queues.get(note_id)
        task = self._dispatch_tasks.get(note_id)
        if queue is None or task is None or task.done():
            queue = asyncio.Queue(maxsize=_MAX_DISPATCH_QUEUE)
            self._dispatch_queues[note_id] = queue
            task = asyncio.create_task(
                self._dispatch_loop(note_id, queue),
                name=f"collaboration-dispatch:{note_id}",
            )
            self._dispatch_tasks[note_id] = task
        if queue.full():
            return None

        item = DispatchItem(
            message=message,
            recipients=recipients,
            size_bytes=size_bytes,
        )
        queue.put_nowait(item)
        self._dispatch_bytes_by_room[note_id] = room_bytes + size_bytes
        self._dispatch_total_bytes += size_bytes
        if ready:
            item.ready.set()
        return item

    async def await_dispatch(
        self,
        item: DispatchItem,
        *,
        timeout: float = _SEND_TIMEOUT_SECONDS + 1,
    ) -> bool:
        try:
            return await asyncio.wait_for(
                asyncio.shield(item.completion),
                timeout=timeout,
            )
        except TimeoutError:
            return False

    async def _dispatch_loop(
        self,
        note_id: str,
        queue: asyncio.Queue[DispatchItem],
    ) -> None:
        current: DispatchItem | None = None
        try:
            while True:
                current = await queue.get()
                try:
                    await current.ready.wait()
                    room = self.rooms.get(note_id, ())
                    recipients = tuple(
                        peer for peer in current.recipients if peer in room
                    )
                    results = (
                        await asyncio.gather(
                            *(self.send(peer, current.message) for peer in recipients)
                        )
                        if recipients
                        else []
                    )
                    delivered = len(recipients) == len(current.recipients) and all(
                        results
                    )
                    self._finish_dispatch(note_id, current, delivered)

                    failed = [
                        peer for peer, result in zip(recipients, results) if not result
                    ]
                    if failed:
                        async with self.room_lock(note_id):
                            active_room = self.rooms.get(note_id, [])
                            for peer in failed:
                                if peer in active_room:
                                    active_room.remove(peer)
                            if not active_room:
                                self.rooms.pop(note_id, None)
                                self._cancel_dispatcher_locked(note_id)
                except asyncio.CancelledError:
                    self._finish_dispatch(note_id, current, False)
                    raise
                except Exception:
                    self._finish_dispatch(note_id, current, False)
                    raise
                finally:
                    queue.task_done()
                    current = None

                if self._dispatch_queues.get(note_id) is not queue:
                    break
        except asyncio.CancelledError:
            if current is not None:
                self._finish_dispatch(note_id, current, False)
                queue.task_done()
            raise
        except Exception:
            logger.exception("Collaboration room dispatcher failed for %s", note_id)
            if current is not None:
                self._finish_dispatch(note_id, current, False)
                queue.task_done()
        finally:
            self._drain_dispatch_queue(note_id, queue)
            current_task = asyncio.current_task()
            if self._dispatch_tasks.get(note_id) is current_task:
                self._dispatch_tasks.pop(note_id, None)
            if self._dispatch_queues.get(note_id) is queue:
                self._dispatch_queues.pop(note_id, None)

    async def leave(self, note_id: str, peer: Peer) -> None:
        notifications: list[PeerNotification] = []
        async with self.room_lock(note_id):
            peers = self.rooms.get(note_id, [])
            if peer in peers:
                peers.remove(peer)
            if not peers:
                self.rooms.pop(note_id, None)
                self._cancel_dispatcher_locked(note_id)
                return
            refresh = await _refresh_room_access_locked(note_id)
            notifications = refresh.notifications
            if refresh.changed or peers:
                await _deliver_access_notifications(notifications)
                await self.broadcast_presence_locked(note_id)

    async def broadcast(
        self,
        note_id: str,
        message: dict,
        *,
        exclude_client_id: str | None = None,
    ) -> None:
        peers = [
            peer
            for peer in list(self.rooms.get(note_id, []))
            if peer.client_id != exclude_client_id
        ]
        if not peers:
            if not self.rooms.get(note_id):
                self.rooms.pop(note_id, None)
            return
        results = await asyncio.gather(
            *(self.send(peer, message) for peer in peers),
            return_exceptions=False,
        )
        room = self.rooms.get(note_id, [])
        for peer, delivered in zip(peers, results):
            if not delivered and peer in room:
                room.remove(peer)
        if not room:
            self.rooms.pop(note_id, None)
            self._cancel_dispatcher_locked(note_id)

    async def broadcast_presence_locked(self, note_id: str) -> None:
        """Broadcast already-validated presence while holding the room lock."""
        peers = self.rooms.get(note_id, [])
        await self.broadcast(
            note_id,
            {
                "type": "presence",
                "participants": [
                    {
                        "user_id": peer.user_id,
                        "display_name": peer.display_name,
                        "client_id": peer.client_id,
                        "role": peer.role,
                    }
                    for peer in peers
                ],
            },
        )

    async def refresh_room_access(self, note_id: str) -> None:
        """Immediately apply share/session changes to every local room peer."""
        async with self.room_lock(note_id):
            refresh = await _refresh_room_access_locked(note_id)
            await _deliver_access_notifications(refresh.notifications)
            if refresh.changed and self.rooms.get(note_id):
                await self.broadcast_presence_locked(note_id)

    async def broadcast_document(self, note_id: str, event: dict) -> None:
        """Linearize a document event, then release PostgreSQL before I/O.

        The caller holds the room lock. The current note row is locked before
        notebook-derived access is recalculated, so a concurrent notebook move
        cannot expose its new content to recipients authorized only through the
        old notebook. The dispatch item's ready gate preserves commit order
        without retaining the row lock during slow WebSocket sends.
        """
        refresh = AccessRefresh(False, None)
        dispatch: DispatchItem | None = None
        oversized: list[Peer] = []
        overloaded: list[Peer] = []
        async with async_session_factory() as db:
            current_note = (
                await db.execute(_select_note(uuid.UUID(note_id), for_update=True))
            ).scalar_one_or_none()
            refresh = await _refresh_room_access_locked(
                note_id,
                locked_note=current_note,
                access_db=db,
            )
            if (
                current_note is not None
                and not current_note.is_deleted
                and self.rooms.get(note_id)
            ):
                if (
                    event.get("epoch") != str(current_note.collab_epoch)
                    or event.get("revision") != current_note.collab_revision
                ):
                    if _content_exceeds_live_limit(current_note.content):
                        oversized = list(self.rooms.pop(note_id, []))
                        self._cancel_dispatcher_locked(note_id)
                    else:
                        event = _snapshot(
                            current_note,
                            kind="resync",
                            code="baseline_changed",
                            message=("The note changed outside the live session."),
                        )
                if not oversized:
                    dispatch = self.enqueue_document_locked(note_id, event)
                    if dispatch is None:
                        # Control-message pressure must never strand a committed
                        # document state. Drop the stale queue and replace it
                        # with one canonical snapshot; partial recipients of an
                        # interrupted older delta converge on this same body.
                        self._cancel_dispatcher_locked(note_id)
                        dispatch = self.enqueue_document_locked(
                            note_id,
                            _snapshot(
                                current_note,
                                kind="resync",
                                code="dispatch_reset",
                                message=(
                                    "Live delivery was reset to the latest saved note."
                                ),
                            ),
                        )
                        if dispatch is None:
                            overloaded = list(self.rooms.pop(note_id, []))
                            self._cancel_dispatcher_locked(note_id)

        try:
            await _deliver_access_notifications(refresh.notifications)
            if oversized:
                await asyncio.gather(
                    *(
                        _notify_and_close(
                            peer,
                            {
                                "type": "error",
                                "code": "note_too_large",
                                "message": "This note is too large to edit live.",
                            },
                            code=4409,
                            reason="Note too large for live editing",
                        )
                        for peer in oversized
                    )
                )
            if overloaded:
                await asyncio.gather(
                    *(
                        _notify_and_close(
                            peer,
                            {
                                "type": "error",
                                "code": "server_busy",
                                "message": (
                                    "Live delivery is at capacity. Please reconnect."
                                ),
                            },
                            code=1013,
                            reason="Live collaboration at capacity",
                        )
                        for peer in overloaded
                    )
                )
            if refresh.changed and self.rooms.get(note_id):
                await self.broadcast_presence_locked(note_id)
        finally:
            if dispatch is not None:
                dispatch.ready.set()


hub = CollaborationHub()


def _bearer_token(websocket: WebSocket) -> str | None:
    value = websocket.headers.get("authorization", "")
    if value.lower().startswith("bearer "):
        return value[7:].strip()
    return None


def _snapshot(note: Note, *, kind: str, role: str | None = None, **extra) -> dict:
    message = {
        "type": kind,
        "note_id": str(note.id),
        "title": note.title,
        "content": note.content,
        "revision": note.collab_revision,
        "epoch": str(note.collab_epoch),
    }
    if role is not None:
        message["role"] = role
    message.update(extra)
    return message


def _operation_ack(note: Note, operation_id: uuid.UUID) -> dict:
    """A duplicate receipt acknowledges the current canonical snapshot."""
    return _snapshot(
        note,
        kind="ack",
        operation_id=str(operation_id),
    )


def _select_note(note_id: uuid.UUID, *, for_update: bool = False):
    # Note.tags is select-in eager by default; live protocol paths only need
    # scalar columns, so suppress that otherwise-per-message extra query.
    query = (
        select(Note)
        .where(Note.id == note_id)
        .options(noload(Note.tags), noload(Note.versions))
    )
    return query.with_for_update() if for_update else query


def _select_note_access_state(note_id: uuid.UUID):
    return (
        select(Note)
        .where(Note.id == note_id)
        .options(
            load_only(
                Note.id,
                Note.user_id,
                Note.notebook_id,
                Note.is_deleted,
                Note.collab_revision,
                Note.collab_epoch,
            ),
            noload(Note.tags),
            noload(Note.versions),
        )
    )


async def _authorized_note(
    db,
    token: str,
    note_id: uuid.UUID,
    *,
    for_update: bool = False,
):
    try:
        user = await authenticate_access_token(db, token)
    except Exception:
        return None, None, None
    query = _select_note(note_id, for_update=for_update)
    note = (await db.execute(query)).scalar_one_or_none()
    role = await share_service.note_role(db, user, note) if note else None
    if note is None or note.is_deleted or role is None:
        return user, note, None
    return user, note, role


async def _notify_and_close(
    peer: Peer,
    message: dict,
    *,
    code: int,
    reason: str,
) -> None:
    await hub.send(peer, message)
    try:
        await asyncio.wait_for(
            peer.socket.close(code=code, reason=reason),
            timeout=_CLOSE_TIMEOUT_SECONDS,
        )
    except Exception:
        pass


async def _deliver_access_notifications(
    notifications: list[PeerNotification],
) -> None:
    """Perform access-related socket I/O after all database locks are gone."""
    if not notifications:
        return
    await asyncio.gather(
        *(
            _notify_and_close(
                notification.peer,
                notification.message,
                code=notification.close_code,
                reason=notification.close_reason or "",
            )
            if notification.close_code is not None
            else hub.send(notification.peer, notification.message)
            for notification in notifications
        )
    )


@asynccontextmanager
async def _access_session(existing_db=None):
    if existing_db is not None:
        yield existing_db
        return
    async with async_session_factory() as db:
        yield db


async def _refresh_room_access_locked(
    note_id: str,
    *,
    locked_note: Note | None | object = _UNSET_NOTE,
    access_db=None,
) -> AccessRefresh:
    """Batch-revalidate peers without doing socket I/O.

    Passing ``locked_note`` means the caller already selected the current Note
    row ``FOR UPDATE``. That makes its notebook id authoritative even while a
    concurrent whole-document update is trying to move the note.
    """
    peers = list(hub.rooms.get(note_id, []))
    if not peers:
        return AccessRefresh(False, None)
    changed = False
    try:
        note_uuid = uuid.UUID(note_id)
    except ValueError:
        note_uuid = None

    claims: list[tuple[Peer, uuid.UUID | None, uuid.UUID | None]] = []
    session_ids: set[uuid.UUID] = set()
    for peer in peers:
        payload = decode_token(peer.token)
        session_id = None
        user_id = None
        if payload is not None and payload.get("type") == "access":
            try:
                session_id = uuid.UUID(str(payload.get("jti")))
                user_id = uuid.UUID(str(payload.get("sub")))
            except (ValueError, TypeError):
                session_id = None
                user_id = None
        if session_id is not None:
            session_ids.add(session_id)
        claims.append((peer, session_id, user_id))

    async with _access_session(access_db) as db:
        if locked_note is _UNSET_NOTE:
            note = (
                (
                    await db.execute(_select_note_access_state(note_uuid))
                ).scalar_one_or_none()
                if note_uuid is not None
                else None
            )
        else:
            note = locked_note
        session_users: dict[uuid.UUID, tuple[Session, User]] = {}
        if session_ids:
            rows = (
                await db.execute(
                    select(Session, User)
                    .join(User, User.id == Session.user_id)
                    .where(Session.id.in_(session_ids))
                )
            ).all()
            session_users = {session.id: (session, user) for session, user in rows}

        role_by_user: dict[uuid.UUID, str] = {}
        user_ids = {
            user_id
            for _peer, session_id, user_id in claims
            if session_id is not None and user_id is not None
        }
        if note is not None and not note.is_deleted and user_ids:
            rows = (
                await db.execute(
                    select(Share.grantee_id, Share.role).where(
                        Share.grantee_id.in_(user_ids),
                        or_(*note_share_conditions(note)),
                    )
                )
            ).all()
            for grantee_id, raw_role in rows:
                role = (
                    raw_role.value if isinstance(raw_role, ShareRole) else str(raw_role)
                )
                previous = role_by_user.get(grantee_id)
                if role == "editor" or previous is None:
                    role_by_user[grantee_id] = role

    now = datetime.now(timezone.utc)
    removals: list[tuple[Peer, dict, int, str]] = []
    role_updates: list[tuple[Peer, str]] = []
    room = hub.rooms.get(note_id, [])
    for peer, session_id, claimed_user_id in claims:
        session_user = session_users.get(session_id) if session_id is not None else None
        session = session_user[0] if session_user is not None else None
        user = session_user[1] if session_user is not None else None
        session_valid = (
            session is not None
            and user is not None
            and claimed_user_id == session.user_id
            and session.revoked_at is None
            and session.expires_at > now
            and user.is_active
        )
        if not session_valid:
            changed = True
            if peer in room:
                room.remove(peer)
            removals.append(
                (
                    peer,
                    {
                        "type": "session_expired",
                        "message": "Your session expired. Reconnecting...",
                    },
                    4401,
                    "Session expired",
                )
            )
            continue

        role = None
        if note is not None and not note.is_deleted:
            role = "owner" if note.user_id == user.id else role_by_user.get(user.id)
        if role is None:
            changed = True
            if peer in room:
                room.remove(peer)
            removals.append(
                (
                    peer,
                    {
                        "type": "access",
                        "role": "revoked",
                        "message": "Your access to this note has ended.",
                    },
                    4403,
                    "Access revoked",
                )
            )
            continue

        peer.user_id = str(user.id)
        peer.display_name = user.display_name or user.email.split("@", 1)[0]
        if peer.role != role:
            peer.role = role
            changed = True
            role_updates.append((peer, role))

    if not room:
        hub.rooms.pop(note_id, None)
        hub._cancel_dispatcher_locked(note_id)
    notifications = [
        PeerNotification(
            peer=peer,
            message=message,
            close_code=code,
            close_reason=reason,
        )
        for peer, message, code, reason in removals
    ]
    notifications.extend(
        PeerNotification(
            peer=peer,
            message={"type": "access", "role": role},
        )
        for peer, role in role_updates
    )
    return AccessRefresh(
        changed=changed,
        note=note if note is not None and not note.is_deleted else None,
        notifications=notifications,
    )


async def notify_access_changed(entity_type: str, entity_id: str) -> None:
    """Called after a share mutation commits so connected peers update now."""
    if entity_type == "note":
        try:
            room_id = str(uuid.UUID(entity_id))
        except ValueError:
            return
        if room_id in hub.rooms:
            await hub.refresh_room_access(room_id)
        return

    # A notebook grant may affect any currently-open note in that notebook.
    room_ids = list(hub.rooms)
    if not room_ids:
        return
    try:
        notebook_uuid = uuid.UUID(entity_id)
        candidate_ids = [uuid.UUID(room_id) for room_id in room_ids]
    except ValueError:
        return
    async with async_session_factory() as db:
        affected = set(
            (
                await db.execute(
                    select(Note.id).where(
                        Note.id.in_(candidate_ids),
                        Note.notebook_id == notebook_uuid,
                    )
                )
            ).scalars()
        )
    for note_id in affected:
        await hub.refresh_room_access(str(note_id))


@router.websocket("/notes/{note_id}/ws")
async def collaborate_note(websocket: WebSocket, note_id: str):
    token = _bearer_token(websocket)
    if not token:
        await websocket.close(code=4401, reason="Authentication required")
        return
    try:
        note_uuid = uuid.UUID(note_id)
    except ValueError:
        await websocket.close(code=4404, reason="Note not found")
        return
    room_id = str(note_uuid)

    # Authenticate before accepting the upgrade, then capture the actual note
    # snapshot only after hello while holding the same lock used by edits.
    auth_failed = False
    async with async_session_factory() as db:
        try:
            user = await authenticate_access_token(db, token)
        except Exception:
            auth_failed = True
        else:
            user_id = str(user.id)
            display_name = user.display_name or user.email.split("@", 1)[0]
    if auth_failed:
        await websocket.close(code=4401, reason="Invalid session")
        return

    await websocket.accept()
    try:
        first = await asyncio.wait_for(
            websocket.receive_json(), timeout=_HELLO_TIMEOUT_SECONDS
        )
    except (TimeoutError, WebSocketDisconnect, ValueError, TypeError):
        await websocket.close(code=4400, reason="hello required")
        return
    if not isinstance(first, dict) or first.get("type") != "hello":
        await websocket.close(code=4400, reason="hello required")
        return
    client_id = str(first.get("client_id", ""))[:100]
    if not client_id:
        await websocket.close(code=4400, reason="client_id required")
        return

    peer = Peer(
        websocket,
        user_id,
        display_name,
        client_id,
        "viewer",
        token,
    )
    admission: DispatchItem | None = None
    async with hub.room_lock(room_id):
        refresh = AccessRefresh(False, None)
        rejection: PeerNotification | None = None
        async with async_session_factory() as db:
            user, note, role = await _authorized_note(
                db,
                token,
                note_uuid,
                for_update=True,
            )
            if user is None:
                rejection = PeerNotification(
                    peer=peer,
                    message={
                        "type": "session_expired",
                        "message": "Your session expired. Reconnecting...",
                    },
                    close_code=4401,
                    close_reason="Invalid session",
                )
            else:
                refresh = await _refresh_room_access_locked(
                    room_id,
                    locked_note=note,
                    access_db=db,
                )
                if note is None or role is None:
                    rejection = PeerNotification(
                        peer=peer,
                        message={
                            "type": "access",
                            "role": "revoked",
                            "message": "This note is unavailable.",
                        },
                        close_code=4404,
                        close_reason="Note not found",
                    )
                elif _content_exceeds_live_limit(note.content):
                    rejection = PeerNotification(
                        peer=peer,
                        message={
                            "type": "error",
                            "code": "note_too_large",
                            "message": "This note is too large to edit live.",
                        },
                        close_code=4409,
                        close_reason="Note too large for live editing",
                    )
                else:
                    peer.role = role
                    peer.display_name = user.display_name or user.email.split("@", 1)[0]
                    room = hub.rooms.get(room_id, [])
                    same_user_count = sum(
                        existing.user_id == str(user.id) for existing in room
                    )
                    server_full = hub.peer_count() >= _MAX_TOTAL_PEERS
                    if server_full or (
                        len(room) >= _MAX_PEERS_PER_ROOM
                        or same_user_count >= _MAX_PEERS_PER_USER_PER_ROOM
                    ):
                        rejection = PeerNotification(
                            peer=peer,
                            message={
                                "type": "error",
                                "code": "server_busy" if server_full else "room_full",
                                "message": (
                                    "Live collaboration is at capacity. Try again soon."
                                    if server_full
                                    else (
                                        "This live room has reached its connection "
                                        "limit."
                                    )
                                ),
                            },
                            close_code=1013 if server_full else 4429,
                            close_reason=(
                                "Live collaboration at capacity"
                                if server_full
                                else "Live room connection limit reached"
                            ),
                        )
                    else:
                        # Capture recipients and queue position while the Note
                        # row is locked, but gate delivery until this session
                        # releases the transaction.
                        hub.add(room_id, peer)
                        admission = hub.enqueue_document_locked(
                            room_id,
                            _snapshot(note, kind="snapshot", role=role),
                            recipients=(peer,),
                        )
                        if admission is None:
                            room.remove(peer)
                            if not room:
                                hub.rooms.pop(room_id, None)
                                hub._cancel_dispatcher_locked(room_id)
                            rejection = PeerNotification(
                                peer=peer,
                                message={
                                    "type": "error",
                                    "code": "room_busy",
                                    "message": (
                                        "The live room is busy. Please reconnect."
                                    ),
                                },
                                close_code=4429,
                                close_reason="Live room busy",
                            )

        await _deliver_access_notifications(refresh.notifications)
        if refresh.changed and hub.rooms.get(room_id):
            await hub.broadcast_presence_locked(room_id)
        if rejection is not None:
            await _deliver_access_notifications([rejection])
            return
        if admission is not None:
            admission.ready.set()

    if admission is None or not await hub.await_dispatch(admission):
        await hub.leave(room_id, peer)
        try:
            await asyncio.wait_for(
                peer.socket.close(code=1011, reason="Snapshot delivery failed"),
                timeout=_CLOSE_TIMEOUT_SECONDS,
            )
        except Exception:
            pass
        return

    async with hub.room_lock(room_id):
        if peer not in hub.rooms.get(room_id, []):
            return
        await hub.broadcast_presence_locked(room_id)

    try:
        while True:
            message = await websocket.receive_json()
            if not isinstance(message, dict):
                await hub.send(peer, {"type": "error", "code": "invalid_message"})
                continue
            kind = message.get("type")
            if kind == "edit":
                await _handle_edit(note_uuid, peer, message)
            elif kind == "resync":
                request_id = message.get("request_id")
                try:
                    request_id = (
                        str(uuid.UUID(request_id))
                        if isinstance(request_id, str)
                        else None
                    )
                except ValueError:
                    request_id = None
                await _send_current_snapshot(note_uuid, peer, request_id)
            elif kind == "cursor":
                cursor = _valid_cursor(message)
                if cursor is None:
                    await hub.send(peer, {"type": "error", "code": "invalid_cursor"})
                    continue
                async with hub.room_lock(room_id):
                    refresh = await _refresh_room_access_locked(room_id)
                    await _deliver_access_notifications(refresh.notifications)
                    if refresh.changed and hub.rooms.get(room_id):
                        await hub.broadcast_presence_locked(room_id)
                    if peer not in hub.rooms.get(room_id, []):
                        break
                    await hub.broadcast(
                        room_id,
                        {
                            "type": "cursor",
                            "client_id": client_id,
                            **cursor,
                        },
                        exclude_client_id=client_id,
                    )
            elif kind == "ping":
                await hub.refresh_room_access(room_id)
                if peer not in hub.rooms.get(room_id, []):
                    break
                await _send_document_state(note_uuid, peer)
            else:
                await hub.send(peer, {"type": "error", "code": "invalid_message"})
    except WebSocketDisconnect:
        pass
    except (ValueError, TypeError):
        try:
            await websocket.close(code=4400, reason="Invalid message")
        except Exception:
            pass
    finally:
        await hub.leave(room_id, peer)
        if peer.edited:
            try:
                await _finalize_version(note_uuid)
            except Exception:
                pass


def _valid_cursor(message: dict) -> dict | None:
    field_name = message.get("field")
    offset = message.get("offset")
    extent = message.get("extent")
    if field_name not in ("title", "content"):
        return None
    if (
        not isinstance(offset, int)
        or isinstance(offset, bool)
        or not isinstance(extent, int)
        or isinstance(extent, bool)
        or not 0 <= offset <= _MAX_CURSOR_OFFSET
        or not 0 <= extent <= _MAX_CURSOR_OFFSET
    ):
        return None
    return {"field": field_name, "offset": offset, "extent": extent}


async def _send_current_snapshot(
    note_id: uuid.UUID,
    peer: Peer,
    request_id: str | None = None,
) -> None:
    note_key = str(note_id)
    async with hub.room_lock(note_key):
        refresh = AccessRefresh(False, None)
        dispatch: DispatchItem | None = None
        notifications: list[PeerNotification] = []
        room_changed = False
        async with async_session_factory() as db:
            try:
                user = await authenticate_access_token(db, peer.token)
            except Exception:
                room = hub.rooms.get(note_key, [])
                if peer in room:
                    room.remove(peer)
                    room_changed = True
                if not room:
                    hub.rooms.pop(note_key, None)
                    hub._cancel_dispatcher_locked(note_key)
                notifications.append(
                    PeerNotification(
                        peer=peer,
                        message={
                            "type": "session_expired",
                            "message": "Your session expired. Reconnecting...",
                        },
                        close_code=4401,
                        close_reason="Session expired",
                    )
                )
            else:
                note = (
                    await db.execute(_select_note(note_id, for_update=True))
                ).scalar_one_or_none()
                refresh = await _refresh_room_access_locked(
                    note_key,
                    locked_note=note,
                    access_db=db,
                )
                role = (
                    await share_service.note_role(db, user, note)
                    if note is not None and not note.is_deleted
                    else None
                )
                if (
                    note is not None
                    and role is not None
                    and peer in hub.rooms.get(note_key, [])
                ):
                    if _content_exceeds_live_limit(note.content):
                        room = hub.rooms.get(note_key, [])
                        room.remove(peer)
                        room_changed = True
                        if not room:
                            hub.rooms.pop(note_key, None)
                            hub._cancel_dispatcher_locked(note_key)
                        notifications.append(
                            PeerNotification(
                                peer=peer,
                                message={
                                    "type": "error",
                                    "code": "note_too_large",
                                    "message": ("This note is too large to edit live."),
                                },
                                close_code=4409,
                                close_reason="Note too large for live editing",
                            )
                        )
                    else:
                        peer.role = role
                        extra = (
                            {"request_id": request_id} if request_id is not None else {}
                        )
                        dispatch = hub.enqueue_document_locked(
                            note_key,
                            _snapshot(
                                note,
                                kind="resync",
                                role=role,
                                **extra,
                            ),
                            recipients=(peer,),
                        )
                        if dispatch is None:
                            notifications.append(
                                PeerNotification(
                                    peer=peer,
                                    message={
                                        "type": "error",
                                        "code": "room_busy",
                                        **(
                                            {"request_id": request_id}
                                            if request_id is not None
                                            else {}
                                        ),
                                        "message": (
                                            "The live room is busy. Retry "
                                            "the resync request."
                                        ),
                                    },
                                )
                            )

        try:
            await _deliver_access_notifications(refresh.notifications)
            await _deliver_access_notifications(notifications)
            if (refresh.changed or room_changed) and hub.rooms.get(note_key):
                await hub.broadcast_presence_locked(note_key)
        finally:
            if dispatch is not None:
                dispatch.ready.set()


async def _send_document_state(note_id: uuid.UUID, peer: Peer) -> None:
    state: dict | None = None
    async with async_session_factory() as db:
        note = (
            await db.execute(_select_note_access_state(note_id))
        ).scalar_one_or_none()
        if note is not None and not note.is_deleted:
            state = {
                "type": "state",
                "revision": note.collab_revision,
                "epoch": str(note.collab_epoch),
            }
    if state is not None:
        await hub.send(peer, state)


async def _finalize_version(note_id: uuid.UUID) -> None:
    async with async_session_factory() as db:
        note = (
            await db.execute(_select_note(note_id, for_update=True))
        ).scalar_one_or_none()
        if note is None or note.is_deleted:
            return
        await note_service.record_version_snapshot(db, note)
        await db.commit()


async def _handle_edit(note_id: uuid.UUID, peer: Peer, message: dict) -> None:
    operation_id_raw = message.get("operation_id")
    field_name = message.get("field")
    if field_name not in ("title", "content"):
        await hub.send(
            peer,
            {
                "type": "error",
                "code": "invalid_field",
                "operation_id": str(operation_id_raw or ""),
            },
        )
        return
    try:
        operation_id = uuid.UUID(str(operation_id_raw))
        base_revision_raw = message.get("base_revision")
        if not isinstance(base_revision_raw, int) or isinstance(
            base_revision_raw, bool
        ):
            raise InvalidDelta("base_revision must be an integer")
        base_revision = base_revision_raw
        base_epoch = uuid.UUID(str(message.get("base_epoch")))
        delta = normalize_delta(message.get("delta"))
        if not delta:
            raise InvalidDelta("delta must contain an operation")
    except (ValueError, TypeError, InvalidDelta) as exc:
        await hub.send(
            peer,
            {
                "type": "error",
                "code": "invalid_edit",
                "operation_id": str(operation_id_raw or ""),
                "message": str(exc),
            },
        )
        return

    note_key = str(note_id)
    async with hub.room_lock(note_key):
        event = None
        response = None
        close_after = False
        close_code = 4403
        async with async_session_factory() as db:
            note = (
                await db.execute(_select_note(note_id, for_update=True))
            ).scalar_one_or_none()
            if note is None or note.is_deleted:
                response = {
                    "type": "error",
                    "code": "note_missing",
                    "operation_id": str(operation_id),
                }
                close_after = True
            else:
                try:
                    acting_user = await authenticate_access_token(db, peer.token)
                except Exception:
                    acting_user = None
                current_role = (
                    await share_service.note_role(db, acting_user, note)
                    if acting_user is not None
                    else None
                )
                if acting_user is None:
                    response = {
                        "type": "session_expired",
                        "operation_id": str(operation_id),
                        "message": "Your session expired. Reconnecting…",
                    }
                    close_after = True
                    close_code = 4401
                elif current_role is None:
                    response = {
                        "type": "access",
                        "role": "revoked",
                        "operation_id": str(operation_id),
                        "message": "Your access to this note has ended.",
                    }
                    close_after = True
                elif _content_exceeds_live_limit(note.content):
                    # The note may have grown through REST/sync after this peer
                    # was admitted. Never build a duplicate ack or resync frame
                    # containing that oversized body; close the live session
                    # and let normal non-realtime note loading handle it.
                    response = {
                        "type": "error",
                        "operation_id": str(operation_id),
                        "code": "note_too_large",
                        "message": "This note is too large to edit live.",
                    }
                    close_after = True
                    close_code = 4409
                elif current_role not in ("owner", "editor"):
                    peer.role = current_role
                    response = _snapshot(
                        note,
                        kind="resync",
                        role=current_role,
                        operation_id=str(operation_id),
                        code="read_only",
                        message="View-only access",
                    )
                else:
                    peer.role = current_role
                    duplicate = (
                        await db.execute(
                            select(CollaborationOperationReceipt.operation_id).where(
                                CollaborationOperationReceipt.note_id == note_id,
                                CollaborationOperationReceipt.operation_id
                                == operation_id,
                            )
                        )
                    ).scalar_one_or_none()
                    if duplicate is not None:
                        response = _operation_ack(note, operation_id)
                    elif (
                        base_epoch != note.collab_epoch
                        or base_revision < 0
                        or base_revision > note.collab_revision
                    ):
                        # The operation was not applied. Omitting its id tells
                        # the client to preserve and re-diff the local text
                        # against this fresh baseline.
                        response = _snapshot(
                            note,
                            kind="resync",
                        )
                    elif hub.dispatch_backlog(note_key) >= _MAX_EDIT_DISPATCH_BACKLOG:
                        # Reserve queue capacity for acknowledgements and
                        # resyncs. The operation was not applied and its id is
                        # deliberately omitted so the client re-diffs/retries.
                        response = _snapshot(
                            note,
                            kind="resync",
                            code="room_busy",
                            message=(
                                "The live room is catching up. Retrying your edit."
                            ),
                        )
                    elif note.collab_revision >= _MAX_JOURNAL_OPERATIONS:
                        # Rotate an active room safely before the persisted OT
                        # history becomes unbounded. Every peer receives the
                        # same new baseline and re-diffs any pending local edit.
                        await db.execute(
                            CollaborationOperation.__table__.delete().where(
                                CollaborationOperation.note_id == note_id
                            )
                        )
                        note.collab_revision = 0
                        note.collab_epoch = uuid.uuid4()
                        await db.commit()
                        event = _snapshot(
                            note,
                            kind="resync",
                            code="baseline_compacted",
                            message="Live edit history was compacted.",
                        )
                    elif note.collab_revision - base_revision > _MAX_TRANSFORM_DISTANCE:
                        response = _snapshot(
                            note,
                            kind="resync",
                            code="stale_revision",
                            message="The live edit baseline is too old.",
                        )
                    else:
                        concurrent = (
                            (
                                await db.execute(
                                    select(CollaborationOperation.delta)
                                    .where(
                                        CollaborationOperation.note_id == note_id,
                                        CollaborationOperation.revision > base_revision,
                                        CollaborationOperation.field == field_name,
                                    )
                                    .order_by(CollaborationOperation.revision)
                                )
                            )
                            .scalars()
                            .all()
                        )
                        try:
                            transformed = delta
                            for previous_delta in concurrent:
                                transformed = transform_delta(
                                    previous_delta, transformed
                                )
                            current = (
                                note.title if field_name == "title" else note.content
                            )
                            updated = apply_delta(current, transformed)
                        except InvalidDelta as exc:
                            response = _snapshot(
                                note,
                                kind="resync",
                                message=str(exc),
                            )
                        else:
                            if field_name == "title" and len(updated) > 500:
                                response = {
                                    "type": "error",
                                    "operation_id": str(operation_id),
                                    "code": "title_too_long",
                                    "message": (
                                        "Titles can contain at most 500 characters."
                                    ),
                                }
                            elif field_name == "content" and (
                                _content_exceeds_live_limit(updated)
                            ):
                                response = {
                                    "type": "error",
                                    "operation_id": str(operation_id),
                                    "code": "note_too_large",
                                    "message": "This note is too large to edit live.",
                                }
                            else:
                                if field_name == "title":
                                    note.title = updated
                                else:
                                    note.content = updated
                                note.collab_revision += 1
                                note.updated_at = datetime.now(timezone.utc)
                                note.edited_at = note.updated_at
                                db.add(
                                    CollaborationOperation(
                                        note_id=note.id,
                                        operation_id=operation_id,
                                        revision=note.collab_revision,
                                        field=field_name,
                                        delta=transformed,
                                        author_id=acting_user.id,
                                        client_id=peer.client_id,
                                    )
                                )
                                db.add(
                                    CollaborationOperationReceipt(
                                        note_id=note.id,
                                        operation_id=operation_id,
                                    )
                                )
                                if (
                                    peer.last_version_check_at is None
                                    or note.updated_at - peer.last_version_check_at
                                    >= timedelta(seconds=30)
                                ):
                                    await note_service.record_version_snapshot(
                                        db,
                                        note,
                                        now=note.updated_at,
                                        minimum_interval=timedelta(seconds=30),
                                    )
                                    peer.last_version_check_at = note.updated_at
                                await db.commit()
                                peer.edited = True
                                event = {
                                    "type": "edit",
                                    "operation_id": str(operation_id),
                                    "client_id": peer.client_id,
                                    "author_id": peer.user_id,
                                    "field": field_name,
                                    "delta": transformed,
                                    "revision": note.collab_revision,
                                    "epoch": str(note.collab_epoch),
                                }

        if event is not None:
            # Still under the room lock, so commit/broadcast order cannot invert.
            await hub.broadcast_document(note_key, event)
        elif response is not None:
            if response.get("type") in {"ack", "resync", "snapshot"}:
                dispatch = hub.enqueue_document_locked(
                    note_key,
                    response,
                    recipients=(peer,),
                    ready=True,
                )
                if dispatch is None:
                    await hub.send(
                        peer,
                        {
                            "type": "error",
                            "code": "room_busy",
                            "message": (
                                "The live room is busy. Requesting a fresh snapshot."
                            ),
                        },
                    )
            else:
                await hub.send(peer, response)
        if close_after:
            try:
                await peer.socket.close(
                    code=close_code,
                    reason=(
                        "Session expired"
                        if close_code == 4401
                        else (
                            "Note too large for live editing"
                            if close_code == 4409
                            else "Access ended"
                        )
                    ),
                )
            except Exception:
                pass


_maintenance_task: asyncio.Task[None] | None = None


async def _compact_expired_note(
    note_id: uuid.UUID,
    delta_cutoff: datetime,
) -> None:
    """Rotate one baseline if any transform delta crossed the retention TTL."""
    note_key = str(note_id)
    event: dict | None = None
    async with hub.room_lock(note_key):
        async with async_session_factory() as db:
            note = (
                await db.execute(_select_note(note_id, for_update=True))
            ).scalar_one_or_none()
            if note is None:
                return
            expired = (
                await db.execute(
                    select(CollaborationOperation.id)
                    .where(
                        CollaborationOperation.note_id == note_id,
                        CollaborationOperation.created_at < delta_cutoff,
                    )
                    .limit(1)
                )
            ).scalar_one_or_none()
            if expired is None:
                return
            await db.execute(
                delete(CollaborationOperation).where(
                    CollaborationOperation.note_id == note_id
                )
            )
            note.collab_revision = 0
            note.collab_epoch = uuid.uuid4()
            await db.commit()
            if not note.is_deleted and hub.rooms.get(note_key):
                event = _snapshot(
                    note,
                    kind="resync",
                    code="baseline_expired",
                    message="Live edit history reached its retention limit.",
                )

        if event is not None:
            await hub.broadcast_document(note_key, event)


async def _run_collaboration_maintenance() -> None:
    """Bound full deltas globally and retain smaller retry receipts for 7 days."""
    now = datetime.now(timezone.utc)
    delta_cutoff = now - _FULL_DELTA_RETENTION
    receipt_cutoff = now - _OPERATION_RECEIPT_RETENTION
    while True:
        async with async_session_factory() as db:
            note_ids = list(
                (
                    await db.execute(
                        select(CollaborationOperation.note_id)
                        .where(CollaborationOperation.created_at < delta_cutoff)
                        .distinct()
                        .limit(_MAINTENANCE_NOTE_BATCH)
                    )
                ).scalars()
            )
            receipt_ids = list(
                (
                    await db.execute(
                        select(CollaborationOperationReceipt.id)
                        .where(
                            CollaborationOperationReceipt.created_at < receipt_cutoff
                        )
                        .order_by(CollaborationOperationReceipt.created_at)
                        .limit(_MAINTENANCE_RECEIPT_BATCH)
                    )
                ).scalars()
            )
            if receipt_ids:
                await db.execute(
                    delete(CollaborationOperationReceipt).where(
                        CollaborationOperationReceipt.id.in_(receipt_ids)
                    )
                )
            await db.commit()

        for note_id in note_ids:
            await _compact_expired_note(note_id, delta_cutoff)

        more_notes = len(note_ids) == _MAINTENANCE_NOTE_BATCH
        more_receipts = len(receipt_ids) == _MAINTENANCE_RECEIPT_BATCH
        if not more_notes and not more_receipts:
            return
        # Drain an accumulated backlog promptly while yielding between bounded
        # transactions/room batches so collaboration traffic still runs.
        await asyncio.sleep(0)


async def _collaboration_maintenance_loop() -> None:
    while True:
        try:
            await asyncio.sleep(_MAINTENANCE_INTERVAL_SECONDS)
            await _run_collaboration_maintenance()
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("Collaboration journal maintenance failed")


async def start_collaboration_maintenance() -> None:
    global _maintenance_task
    if _maintenance_task is None or _maintenance_task.done():
        _maintenance_task = asyncio.create_task(
            _collaboration_maintenance_loop(),
            name="collaboration-journal-maintenance",
        )


async def stop_collaboration_maintenance() -> None:
    global _maintenance_task
    task = _maintenance_task
    _maintenance_task = None
    if task is None:
        return
    task.cancel()
    try:
        await asyncio.wait_for(task, timeout=_CLOSE_TIMEOUT_SECONDS)
    except (asyncio.CancelledError, TimeoutError):
        pass
