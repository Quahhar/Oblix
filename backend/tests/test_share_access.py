import uuid
from types import SimpleNamespace

from sqlalchemy import or_, select
from sqlalchemy.dialects import postgresql

from app.models.share import Share
from app.services.share_service import note_share_conditions


def _compiled_access_query(note) -> str:
    statement = select(Share.role).where(or_(*note_share_conditions(note)))
    return str(statement.compile(dialect=postgresql.dialect()))


def test_notebook_derived_note_access_requires_a_live_notebook():
    note = SimpleNamespace(id=uuid.uuid4(), notebook_id=uuid.uuid4())

    query = _compiled_access_query(note)

    assert "EXISTS (SELECT notebooks.id" in query
    assert "notebooks.id =" in query
    assert "notebooks.is_deleted IS false" in query


def test_direct_note_access_does_not_depend_on_a_notebook():
    note = SimpleNamespace(id=uuid.uuid4(), notebook_id=None)

    query = _compiled_access_query(note)

    assert "shares.entity_id =" in query
    assert "notebooks" not in query
