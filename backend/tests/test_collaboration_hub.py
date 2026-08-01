import asyncio
import uuid
from types import SimpleNamespace

import pytest

from app.routers import collaboration as collaboration_router
from app.routers.collaboration import CollaborationHub, Peer, _operation_ack


class RecordingSocket:
    def __init__(self):
        self.sent: list[dict] = []
        self.closed: list[tuple[int, str]] = []

    async def send_json(self, message: dict) -> None:
        self.sent.append(message)

    async def close(self, *, code: int, reason: str) -> None:
        self.closed.append((code, reason))


class BlockingSocket(RecordingSocket):
    def __init__(self):
        super().__init__()
        self.send_started = asyncio.Event()
        self.send_cancelled = asyncio.Event()

    async def send_json(self, message: dict) -> None:
        self.send_started.set()
        try:
            await asyncio.Event().wait()
        finally:
            self.send_cancelled.set()


def make_peer(socket, *, client_id: str) -> Peer:
    return Peer(
        socket=socket,
        user_id=f"user-{client_id}",
        display_name=client_id,
        client_id=client_id,
        role="editor",
        token="token",
    )


def test_receipt_retry_ack_carries_canonical_document_and_operation():
    operation_id = uuid.uuid4()
    note = SimpleNamespace(
        id=uuid.uuid4(),
        title="canonical title",
        content="canonical body",
        collab_revision=0,
        collab_epoch=uuid.uuid4(),
    )

    message = _operation_ack(note, operation_id)

    assert message == {
        "type": "ack",
        "note_id": str(note.id),
        "revision": 0,
        "epoch": str(note.collab_epoch),
        "operation_id": str(operation_id),
        "title": "canonical title",
        "content": "canonical body",
    }


@pytest.mark.asyncio
async def test_room_lock_is_evicted_after_last_lease():
    hub = CollaborationHub()

    async with hub.room_lock("note-1"):
        assert "note-1" in hub.locks

    assert "note-1" not in hub.locks
    assert "note-1" not in hub._lock_users


@pytest.mark.asyncio
async def test_waiting_lease_keeps_one_stable_room_lock():
    hub = CollaborationHub()
    first_entered = asyncio.Event()
    release_first = asyncio.Event()
    second_entered = asyncio.Event()

    async def first():
        async with hub.room_lock("note-1"):
            first_entered.set()
            await release_first.wait()

    async def second():
        async with hub.room_lock("note-1"):
            second_entered.set()

    first_task = asyncio.create_task(first())
    await first_entered.wait()
    original_lock = hub.locks["note-1"]
    second_task = asyncio.create_task(second())
    await asyncio.sleep(0)

    assert hub._lock_users["note-1"] == 2
    assert hub.locks["note-1"] is original_lock

    release_first.set()
    await asyncio.gather(first_task, second_task)
    assert second_entered.is_set()
    assert "note-1" not in hub.locks


@pytest.mark.asyncio
async def test_document_dispatch_waits_for_commit_gate_and_preserves_order():
    hub = CollaborationHub()
    socket = RecordingSocket()
    peer = make_peer(socket, client_id="client-1")

    async with hub.room_lock("note-1"):
        hub.add("note-1", peer)
        first = hub.enqueue_document_locked(
            "note-1",
            {"type": "edit", "revision": 1},
        )
        second = hub.enqueue_document_locked(
            "note-1",
            {"type": "edit", "revision": 2},
            ready=True,
        )

    assert first is not None
    assert second is not None
    await asyncio.sleep(0)
    assert socket.sent == []
    assert not first.completion.done()
    assert not second.completion.done()

    first.ready.set()
    assert await hub.await_dispatch(first, timeout=0.5)
    assert await hub.await_dispatch(second, timeout=0.5)
    assert [message["revision"] for message in socket.sent] == [1, 2]
    assert hub._dispatch_bytes_by_room == {}
    assert hub._dispatch_total_bytes == 0

    await hub.leave("note-1", peer)


@pytest.mark.asyncio
async def test_document_dispatch_uses_recipient_snapshot_from_enqueue_time():
    hub = CollaborationHub()
    first_socket = RecordingSocket()
    second_socket = RecordingSocket()
    first_peer = make_peer(first_socket, client_id="client-1")
    second_peer = make_peer(second_socket, client_id="client-2")

    async with hub.room_lock("note-1"):
        hub.add("note-1", first_peer)
        item = hub.enqueue_document_locked(
            "note-1",
            {"type": "edit", "revision": 1},
        )
        hub.add("note-1", second_peer)

    assert item is not None
    item.ready.set()
    assert await hub.await_dispatch(item, timeout=0.5)
    assert first_socket.sent == [{"type": "edit", "revision": 1}]
    assert second_socket.sent == []

    async with hub.room_lock("note-1"):
        hub.rooms.pop("note-1")
        hub._cancel_dispatcher_locked("note-1")
    await asyncio.sleep(0)


@pytest.mark.asyncio
async def test_last_peer_leave_cancels_blocked_dispatcher_with_bounded_teardown():
    hub = CollaborationHub()
    socket = BlockingSocket()
    peer = make_peer(socket, client_id="client-1")

    async with hub.room_lock("note-1"):
        hub.add("note-1", peer)
        item = hub.enqueue_document_locked(
            "note-1",
            {"type": "edit", "revision": 1},
            ready=True,
        )

    assert item is not None
    dispatcher = hub._dispatch_tasks["note-1"]
    await asyncio.wait_for(socket.send_started.wait(), timeout=0.5)
    await asyncio.wait_for(hub.leave("note-1", peer), timeout=0.5)
    await asyncio.wait_for(socket.send_cancelled.wait(), timeout=0.5)

    with pytest.raises(asyncio.CancelledError):
        await dispatcher
    assert item.completion.done()
    assert item.completion.result() is False
    assert "note-1" not in hub.rooms
    assert "note-1" not in hub._dispatch_queues
    assert "note-1" not in hub._dispatch_tasks
    assert hub._dispatch_bytes_by_room == {}
    assert hub._dispatch_total_bytes == 0


@pytest.mark.asyncio
async def test_dispatch_byte_budget_includes_in_flight_frames(monkeypatch):
    hub = CollaborationHub()
    socket = BlockingSocket()
    peer = make_peer(socket, client_id="client-1")
    message = {"type": "resync", "content": "x" * 1_000}

    async with hub.room_lock("note-1"):
        hub.add("note-1", peer)
        first = hub.enqueue_document_locked("note-1", message, ready=True)

    assert first is not None
    dispatcher = hub._dispatch_tasks["note-1"]
    await asyncio.wait_for(socket.send_started.wait(), timeout=0.5)
    monkeypatch.setattr(
        collaboration_router,
        "_MAX_DISPATCH_BYTES_PER_ROOM",
        (first.size_bytes * 2) - 1,
    )

    async with hub.room_lock("note-1"):
        rejected = hub.enqueue_document_locked("note-1", message, ready=True)

    assert rejected is None
    assert hub._dispatch_bytes_by_room == {"note-1": first.size_bytes}
    assert hub._dispatch_total_bytes == first.size_bytes

    second_socket = RecordingSocket()
    second_peer = make_peer(second_socket, client_id="client-2")
    monkeypatch.setattr(
        collaboration_router,
        "_MAX_DISPATCH_BYTES_PER_ROOM",
        first.size_bytes * 3,
    )
    monkeypatch.setattr(
        collaboration_router,
        "_MAX_DISPATCH_BYTES_TOTAL",
        (first.size_bytes * 2) - 1,
    )
    async with hub.room_lock("note-2"):
        hub.add("note-2", second_peer)
        globally_rejected = hub.enqueue_document_locked(
            "note-2",
            message,
            ready=True,
        )
    assert globally_rejected is None
    await hub.leave("note-2", second_peer)

    await asyncio.wait_for(hub.leave("note-1", peer), timeout=0.5)
    await asyncio.wait_for(socket.send_cancelled.wait(), timeout=0.5)
    with pytest.raises(asyncio.CancelledError):
        await dispatcher
    assert hub._dispatch_bytes_by_room == {}
    assert hub._dispatch_total_bytes == 0


@pytest.mark.parametrize("role", ["viewer", "editor"])
@pytest.mark.asyncio
async def test_oversized_note_after_admission_closes_without_queueing_body(
    monkeypatch,
    role,
):
    """A REST/sync replacement can grow a note after WebSocket admission."""
    note_id = uuid.uuid4()
    operation_id = uuid.uuid4()
    note = SimpleNamespace(
        id=note_id,
        title="canonical title",
        content="x" * 11,
        is_deleted=False,
        collab_revision=7,
        collab_epoch=uuid.uuid4(),
    )
    acting_user = SimpleNamespace(id=uuid.uuid4())

    class ScalarResult:
        def scalar_one_or_none(self):
            return note

    class FakeDb:
        def __init__(self):
            self.execute_count = 0
            self.committed = False
            self.added: list[object] = []

        async def execute(self, _statement):
            self.execute_count += 1
            return ScalarResult()

        async def commit(self):
            self.committed = True

        def add(self, value):
            self.added.append(value)

    class FakeSessionContext:
        def __init__(self, db):
            self.db = db

        async def __aenter__(self):
            return self.db

        async def __aexit__(self, _exc_type, _exc, _tb):
            return False

    db = FakeDb()
    local_hub = CollaborationHub()
    socket = RecordingSocket()
    peer = make_peer(socket, client_id="client-1")
    local_hub.add(str(note_id), peer)

    async def authenticate(_db, _token):
        return acting_user

    async def note_role(_db, _user, _note):
        return role

    real_utf16_length = collaboration_router.utf16_length

    def bounded_utf16_length(value):
        # The production fast path must reject an obviously over-limit body
        # from len() without allocating a second UTF-16 copy of that body.
        if len(value) > 10:
            raise AssertionError("oversized body reached utf16_length")
        return real_utf16_length(value)

    monkeypatch.setattr(collaboration_router, "hub", local_hub)
    monkeypatch.setattr(
        collaboration_router,
        "async_session_factory",
        lambda: FakeSessionContext(db),
    )
    monkeypatch.setattr(
        collaboration_router,
        "authenticate_access_token",
        authenticate,
    )
    monkeypatch.setattr(
        collaboration_router.share_service,
        "note_role",
        note_role,
    )
    monkeypatch.setattr(collaboration_router, "_MAX_LIVE_CONTENT_UNITS", 10)
    monkeypatch.setattr(
        collaboration_router,
        "utf16_length",
        bounded_utf16_length,
    )

    await collaboration_router._handle_edit(
        note_id,
        peer,
        {
            "type": "edit",
            "operation_id": str(operation_id),
            "field": "title",
            "base_revision": 0,
            "base_epoch": str(uuid.uuid4()),
            "delta": [{"insert": "z"}],
        },
    )

    assert socket.sent == [
        {
            "type": "error",
            "operation_id": str(operation_id),
            "code": "note_too_large",
            "message": "This note is too large to edit live.",
        }
    ]
    assert socket.closed == [(4409, "Note too large for live editing")]
    assert all("title" not in message and "content" not in message for message in socket.sent)
    assert str(note_id) not in local_hub._dispatch_queues
    assert local_hub._dispatch_bytes_by_room == {}
    assert local_hub._dispatch_total_bytes == 0
    assert note.collab_revision == 7
    assert note.content == "x" * 11
    assert db.execute_count == 1
    assert not db.committed
    assert db.added == []
