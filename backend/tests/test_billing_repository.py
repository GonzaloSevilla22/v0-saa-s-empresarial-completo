"""
mp-real-subscriptions follow-up (task 8.8) — BillingRepository.search_accounts
TDD tests (RED/GREEN/TRIANGULATE). Mismo patrón que
test_subscriptions_repository.py: asyncpg mockeado, se verifica el SQL vía
call_args y el comportamiento vía el valor de retorno. No toca una DB real.
"""
from __future__ import annotations

from unittest.mock import AsyncMock

import pytest

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"


@pytest.fixture
def billing_repo():
    from backend.repositories.billing_repository import BillingRepository

    conn = AsyncMock()
    return BillingRepository(conn), conn


class TestListReceipts:
    """bugfix/receipts-subscription-charges (2026-09-04): 'Recibos de Pago'
    sólo contemplaba billing_events.event_type='plan_upgraded' (flujo legacy
    de pago único). Los cobros recurrentes de mp-real-subscriptions escriben
    event_type='subscription_payment_approved' y nunca aparecían en la lista
    ni recibían receipt_number. RED antes del fix: la SQL sólo menciona
    'plan_upgraded'."""

    @pytest.mark.asyncio
    async def test_select_and_count_include_subscription_payment_approved(
        self, billing_repo
    ):
        """RED/GREEN: tanto el SELECT paginado como el count(*) tienen que
        filtrar por AMBOS event_type — si uno de los dos queda atrás, el
        total de la paginación diverge de lo que se ve en pantalla."""
        repo, conn = billing_repo
        conn.fetch = AsyncMock(return_value=[])
        conn.fetchval = AsyncMock(return_value=0)

        await repo.list_receipts(limit=50, offset=0)

        select_sql = conn.fetch.call_args.args[0]
        count_sql = conn.fetchval.call_args.args[0]
        assert "subscription_payment_approved" in select_sql
        assert "plan_upgraded" in select_sql
        assert "subscription_payment_approved" in count_sql
        assert "plan_upgraded" in count_sql

    @pytest.mark.asyncio
    async def test_get_receipt_includes_subscription_payment_approved(
        self, billing_repo
    ):
        """RED/GREEN: el detalle de un recibo individual (usado por el PDF y
        por el reenvío de email) tiene que poder resolver un
        subscription_payment_approved, no sólo un plan_upgraded legacy."""
        repo, conn = billing_repo
        conn.fetchrow = AsyncMock(return_value=None)

        await repo.get_receipt("11111111-1111-1111-1111-111111111111")

        sql = conn.fetchrow.call_args.args[0]
        assert "subscription_payment_approved" in sql
        assert "plan_upgraded" in sql

    @pytest.mark.asyncio
    async def test_receipt_event_types_is_a_single_shared_constant(self):
        """TRIANGULATE: regla del proyecto 'reutilización antes que
        repetición' — el SELECT y el count(*) tienen que derivar de LA MISMA
        tupla, no de dos listas de literales que puedan divergir con el
        tiempo (fue exactamente el bug: alguien agregó el evento nuevo en un
        lugar y se olvidó del otro)."""
        from backend.repositories.billing_repository import (
            RECEIPT_EVENT_TYPES,
            _RECEIPT_SELECT,
        )

        assert RECEIPT_EVENT_TYPES == ("plan_upgraded", "subscription_payment_approved")
        for event_type in RECEIPT_EVENT_TYPES:
            assert event_type in _RECEIPT_SELECT

    @pytest.mark.asyncio
    async def test_list_receipts_returns_rows_and_total(self, billing_repo):
        """TRIANGULATE: sigue devolviendo (rows, total) tal cual venían de
        conn.fetch/conn.fetchval — el fix no cambia el contrato de retorno."""
        repo, conn = billing_repo
        rows = [{"id": "evt-1", "receipt_number": "RC-2026-000002"}]
        conn.fetch = AsyncMock(return_value=rows)
        conn.fetchval = AsyncMock(return_value=2)

        result_rows, total = await repo.list_receipts(limit=50, offset=0)

        assert result_rows == rows
        assert total == 2


class TestSearchAccounts:
    @pytest.mark.asyncio
    async def test_wraps_query_in_ilike_wildcard_pattern(self, billing_repo):
        """RED: el término de búsqueda se envuelve en %...% para el ILIKE."""
        repo, conn = billing_repo
        conn.fetch = AsyncMock(return_value=[])

        await repo.search_accounts("buyer@example.com")

        args = conn.fetch.call_args.args
        assert args[1] == "%buyer@example.com%"

    @pytest.mark.asyncio
    async def test_searches_by_email_or_name_or_business_name(self, billing_repo):
        """GREEN: la búsqueda cubre email, nombre y razón social del owner —
        accounts no tiene un nombre de negocio propio."""
        repo, conn = billing_repo
        conn.fetch = AsyncMock(return_value=[])

        await repo.search_accounts("acme")

        sql = conn.fetch.call_args.args[0]
        assert "u.email ILIKE $1" in sql
        assert "p.name ILIKE $1" in sql
        assert "p.business_name ILIKE $1" in sql
        assert "FROM public.accounts a" in sql
        assert "JOIN auth.users u ON u.id = a.owner_user_id" in sql

    @pytest.mark.asyncio
    async def test_strips_whitespace_before_wrapping(self, billing_repo):
        """TRIANGULATE: espacios accidentales en el input no rompen el match."""
        repo, conn = billing_repo
        conn.fetch = AsyncMock(return_value=[])

        await repo.search_accounts("  buyer@example.com  ")

        args = conn.fetch.call_args.args
        assert args[1] == "%buyer@example.com%"

    @pytest.mark.asyncio
    async def test_default_limit_is_twenty(self, billing_repo):
        """TRIANGULATE: el límite por defecto acota el resultado (selector,
        no un export)."""
        repo, conn = billing_repo
        conn.fetch = AsyncMock(return_value=[])

        await repo.search_accounts("acme")

        args = conn.fetch.call_args.args
        assert args[2] == 20

    @pytest.mark.asyncio
    async def test_returns_rows_from_conn_fetch(self, billing_repo):
        repo, conn = billing_repo
        row = {
            "account_id": ACCOUNT_ID,
            "owner_email": "buyer@example.com",
            "owner_name": "Buyer Test",
            "billing_plan": "pro",
        }
        conn.fetch = AsyncMock(return_value=[row])

        result = await repo.search_accounts("buyer")

        assert result == [row]
