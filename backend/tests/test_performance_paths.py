from unittest.mock import AsyncMock, Mock
import uuid

import pytest

from app.models.user import User
from app.models.note import Note
from app.models.task import Task
from app.services.sync_service import SyncService
from app.utils import auth_dependency


@pytest.mark.asyncio
async def test_access_token_authentication_uses_one_database_query(monkeypatch):
    user_id = uuid.uuid4()
    session_id = uuid.uuid4()
    user = User(
        id=user_id,
        email="fast-auth@example.com",
        display_name="Fast auth",
    )
    monkeypatch.setattr(
        auth_dependency,
        "decode_token",
        lambda _token: {
            "type": "access",
            "sub": str(user_id),
            "jti": str(session_id),
        },
    )
    result = Mock()
    result.scalar_one_or_none.return_value = user
    db = AsyncMock()
    db.execute.return_value = result

    authenticated = await auth_dependency.authenticate_access_token(db, "token")

    assert authenticated is user
    db.execute.assert_awaited_once()


@pytest.mark.asyncio
async def test_idle_push_enables_no_change_preflight(monkeypatch):
    service = SyncService()
    get_changes = AsyncMock(return_value=[])
    monkeypatch.setattr(service, "_get_changes_since", get_changes)
    user = User(
        id=uuid.uuid4(),
        email="idle-sync@example.com",
        display_name="Idle sync",
    )
    db = AsyncMock()

    result = await service.push_changes(
        db,
        user,
        [],
        last_sync_at="2026-08-08T12:00:00+00:00",
    )

    assert result["server_changes"] == []
    get_changes.assert_awaited_once_with(
        db,
        user,
        "2026-08-08T12:00:00+00:00",
        probe_changed_types=True,
    )


@pytest.mark.asyncio
async def test_no_change_preflight_skips_entity_hydration(monkeypatch):
    service = SyncService()
    changed_types = AsyncMock(return_value=set())
    monkeypatch.setattr(service, "_changed_types_since", changed_types)
    user = User(
        id=uuid.uuid4(),
        email="no-changes@example.com",
        display_name="No changes",
    )
    db = AsyncMock()

    changes = await service._get_changes_since(
        db,
        user,
        "2026-08-08T12:00:00+00:00",
        probe_changed_types=True,
    )

    assert changes == []
    changed_types.assert_awaited_once()
    db.execute.assert_not_awaited()


@pytest.mark.asyncio
async def test_change_probe_hydrates_only_changed_entity_types(monkeypatch):
    service = SyncService()
    monkeypatch.setattr(
        service,
        "_changed_types_since",
        AsyncMock(return_value={"note"}),
    )
    monkeypatch.setattr(
        service,
        "_type_specs",
        lambda _types: [
            ("note", Note, lambda _row: {"entity_type": "note"}, ()),
            ("task", Task, lambda _row: {"entity_type": "task"}, ()),
        ],
    )
    user = User(
        id=uuid.uuid4(),
        email="one-type@example.com",
        display_name="One changed type",
    )
    query_result = Mock()
    query_result.scalars.return_value.unique.return_value.all.return_value = [object()]
    db = AsyncMock()
    db.execute.return_value = query_result

    changes = await service._get_changes_since(
        db,
        user,
        "2026-08-08T12:00:00+00:00",
        probe_changed_types=True,
    )

    assert changes == [{"entity_type": "note"}]
    db.execute.assert_awaited_once()
