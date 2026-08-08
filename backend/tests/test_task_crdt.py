from datetime import datetime, timedelta, timezone

from app.services.task_crdt import (
    NOTEBOOK_CRDT_FIELDS,
    NOTE_CRDT_FIELDS,
    winning_fields,
)


def _clock(at: datetime, device: str) -> dict[str, str]:
    return {"timestamp": at.isoformat(), "device_id": device}


def test_concurrent_changes_to_different_task_fields_both_win():
    base = datetime(2026, 8, 8, tzinfo=timezone.utc)
    current = {
        "title": _clock(base + timedelta(seconds=2), "laptop"),
        "is_completed": _clock(base, "laptop"),
    }
    incoming = {
        "title": "old phone title",
        "is_completed": True,
        "field_clocks": {
            "title": _clock(base + timedelta(seconds=1), "phone"),
            "is_completed": _clock(base + timedelta(seconds=3), "phone"),
        },
    }

    winners = winning_fields(
        current,
        incoming,
        current_fallback_timestamp=base,
        incoming_fallback_timestamp=(base + timedelta(seconds=3)).isoformat(),
        incoming_device_id="phone",
        now=base + timedelta(seconds=4),
    )

    assert set(winners) == {"is_completed"}


def test_device_id_deterministically_breaks_equal_timestamp_ties():
    at = datetime(2026, 8, 8, tzinfo=timezone.utc)
    incoming = {
        "title": "phone title",
        "field_clocks": {"title": _clock(at, "phone")},
    }

    winners = winning_fields(
        {"title": _clock(at, "laptop")},
        incoming,
        current_fallback_timestamp=at,
        incoming_fallback_timestamp=at.isoformat(),
        incoming_device_id="phone",
        now=at,
    )

    assert set(winners) == {"title"}


def test_note_pin_and_title_merge_independently():
    base = datetime(2026, 8, 8, tzinfo=timezone.utc)
    winners = winning_fields(
        {
            "title": _clock(base, "phone"),
            "is_pinned": _clock(base + timedelta(seconds=3), "phone"),
        },
        {
            "title": "Automated title",
            "is_pinned": False,
            "field_clocks": {
                "title": _clock(base + timedelta(seconds=4), "laptop"),
                "is_pinned": _clock(base + timedelta(seconds=1), "laptop"),
            },
        },
        current_fallback_timestamp=base,
        incoming_fallback_timestamp=(base + timedelta(seconds=4)).isoformat(),
        incoming_device_id="laptop",
        now=base + timedelta(seconds=5),
        fields=NOTE_CRDT_FIELDS,
    )
    assert set(winners) == {"title"}


def test_notebook_name_and_order_merge_independently():
    base = datetime(2026, 8, 8, tzinfo=timezone.utc)
    winners = winning_fields(
        {
            "name": _clock(base + timedelta(seconds=3), "phone"),
            "sort_order": _clock(base, "phone"),
        },
        {
            "name": "Old name",
            "sort_order": 9,
            "field_clocks": {
                "name": _clock(base + timedelta(seconds=1), "laptop"),
                "sort_order": _clock(base + timedelta(seconds=4), "laptop"),
            },
        },
        current_fallback_timestamp=base,
        incoming_fallback_timestamp=(base + timedelta(seconds=4)).isoformat(),
        incoming_device_id="laptop",
        now=base + timedelta(seconds=5),
        fields=NOTEBOOK_CRDT_FIELDS,
    )
    assert set(winners) == {"sort_order"}
