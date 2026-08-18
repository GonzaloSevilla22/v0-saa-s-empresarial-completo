"""
clientes-frecuentes-historial — TDD tests para los métodos de actividad y
historial de ClientRepository (tasks 3.1 RED / 3.3 / 3.4 / 3.5 / 3.6
TRIANGULATE). Mock de asyncpg — se verifica la SQL emitida vía call_args,
mismo patrón que test_client_address_repository.py.
"""
from __future__ import annotations

import datetime
from decimal import Decimal
from unittest.mock import AsyncMock

import pytest

from backend.core.client_activity import (
    FRECUENTE_MIN_OPS,
    FRECUENTE_WINDOW_DAYS,
    INACTIVO_MIN_DAYS,
)
from backend.repositories.client_repository import ClientRepository

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
CLIENT_ID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
TODAY = datetime.date(2026, 8, 14)


@pytest.fixture
def client_repo():
    conn = AsyncMock()
    return ClientRepository(conn), conn


# ── 3.1 RED / 3.2 GREEN — list_activity_page ─────────────────────────────────


class TestListActivityPage:
    @pytest.mark.asyncio
    async def test_envelope_shape(self, client_repo):
        repo, conn = client_repo
        conn.fetchval = AsyncMock(return_value=2)
        conn.fetch = AsyncMock(return_value=[{"id": CLIENT_ID, "activity_status": "activo"}])

        result = await repo.list_activity_page(ACCOUNT_ID, today=TODAY, page=0, size=25)

        assert set(result.keys()) == {"items", "total", "page", "pages"}
        assert result["total"] == 2
        assert result["page"] == 0
        assert result["pages"] == 1

    @pytest.mark.asyncio
    async def test_excludes_soft_deleted(self, client_repo):
        repo, conn = client_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_activity_page(ACCOUNT_ID, today=TODAY, page=0, size=25)

        sql = conn.fetch.call_args.args[0]
        assert "deleted_at IS NULL" in sql

    @pytest.mark.asyncio
    async def test_scopes_by_account_id(self, client_repo):
        repo, conn = client_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_activity_page(ACCOUNT_ID, today=TODAY, page=0, size=25)

        args = conn.fetch.call_args.args
        assert ACCOUNT_ID in args

    @pytest.mark.asyncio
    async def test_thresholds_travel_as_query_parameters(self, client_repo):
        """client-activity §'Umbrales canónicos en una única fuente de verdad':
        FRECUENTE_MIN_OPS / FRECUENTE_WINDOW_DAYS / INACTIVO_MIN_DAYS viajan
        como parámetros posicionales de la consulta, no interpolados."""
        repo, conn = client_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_activity_page(ACCOUNT_ID, today=TODAY, page=0, size=25)

        args = conn.fetch.call_args.args
        assert FRECUENTE_WINDOW_DAYS in args
        assert FRECUENTE_MIN_OPS in args
        assert INACTIVO_MIN_DAYS in args
        assert TODAY in args

    # ── 3.3 TRIANGULATE ──────────────────────────────────────────────────────

    @pytest.mark.asyncio
    async def test_operation_is_the_purchase_unit_group_by_op_key(self, client_repo):
        """Una operación con varias líneas cuenta 1 compra: el LATERAL agrupa
        por COALESCE(operation_id, id), no por fila de sales."""
        repo, conn = client_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_activity_page(ACCOUNT_ID, today=TODAY, page=0, size=25)

        sql = conn.fetch.call_args.args[0]
        assert "GROUP BY COALESCE(s.operation_id::text, s.id::text)" in sql

    @pytest.mark.asyncio
    async def test_line_amount_is_canonical_coalesce(self, client_repo):
        """RN-D / reporting-invariants: COALESCE(sale_items.subtotal,
        sales.total, sales.amount) — nunca sumar `amount` a secas cuando existe
        `total`/`subtotal` (evita la subvaluación con quantity > 1)."""
        repo, conn = client_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_activity_page(ACCOUNT_ID, today=TODAY, page=0, size=25)

        sql = conn.fetch.call_args.args[0]
        assert "COALESCE(si.subtotal, s.total, s.amount)" in sql

    @pytest.mark.asyncio
    async def test_sales_correlated_by_client_id_not_only_account(self, client_repo):
        """Ventas con client_id NULL no se atribuyen a ningún cliente: el
        LATERAL correlaciona explícitamente por s.client_id = c.id."""
        repo, conn = client_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_activity_page(ACCOUNT_ID, today=TODAY, page=0, size=25)

        sql = conn.fetch.call_args.args[0]
        assert "s.client_id = c.id" in sql

    @pytest.mark.asyncio
    async def test_client_without_sales_defaults_aggregates_to_zero(self, client_repo):
        repo, conn = client_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_activity_page(ACCOUNT_ID, today=TODAY, page=0, size=25)

        sql = conn.fetch.call_args.args[0]
        assert "COALESCE(agg.ops_total, 0)" in sql
        assert "COALESCE(agg.total_spent, 0)" in sql

    @pytest.mark.asyncio
    async def test_activity_status_filter_is_a_query_parameter(self, client_repo):
        repo, conn = client_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_activity_page(
            ACCOUNT_ID, today=TODAY, page=0, size=25, activity_status="inactivo"
        )

        args = conn.fetch.call_args.args
        assert "inactivo" in args

    @pytest.mark.asyncio
    async def test_search_matches_name_or_email_case_insensitive(self, client_repo):
        repo, conn = client_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_activity_page(ACCOUNT_ID, today=TODAY, page=0, size=25, search="acme")

        sql = conn.fetch.call_args.args[0]
        args = conn.fetch.call_args.args
        assert "ILIKE" in sql
        assert "acme" in args

    @pytest.mark.asyncio
    async def test_sort_by_last_purchase_puts_nulls_last(self, client_repo):
        """Clientes sin compras (last_purchase_date NULL) quedan al final del
        orden por última compra, en cualquier dirección."""
        repo, conn = client_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_activity_page(
            ACCOUNT_ID, today=TODAY, page=0, size=25, sort="last_purchase", sort_dir="desc"
        )

        sql = conn.fetch.call_args.args[0]
        assert "last_purchase_date DESC NULLS LAST" in sql

    # ── deudas-menores-agosto (G3) — orden por defecto: última compra ────────

    @pytest.mark.asyncio
    async def test_default_order_is_last_purchase_desc_when_not_specified(self, client_repo):
        """G3: sin pasar sort/sort_dir, el default pasa de name ASC a
        last_purchase_date DESC NULLS LAST (design.md §D7) — cierra la OQ-4
        de clientes-frecuentes-historial."""
        repo, conn = client_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_activity_page(ACCOUNT_ID, today=TODAY, page=0, size=25)

        sql = conn.fetch.call_args.args[0]
        assert "ORDER BY last_purchase_date DESC NULLS LAST" in sql

    @pytest.mark.asyncio
    async def test_explicit_sort_by_name_still_works(self, client_repo):
        """TRIANGULATE: el default nuevo no rompe el control explícito del
        usuario — sort=name sigue funcionando como antes."""
        repo, conn = client_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_activity_page(ACCOUNT_ID, today=TODAY, page=0, size=25, sort="name", sort_dir="asc")

        sql = conn.fetch.call_args.args[0]
        assert "ORDER BY name ASC" in sql

    @pytest.mark.asyncio
    async def test_default_order_tiebreaks_by_id_for_stable_pagination(self, client_repo):
        """TRIANGULATE: el desempate `, id ASC` sigue presente en el default
        nuevo — evita filas repetidas u omitidas al paginar con fechas
        empatadas o nulas."""
        repo, conn = client_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_activity_page(ACCOUNT_ID, today=TODAY, page=0, size=25)

        sql = conn.fetch.call_args.args[0]
        assert "ORDER BY last_purchase_date DESC NULLS LAST, id ASC" in sql

    @pytest.mark.asyncio
    async def test_unknown_sort_never_interpolated_falls_back_to_name(self, client_repo):
        """Defensa en profundidad: aunque `sort` ya se valida en el schema del
        router (Literal), el repository jamás debe interpolar una columna
        arbitraria en el ORDER BY."""
        repo, conn = client_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_activity_page(
            ACCOUNT_ID, today=TODAY, page=0, size=25, sort="x'; DROP TABLE clients; --"
        )

        sql = conn.fetch.call_args.args[0]
        assert "DROP TABLE" not in sql
        assert "ORDER BY name" in sql


# ── 3.4 RED→GREEN — get_activity_for reutiliza la misma SQL ─────────────────


class TestGetActivityFor:
    @pytest.mark.asyncio
    async def test_reuses_same_aggregate_definition_as_list(self, client_repo):
        repo, conn = client_repo
        conn.fetchrow = AsyncMock(
            return_value={"id": CLIENT_ID, "activity_status": "frecuente", "purchase_count": 5}
        )

        row = await repo.get_activity_for(CLIENT_ID, ACCOUNT_ID, today=TODAY)

        sql = conn.fetchrow.call_args.args[0]
        assert "COALESCE(si.subtotal, s.total, s.amount)" in sql
        assert "COALESCE(s.operation_id::text, s.id::text)" in sql
        assert dict(row)["purchase_count"] == 5

    @pytest.mark.asyncio
    async def test_scopes_by_client_and_account(self, client_repo):
        repo, conn = client_repo
        conn.fetchrow = AsyncMock(return_value=None)

        await repo.get_activity_for(CLIENT_ID, ACCOUNT_ID, today=TODAY)

        args = conn.fetchrow.call_args.args
        assert CLIENT_ID in args
        assert ACCOUNT_ID in args

    @pytest.mark.asyncio
    async def test_returns_none_when_client_not_found(self, client_repo):
        repo, conn = client_repo
        conn.fetchrow = AsyncMock(return_value=None)

        result = await repo.get_activity_for(CLIENT_ID, ACCOUNT_ID, today=TODAY)

        assert result is None


# ── 3.5 RED→GREEN / 3.6 TRIANGULATE — list_purchases_page ───────────────────


class TestListPurchasesPage:
    @pytest.mark.asyncio
    async def test_envelope_shape(self, client_repo):
        repo, conn = client_repo
        conn.fetchval = AsyncMock(return_value=5)
        conn.fetch = AsyncMock(
            return_value=[{"operation_id": "op-1", "item_count": 3, "total": Decimal("300")}]
        )

        result = await repo.list_purchases_page(CLIENT_ID, ACCOUNT_ID, page=0, size=25)

        assert set(result.keys()) == {"items", "total", "page", "pages"}

    @pytest.mark.asyncio
    async def test_groups_lines_by_operation(self, client_repo):
        repo, conn = client_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_purchases_page(CLIENT_ID, ACCOUNT_ID, page=0, size=25)

        sql = conn.fetch.call_args.args[0]
        assert "GROUP BY" in sql
        assert "COALESCE(s.operation_id::text, s.id::text)" in sql

    @pytest.mark.asyncio
    async def test_ordered_by_date_descending(self, client_repo):
        repo, conn = client_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_purchases_page(CLIENT_ID, ACCOUNT_ID, page=0, size=25)

        sql = conn.fetch.call_args.args[0]
        assert "ORDER BY" in sql
        assert "DESC" in sql

    @pytest.mark.asyncio
    async def test_out_of_range_page_returns_empty_items_but_keeps_total(self, client_repo):
        repo, conn = client_repo
        conn.fetchval = AsyncMock(return_value=5)
        conn.fetch = AsyncMock(return_value=[])

        result = await repo.list_purchases_page(CLIENT_ID, ACCOUNT_ID, page=99, size=25)

        assert result["items"] == []
        assert result["total"] == 5
        assert result["pages"] == 1

    @pytest.mark.asyncio
    async def test_scoped_by_client_and_account(self, client_repo):
        repo, conn = client_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_purchases_page(CLIENT_ID, ACCOUNT_ID, page=0, size=25)

        args = conn.fetch.call_args.args
        assert CLIENT_ID in args
        assert ACCOUNT_ID in args

    @pytest.mark.asyncio
    async def test_operation_date_is_cast_to_calendar_date(self, client_repo):
        """Regresión (encontrada corriendo contra Postgres local real, no el
        mock): `s.date` es `timestamp with time zone`; MAX(date) a secas
        devuelve un datetime con hora, y ClientPurchaseOut.operation_date es
        `datetime.date` — Pydantic lo rechaza
        (`date_from_datetime_inexact`). El ::date + AT TIME ZONE evita que
        asyncpg devuelva un datetime con componente horario."""
        repo, conn = client_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_purchases_page(CLIENT_ID, ACCOUNT_ID, page=0, size=25)

        sql = conn.fetch.call_args.args[0]
        assert "(s.date AT TIME ZONE 'America/Argentina/Mendoza')::date" in sql
        assert "MAX(op_day)" in sql


# ── Grupo 4 — timezone argentino (tasks 4.1/4.2/4.3/4.4) ────────────────────


class TestArgentinianCalendarDay:
    @pytest.mark.asyncio
    async def test_operation_day_converts_to_argentina_timezone(self, client_repo):
        """4.1/4.2: una venta a las 22:00 ART (01:00 UTC del día siguiente)
        debe resolver al día D — la conversión AT TIME ZONE ocurre ANTES de
        tomar ::date, nunca sobre el instante UTC crudo."""
        repo, conn = client_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_activity_page(ACCOUNT_ID, today=TODAY, page=0, size=25)

        sql = conn.fetch.call_args.args[0]
        assert "(s.date AT TIME ZONE 'America/Argentina/Mendoza')::date" in sql

    @pytest.mark.asyncio
    async def test_days_since_last_purchase_anchored_to_reference_day_parameter(self, client_repo):
        """El día de referencia (`reporting_local_today()`, ya resuelto por el
        service) viaja como parámetro `$1`, no como `now()` del servidor."""
        repo, conn = client_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_activity_page(ACCOUNT_ID, today=TODAY, page=0, size=25)

        sql = conn.fetch.call_args.args[0]
        assert "($1::date - agg.last_op_day)" in sql

    @pytest.mark.asyncio
    async def test_frequency_window_is_inclusive_of_boundary_day(self, client_repo):
        """4.3 TRIANGULATE: ventana de 90 días inclusive — D-89 entra, D-90
        no entra. `$2::int - 1` es exactamente ese ajuste de inclusividad."""
        repo, conn = client_repo
        conn.fetchval = AsyncMock(return_value=0)
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_activity_page(ACCOUNT_ID, today=TODAY, page=0, size=25)

        sql = conn.fetch.call_args.args[0]
        assert "ops.op_day >= $1::date - ($2::int - 1)" in sql

    def test_no_now_interval_arithmetic_in_client_repository(self):
        """4.4: guardarraíl por grep — ninguna consulta nueva hace aritmética
        de fechas contra `now()` (`now() -`), sólo se permite la MENCIÓN en
        comentarios/docstrings (business-day-timezone)."""
        import pathlib

        source = pathlib.Path(__file__).resolve().parents[1] / "repositories" / "client_repository.py"
        text = source.read_text(encoding="utf-8")
        assert "now() -" not in text
        assert "now()::date" not in text
