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
