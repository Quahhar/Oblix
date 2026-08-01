import pytest

from app.services.text_ot import (
    InvalidDelta,
    apply_delta,
    normalize_delta,
    transform_delta,
    utf16_length,
)


def test_applies_plain_text_delta():
    delta = [{"retain": 6}, {"delete": 5}, {"insert": "Oblix"}]
    assert apply_delta("Hello world", delta) == "Hello Oblix"


def test_concurrent_inserts_are_preserved_in_server_order():
    first = [{"retain": 1}, {"insert": "A"}]
    second = [{"retain": 1}, {"insert": "B"}]
    after_first = apply_delta("xy", first)
    transformed_second = transform_delta(first, second)
    assert apply_delta(after_first, transformed_second) == "xABy"


def test_delete_does_not_remove_a_concurrent_insert():
    delete_original = [{"retain": 1}, {"delete": 2}]
    concurrent_insert = [{"retain": 2}, {"insert": "X"}]
    after_insert = apply_delta("abcd", concurrent_insert)
    transformed_delete = transform_delta(concurrent_insert, delete_original)
    assert apply_delta(after_insert, transformed_delete) == "aXd"


def test_rejects_delta_beyond_document():
    with pytest.raises(InvalidDelta):
        apply_delta("short", [{"retain": 10}])


def test_uses_dart_utf16_offsets_after_emoji():
    assert utf16_length("A😀B") == 4
    assert apply_delta("A😀B", [{"retain": 3}, {"insert": "X"}]) == "A😀XB"
    assert apply_delta("A😀B", [{"retain": 1}, {"delete": 2}]) == "AB"


def test_rejects_an_offset_inside_a_surrogate_pair():
    with pytest.raises(InvalidDelta, match="splits a Unicode character"):
        apply_delta("A😀B", [{"retain": 2}, {"insert": "X"}])


def test_concurrent_emoji_inserts_keep_server_order():
    first = [{"retain": 2}, {"insert": "A"}]
    second = [{"retain": 2}, {"insert": "B"}]
    after_first = apply_delta("😀x", first)
    transformed_second = transform_delta(first, second)
    assert apply_delta(after_first, transformed_second) == "😀ABx"


def test_rejects_huge_numeric_operations_without_transforming():
    with pytest.raises(InvalidDelta, match="bounded integer"):
        normalize_delta([{"retain": 10**100}])


def test_caps_aggregate_insert_size():
    with pytest.raises(InvalidDelta, match="bounded string"):
        normalize_delta([{"insert": "a" * 60_000}, {"insert": "b" * 60_000}])
