"""
fix/tenancy-bank-accounts-leak — regresión multi-tenant (hotfix de seguridad,
2026-08-22, aprobado por el PO).

Causa raíz: varios repositories leían tablas confiando SOLO en RLS
(`account_id IN current_account_ids()`), pero el pool de conexiones corre la
sesión como OWNER de las tablas mientras la palanca `TENANCY_TX_SCOPE_ENABLED`
(Paso 2 de v31-tenancy-pool-rls) sigue apagada — así que RLS NO se aplica y
esas queries devuelven filas de TODOS los tenants (o, en los métodos que
reciben un id de un hijo por path param — bank_account_id, session_id,
customer_account_id, etc. — devuelven la fila de CUALQUIER cuenta con solo
adivinar/filtrar el UUID, sin verificar pertenencia).

Regla de la casa (reforzada por este hotfix): todo repository query SIEMPRE
lleva un filtro EXPLÍCITO por account_id — RLS es la red de seguridad, nunca
el único guard.

Dos tenants de prueba (A y B) en cada test: A NUNCA debe ver datos de B.
"""
from __future__ import annotations

from unittest.mock import AsyncMock

import pytest

ACCOUNT_A = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
ACCOUNT_B = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
BANK_ACCOUNT_B = "cccccccc-cccc-cccc-cccc-cccccccccccc"


# ═══════════════════════════════════════════════════════════════════════════
# 1. BankAccountRepository.list_active — leak reportado (sin NINGÚN filtro)
# ═══════════════════════════════════════════════════════════════════════════

@pytest.fixture
def bank_account_repo():
    from backend.repositories.bank_account_repository import BankAccountRepository

    conn = AsyncMock()
    return BankAccountRepository(conn), conn


class TestBankAccountListActiveTenancy:
    @pytest.mark.asyncio
    async def test_list_active_filters_by_caller_account_id(self, bank_account_repo):
        """RED (pre-fix): list_active() no recibía account_id y devolvía TODAS
        las cuentas bancarias activas de TODOS los tenants — el selector de
        cuenta bancaria de un usuario del tenant A mostraba cuentas de B/C/D.
        GREEN: la query SIEMPRE lleva `account_id = $1` como filtro explícito."""
        repo, conn = bank_account_repo
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_active(ACCOUNT_A)

        sql = conn.fetch.call_args.args[0]
        params = conn.fetch.call_args.args[1:]
        assert "account_id = $1" in sql
        assert params == (ACCOUNT_A,)

    @pytest.mark.asyncio
    async def test_list_active_requires_account_id_argument(self, bank_account_repo):
        """TRIANGULATE: la firma ya no acepta llamarse sin account_id (defensa
        en profundidad a nivel de tipo — un caller nuevo no puede omitirlo por
        accidente)."""
        repo, _conn = bank_account_repo
        with pytest.raises(TypeError):
            await repo.list_active()  # type: ignore[call-arg]


# ═══════════════════════════════════════════════════════════════════════════
# 2. BankAccountRepository.list_movements_page — IDOR vía bank_account_id
# ═══════════════════════════════════════════════════════════════════════════

class TestBankAccountMovementsTenancy:
    @pytest.mark.asyncio
    async def test_list_movements_page_scopes_by_owner_account(self, bank_account_repo):
        """RED (pre-fix): list_movements_page(bank_account_id) solo filtraba
        por bm.bank_account_id — un id de OTRO tenant (adivinado o filtrado)
        devolvía sus movimientos igual. GREEN: el SELECT hace JOIN/EXISTS
        contra bank_accounts.account_id = $caller."""
        repo, conn = bank_account_repo
        conn.fetch = AsyncMock(return_value=[])
        conn.fetchval = AsyncMock(return_value=0)

        await repo.list_movements_page(
            BANK_ACCOUNT_B, account_id=ACCOUNT_A, page=0, size=30
        )

        select_sql = conn.fetch.call_args.args[0]
        count_sql = conn.fetchval.call_args.args[0]
        assert "bank_accounts" in select_sql and "account_id" in select_sql
        assert "bank_accounts" in count_sql and "account_id" in count_sql
        # account_id del caller viaja como parámetro en ambas queries.
        assert ACCOUNT_A in conn.fetch.call_args.args[1:]
        assert ACCOUNT_A in conn.fetchval.call_args.args[1:]

    @pytest.mark.asyncio
    async def test_get_owned_returns_none_for_foreign_bank_account(self, bank_account_repo):
        """El helper de pertenencia (usado por el service para el 404) no
        devuelve la fila si el bank_account_id no es de la cuenta del caller."""
        repo, conn = bank_account_repo
        conn.fetchrow = AsyncMock(return_value=None)

        result = await repo.get_by_id_for_account(BANK_ACCOUNT_B, ACCOUNT_A)

        assert result is None
        sql = conn.fetchrow.call_args.args[0]
        params = conn.fetchrow.call_args.args[1:]
        assert "account_id" in sql
        assert params == (BANK_ACCOUNT_B, ACCOUNT_A)


class TestBankAccountMovementsService:
    @pytest.mark.asyncio
    async def test_service_404s_when_bank_account_not_owned_by_caller(self):
        """Service: si el bank_account_id no pertenece a la cuenta del caller,
        404 ANTES de listar movimientos (no filtra en silencio a vacío, que
        sería indistinguible de "cuenta propia sin movimientos")."""
        from fastapi import HTTPException

        from backend.services import bank_movements as bank_movements_service

        repo = AsyncMock()
        repo.get_by_id_for_account = AsyncMock(return_value=None)
        repo.list_movements_page = AsyncMock()

        with pytest.raises(HTTPException) as exc_info:
            await bank_movements_service.list_movements(
                repo,
                BANK_ACCOUNT_B,
                account_id=ACCOUNT_A,
                page=0,
                size=30,
                types=None,
                status=None,
                q=None,
                date_from=None,
                date_to=None,
            )

        assert exc_info.value.status_code == 404
        repo.list_movements_page.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_service_lists_movements_when_owned(self):
        """Con la cuenta propia, delega normalmente al repo."""
        from backend.services import bank_movements as bank_movements_service

        repo = AsyncMock()
        repo.get_by_id_for_account = AsyncMock(return_value={"id": BANK_ACCOUNT_B})
        repo.list_movements_page = AsyncMock(
            return_value={"items": [], "total": 0, "page": 0, "pages": 0}
        )

        result = await bank_movements_service.list_movements(
            repo,
            BANK_ACCOUNT_B,
            account_id=ACCOUNT_A,
            page=0,
            size=30,
            types=None,
            status=None,
            q=None,
            date_from=None,
            date_to=None,
        )

        assert result["total"] == 0
        repo.list_movements_page.assert_awaited_once()


# ═══════════════════════════════════════════════════════════════════════════
# 3. Router-level: /bank-accounts nunca devuelve filas fuera de get_account_id
# ═══════════════════════════════════════════════════════════════════════════

class TestBankAccountsRouterTenancy:
    @pytest.mark.asyncio
    async def test_list_bank_accounts_passes_resolved_account_id_to_repo(
        self, async_client, mock_pool
    ):
        """El router SIEMPRE resuelve account_id vía get_account_id (dependency
        que consulta account_members por auth.uid(), explícitamente filtrado —
        no confía en RLS de bank_accounts) y lo pasa al repo."""
        from unittest.mock import patch

        from backend.tests.conftest import make_token, TEST_ACCOUNT_ID

        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[])
        user_token = make_token({"app_metadata": {"role": "user"}})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/bank-accounts",
                headers={"Authorization": f"Bearer {user_token}"},
            )

        assert resp.status_code == 200
        sql = conn.fetch.call_args.args[0]
        params = conn.fetch.call_args.args[1:]
        assert "account_id = $1" in sql
        assert params == (str(TEST_ACCOUNT_ID),)
