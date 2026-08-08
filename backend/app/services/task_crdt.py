"""Deterministic field-level LWW map used by offline task synchronization.

Each mutable task field is an independent LWW register. Timestamps decide first;
the stable device id breaks ties, so replicas converge regardless of delivery
order while edits to different fields are preserved.
"""

from datetime import datetime, timedelta, timezone
from typing import Any, Mapping, Optional


TASK_CRDT_FIELDS = (
    "title",
    "description",
    "note_id",
    "due_date",
    "sort_order",
    "is_completed",
    "is_deleted",
)
NOTE_CRDT_FIELDS = (
    "title",
    "content",
    "content_type",
    "notebook_id",
    "is_pinned",
    "is_archived",
    "tags",
    "is_deleted",
)
NOTEBOOK_CRDT_FIELDS = ("name", "parent_id", "sort_order", "is_deleted")

Clock = tuple[datetime, str]


def _parse_timestamp(value: Any) -> Optional[datetime]:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def canonical_clock(
    timestamp: Any,
    device_id: Any,
    *,
    now: Optional[datetime] = None,
) -> Clock:
    """Normalize an untrusted clock and bound future-device skew."""
    server_now = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    parsed = _parse_timestamp(timestamp) or server_now
    if parsed > server_now + timedelta(minutes=5):
        parsed = server_now
    return parsed, str(device_id or "")[:255]


def stored_clock(
    clocks: Any,
    field: str,
    *,
    fallback_timestamp: datetime,
) -> Clock:
    raw = clocks.get(field) if isinstance(clocks, Mapping) else None
    if isinstance(raw, Mapping):
        parsed = _parse_timestamp(raw.get("timestamp"))
        if parsed is not None:
            return parsed, str(raw.get("device_id") or "")[:255]
    return fallback_timestamp.astimezone(timezone.utc), ""


def incoming_clock(
    data: Mapping[str, Any],
    field: str,
    *,
    fallback_timestamp: Any,
    fallback_device_id: Any,
    now: Optional[datetime] = None,
) -> Clock:
    raw_clocks = data.get("field_clocks")
    raw = raw_clocks.get(field) if isinstance(raw_clocks, Mapping) else None
    if isinstance(raw, Mapping):
        return canonical_clock(
            raw.get("timestamp") or fallback_timestamp,
            raw.get("device_id") or fallback_device_id,
            now=now,
        )
    return canonical_clock(fallback_timestamp, fallback_device_id, now=now)


def serialize_clock(clock: Clock) -> dict[str, str]:
    return {"timestamp": clock[0].isoformat(), "device_id": clock[1]}


def winning_fields(
    current_clocks: Any,
    incoming_data: Mapping[str, Any],
    *,
    current_fallback_timestamp: datetime,
    incoming_fallback_timestamp: Any,
    incoming_device_id: Any,
    now: Optional[datetime] = None,
    fields: tuple[str, ...] = TASK_CRDT_FIELDS,
) -> dict[str, Clock]:
    winners: dict[str, Clock] = {}
    for field in fields:
        if field not in incoming_data:
            continue
        candidate = incoming_clock(
            incoming_data,
            field,
            fallback_timestamp=incoming_fallback_timestamp,
            fallback_device_id=incoming_device_id,
            now=now,
        )
        current = stored_clock(
            current_clocks,
            field,
            fallback_timestamp=current_fallback_timestamp,
        )
        if candidate > current:
            winners[field] = candidate
    return winners


def initial_field_clocks(
    timestamp: datetime,
    device_id: str,
    fields: tuple[str, ...] = TASK_CRDT_FIELDS,
) -> dict[str, dict[str, str]]:
    stamp = serialize_clock((timestamp.astimezone(timezone.utc), device_id[:255]))
    return {field: dict(stamp) for field in fields}
