"""qa-integral-modulos (G9, tasks 9.1-9.2) — guard de baja de proveedor con
saldo abierto (H10, OQ-1 resuelta por su recomendación: bloquear).

El QA del 2026-08-30 borró un proveedor con $116.550 de deuda en cuenta
corriente sin ninguna advertencia: el soft delete lo saca de todas las listas
y la cuenta corriente (solo alcanzable desde la fila del proveedor) queda
inalcanzable — la deuda se vuelve invisible.

Fix (D7): el service consulta `supplier_accounts.balance` ANTES del soft
delete y bloquea con 409 RFC 7807 (`code=P0409`, ya mapeado — sin ERRCODE
nuevo) cuando el saldo es distinto de 0, con el monto en el `detail` para que
el diálogo del frontend lo muestre. Saldo 0 o sin cuenta siguen borrando.
"""
from __future__ import annotations

from decimal import Decimal
from unittest.mock import AsyncMock, patch

from backend.tests.conftest import make_token
from backend.tests.test_suppliers_api import SUPPLIER_ID, SUPPLIER_ROW


def _delete_headers() -> dict[str, str]:
    return {"Authorization": f"Bearer {make_token({'role': 'user'})}"}


async def test_delete_supplier_with_open_balance_returns_409(async_client, mock_pool):
    """RED 9.1: saldo ≠ 0 → 409 con el saldo en el detail; el soft delete NO corre."""
    pool, conn = mock_pool
    conn.fetchrow = AsyncMock(
        side_effect=[
            SUPPLIER_ROW,                          # get_by_id del service
            {"balance": Decimal("116550.00")},     # supplier_accounts.balance
        ]
    )
    conn.execute = AsyncMock(return_value="UPDATE 1")
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/suppliers/{SUPPLIER_ID}", headers=_delete_headers()
        )

    assert resp.status_code == 409
    body = resp.json()
    assert body["code"] == "P0409"
    # El monto viaja en el detail (formato AR) para que el diálogo lo muestre.
    assert "116.550,00" in body["detail"]
    # No se soft-deleteó nada.
    soft_deletes = [
        c for c in conn.execute.call_args_list if "UPDATE suppliers" in c.args[0]
    ]
    assert soft_deletes == []


async def test_delete_supplier_with_negative_balance_also_blocks(async_client, mock_pool):
    """TRIANGULATE: saldo a favor (negativo) también es saldo abierto → 409."""
    pool, conn = mock_pool
    conn.fetchrow = AsyncMock(
        side_effect=[SUPPLIER_ROW, {"balance": Decimal("-500.00")}]
    )
    conn.execute = AsyncMock(return_value="UPDATE 1")
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/suppliers/{SUPPLIER_ID}", headers=_delete_headers()
        )

    assert resp.status_code == 409
    assert resp.json()["code"] == "P0409"


async def test_delete_supplier_with_zero_balance_still_deletes(async_client, mock_pool):
    """TRIANGULATE: saldo saldado (0) sigue borrando → 204."""
    pool, conn = mock_pool
    conn.fetchrow = AsyncMock(
        side_effect=[SUPPLIER_ROW, {"balance": Decimal("0.00")}]
    )
    conn.execute = AsyncMock(return_value="UPDATE 1")
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/suppliers/{SUPPLIER_ID}", headers=_delete_headers()
        )

    assert resp.status_code == 204
    soft_deletes = [
        c for c in conn.execute.call_args_list if "UPDATE suppliers" in c.args[0]
    ]
    assert len(soft_deletes) == 1


async def test_delete_supplier_without_account_still_deletes(async_client, mock_pool):
    """TRIANGULATE: proveedor sin cuenta corriente (fila ausente) sigue borrando."""
    pool, conn = mock_pool
    conn.fetchrow = AsyncMock(side_effect=[SUPPLIER_ROW, None])
    conn.execute = AsyncMock(return_value="UPDATE 1")
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/suppliers/{SUPPLIER_ID}", headers=_delete_headers()
        )

    assert resp.status_code == 204


async def test_balance_query_is_scoped_to_supplier_and_account(mock_pool):
    """El saldo se consulta scopeado a supplier_id Y account_id (tenencia)."""
    from backend.repositories.supplier_repository import SupplierRepository

    _pool, conn = mock_pool
    conn.fetchrow = AsyncMock(return_value=None)
    repo = SupplierRepository(conn)

    await repo.get_account_balance(SUPPLIER_ID, "acct-1")

    sql = conn.fetchrow.call_args.args[0]
    assert "supplier_accounts" in sql
    assert "supplier_id" in sql
    assert "account_id" in sql
