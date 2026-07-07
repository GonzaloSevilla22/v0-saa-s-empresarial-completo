"""
v3-api-standards §2 — Paginación estándar (`?page&size` -> {items,total,page,pages}).

Cubre:
- 2.1 PageOut[T] genérico Pydantic
- 2.2 BaseRepository.paginate(select_sql, count_sql, *args, page, size)
- 2.3 Tests de paginate: una página, total=0 sin división por cero, misma
  conexión (aislamiento/JWT-passthrough)
"""
from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest
from pydantic import BaseModel

from backend.repositories.base import BaseRepository
from backend.schemas.common import PageOut
from backend.tests.conftest import make_token


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


# ── 2.7 / 2.8 / 2.9 — endpoints migrados a page/size + PageOut ──────────────

CUSTOMER_ACCOUNT_ID = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
SUPPLIER_ACCOUNT_ID = "ffffffff-ffff-ffff-ffff-ffffffffffff"


@pytest.mark.asyncio
async def test_customer_account_movements_returns_page_envelope(async_client, mock_pool):
    """2.7: GET /customer-accounts/{id}/movements -> {items,total,page,pages}
    en vez de la lista plana de limit/offset."""
    pool, conn = mock_pool
    token = make_token()
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchval = AsyncMock(return_value=0)

    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            f"/customer-accounts/{CUSTOMER_ACCOUNT_ID}/movements",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert resp.status_code == 200
    body = resp.json()
    assert body["items"] == []
    assert body["total"] == 0
    assert body["page"] == 0
    assert body["pages"] == 0


@pytest.mark.asyncio
async def test_customer_account_movements_page_out_of_range_returns_empty(async_client, mock_pool):
    """TRIANGULATE: página fuera de rango -> 200 con items vacío, no error."""
    pool, conn = mock_pool
    token = make_token()
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchval = AsyncMock(return_value=5)

    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            f"/customer-accounts/{CUSTOMER_ACCOUNT_ID}/movements?page=9&size=25",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert resp.status_code == 200
    body = resp.json()
    assert body["items"] == []
    assert body["total"] == 5
    assert body["page"] == 9


@pytest.mark.asyncio
async def test_customer_account_movements_size_over_max_returns_422(async_client, mock_pool):
    """2.10: size sobre la cota máxima (200) -> 422 problem+json, sin ejecutar query."""
    pool, conn = mock_pool
    token = make_token()

    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            f"/customer-accounts/{CUSTOMER_ACCOUNT_ID}/movements?size=9999",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert resp.status_code == 422
    assert resp.headers["content-type"].startswith("application/problem+json")
    conn.fetch.assert_not_awaited()


@pytest.mark.asyncio
async def test_supplier_account_movements_returns_page_envelope(async_client, mock_pool):
    """2.8: GET /supplier-accounts/{id}/movements -> {items,total,page,pages}."""
    pool, conn = mock_pool
    token = make_token()
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchval = AsyncMock(return_value=0)

    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            f"/supplier-accounts/{SUPPLIER_ACCOUNT_ID}/movements",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert resp.status_code == 200
    body = resp.json()
    assert body["items"] == []
    assert body["total"] == 0
    assert body["page"] == 0
    assert body["pages"] == 0


@pytest.mark.asyncio
async def test_journal_entries_returns_page_envelope(async_client, mock_pool):
    """2.9: GET /journal-entries -> {items,total,page,pages} en vez de lista plana."""
    from backend.tests.conftest import TEST_ACCOUNT_ID

    pool, conn = mock_pool
    token = make_token()
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchval = AsyncMock(return_value=0)

    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/journal-entries",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert resp.status_code == 200
    body = resp.json()
    assert body["items"] == []
    assert body["total"] == 0
    assert body["page"] == 0
    assert body["pages"] == 0


@pytest.mark.asyncio
async def test_supplier_account_movements_size_over_max_returns_422(async_client, mock_pool):
    """2.10: size sobre la cota máxima (200) -> 422 problem+json, sin ejecutar query."""
    pool, conn = mock_pool
    token = make_token()

    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            f"/supplier-accounts/{SUPPLIER_ACCOUNT_ID}/movements?size=9999",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert resp.status_code == 422
    assert resp.headers["content-type"].startswith("application/problem+json")
    conn.fetch.assert_not_awaited()


@pytest.mark.asyncio
async def test_journal_entries_size_over_max_returns_422(async_client, mock_pool):
    """2.10: size sobre la cota máxima (500) -> 422 problem+json."""
    pool, conn = mock_pool
    token = make_token()

    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/journal-entries?size=99999",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert resp.status_code == 422
    assert resp.headers["content-type"].startswith("application/problem+json")
    conn.fetch.assert_not_awaited()


@pytest.mark.asyncio
async def test_journal_entries_page_out_of_range_returns_empty_items(async_client, mock_pool):
    """2.10: página fuera de rango -> 200 con items vacío, no error."""
    pool, conn = mock_pool
    token = make_token()
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchval = AsyncMock(return_value=3)

    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/journal-entries?page=50&size=100",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert resp.status_code == 200
    body = resp.json()
    assert body["items"] == []
    assert body["total"] == 3
    assert body["page"] == 50


@pytest.mark.asyncio
async def test_journal_entries_with_results_computes_pages(async_client, mock_pool):
    """TRIANGULATE: con resultados, pages = ceil(total/size) y las líneas se
    siguen agrupando por entry_id (batch fetch de journal_lines)."""
    pool, conn = mock_pool
    token = make_token()

    entry_row = {
        "id": "11111111-1111-1111-1111-111111111112",
        "account_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        "posted_at": "2026-07-01T00:00:00+00:00",
        "status": "posted",
        "source_doc_type": "SalesOrder",
        "source_doc_ref": None,
        "reversal_of": None,
        "created_at": "2026-07-01T00:00:00+00:00",
    }

    async def fetch_side_effect(query, *args):
        if "journal_lines" in query:
            return []
        return [entry_row]

    conn.fetch = AsyncMock(side_effect=fetch_side_effect)
    conn.fetchval = AsyncMock(return_value=45)

    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/journal-entries?page=0&size=20",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] == 45
    assert body["pages"] == 3  # ceil(45/20)
    assert len(body["items"]) == 1
    assert body["items"][0]["lines"] == []
