"""v3-soft-delete-policy (OQ2): soft delete de cashboxes.

`cashboxes` no tiene account_id directo — su scope de cuenta es indirecto vía
branch_id → branches.account_id. Por eso queda FUERA de la allowlist del
soft_delete genérico del BaseRepository y su borrado vive acá, resolviendo el
scope con un JOIN a branches (decisión OQ2 del design, resuelta en apply).
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
    conn.execute = AsyncMock(return_value="UPDATE 1")
    return conn


@pytest.mark.asyncio
async def test_list_cashboxes_excludes_soft_deleted(mock_conn):
    repo = CashboxRepository(mock_conn)

    await repo.list_cashboxes(BRANCH_ID)

    sql = mock_conn.fetch.call_args.args[0]
    assert "deleted_at IS NULL" in sql


@pytest.mark.asyncio
async def test_soft_delete_cashbox_scopes_account_via_branch_join(mock_conn):
    """OQ2: el UPDATE resuelve la cuenta vía branches (b.account_id = $2) —
    no existe cashboxes.account_id."""
    repo = CashboxRepository(mock_conn)

    affected = await repo.soft_delete_cashbox(CASHBOX_ID, ACCOUNT_ID, USER_ID)

    assert affected is True
    sql = mock_conn.execute.call_args.args[0]
    assert "UPDATE public.cashboxes" in sql
    assert "deleted_at = now()" in sql
    assert "branches" in sql
    assert "account_id = $2" in sql
    assert "deleted_at IS NULL" in sql
    assert mock_conn.execute.call_args.args[1:] == (CASHBOX_ID, ACCOUNT_ID, USER_ID)


@pytest.mark.asyncio
async def test_soft_delete_cashbox_wrong_account_is_noop(mock_conn):
    """Aislamiento por cuenta: la DB no matchea el JOIN → 0 filas → False."""
    mock_conn.execute = AsyncMock(return_value="UPDATE 0")
    repo = CashboxRepository(mock_conn)

    affected = await repo.soft_delete_cashbox(
        CASHBOX_ID, "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", USER_ID
    )

    assert affected is False


@pytest.mark.asyncio
async def test_generic_soft_delete_rejects_cashboxes():
    """El soft_delete genérico rechaza "cashboxes" (sin account_id directo):
    la única vía es soft_delete_cashbox con el JOIN."""
    conn = AsyncMock()
    repo = CashboxRepository(conn)

    with pytest.raises(ValueError):
        await repo.soft_delete("cashboxes", CASHBOX_ID, ACCOUNT_ID, USER_ID)

    conn.execute.assert_not_awaited()
