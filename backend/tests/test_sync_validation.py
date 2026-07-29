from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock
import uuid

import pytest

from app.models.user import User
from app.services.sync_service import SyncService, _client_ts


def test_future_client_timestamp_is_capped_to_server_time():
    now = datetime(2026, 7, 29, tzinfo=timezone.utc)
    future = (now + timedelta(days=365)).isoformat()

    assert _client_ts(future, now=now) == now


def test_normal_clock_skew_is_preserved():
    now = datetime(2026, 7, 29, tzinfo=timezone.utc)
    client_time = now + timedelta(minutes=2)

    assert _client_ts(client_time.isoformat(), now=now) == client_time


@pytest.mark.asyncio
async def test_sync_notebook_parent_cannot_create_cycle(monkeypatch):
    service = SyncService()
    current_id = uuid.uuid4()
    parent_id = uuid.uuid4()
    user = User(
        id=uuid.uuid4(),
        email="test@example.com",
        display_name="Test",
    )
    monkeypatch.setattr(
        service,
        "_owned_notebook_id",
        AsyncMock(return_value=parent_id),
    )
    rows_result = AsyncMock()
    rows_result.all = lambda: [
        (parent_id, current_id),
        (current_id, None),
    ]
    db = AsyncMock()
    db.execute.return_value = rows_result

    resolved = await service._safe_notebook_parent(
        db, user, str(parent_id), current_id
    )

    assert resolved is None
