"""
estadisticas-ventas E2 — tests TDD de los desgloses por dimensión y del top de
clientes (tasks 6.1 / 6.3): rpc_sales_breakdown / rpc_sales_top_clients
(migración 20261025000001) detrás de GET /reports/statistics/breakdown y
/reports/statistics/clients. Espejo de test_statistics.py (E1).

Invariantes bajo test:
- La dimensión viaja LIGADA a la RPC y el router la acota con Literal
  (canal / branch / weekday / hour / category): 422 fuera del dominio, sin
  ejecutar consulta. Ídem el límite del top (1..200).
- El tramo "Sin canal" / "Sin sucursal" / "Sin categoría" viaja con key null
  y su rótulo; el service no lo filtra ni lo renombra.
- Top clientes: las filas row_kind='client' son los items; la fila
  row_kind='unassigned' se compone aparte (OQ-2) y NUNCA se cuela como
  cliente; si la RPC no la devuelve es un 500, no un "sin ventas".
- La ventana aplicada (D8) viaja en la respuesta.
"""
from __future__ import annotations

import datetime as dt
from decimal import Decimal
from unittest.mock import AsyncMock, patch

import asyncpg
import pytest
from fastapi import HTTPException

from backend.tests.conftest import make_token
from backend.tests.test_statistics import ACCOUNT_ID, END, START, WINDOW

CLIENT_A = "11111111-1111-1111-1111-111111111111"
CLIENT_B = "22222222-2222-2222-2222-222222222222"
BRANCH_1 = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"


def _bd_row(key: str | None, label: str, order: int, revenue: str, units: str = "1", ops: int = 1) -> dict:
    return {
        "bucket_key": key,
        "bucket_label": label,
        "sort_order": order,
        "revenue": Decimal(revenue),
        "units": Decimal(units),
        "operations": ops,
        **WINDOW,
    }


BREAKDOWN_ROWS = [
    _bd_row("local", "local", 1, "2900", "4", 2),
    _bd_row("instagram", "instagram", 2, "2100", "3", 1),
    _bd_row(None, "Sin canal", 3, "600", "2", 2),
]


def _tc_row(kind: str, rank: int | None, client_id: str | None, name: str | None, revenue: str,
            units: str, ops: int, total_clients: int = 2) -> dict:
    return {
        "row_kind": kind,
        "rank": rank,
        "client_id": client_id,
        "client_name": name,
        "revenue": Decimal(revenue),
        "units": Decimal(units),
        "operations": ops,
        "last_sale_date": dt.date(2026, 8, 31),
        "total_clients": total_clients,
        **WINDOW,
    }


TOP_ROWS = [
    _tc_row("client", 1, CLIENT_A, "Ana", "2900", "4", 2),
    _tc_row("client", 2, CLIENT_B, "Beto", "2100", "3", 1),
    _tc_row("unassigned", None, None, None, "500", "1", 1),
]


@pytest.fixture
def statistics_repo():
    from backend.repositories.statistics_repository import StatisticsRepository

    conn = AsyncMock()
    return StatisticsRepository(conn), conn


# ── 6.1 RED: repository ──────────────────────────────────────────────────────

class TestStatisticsRepositoryBreakdown:
    @pytest.mark.asyncio
    async def test_calls_rpc_with_bound_params_only(self, statistics_repo):
        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=BREAKDOWN_ROWS)

        rows = await repo.fetch_sales_breakdown(
            ACCOUNT_ID, start=START, end=END, dimension="canal", branch_id=None, canal=None
        )

        assert rows == BREAKDOWN_ROWS
        sql = conn.fetch.call_args[0][0].lower()
        args = conn.fetch.call_args[0][1:]
        assert "rpc_sales_breakdown($1::uuid, $2::date, $3::date, $4::text, $5::uuid, $6::text)" in sql
        assert args == (ACCOUNT_ID, START, END, "canal", None, None)
        # La dimensión viaja LIGADA: jamás interpolada en el SQL.
        assert "canal" not in sql

    @pytest.mark.asyncio
    async def test_branch_filter_travels_bound(self, statistics_repo):
        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=[])

        await repo.fetch_sales_breakdown(
            ACCOUNT_ID, start=START, end=END, dimension="hour", branch_id=BRANCH_1, canal="local"
        )

        args = conn.fetch.call_args[0][1:]
        assert args[3] == "hour" and args[4] == BRANCH_1 and args[5] == "local"
        assert BRANCH_1 not in conn.fetch.call_args[0][0]


class TestStatisticsRepositoryTopClients:
    @pytest.mark.asyncio
    async def test_calls_rpc_with_bound_params_only(self, statistics_repo):
        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=TOP_ROWS)

        rows = await repo.fetch_top_clients(
            ACCOUNT_ID, start=START, end=END, branch_id=None, limit=10
        )

        assert rows == TOP_ROWS
        sql = conn.fetch.call_args[0][0].lower()
        args = conn.fetch.call_args[0][1:]
        assert "rpc_sales_top_clients($1::uuid, $2::date, $3::date, $4::uuid, $5::integer)" in sql
        assert args == (ACCOUNT_ID, START, END, None, 10)

    @pytest.mark.asyncio
    async def test_branch_and_limit_travel_bound(self, statistics_repo):
        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=[])

        await repo.fetch_top_clients(ACCOUNT_ID, start=START, end=END, branch_id=BRANCH_1, limit=5)

        args = conn.fetch.call_args[0][1:]
        assert args[3] == BRANCH_1 and args[4] == 5
        assert BRANCH_1 not in conn.fetch.call_args[0][0]


# ── 6.1 RED: service ─────────────────────────────────────────────────────────

class TestStatisticsServiceBreakdown:
    @pytest.mark.asyncio
    async def test_dimension_outside_dictionary_is_422_without_query(self, statistics_repo):
        from backend.services import statistics as service

        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=BREAKDOWN_ROWS)

        with pytest.raises(HTTPException) as exc:
            await service.get_sales_breakdown(
                repo, ACCOUNT_ID, start=START, end=END, dimension="product", branch_id=None, canal=None
            )
        assert exc.value.status_code == 422
        conn.fetch.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_end_before_start_is_422_without_query(self, statistics_repo):
        from backend.services import statistics as service

        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=BREAKDOWN_ROWS)

        with pytest.raises(HTTPException) as exc:
            await service.get_sales_breakdown(
                repo, ACCOUNT_ID, start=END, end=START, dimension="canal", branch_id=None, canal=None
            )
        assert exc.value.status_code == 422
        conn.fetch.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_composes_rows_keeping_null_key_bucket_and_window(self, statistics_repo):
        from backend.services import statistics as service

        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=BREAKDOWN_ROWS)

        result = await service.get_sales_breakdown(
            repo, ACCOUNT_ID, start=START, end=END, dimension="canal", branch_id=None, canal=None
        )

        assert result["dimension"] == "canal"
        assert result["window"] == {
            "start": dt.date(2026, 8, 2), "end": dt.date(2026, 8, 31),
            "history_days": 30, "clamped": True,
        }
        assert [r["key"] for r in result["rows"]] == ["local", "instagram", None]
        assert result["rows"][2]["label"] == "Sin canal"
        assert result["rows"][2]["revenue"] == Decimal("600")
        assert result["rows"][0]["sort_order"] == 1 and result["rows"][0]["operations"] == 2
        assert sum(r["revenue"] for r in result["rows"]) == Decimal("5600")

    @pytest.mark.asyncio
    async def test_empty_breakdown_has_no_window_and_no_rows(self, statistics_repo):
        from backend.services import statistics as service

        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=[])

        result = await service.get_sales_breakdown(
            repo, ACCOUNT_ID, start=START, end=END, dimension="category", branch_id=None, canal=None
        )

        assert result == {"dimension": "category", "window": None, "rows": []}

    @pytest.mark.asyncio
    async def test_every_dimension_of_the_dictionary_reaches_the_rpc_bound(self, statistics_repo):
        from backend.services import statistics as service

        repo, conn = statistics_repo
        for dim in ("canal", "branch", "weekday", "hour", "category"):
            conn.fetch = AsyncMock(return_value=[])
            await service.get_sales_breakdown(
                repo, ACCOUNT_ID, start=START, end=END, dimension=dim, branch_id=None, canal=None
            )
            assert conn.fetch.call_args[0][4] == dim

    @pytest.mark.asyncio
    async def test_p0401_maps_to_403_and_p0400_to_422(self, statistics_repo):
        from backend.services import statistics as service

        repo, conn = statistics_repo
        for code, status in (("P0401", 403), ("P0400", 422)):
            err = asyncpg.exceptions.RaiseError("boom")
            err.sqlstate = code
            conn.fetch = AsyncMock(side_effect=err)
            with pytest.raises(HTTPException) as exc:
                await service.get_sales_breakdown(
                    repo, ACCOUNT_ID, start=START, end=END, dimension="weekday", branch_id=None, canal=None
                )
            assert exc.value.status_code == status, code


class TestStatisticsServiceTopClients:
    @pytest.mark.asyncio
    async def test_composes_items_unassigned_total_and_window(self, statistics_repo):
        from backend.services import statistics as service

        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=TOP_ROWS)

        result = await service.get_top_clients(
            repo, ACCOUNT_ID, start=START, end=END, branch_id=None, limit=10
        )

        assert set(result.keys()) == {"window", "items", "unassigned", "total_clients"}
        assert result["window"]["clamped"] is True
        assert [i["client_id"] for i in result["items"]] == [CLIENT_A, CLIENT_B]
        assert result["items"][0]["rank"] == 1 and result["items"][0]["client_name"] == "Ana"
        assert result["items"][0]["revenue"] == Decimal("2900")
        # OQ-2: la fila sin cliente NO es un item — viaja aparte.
        assert all(i["client_name"] is not None for i in result["items"])
        assert result["unassigned"] == {
            "revenue": Decimal("500"), "units": Decimal("1"), "operations": 1,
            "last_sale_date": dt.date(2026, 8, 31),
        }
        assert result["total_clients"] == 2

    @pytest.mark.asyncio
    async def test_only_unassigned_row_means_zero_clients_not_an_error(self, statistics_repo):
        from backend.services import statistics as service

        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=[_tc_row("unassigned", None, None, None, "0", "0", 0, total_clients=0)])

        result = await service.get_top_clients(
            repo, ACCOUNT_ID, start=START, end=END, branch_id=None, limit=10
        )

        assert result["items"] == []
        assert result["total_clients"] == 0
        assert result["unassigned"]["revenue"] == Decimal("0")
        assert result["window"]["start"] == dt.date(2026, 8, 2)

    @pytest.mark.asyncio
    async def test_missing_unassigned_row_is_500(self, statistics_repo):
        from backend.services import statistics as service

        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=TOP_ROWS[:2])

        with pytest.raises(HTTPException) as exc:
            await service.get_top_clients(
                repo, ACCOUNT_ID, start=START, end=END, branch_id=None, limit=10
            )
        assert exc.value.status_code == 500

    @pytest.mark.asyncio
    async def test_end_before_start_is_422_without_query(self, statistics_repo):
        from backend.services import statistics as service

        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=TOP_ROWS)

        with pytest.raises(HTTPException) as exc:
            await service.get_top_clients(
                repo, ACCOUNT_ID, start=END, end=START, branch_id=None, limit=10
            )
        assert exc.value.status_code == 422
        conn.fetch.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_limit_and_branch_pass_through_bound(self, statistics_repo):
        from backend.services import statistics as service

        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=TOP_ROWS)

        await service.get_top_clients(
            repo, ACCOUNT_ID, start=START, end=END, branch_id=BRANCH_1, limit=3
        )

        assert conn.fetch.call_args[0][4] == BRANCH_1
        assert conn.fetch.call_args[0][5] == 3


# ── 6.3 RED: router — GET /reports/statistics/breakdown ──────────────────────

class TestBreakdownEndpoint:
    @pytest.mark.asyncio
    async def test_ok_shape_with_null_key_bucket(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=BREAKDOWN_ROWS)
        token = make_token({"app_metadata": {"account_role": "member"}})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/statistics/breakdown?start=2026-08-01&end=2026-08-31&dimension=canal",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        data = resp.json()
        assert set(data.keys()) == {"dimension", "window", "rows"}
        assert data["dimension"] == "canal"
        assert data["window"] == {"start": "2026-08-02", "end": "2026-08-31", "history_days": 30, "clamped": True}
        assert len(data["rows"]) == 3
        assert data["rows"][2]["key"] is None
        assert data["rows"][2]["label"] == "Sin canal"
        assert Decimal(data["rows"][2]["revenue"]) == Decimal("600")
        assert data["rows"][0]["sort_order"] == 1 and data["rows"][0]["operations"] == 2
        assert Decimal(data["rows"][0]["units"]) == Decimal("4")

    @pytest.mark.asyncio
    async def test_dimension_outside_literal_is_422_without_query(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=BREAKDOWN_ROWS)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/statistics/breakdown?start=2026-08-01&end=2026-08-31&dimension=product",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 422
        conn.fetch.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_dimension_is_required(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=BREAKDOWN_ROWS)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/statistics/breakdown?start=2026-08-01&end=2026-08-31",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 422
        conn.fetch.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_branch_id_is_bound_as_uuid_string(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=BREAKDOWN_ROWS)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/reports/statistics/breakdown?start=2026-08-01&end=2026-08-31&dimension=branch&branch_id={BRANCH_1}",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        assert conn.fetch.call_args[0][4] == "branch"
        assert conn.fetch.call_args[0][5] == BRANCH_1

    @pytest.mark.asyncio
    async def test_hour_dimension_is_accepted(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[_bd_row("14", "14:00", 14, "2600", "4", 2)])
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/statistics/breakdown?start=2026-08-01&end=2026-08-31&dimension=hour",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        assert resp.json()["rows"][0] == {
            "key": "14", "label": "14:00", "sort_order": 14,
            "revenue": "2600", "units": "4", "operations": 2,
        }

    @pytest.mark.asyncio
    async def test_p0401_from_rpc_maps_to_403(self, async_client, mock_pool):
        pool, conn = mock_pool
        err = asyncpg.exceptions.RaiseError("unauthorized")
        err.sqlstate = "P0401"
        conn.fetch = AsyncMock(side_effect=err)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/statistics/breakdown?start=2026-08-01&end=2026-08-31&dimension=weekday",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 403


# ── 6.3 RED: router — GET /reports/statistics/clients ────────────────────────

class TestTopClientsEndpoint:
    @pytest.mark.asyncio
    async def test_ok_shape_with_unassigned_apart(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=TOP_ROWS)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/statistics/clients?start=2026-08-01&end=2026-08-31",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        data = resp.json()
        assert set(data.keys()) == {"window", "items", "unassigned", "total_clients"}
        assert data["total_clients"] == 2
        assert [i["client_name"] for i in data["items"]] == ["Ana", "Beto"]
        assert data["items"][0]["rank"] == 1 and data["items"][0]["client_id"] == CLIENT_A
        assert data["items"][0]["last_sale_date"] == "2026-08-31"
        assert Decimal(data["unassigned"]["revenue"]) == Decimal("500")
        assert data["unassigned"]["operations"] == 1
        assert data["window"]["clamped"] is True
        # OQ-2: ninguna fila del ranking representa "sin cliente".
        assert all(i["client_name"] is not None for i in data["items"])

    @pytest.mark.asyncio
    async def test_default_limit_is_10_and_bound(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=TOP_ROWS)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/statistics/clients?start=2026-08-01&end=2026-08-31",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        assert conn.fetch.call_args[0][5] == 10

    @pytest.mark.asyncio
    async def test_limit_outside_bounds_is_422_without_query(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=TOP_ROWS)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            for bad in ("0", "999"):
                resp = await async_client.get(
                    f"/reports/statistics/clients?start=2026-08-01&end=2026-08-31&limit={bad}",
                    headers={"Authorization": f"Bearer {token}"},
                )
                assert resp.status_code == 422, bad
        conn.fetch.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_foreign_client_row_travels_with_null_id_and_placeholder_name(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[
            _tc_row("client", 1, None, "Cliente no disponible", "100", "1", 1, total_clients=1),
            _tc_row("unassigned", None, None, None, "0", "0", 0, total_clients=1),
        ])
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/statistics/clients?start=2026-08-01&end=2026-08-31",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        row = resp.json()["items"][0]
        assert row["client_id"] is None and row["client_name"] == "Cliente no disponible"

    @pytest.mark.asyncio
    async def test_p0401_from_rpc_maps_to_403(self, async_client, mock_pool):
        pool, conn = mock_pool
        err = asyncpg.exceptions.RaiseError("unauthorized")
        err.sqlstate = "P0401"
        conn.fetch = AsyncMock(side_effect=err)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/statistics/clients?start=2026-08-01&end=2026-08-31",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 403


class TestOpenApiRegistrationE2:
    @pytest.mark.asyncio
    async def test_routes_are_published(self, async_client):
        resp = await async_client.get("/openapi.json")
        assert resp.status_code == 200
        paths = resp.json()["paths"]
        assert "/reports/statistics/breakdown" in paths
        assert "/reports/statistics/clients" in paths
