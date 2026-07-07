"""
v3-api-standards §2 — Paginación estándar (`?page&size` -> {items,total,page,pages}).

Cubre:
- 2.1 PageOut[T] genérico Pydantic
- 2.2 BaseRepository.paginate(select_sql, count_sql, *args, page, size)
- 2.3 Tests de paginate: una página, total=0 sin división por cero, misma
  conexión (aislamiento/JWT-passthrough)
"""
from __future__ import annotations

from unittest.mock import AsyncMock

import pytest
from pydantic import BaseModel

from backend.repositories.base import BaseRepository
from backend.schemas.common import PageOut


class _Row(BaseModel):
    id: int
    name: str


# ── 2.1 — PageOut[T] genérico ────────────────────────────────────────────────


def test_page_out_generic_has_standard_envelope_fields():
    page = PageOut[_Row](items=[_Row(id=1, name="a")], total=1, page=0, pages=1)
    assert page.items == [_Row(id=1, name="a")]
    assert page.total == 1
    assert page.page == 0
    assert page.pages == 1


def test_page_out_generic_serializes_with_model_dump():
    page = PageOut[_Row](items=[_Row(id=1, name="a")], total=1, page=0, pages=1)
    dumped = page.model_dump()
    assert set(dumped.keys()) == {"items", "total", "page", "pages"}


# ── 2.2 / 2.3 — BaseRepository.paginate ─────────────────────────────────────


@pytest.fixture
def mock_conn():
    conn = AsyncMock()
    return conn


@pytest.mark.asyncio
async def test_paginate_builds_envelope_for_a_page(mock_conn):
    """2.3: página intermedia — 60 filas, page=1, size=25 -> pages=3, offset=25."""
    rows = [{"id": i, "name": f"row-{i}"} for i in range(25)]
    mock_conn.fetch = AsyncMock(return_value=rows)
    mock_conn.fetchval = AsyncMock(return_value=60)
    repo = BaseRepository(mock_conn)

    result = await repo.paginate(
        "SELECT * FROM widgets WHERE account_id = $1",
        "SELECT COUNT(*) FROM widgets WHERE account_id = $1",
        "acc-1",
        page=1,
        size=25,
    )

    assert result["total"] == 60
    assert result["page"] == 1
    assert result["pages"] == 3
    assert len(result["items"]) == 25

    # offset = page * size = 25
    fetch_call = mock_conn.fetch.call_args
    assert fetch_call.args[0].strip().startswith("SELECT * FROM widgets")
    assert "LIMIT" in fetch_call.args[0]
    assert "OFFSET" in fetch_call.args[0]
    # args: account_id, limit, offset (orden documentado en el helper)
    assert fetch_call.args[1] == "acc-1"
    assert 25 in fetch_call.args[2:]  # size
    assert 25 in fetch_call.args[2:]  # offset (page*size=25 too, sanity)


@pytest.mark.asyncio
async def test_paginate_total_zero_returns_pages_zero_without_division_error(mock_conn):
    """2.3 TRIANGULATE: total=0 -> pages=0, sin ZeroDivisionError."""
    mock_conn.fetch = AsyncMock(return_value=[])
    mock_conn.fetchval = AsyncMock(return_value=0)
    repo = BaseRepository(mock_conn)

    result = await repo.paginate(
        "SELECT * FROM widgets WHERE account_id = $1",
        "SELECT COUNT(*) FROM widgets WHERE account_id = $1",
        "acc-1",
        page=0,
        size=25,
    )

    assert result == {"items": [], "total": 0, "page": 0, "pages": 0}


@pytest.mark.asyncio
async def test_paginate_first_page_partial_results(mock_conn):
    """2.3 TRIANGULATE adicional: total no múltiplo del size -> ceil correcto."""
    rows = [{"id": i} for i in range(5)]
    mock_conn.fetch = AsyncMock(return_value=rows)
    mock_conn.fetchval = AsyncMock(return_value=55)
    repo = BaseRepository(mock_conn)

    result = await repo.paginate(
        "SELECT * FROM widgets WHERE account_id = $1",
        "SELECT COUNT(*) FROM widgets WHERE account_id = $1",
        "acc-1",
        page=2,
        size=25,
    )

    assert result["total"] == 55
    assert result["pages"] == 3  # ceil(55/25) = 3
    assert result["page"] == 2


@pytest.mark.asyncio
async def test_paginate_uses_same_connection_for_select_and_count(mock_conn):
    """2.3: aislamiento/JWT-passthrough — ambas queries corren sobre la misma
    conexión inyectada, sin abrir conexiones nuevas ni re-inyectar claims."""
    mock_conn.fetch = AsyncMock(return_value=[])
    mock_conn.fetchval = AsyncMock(return_value=0)
    repo = BaseRepository(mock_conn)

    await repo.paginate(
        "SELECT * FROM widgets WHERE account_id = $1",
        "SELECT COUNT(*) FROM widgets WHERE account_id = $1",
        "acc-1",
        page=0,
        size=10,
    )

    mock_conn.fetch.assert_awaited_once()
    mock_conn.fetchval.assert_awaited_once()


@pytest.mark.asyncio
async def test_paginate_count_query_receives_same_filter_args(mock_conn):
    mock_conn.fetch = AsyncMock(return_value=[])
    mock_conn.fetchval = AsyncMock(return_value=0)
    repo = BaseRepository(mock_conn)

    await repo.paginate(
        "SELECT * FROM widgets WHERE account_id = $1 AND status = $2",
        "SELECT COUNT(*) FROM widgets WHERE account_id = $1 AND status = $2",
        "acc-1",
        "active",
        page=0,
        size=10,
    )

    count_call = mock_conn.fetchval.call_args
    assert count_call.args[1:] == ("acc-1", "active")
