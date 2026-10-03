"""remitos-compra (tanda A, task 2.5, OQ-RC11) — un proveedor con remitos de
compra pendientes no se borra.

El soft delete saca al proveedor de todas las listas: sus remitos pendientes (y
la deuda futura que la conversión a crédito le carga a él) quedarían
inalcanzables. Es la misma clase de deuda que el saldo abierto de su cuenta
corriente (qa-integral-modulos G9/D7), así que reutiliza el MISMO `409 P0409`
(sin código nuevo): el service cuenta los remitos `issued` de sentido compra del
proveedor ANTES del soft delete y bloquea con el conteo en el `detail`.

Strict TDD: escrito antes que `SupplierRepository.count_pending_purchase_delivery_notes`
y que su uso en `delete_supplier`. Molde: `test_supplier_delete_balance_guard.py`.

Spec: openspec/changes/remitos-compra/specs/supplier-directory/spec.md
("Un proveedor con remitos de compra pendientes no se borra").
"""
from __future__ import annotations

from decimal import Decimal
from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import make_token
from backend.tests.test_suppliers_api import SUPPLIER_ID, SUPPLIER_ROW


def _delete_headers() -> dict[str, str]:
    return {"Authorization": f"Bearer {make_token({'role': 'user'})}"}


def _wire(conn, *, pending, balance=None):
    """`fetchrow` atiende el proveedor y su saldo (como en el guard de saldo);
    `fetchval` atiende el conteo de remitos de compra pendientes."""
    conn.fetchrow = AsyncMock(side_effect=[SUPPLIER_ROW, None if balance is None else {"balance": balance}])
    conn.fetchval = AsyncMock(return_value=pending)
    conn.execute = AsyncMock(return_value="UPDATE 1")


def _soft_deletes(conn):
    return [c for c in conn.execute.call_args_list if "UPDATE suppliers" in c.args[0]]


@pytest.mark.parametrize(
    "pending,message",
    [
        (1, "El proveedor tiene 1 remito de compra pendiente: convertilo o anulalo antes de borrarlo"),
        (2, "El proveedor tiene 2 remitos de compra pendientes: convertilos o anulalos antes de borrarlo"),
        (13, "El proveedor tiene 13 remitos de compra pendientes: convertilos o anulalos antes de borrarlo"),
    ],
)
async def test_a_supplier_with_pending_purchase_delivery_notes_is_a_409_with_the_count(
    async_client, mock_pool, pending, message
):
    pool, conn = mock_pool
    _wire(conn, pending=pending)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(f"/suppliers/{SUPPLIER_ID}", headers=_delete_headers())

    assert resp.status_code == 409
    assert resp.headers["content-type"].startswith("application/problem+json")
    body = resp.json()
    # el MISMO conflicto que el saldo abierto: ningún código nuevo
    assert body["code"] == "P0409"
    assert message in body["detail"]
    assert _soft_deletes(conn) == [], "el proveedor sigue vivo"


@pytest.mark.parametrize("pending", [0, None])
async def test_without_pending_notes_the_supplier_is_deleted_as_before(async_client, mock_pool, pending):
    """Remitos convertidos, anulados o de otra cuenta no cuentan (el conteo sólo
    trae `issued` de compra de ESTA cuenta y proveedor): 0 o sin fila → borra."""
    pool, conn = mock_pool
    _wire(conn, pending=pending, balance=Decimal("0.00"))
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(f"/suppliers/{SUPPLIER_ID}", headers=_delete_headers())

    assert resp.status_code == 204
    assert len(_soft_deletes(conn)) == 1


async def test_the_balance_guard_still_goes_first(async_client, mock_pool):
    """CONTROL: con saldo abierto el 409 es el del saldo (monto en el detail), y el
    conteo de remitos ni se consulta."""
    pool, conn = mock_pool
    _wire(conn, pending=3, balance=Decimal("116550.00"))
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(f"/suppliers/{SUPPLIER_ID}", headers=_delete_headers())

    assert resp.status_code == 409
    assert "116.550,00" in resp.json()["detail"]
    conn.fetchval.assert_not_awaited()
    assert _soft_deletes(conn) == []


async def test_a_missing_supplier_is_still_a_404_before_any_count(async_client, mock_pool):
    pool, conn = mock_pool
    conn.fetchrow = AsyncMock(return_value=None)
    conn.fetchval = AsyncMock(return_value=5)
    conn.execute = AsyncMock(return_value="UPDATE 1")
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(f"/suppliers/{SUPPLIER_ID}", headers=_delete_headers())

    assert resp.status_code == 404
    conn.fetchval.assert_not_awaited()


async def test_the_count_is_scoped_to_account_supplier_direction_and_status(mock_pool):
    """Tenencia y alcance: cuenta, proveedor, sentido compra y estado `issued`."""
    from backend.repositories.supplier_repository import SupplierRepository

    _pool, conn = mock_pool
    conn.fetchval = AsyncMock(return_value=2)
    repo = SupplierRepository(conn)

    assert await repo.count_pending_purchase_delivery_notes(SUPPLIER_ID, "acct-1") == 2

    sql = conn.fetchval.call_args.args[0]
    assert "delivery_notes" in sql
    assert "supplier_id = $1" in sql and "account_id = $2" in sql
    assert "direction = 'purchase'" in sql and "status = 'issued'" in sql
    assert conn.fetchval.call_args.args[1:] == (SUPPLIER_ID, "acct-1")


async def test_an_empty_count_is_zero(mock_pool):
    from backend.repositories.supplier_repository import SupplierRepository

    _pool, conn = mock_pool
    conn.fetchval = AsyncMock(return_value=None)
    assert await SupplierRepository(conn).count_pending_purchase_delivery_notes(SUPPLIER_ID, "acct-1") == 0
