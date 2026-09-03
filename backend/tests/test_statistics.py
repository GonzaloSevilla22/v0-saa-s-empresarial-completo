"""
estadisticas-ventas E1 — tests TDD del read-model de estadísticas de ventas
(tasks 3.1 / 3.7).

Cubre StatisticsRepository (asyncpg mockeado, espejo de
test_receivables_report.py), el service (validación de rango → 422 sin
consulta, composición de la evolución por `period`, diccionario de orden,
mapeo de ERRCODEs) y los endpoints GET /reports/statistics/evolution y
/reports/statistics/products (async_client + mock_pool).

Invariantes bajo test:
- El orden del ranking y el bucket de la evolución viajan como parámetros
  ligados a la RPC (nunca interpolados) y el router los acota con Literal
  (422 fuera del dominio, sin ejecutar consulta).
- La ventana efectivamente aplicada (clamp de plan, D8) viaja en la respuesta.
- La paginación del ranking se resuelve en la RPC sobre el conjunto completo;
  el envelope estándar {items,total,page,pages} se arma desde total_count.
- Una página fuera de rango sigue informando el total (sonda de 1 fila).
"""
from __future__ import annotations

import datetime as dt
from decimal import Decimal
from unittest.mock import AsyncMock, patch

import asyncpg
import pytest
from fastapi import HTTPException

from backend.tests.conftest import make_token

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
PRODUCT_A = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
PRODUCT_B = "cccccccc-cccc-cccc-cccc-cccccccccccc"
PARENT_B = "dddddddd-dddd-dddd-dddd-dddddddddddd"

START = dt.date(2026, 8, 1)
END = dt.date(2026, 8, 31)

WINDOW = {
    "window_start": dt.date(2026, 8, 2),
    "window_end": dt.date(2026, 8, 31),
    "history_days": 30,
    "window_clamped": True,
}


def _evo_row(period: str, bucket_start: dt.date, bucket_end: dt.date, revenue: str, nc: str = "0",
             units: str = "1", ops: int = 1, service: str = "0") -> dict:
    return {
        "period": period,
        "bucket_start": bucket_start,
        "bucket_end": bucket_end,
        "revenue": Decimal(revenue),
        "credit_notes": Decimal(nc),
        "net_revenue": Decimal(revenue) - Decimal(nc),
        "units": Decimal(units),
        "operations": ops,
        "service_revenue": Decimal(service),
        **WINDOW,
    }


EVO_ROWS = [
    _evo_row("bucket", dt.date(2026, 8, 2), dt.date(2026, 8, 2), "2900", nc="150", units="4", ops=2, service="400"),
    _evo_row("bucket", dt.date(2026, 8, 3), dt.date(2026, 8, 3), "0", units="0", ops=0),
    _evo_row("current", dt.date(2026, 8, 2), dt.date(2026, 8, 31), "2900", nc="150", units="4", ops=2, service="400"),
    _evo_row("previous", dt.date(2026, 7, 3), dt.date(2026, 8, 1), "333", units="1", ops=1),
]


def _rank_row(rank: int, product_id: str, name: str, units: str, revenue: str, total_count: int = 2,
              margin: str | None = "850", coverage: str = "33.3", parent_id: str | None = None,
              variant_count: int = 0) -> dict:
    return {
        "rank": rank,
        "product_id": product_id,
        "product_name": name,
        "sku": None,
        "category": "Otros",
        "parent_id": parent_id,
        "parent_name": "Padre" if parent_id else None,
        "is_group": variant_count > 0,
        "variant_count": variant_count,
        "units": Decimal(units),
        "revenue": Decimal(revenue),
        "operations": 3,
        "total_cost": Decimal("1500") if margin is not None else None,
        "gross_margin": Decimal(margin) if margin is not None else None,
        "gross_margin_pct": Decimal("36.17") if margin is not None else None,
        "cost_coverage_pct": Decimal(coverage),
        "last_sale_date": dt.date(2026, 8, 31),
        "total_count": total_count,
        **WINDOW,
    }


RANK_ROWS = [
    _rank_row(1, PRODUCT_A, "Simple", "5", "2350"),
    _rank_row(2, PARENT_B, "Padre", "4", "2600", margin="2250", coverage="0", variant_count=2),
]


@pytest.fixture
def statistics_repo():
    from backend.repositories.statistics_repository import StatisticsRepository

    conn = AsyncMock()
    return StatisticsRepository(conn), conn


# ── 3.1 RED: repository ──────────────────────────────────────────────────────

class TestStatisticsRepositoryEvolution:
    @pytest.mark.asyncio
    async def test_calls_rpc_with_bound_params_only(self, statistics_repo):
        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=EVO_ROWS)

        rows = await repo.fetch_sales_evolution(
            ACCOUNT_ID, start=START, end=END, bucket="week", branch_id=None, canal=None
        )

        assert rows == EVO_ROWS
        sql = conn.fetch.call_args[0][0].lower()
        args = conn.fetch.call_args[0][1:]
        assert "rpc_sales_evolution($1::uuid, $2::date, $3::date, $4::text, $5::uuid, $6::text)" in sql
        assert args == (ACCOUNT_ID, START, END, "week", None, None)
        # El bucket viaja LIGADO: jamás aparece interpolado en el SQL.
        assert "week" not in sql

    @pytest.mark.asyncio
    async def test_branch_and_canal_travel_as_bound_params(self, statistics_repo):
        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=[])
        branch = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"

        await repo.fetch_sales_evolution(
            ACCOUNT_ID, start=START, end=END, bucket="day", branch_id=branch, canal="online"
        )

        args = conn.fetch.call_args[0][1:]
        assert args[4] == branch
        assert args[5] == "online"
        assert "online" not in conn.fetch.call_args[0][0]


class TestStatisticsRepositoryRanking:
    @pytest.mark.asyncio
    async def test_envelope_from_total_count_and_window(self, statistics_repo):
        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=[_rank_row(1, PRODUCT_A, "Simple", "5", "2350", total_count=5),
                                             _rank_row(2, PRODUCT_B, "Otro", "4", "2000", total_count=5)])

        page = await repo.fetch_product_ranking_page(
            ACCOUNT_ID, start=START, end=END, order_by="units", group_variants=True,
            page=0, size=2, branch_id=None, canal=None,
        )

        assert set(page.keys()) == {"items", "total", "page", "pages", "window"}
        assert page["total"] == 5
        assert page["page"] == 0
        assert page["pages"] == 3
        assert len(page["items"]) == 2
        assert page["window"] == {
            "start": dt.date(2026, 8, 2), "end": dt.date(2026, 8, 31),
            "history_days": 30, "clamped": True,
        }
        sql = conn.fetch.call_args[0][0].lower()
        args = conn.fetch.call_args[0][1:]
        assert "rpc_product_ranking($1::uuid, $2::date, $3::date, $4::text, $5::boolean, $6::uuid, $7::text, $8::integer, $9::integer)" in sql
        # limit = size, offset = page * size — resueltos en la RPC, no acá.
        assert args[7] == 2 and args[8] == 0
        assert "units" not in sql

    @pytest.mark.asyncio
    async def test_offset_is_page_times_size(self, statistics_repo):
        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=[_rank_row(7, PRODUCT_A, "Simple", "5", "2350", total_count=9)])

        page = await repo.fetch_product_ranking_page(
            ACCOUNT_ID, start=START, end=END, order_by="revenue", group_variants=False,
            page=3, size=2, branch_id=None, canal=None,
        )

        args = conn.fetch.call_args[0][1:]
        assert args[3] == "revenue" and args[4] is False
        assert args[7] == 2 and args[8] == 6
        assert page["total"] == 9 and page["pages"] == 5 and page["page"] == 3

    @pytest.mark.asyncio
    async def test_page_out_of_range_probes_total_with_one_row(self, statistics_repo):
        """Página vacía más allá del final: el total NO se pierde — se sondea
        la primera fila (limit 1, offset 0) para leer total_count y ventana."""
        repo, conn = statistics_repo
        probe_row = _rank_row(1, PRODUCT_A, "Simple", "5", "2350", total_count=5)
        conn.fetch = AsyncMock(side_effect=[[], [probe_row]])

        page = await repo.fetch_product_ranking_page(
            ACCOUNT_ID, start=START, end=END, order_by="units", group_variants=True,
            page=99, size=25, branch_id=None, canal=None,
        )

        assert page["items"] == []
        assert page["total"] == 5
        assert page["pages"] == 1
        assert page["page"] == 99
        assert page["window"]["clamped"] is True
        assert conn.fetch.await_count == 2
        probe_args = conn.fetch.call_args_list[1][0][1:]
        assert probe_args[7] == 1 and probe_args[8] == 0

    @pytest.mark.asyncio
    async def test_empty_first_page_means_zero_without_probe(self, statistics_repo):
        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=[])

        page = await repo.fetch_product_ranking_page(
            ACCOUNT_ID, start=START, end=END, order_by="units", group_variants=True,
            page=0, size=25, branch_id=None, canal=None,
        )

        assert page == {"items": [], "total": 0, "page": 0, "pages": 0, "window": None}
        assert conn.fetch.await_count == 1


# ── 3.1 RED: service ─────────────────────────────────────────────────────────

class TestStatisticsService:
    @pytest.mark.asyncio
    async def test_evolution_end_before_start_is_422_without_query(self, statistics_repo):
        from backend.services import statistics as service

        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=EVO_ROWS)

        with pytest.raises(HTTPException) as exc:
            await service.get_sales_evolution(
                repo, ACCOUNT_ID, start=END, end=START, bucket="day", branch_id=None, canal=None
            )

        assert exc.value.status_code == 422
        conn.fetch.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_single_day_range_is_valid(self, statistics_repo):
        from backend.services import statistics as service

        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=EVO_ROWS)

        result = await service.get_sales_evolution(
            repo, ACCOUNT_ID, start=START, end=START, bucket="day", branch_id=None, canal=None
        )

        assert result["bucket"] == "day"
        conn.fetch.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_evolution_composes_points_current_previous_and_window(self, statistics_repo):
        from backend.services import statistics as service

        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=EVO_ROWS)

        result = await service.get_sales_evolution(
            repo, ACCOUNT_ID, start=START, end=END, bucket="day", branch_id=None, canal=None
        )

        assert result["window"] == {
            "start": dt.date(2026, 8, 2), "end": dt.date(2026, 8, 31),
            "history_days": 30, "clamped": True,
        }
        assert [p["bucket_start"] for p in result["points"]] == [dt.date(2026, 8, 2), dt.date(2026, 8, 3)]
        assert result["points"][0]["net_revenue"] == Decimal("2750")
        assert result["current"]["revenue"] == Decimal("2900")
        assert result["current"]["service_revenue"] == Decimal("400")
        assert result["current"]["start"] == dt.date(2026, 8, 2)
        assert result["previous"]["revenue"] == Decimal("333")
        assert result["previous"]["start"] == dt.date(2026, 7, 3)
        assert result["previous"]["end"] == dt.date(2026, 8, 1)
        # Las filas de totales NO se cuelan como puntos.
        assert all(p["bucket_end"] <= dt.date(2026, 8, 3) for p in result["points"])

    @pytest.mark.asyncio
    async def test_evolution_without_current_row_is_500(self, statistics_repo):
        from backend.services import statistics as service

        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=[EVO_ROWS[0]])

        with pytest.raises(HTTPException) as exc:
            await service.get_sales_evolution(
                repo, ACCOUNT_ID, start=START, end=END, bucket="day", branch_id=None, canal=None
            )
        assert exc.value.status_code == 500

    @pytest.mark.asyncio
    async def test_ranking_order_outside_dictionary_is_422_without_query(self, statistics_repo):
        from backend.services import statistics as service

        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=RANK_ROWS)

        with pytest.raises(HTTPException) as exc:
            await service.get_product_ranking(
                repo, ACCOUNT_ID, start=START, end=END, order_by="evil", group_variants=True,
                page=0, size=25, branch_id=None, canal=None,
            )
        assert exc.value.status_code == 422
        conn.fetch.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_ranking_end_before_start_is_422(self, statistics_repo):
        from backend.services import statistics as service

        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=RANK_ROWS)

        with pytest.raises(HTTPException) as exc:
            await service.get_product_ranking(
                repo, ACCOUNT_ID, start=END, end=START, order_by="units", group_variants=True,
                page=0, size=25, branch_id=None, canal=None,
            )
        assert exc.value.status_code == 422
        conn.fetch.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_ranking_passes_through_envelope(self, statistics_repo):
        from backend.services import statistics as service

        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=RANK_ROWS)

        result = await service.get_product_ranking(
            repo, ACCOUNT_ID, start=START, end=END, order_by="margin", group_variants=True,
            page=0, size=25, branch_id=None, canal=None,
        )

        assert result["total"] == 2
        assert result["items"][1]["variant_count"] == 2
        assert conn.fetch.call_args[0][4] == "margin"

    @pytest.mark.asyncio
    async def test_p0401_maps_to_403_and_p0400_to_422(self, statistics_repo):
        from backend.services import statistics as service

        repo, conn = statistics_repo
        for code, status in (("P0401", 403), ("P0400", 422)):
            err = asyncpg.exceptions.RaiseError("boom")
            err.sqlstate = code
            conn.fetch = AsyncMock(side_effect=err)
            with pytest.raises(HTTPException) as exc:
                await service.get_sales_evolution(
                    repo, ACCOUNT_ID, start=START, end=END, bucket="day", branch_id=None, canal=None
                )
            assert exc.value.status_code == status, code


# ── 3.7 RED: router — GET /reports/statistics/evolution ──────────────────────

class TestEvolutionEndpoint:
    @pytest.mark.asyncio
    async def test_ok_shape_with_window(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=EVO_ROWS)
        token = make_token({"app_metadata": {"account_role": "member"}})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/statistics/evolution?start=2026-08-01&end=2026-08-31&bucket=day",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        data = resp.json()
        assert set(data.keys()) == {"bucket", "window", "points", "current", "previous"}
        assert data["window"] == {"start": "2026-08-02", "end": "2026-08-31", "history_days": 30, "clamped": True}
        assert len(data["points"]) == 2
        assert data["points"][0]["bucket_start"] == "2026-08-02"
        assert Decimal(data["points"][0]["net_revenue"]) == Decimal("2750")
        assert Decimal(data["current"]["service_revenue"]) == Decimal("400")
        assert Decimal(data["previous"]["revenue"]) == Decimal("333")
        assert data["current"]["operations"] == 2

    @pytest.mark.asyncio
    async def test_bucket_outside_literal_is_422_without_query(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=EVO_ROWS)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/statistics/evolution?start=2026-08-01&end=2026-08-31&bucket=hour",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 422
        conn.fetch.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_end_before_start_is_422_without_query(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=EVO_ROWS)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/statistics/evolution?start=2026-08-31&end=2026-08-01",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 422
        conn.fetch.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_missing_dates_is_422(self, async_client, mock_pool):
        pool, conn = mock_pool
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/statistics/evolution",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 422

    @pytest.mark.asyncio
    async def test_account_without_sales_returns_zero_points(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[
            _evo_row("bucket", dt.date(2026, 8, 1), dt.date(2026, 8, 1), "0", units="0", ops=0),
            _evo_row("current", dt.date(2026, 8, 1), dt.date(2026, 8, 1), "0", units="0", ops=0),
            _evo_row("previous", dt.date(2026, 7, 31), dt.date(2026, 7, 31), "0", units="0", ops=0),
        ])
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/statistics/evolution?start=2026-08-01&end=2026-08-01",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        data = resp.json()
        assert Decimal(data["current"]["revenue"]) == 0
        assert data["current"]["operations"] == 0
        assert len(data["points"]) == 1

    @pytest.mark.asyncio
    async def test_p0401_from_rpc_maps_to_403(self, async_client, mock_pool):
        pool, conn = mock_pool
        err = asyncpg.exceptions.RaiseError("unauthorized")
        err.sqlstate = "P0401"
        conn.fetch = AsyncMock(side_effect=err)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/statistics/evolution?start=2026-08-01&end=2026-08-31",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 403


# ── 3.7 RED: router — GET /reports/statistics/products ───────────────────────

class TestProductRankingEndpoint:
    @pytest.mark.asyncio
    async def test_ok_envelope_with_window(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=RANK_ROWS)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/statistics/products?start=2026-08-01&end=2026-08-31&order_by=units",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        data = resp.json()
        assert set(data.keys()) == {"items", "total", "page", "pages", "window"}
        assert data["total"] == 2 and data["pages"] == 1 and data["page"] == 0
        assert data["window"]["clamped"] is True
        row = data["items"][1]
        assert row["product_name"] == "Padre"
        assert row["is_group"] is True and row["variant_count"] == 2
        assert Decimal(row["cost_coverage_pct"]) == Decimal("0")
        assert data["items"][0]["last_sale_date"] == "2026-08-31"

    @pytest.mark.asyncio
    async def test_null_margin_travels_as_null_never_zero(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[_rank_row(1, PRODUCT_A, "Sin costo", "5", "2350", total_count=1, margin=None)])
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/statistics/products?start=2026-08-01&end=2026-08-31",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        row = resp.json()["items"][0]
        assert row["gross_margin"] is None
        assert row["gross_margin_pct"] is None
        assert row["total_cost"] is None

    @pytest.mark.asyncio
    async def test_order_by_outside_literal_is_422_without_query(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=RANK_ROWS)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/statistics/products?start=2026-08-01&end=2026-08-31&order_by=evil",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 422
        conn.fetch.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_size_over_max_is_422(self, async_client, mock_pool):
        pool, conn = mock_pool
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/statistics/products?start=2026-08-01&end=2026-08-31&size=999",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 422

    @pytest.mark.asyncio
    async def test_page_out_of_range_keeps_total(self, async_client, mock_pool):
        pool, conn = mock_pool
        probe = _rank_row(1, PRODUCT_A, "Simple", "5", "2350", total_count=2)
        conn.fetch = AsyncMock(side_effect=[[], [probe]])
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/statistics/products?start=2026-08-01&end=2026-08-31&page=9&size=25",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        data = resp.json()
        assert data["items"] == [] and data["total"] == 2 and data["page"] == 9

    @pytest.mark.asyncio
    async def test_group_variants_false_is_bound(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=RANK_ROWS)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/statistics/products?start=2026-08-01&end=2026-08-31&group_variants=false",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        assert conn.fetch.call_args[0][5] is False

    @pytest.mark.asyncio
    async def test_p0401_from_rpc_maps_to_403(self, async_client, mock_pool):
        pool, conn = mock_pool
        err = asyncpg.exceptions.RaiseError("unauthorized")
        err.sqlstate = "P0401"
        conn.fetch = AsyncMock(side_effect=err)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/statistics/products?start=2026-08-01&end=2026-08-31",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 403


# ── 3.6: el router está registrado y aparece en el OpenAPI ───────────────────

class TestOpenApiRegistration:
    @pytest.mark.asyncio
    async def test_routes_are_published(self, async_client):
        resp = await async_client.get("/openapi.json")
        assert resp.status_code == 200
        paths = resp.json()["paths"]
        assert "/reports/statistics/evolution" in paths
        assert "/reports/statistics/products" in paths
