"""
estadisticas-ventas E3 — tests TDD del detalle por producto (tasks 9.1 / 9.3 /
9.6): rpc_product_sales_evolution (migración 20261026000001) detrás de
GET /reports/statistics/products/{product_id}. Espejo de test_statistics_e2.py.

Invariantes bajo test:
- El bucket viaja LIGADO a la RPC y el router lo acota con Literal
  (day / week / month): 422 fuera del dominio, sin ejecutar consulta. El
  product_id se valida como uuid antes de tocar la base (422 si no lo es).
- Tres clases de fila (row_kind = total / bucket / member): el service
  compone {product, totals, points, members} SIN re-agregar buckets ni
  miembros; si la RPC no devolvió la fila total es un 500, no un "sin
  ventas".
- Producto ajeno o inexistente: la RPC lanza P0404 y el endpoint responde
  404 en RFC 7807 (application/problem+json), nunca un 200 vacío.
- Producto sin ventas en el período: 200 con totales en cero y margen null
  (nunca 0), buckets en cero y sin miembros.
- La cabecera (nombre, sku, categoría, padre, is_group, variant_count) y la
  ventana aplicada (D8) viajan en la respuesta.
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

PARENT = "dddddddd-dddd-dddd-dddd-dddddddddddd"
VARIANT_1 = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
VARIANT_2 = "cccccccc-cccc-cccc-cccc-cccccccccccc"
BRANCH_1 = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"

HEAD = {
    "product_id": PARENT,
    "product_name": "Remera",
    "product_sku": "REM-001",
    "product_category": "Ropa",
    "parent_id": None,
    "parent_name": None,
    "is_group": True,
    "variant_count": 2,
}


def _row(kind: str, *, rank: int | None = None, bucket_start: dt.date | None = None,
         bucket_end: dt.date | None = None, variant_id: str | None = None, variant_name: str | None = None,
         variant_sku: str | None = None, units: str = "0", revenue: str = "0", ops: int = 0,
         cost: str | None = None, margin: str | None = None, margin_pct: str | None = None,
         coverage: str | None = None, last_sale: dt.date | None = None, head: dict | None = None) -> dict:
    return {
        "row_kind": kind,
        "rank": rank,
        **(head or HEAD),
        "bucket_start": bucket_start,
        "bucket_end": bucket_end,
        "variant_id": variant_id,
        "variant_name": variant_name,
        "variant_sku": variant_sku,
        "units": Decimal(units),
        "revenue": Decimal(revenue),
        "operations": ops,
        "total_cost": Decimal(cost) if cost is not None else None,
        "gross_margin": Decimal(margin) if margin is not None else None,
        "gross_margin_pct": Decimal(margin_pct) if margin_pct is not None else None,
        "cost_coverage_pct": Decimal(coverage) if coverage is not None else None,
        "last_sale_date": last_sale,
        **WINDOW,
    }


DETAIL_ROWS = [
    _row("total", units="5", revenue="4300", ops=4, cost="750", margin="3550", margin_pct="82.56",
         coverage="25.0", last_sale=dt.date(2026, 8, 31)),
    _row("bucket", bucket_start=dt.date(2026, 8, 30), bucket_end=dt.date(2026, 8, 30),
         units="1", revenue="500", ops=1, cost="50", margin="450", margin_pct="90.00", coverage="0.0",
         last_sale=dt.date(2026, 8, 30)),
    _row("bucket", bucket_start=dt.date(2026, 8, 31), bucket_end=dt.date(2026, 8, 31),
         units="3", revenue="3000", ops=2, cost="600", margin="2400", margin_pct="80.00", coverage="50.0",
         last_sale=dt.date(2026, 8, 31)),
    _row("member", rank=1, variant_id=VARIANT_1, variant_name="Remera M", variant_sku="REM-001-M",
         units="3", revenue="3000", ops=2, cost="600", margin="2400", margin_pct="80.00", coverage="50.0",
         last_sale=dt.date(2026, 8, 31)),
    _row("member", rank=2, variant_id=VARIANT_2, variant_name="Remera L", variant_sku="REM-001-L",
         units="1", revenue="500", ops=1, cost="50", margin="450", margin_pct="90.00", coverage="0.0",
         last_sale=dt.date(2026, 8, 30)),
]

IDLE_HEAD = {**HEAD, "product_id": VARIANT_2, "product_name": "Quieto", "product_sku": None,
             "product_category": None, "is_group": False, "variant_count": 0}
IDLE_ROWS = [
    _row("total", head=IDLE_HEAD),
    _row("bucket", head=IDLE_HEAD, bucket_start=dt.date(2026, 8, 30), bucket_end=dt.date(2026, 8, 30)),
    _row("bucket", head=IDLE_HEAD, bucket_start=dt.date(2026, 8, 31), bucket_end=dt.date(2026, 8, 31)),
]


@pytest.fixture
def statistics_repo():
    from backend.repositories.statistics_repository import StatisticsRepository

    conn = AsyncMock()
    return StatisticsRepository(conn), conn


# ── 9.1 RED: repository ──────────────────────────────────────────────────────

class TestStatisticsRepositoryProductDetail:
    @pytest.mark.asyncio
    async def test_calls_rpc_with_bound_params_only(self, statistics_repo):
        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=DETAIL_ROWS)

        rows = await repo.fetch_product_sales_evolution(
            ACCOUNT_ID, PARENT, start=START, end=END, bucket="week", branch_id=None, canal=None
        )

        assert rows == DETAIL_ROWS
        sql = conn.fetch.call_args[0][0].lower()
        args = conn.fetch.call_args[0][1:]
        assert (
            "rpc_product_sales_evolution($1::uuid, $2::uuid, $3::date, $4::date, $5::text, $6::uuid, $7::text)"
            in sql
        )
        assert args == (ACCOUNT_ID, PARENT, START, END, "week", None, None)
        # El bucket y el producto viajan LIGADOS: jamás interpolados en el SQL.
        assert "week" not in sql and PARENT not in sql

    @pytest.mark.asyncio
    async def test_branch_and_canal_travel_bound(self, statistics_repo):
        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=[])

        await repo.fetch_product_sales_evolution(
            ACCOUNT_ID, PARENT, start=START, end=END, bucket="day", branch_id=BRANCH_1, canal="local"
        )

        args = conn.fetch.call_args[0][1:]
        assert args[4] == "day" and args[5] == BRANCH_1 and args[6] == "local"
        assert BRANCH_1 not in conn.fetch.call_args[0][0]


# ── 9.1 RED: service ─────────────────────────────────────────────────────────

class TestGetProductSalesEvolutionService:
    @pytest.mark.asyncio
    async def test_composes_header_totals_points_and_members_without_reaggregating(self, statistics_repo):
        from backend.services import statistics as svc

        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=DETAIL_ROWS)

        out = await svc.get_product_sales_evolution(
            repo, ACCOUNT_ID, product_id=PARENT, start=START, end=END, bucket="day",
            branch_id=None, canal=None,
        )

        assert set(out.keys()) == {"product", "bucket", "window", "totals", "points", "members"}
        assert out["bucket"] == "day"
        assert out["window"] == {"start": WINDOW["window_start"], "end": WINDOW["window_end"],
                                 "history_days": 30, "clamped": True}
        # Cabecera desde la fila total, tal cual la RPC la rotula.
        assert out["product"] == {
            "product_id": PARENT, "product_name": "Remera", "sku": "REM-001", "category": "Ropa",
            "parent_id": None, "parent_name": None, "is_group": True, "variant_count": 2,
        }
        # Totales: los de la fila total, NO la suma de los buckets ni de los miembros.
        assert out["totals"]["revenue"] == Decimal("4300")
        assert out["totals"]["units"] == Decimal("5")
        assert out["totals"]["operations"] == 4
        assert out["totals"]["gross_margin"] == Decimal("3550")
        assert out["totals"]["cost_coverage_pct"] == Decimal("25.0")
        assert out["totals"]["last_sale_date"] == dt.date(2026, 8, 31)
        # Puntos: los buckets en el orden de la RPC.
        assert [p["bucket_start"] for p in out["points"]] == [dt.date(2026, 8, 30), dt.date(2026, 8, 31)]
        assert out["points"][1]["revenue"] == Decimal("3000") and out["points"][1]["operations"] == 2
        # Miembros: rank y contexto de cada variante, en el orden de la RPC.
        assert [m["rank"] for m in out["members"]] == [1, 2]
        assert out["members"][0]["product_id"] == VARIANT_1
        assert out["members"][0]["product_name"] == "Remera M"
        assert out["members"][0]["sku"] == "REM-001-M"
        assert out["members"][0]["revenue"] == Decimal("3000")
        assert out["members"][1]["gross_margin"] == Decimal("450")

    @pytest.mark.asyncio
    async def test_product_without_sales_is_zero_totals_with_null_margin_not_an_error(self, statistics_repo):
        from backend.services import statistics as svc

        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=IDLE_ROWS)

        out = await svc.get_product_sales_evolution(
            repo, ACCOUNT_ID, product_id=VARIANT_2, start=START, end=END, bucket="day",
            branch_id=None, canal=None,
        )

        assert out["product"]["product_name"] == "Quieto"
        assert out["product"]["is_group"] is False and out["product"]["variant_count"] == 0
        assert out["totals"]["revenue"] == Decimal("0") and out["totals"]["operations"] == 0
        # Margen ausente se PRESERVA como None — nunca 0 (D11).
        assert out["totals"]["gross_margin"] is None
        assert out["totals"]["total_cost"] is None
        assert out["totals"]["cost_coverage_pct"] is None
        assert out["totals"]["last_sale_date"] is None
        assert len(out["points"]) == 2 and all(p["revenue"] == Decimal("0") for p in out["points"])
        assert out["members"] == []

    @pytest.mark.asyncio
    async def test_missing_total_row_is_500(self, statistics_repo):
        from backend.services import statistics as svc

        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=[r for r in DETAIL_ROWS if r["row_kind"] != "total"])

        with pytest.raises(HTTPException) as exc:
            await svc.get_product_sales_evolution(
                repo, ACCOUNT_ID, product_id=PARENT, start=START, end=END, bucket="day",
                branch_id=None, canal=None,
            )
        assert exc.value.status_code == 500

    @pytest.mark.asyncio
    async def test_end_before_start_is_422_without_query(self, statistics_repo):
        from backend.services import statistics as svc

        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=DETAIL_ROWS)

        with pytest.raises(HTTPException) as exc:
            await svc.get_product_sales_evolution(
                repo, ACCOUNT_ID, product_id=PARENT, start=END, end=START, bucket="day",
                branch_id=None, canal=None,
            )
        assert exc.value.status_code == 422
        conn.fetch.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_bucket_outside_dictionary_is_422_without_query(self, statistics_repo):
        from backend.services import statistics as svc

        repo, conn = statistics_repo
        conn.fetch = AsyncMock(return_value=DETAIL_ROWS)

        with pytest.raises(HTTPException) as exc:
            await svc.get_product_sales_evolution(
                repo, ACCOUNT_ID, product_id=PARENT, start=START, end=END, bucket="hour",
                branch_id=None, canal=None,
            )
        assert exc.value.status_code == 422
        conn.fetch.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_p0404_maps_to_404_and_p0401_to_403(self, statistics_repo):
        from backend.services import statistics as svc

        repo, conn = statistics_repo
        for code, status in (("P0404", 404), ("P0401", 403), ("P0400", 422)):
            err = asyncpg.exceptions.RaiseError("boom")
            err.sqlstate = code
            conn.fetch = AsyncMock(side_effect=err)
            with pytest.raises(HTTPException) as exc:
                await svc.get_product_sales_evolution(
                    repo, ACCOUNT_ID, product_id=PARENT, start=START, end=END, bucket="day",
                    branch_id=None, canal=None,
                )
            assert exc.value.status_code == status, code


# ── 9.3 RED: router — GET /reports/statistics/products/{product_id} ─────────

class TestProductDetailEndpoint:
    @pytest.mark.asyncio
    async def test_ok_shape_with_header_points_and_members(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=DETAIL_ROWS)
        token = make_token({"app_metadata": {"account_role": "member"}})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/reports/statistics/products/{PARENT}?start=2026-08-01&end=2026-08-31&bucket=day",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        data = resp.json()
        assert set(data.keys()) == {"product", "bucket", "window", "totals", "points", "members"}
        assert data["product"]["product_id"] == PARENT
        assert data["product"]["product_name"] == "Remera"
        assert data["product"]["is_group"] is True and data["product"]["variant_count"] == 2
        assert data["window"] == {"start": "2026-08-02", "end": "2026-08-31", "history_days": 30, "clamped": True}
        assert Decimal(data["totals"]["revenue"]) == Decimal("4300")
        assert data["totals"]["operations"] == 4
        assert Decimal(data["totals"]["cost_coverage_pct"]) == Decimal("25.0")
        assert len(data["points"]) == 2 and data["points"][0]["bucket_start"] == "2026-08-30"
        assert [m["rank"] for m in data["members"]] == [1, 2]
        assert data["members"][0]["product_id"] == VARIANT_1 and data["members"][0]["sku"] == "REM-001-M"
        # response_model filtra: las columnas internas de la RPC no llegan al cliente.
        assert "row_kind" not in data["totals"] and "window_start" not in data["totals"]
        # El producto viaja LIGADO a la RPC (2º parámetro), nunca interpolado.
        assert conn.fetch.call_args[0][2] == PARENT
        assert conn.fetch.call_args[0][5] == "day"

    @pytest.mark.asyncio
    async def test_bucket_outside_literal_is_422_without_query(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=DETAIL_ROWS)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/reports/statistics/products/{PARENT}?start=2026-08-01&end=2026-08-31&bucket=hour",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 422
        conn.fetch.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_product_id_must_be_uuid(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=DETAIL_ROWS)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/statistics/products/not-a-uuid?start=2026-08-01&end=2026-08-31",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 422
        conn.fetch.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_foreign_product_is_404_problem_json(self, async_client, mock_pool):
        pool, conn = mock_pool
        err = asyncpg.exceptions.RaiseError("Product not found")
        err.sqlstate = "P0404"
        conn.fetch = AsyncMock(side_effect=err)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/reports/statistics/products/{PARENT}?start=2026-08-01&end=2026-08-31",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 404
        assert resp.headers["content-type"].startswith("application/problem+json")
        body = resp.json()
        assert body["status"] == 404
        assert "title" in body and "detail" in body

    @pytest.mark.asyncio
    async def test_branch_id_and_canal_are_bound(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=DETAIL_ROWS)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/reports/statistics/products/{PARENT}?start=2026-08-01&end=2026-08-31"
                f"&bucket=month&branch_id={BRANCH_1}&canal=local",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        args = conn.fetch.call_args[0]
        assert args[5] == "month" and args[6] == BRANCH_1 and args[7] == "local"

    @pytest.mark.asyncio
    async def test_end_before_start_is_422(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=DETAIL_ROWS)
        token = make_token()

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/reports/statistics/products/{PARENT}?start=2026-08-31&end=2026-08-01",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 422
        conn.fetch.assert_not_awaited()
