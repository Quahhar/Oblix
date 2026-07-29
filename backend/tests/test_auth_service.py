from unittest.mock import AsyncMock

import pytest
from fastapi import HTTPException

from app.config import settings
from app.services.auth_service import auth_service


@pytest.mark.asyncio
async def test_google_auth_is_disabled_without_audience(monkeypatch):
    monkeypatch.setattr(settings, "GOOGLE_CLIENT_ID", None)

    with pytest.raises(HTTPException) as exc:
        await auth_service.google_auth(AsyncMock(), "untrusted-token")

    assert exc.value.status_code == 503
    assert exc.value.detail == "Google sign-in is not configured"
