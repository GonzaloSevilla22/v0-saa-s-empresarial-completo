"""v3-soft-delete-policy (OQ2): soft delete de cashboxes.

`cashboxes` no tiene account_id directo — su scope de cuenta es indirecto vía
branch_id → branches.account_id. Por eso queda FUERA de la allowlist del
soft_delete genérico del BaseRepository.

v31-tenancy-pool-rls (colisión #2, sign-off PO 2026-08-01): cashboxes no
tiene policy de UPDATE — el UPDATE directo con el JOIN a branches quedó
encaminado por rpc_soft_delete_cashbox (SECURITY DEFINER), que agrega el
check is_account_writer(account_id) (mismo que cashboxes_insert). El JOIN a
branches y el check de cuenta ahora viven en la RPC — se prueban con gates
SQL contra Postgres real (supabase/migrations/20260828000001_v31_rls_
collision_rpcs.sql, gates cash-a/cash-b). Este test verifica el CONTRATO del
repository: qué RPC llama y con qué parámetros, y que su valor de retorno
(boolean) se propaga sin modificar.
"""
from __future__ import annotations

from unittest.mock import AsyncMock

import pytest

from backend.repositories.cashbox_repository import CashboxRepository

CASHBOX_ID = "66666666-6666-6666-6666-666666666666"
BRANCH_ID = "77777777-7777-7777-7777-777777777777"
ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
USER_ID = "11111111-1111-1111-1111-111111111111"


@pytest.fixture
def mock_conn():
    conn = AsyncMock()
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchval = AsyncMock(return_value=True)
    return conn


@pytest.mark.asyncio
async def test_list_cashboxes_excludes_soft_deleted(mock_conn):
    repo = CashboxRepository(mock_conn)

    await repo.list_cashboxes(BRANCH_ID, ACCOUNT_ID)

    sql = mock_conn.fetch.call_args.args[0]
    assert "deleted_at IS NULL" in sql


@pytest.mark.asyncio
async def test_soft_delete_cashbox_calls_rpc_with_all_three_params(mock_conn):
    """RED→GREEN (v31-tenancy-pool-rls colisión #2): soft_delete_cashbox ya
    NO ejecuta el UPDATE directo — llama a rpc_soft_delete_cashbox con
    (cashbox_id, account_id, deleted_by) y propaga su resultado."""
    repo = CashboxRepository(mock_conn)

    affected = await repo.soft_delete_cashbox(CASHBOX_ID, ACCOUNT_ID, USER_ID)

    assert affected is True
    mock_conn.fetchval.assert_awaited_once()
    query, cashbox_id, account_id, deleted_by = mock_conn.fetchval.call_args.args
    assert "rpc_soft_delete_cashbox" in query
    assert cashbox_id == CASHBOX_ID
    assert account_id == ACCOUNT_ID
    assert deleted_by == USER_ID


@pytest.mark.asyncio
async def test_soft_delete_cashbox_propagates_false_from_rpc(mock_conn):
    """TRIANGULATE: cuenta ajena / sin permiso de writer → la RPC devuelve
    false (no un 42501 crudo) — el repository lo propaga tal cual, sin
    reinterpretar. El aislamiento por cuenta real (is_account_writer + JOIN a
    branches) se prueba contra Postgres real en el gate SQL (cash-b)."""
    mock_conn.fetchval = AsyncMock(return_value=False)
    repo = CashboxRepository(mock_conn)

    affected = await repo.soft_delete_cashbox(
        CASHBOX_ID, "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", USER_ID
    )

    assert affected is False


@pytest.mark.asyncio
async def test_generic_soft_delete_rejects_cashboxes():
    """El soft_delete genérico rechaza "cashboxes" (sin account_id directo):
    la única vía es soft_delete_cashbox -> rpc_soft_delete_cashbox."""
    conn = AsyncMock()
    repo = CashboxRepository(conn)

    with pytest.raises(ValueError):
        await repo.soft_delete("cashboxes", CASHBOX_ID, ACCOUNT_ID, USER_ID)

    conn.execute.assert_not_awaited()
