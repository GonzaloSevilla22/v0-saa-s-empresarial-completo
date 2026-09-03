"""
cobranzas-panel — tests TDD del read-model de cuentas por cobrar (tasks 3.1-3.8).

Cubre CustomerAccountRepository.list_receivables_page / get_receivables_summary
(asyncpg mockeado, espejo de test_payment_method_repository.py), el service sin
gate de plan (D10) y los endpoints GET /reports/receivables + /summary
(async_client, espejo de test_payment_method_router.py).

Invariante D2: el predicado de "quién es deudor" vive UNA sola vez, en
rpc_receivables_report — ni el listado ni el resumen lo re-declaran.
"""
from __future__ import annotations

from decimal import Decimal
from unittest.mock import AsyncMock, patch

import asyncpg
import pytest

from backend.tests.conftest import make_token

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
CLIENT_A = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
CLIENT_B = "cccccccc-cccc-cccc-cccc-cccccccccccc"
CLIENT_C = "dddddddd-dddd-dddd-dddd-dddddddddddd"

ROW_A = {
    "client_id": CLIENT_A,
    "client_name": "Deudor Grande",
    "balance": Decimal("2500"),
    "days_since_last_charge": 12,
    "days_since_last_payment": 30,
    "last_payment_date": "2026-08-03",
}

ROW_B = {
    "client_id": CLIENT_B,
    "client_name": "Deudor Chico",
    "balance": Decimal("1000"),
    "days_since_last_charge": 3,
    "days_since_last_payment": None,
    "last_payment_date": None,
}

# OQ-4: deuda nacida sólo de un adjustment — antigüedades nulas.
ROW_C = {
    "client_id": CLIENT_C,
    "client_name": "Solo Ajuste",
    "balance": Decimal("400"),
    "days_since_last_charge": None,
    "days_since_last_payment": None,
    "last_payment_date": None,
}


@pytest.fixture
def receivables_repo():
    from backend.repositories.customer_account_repository import (
        CustomerAccountRepository,
    )

    conn = AsyncMock()
    return CustomerAccountRepository(conn), conn


# ── 3.1 RED: repository — listado paginado ───────────────────────────────────

class TestListReceivablesPage:
    @pytest.mark.asyncio
    async def test_returns_standard_envelope_over_rpc(self, receivables_repo):
        repo, conn = receivables_repo
        conn.fetchval = AsyncMock(return_value=3)
        conn.fetch = AsyncMock(return_value=[ROW_A, ROW_B, ROW_C])

        result = await repo.list_receivables_page(
            ACCOUNT_ID, page=0, size=25, sort="balance", sort_dir="desc"
        )

        assert set(result.keys()) == {"items", "total", "page", "pages"}
        assert result["total"] == 3
        assert result["page"] == 0
        assert result["pages"] == 1
        assert result["items"][0]["client_name"] == "Deudor Grande"

        select_sql = conn.fetch.call_args[0][0].lower()
        count_sql = conn.fetchval.call_args[0][0].lower()
        assert "rpc_receivables_report($1::uuid)" in select_sql
        assert "count(*)" in count_sql
        assert "rpc_receivables_report($1::uuid)" in count_sql

    @pytest.mark.asyncio
    async def test_default_sort_is_balance_desc(self, receivables_repo):
        repo, conn = receivables_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_receivables_page(
            ACCOUNT_ID, page=0, size=25, sort="balance", sort_dir="desc"
        )

        select_sql = conn.fetch.call_args[0][0].lower()
        assert "order by balance desc" in select_sql

    @pytest.mark.asyncio
    async def test_sort_translated_by_dict_never_interpolated(self, receivables_repo):
        """El criterio viaja por diccionario a columna — un valor fuera del
        dominio NO se interpola jamás en el SQL (cae al orden por defecto)."""
        repo, conn = receivables_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_receivables_page(
            ACCOUNT_ID,
            page=0,
            size=25,
            sort="days_since_last_charge",
            sort_dir="asc",
        )
        select_sql = conn.fetch.call_args[0][0].lower()
        assert "order by days_since_last_charge asc" in select_sql

        malicious = "balance; DROP TABLE clients--"
        await repo.list_receivables_page(
            ACCOUNT_ID, page=0, size=25, sort=malicious, sort_dir="desc"
        )
        select_sql = conn.fetch.call_args[0][0].lower()
        assert "drop table" not in select_sql
        assert "order by balance desc" in select_sql

    @pytest.mark.asyncio
    async def test_no_second_debtor_predicate_outside_rpc(self, receivables_repo):
        """D2: ni el listado ni su COUNT re-declaran `balance > 0` /
        `deleted_at` — el predicado de deudor vive sólo en el RPC."""
        repo, conn = receivables_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_receivables_page(
            ACCOUNT_ID, page=0, size=25, sort="balance", sort_dir="desc"
        )

        select_sql = conn.fetch.call_args[0][0].lower()
        count_sql = conn.fetchval.call_args[0][0].lower()
        for sql in (select_sql, count_sql):
            assert "balance > 0" not in sql
            assert "deleted_at" not in sql


# ── 3.1 RED: repository — resumen (D2: mismo RPC, sin segundo predicado) ─────

class TestGetReceivablesSummary:
    @pytest.mark.asyncio
    async def test_returns_summary_shape(self, receivables_repo):
        repo, conn = receivables_repo
        conn.fetchrow = AsyncMock(
            return_value={"total_receivable": Decimal("3900"), "debtor_count": 3}
        )

        result = await repo.get_receivables_summary(ACCOUNT_ID)

        assert result == {"total_receivable": Decimal("3900"), "debtor_count": 3}
        sql = conn.fetchrow.call_args[0][0].lower()
        assert "rpc_receivables_report($1::uuid)" in sql
        assert "sum(balance)" in sql
        assert "count(*)" in sql

    @pytest.mark.asyncio
    async def test_summary_without_debtors_is_zero(self, receivables_repo):
        repo, conn = receivables_repo
        conn.fetchrow = AsyncMock(
            return_value={"total_receivable": Decimal("0"), "debtor_count": 0}
        )

        result = await repo.get_receivables_summary(ACCOUNT_ID)

        assert result["total_receivable"] == Decimal("0")
        assert result["debtor_count"] == 0

    @pytest.mark.asyncio
    async def test_summary_reads_from_same_rpc_as_list(self, receivables_repo):
        """D2: el FROM del resumen es EXACTAMENTE el mismo RPC que alimenta el
        listado — una segunda definición de deudor es un defecto."""
        repo, conn = receivables_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])
        conn.fetchrow = AsyncMock(
            return_value={"total_receivable": Decimal("0"), "debtor_count": 0}
        )

        await repo.list_receivables_page(
            ACCOUNT_ID, page=0, size=25, sort="balance", sort_dir="desc"
        )
        await repo.get_receivables_summary(ACCOUNT_ID)

        shared_from = "from public.rpc_receivables_report($1::uuid)"
        assert shared_from in conn.fetch.call_args[0][0].lower()
        assert shared_from in conn.fetchrow.call_args[0][0].lower()
        summary_sql = conn.fetchrow.call_args[0][0].lower()
        assert "balance > 0" not in summary_sql
        assert "deleted_at" not in summary_sql


# ── 3.7 RED: router — GET /reports/receivables ───────────────────────────────

class TestReceivablesReportEndpoint:
    @pytest.mark.asyncio
    async def test_report_ok_for_member(self, async_client, mock_pool):
        """Sin gate de plan (D10): cualquier miembro lee el reporte."""
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=3)
        conn.fetch = AsyncMock(return_value=[ROW_A, ROW_B, ROW_C])
        token = make_token({"app_metadata": {"account_role": "member"}})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/receivables",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        data = resp.json()
        assert set(data.keys()) == {"items", "total", "page", "pages"}
        assert data["total"] == 3
        assert data["items"][0]["client_name"] == "Deudor Grande"
        # OQ-4: la antigüedad ausente viaja como null, jamás degradada a 0.
        assert data["items"][2]["days_since_last_charge"] is None
        assert data["items"][2]["days_since_last_payment"] is None

    @pytest.mark.asyncio
    async def test_page_out_of_range_returns_empty_items_with_total(
        self, async_client, mock_pool
    ):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=3)
        conn.fetch = AsyncMock(return_value=[])
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/receivables?page=99&size=25",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        data = resp.json()
        assert data["items"] == []
        assert data["total"] == 3
        assert data["page"] == 99

    @pytest.mark.asyncio
    async def test_size_over_max_is_422(self, async_client, mock_pool):
        pool, conn = mock_pool
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/receivables?size=999",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 422

    @pytest.mark.asyncio
    async def test_sort_outside_literal_is_422_without_query(
        self, async_client, mock_pool
    ):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[])
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/receivables?sort=evil_column",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 422
        conn.fetch.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_p0401_from_rpc_maps_to_403(self, async_client, mock_pool):
        pool, conn = mock_pool
        err = asyncpg.exceptions.RaiseError("unauthorized")
        err.sqlstate = "P0401"
        conn.fetchval = AsyncMock(side_effect=err)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/receivables",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 403


# ── 3.7/3.8 RED: router — GET /reports/receivables/summary ───────────────────

class TestReceivablesSummaryEndpoint:
    @pytest.mark.asyncio
    async def test_summary_ok(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(
            return_value={"total_receivable": Decimal("3900"), "debtor_count": 3}
        )
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/receivables/summary",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        data = resp.json()
        assert Decimal(str(data["total_receivable"])) == Decimal("3900")
        assert data["debtor_count"] == 3

    @pytest.mark.asyncio
    async def test_summary_closes_against_list_pages(self, async_client, mock_pool):
        """Escenario de la spec: el total del resumen coincide con la suma de
        los saldos de todas las páginas del listado (mismo RPC, D2)."""
        pool, conn = mock_pool
        all_rows = [ROW_A, ROW_B, ROW_C]
        token = make_token()

        # Página 0 (size=2) y página 1 (size=2) del listado.
        conn.fetchval = AsyncMock(return_value=3)
        conn.fetch = AsyncMock(side_effect=[all_rows[:2], all_rows[2:]])
        with patch("backend.core.database.pool", pool):
            resp_p0 = await async_client.get(
                "/reports/receivables?page=0&size=2",
                headers={"Authorization": f"Bearer {token}"},
            )
            resp_p1 = await async_client.get(
                "/reports/receivables?page=1&size=2",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp_p0.status_code == 200 and resp_p1.status_code == 200
        paged_sum = sum(
            Decimal(str(item["balance"]))
            for item in resp_p0.json()["items"] + resp_p1.json()["items"]
        )

        conn.fetchrow = AsyncMock(
            return_value={"total_receivable": Decimal("3900"), "debtor_count": 3}
        )
        with patch("backend.core.database.pool", pool):
            resp_summary = await async_client.get(
                "/reports/receivables/summary",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp_summary.status_code == 200
        assert Decimal(str(resp_summary.json()["total_receivable"])) == paged_sum

    @pytest.mark.asyncio
    async def test_summary_p0401_maps_to_403(self, async_client, mock_pool):
        pool, conn = mock_pool
        err = asyncpg.exceptions.RaiseError("unauthorized")
        err.sqlstate = "P0401"
        conn.fetchrow = AsyncMock(side_effect=err)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/receivables/summary",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 403
