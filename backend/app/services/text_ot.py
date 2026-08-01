"""Minimal plain-text Quill Delta validation, application and transformation.

Only string inserts and integer retain/delete operations are accepted. This is
the subset emitted by Oblix's plain-text controllers and keeps the wire format
compatible with mature Quill Delta implementations on clients.
"""

from dataclasses import dataclass
from typing import Any


class InvalidDelta(ValueError):
    pass


_MAX_COMPONENTS = 1000
_MAX_INSERT_UNITS = 100_000
_MAX_NUMERIC_UNITS = 2_000_000


def utf16_length(value: str) -> int:
    """Return the UTF-16 code units used by Dart and Quill Delta offsets."""
    try:
        return len(value.encode("utf-16-le")) // 2
    except UnicodeEncodeError as exc:
        raise InvalidDelta("text contains an unpaired Unicode surrogate") from exc


def _utf16_slice(value: str, start: int, end: int | None = None) -> str:
    """Slice using Dart String offsets and reject split surrogate pairs."""
    encoded = value.encode("utf-16-le")
    upper = len(encoded) // 2 if end is None else end
    try:
        return encoded[start * 2 : upper * 2].decode("utf-16-le")
    except UnicodeDecodeError as exc:
        raise InvalidDelta("operation splits a Unicode character") from exc


def normalize_delta(raw: Any) -> list[dict]:
    if not isinstance(raw, list) or len(raw) > _MAX_COMPONENTS:
        raise InvalidDelta("delta must be a bounded operation list")
    out: list[dict] = []
    inserted_units = 0
    for item in raw:
        if not isinstance(item, dict) or len(item) != 1:
            raise InvalidDelta("each delta component must have one operation")
        key, value = next(iter(item.items()))
        if key == "insert":
            if not isinstance(value, str):
                raise InvalidDelta("insert must be a bounded string")
            inserted_units += utf16_length(value)
            if inserted_units > _MAX_INSERT_UNITS:
                raise InvalidDelta("insert must be a bounded string")
            if value:
                _push(out, {"insert": value})
        elif key in ("retain", "delete"):
            if (
                not isinstance(value, int)
                or isinstance(value, bool)
                or value <= 0
                or value > _MAX_NUMERIC_UNITS
            ):
                raise InvalidDelta(f"{key} must be a positive bounded integer")
            _push(out, {key: value})
        else:
            raise InvalidDelta(f"unsupported delta operation: {key}")
    return out


def apply_delta(text: str, delta: list[dict]) -> str:
    cursor = 0
    text_units = utf16_length(text)
    chunks: list[str] = []
    for component in normalize_delta(delta):
        key, value = next(iter(component.items()))
        if key == "retain":
            end = cursor + value
            if end > text_units:
                raise InvalidDelta("retain extends beyond the document")
            chunks.append(_utf16_slice(text, cursor, end))
            cursor = end
        elif key == "delete":
            cursor += value
            if cursor > text_units:
                raise InvalidDelta("delete extends beyond the document")
        else:
            chunks.append(value)
    chunks.append(_utf16_slice(text, cursor))
    return "".join(chunks)


def transform_delta(applied: list[dict], incoming: list[dict]) -> list[dict]:
    """Transform *incoming* so it can run after already-applied *applied*.

    Earlier server revisions have insertion priority at identical positions,
    giving every participant the same deterministic ordering.
    """
    left = _Iterator(normalize_delta(applied))
    right = _Iterator(normalize_delta(incoming))
    result: list[dict] = []
    while left.has_next or right.has_next:
        if left.peek_type == "insert":
            _push(result, {"retain": left.take_length()})
            continue
        if right.peek_type == "insert":
            _push(result, right.take())
            continue

        length = min(left.peek_length, right.peek_length)
        if length == _INFINITY:
            break
        a = left.take(length)
        b = right.take(length)
        if "delete" in a:
            continue
        if "delete" in b:
            _push(result, b)
        else:
            _push(result, {"retain": length})
    while result and "retain" in result[-1]:
        result.pop()
    return result


def _push(out: list[dict], component: dict) -> None:
    key, value = next(iter(component.items()))
    if not value:
        return
    if out and key in out[-1]:
        out[-1][key] += value
    else:
        out.append({key: value})


_INFINITY = 1 << 60


@dataclass
class _Iterator:
    operations: list[dict]
    index: int = 0
    offset: int = 0

    @property
    def has_next(self) -> bool:
        return self.index < len(self.operations)

    @property
    def peek_type(self) -> str:
        if not self.has_next:
            return "retain"
        return next(iter(self.operations[self.index]))

    @property
    def peek_length(self) -> int:
        if not self.has_next:
            return _INFINITY
        value = next(iter(self.operations[self.index].values()))
        return (
            utf16_length(value) - self.offset
            if isinstance(value, str)
            else value - self.offset
        )

    def take_length(self) -> int:
        length = self.peek_length
        self.take(length)
        return length

    def take(self, length: int | None = None) -> dict:
        if not self.has_next:
            amount = length if length is not None else _INFINITY
            return {"retain": amount}
        operation = self.operations[self.index]
        key, value = next(iter(operation.items()))
        available = self.peek_length
        amount = available if length is None else min(length, available)
        if key == "insert":
            result = {"insert": _utf16_slice(value, self.offset, self.offset + amount)}
        else:
            result = {key: amount}
        self.offset += amount
        total = utf16_length(value) if isinstance(value, str) else value
        if self.offset >= total:
            self.index += 1
            self.offset = 0
        return result
