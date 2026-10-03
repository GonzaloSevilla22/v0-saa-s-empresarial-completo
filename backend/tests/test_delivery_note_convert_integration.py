"""
remitos-venta (tanda B, tareas 7.1-7.2, "RED que persiste de verdad") — la
conversión del remito en venta contra el Postgres LOCAL real (stack de
`supabase start`, con 20261070000001 aplicada). Marcado
`@pytest.mark.integration`: excluido del gate de CI (`-m "not integration"`);
correr a mano con `-m integration`. La evidencia de CI del esquema es el gate SQL
supabase/tests/test_remito_a_venta.sql.

Por qué además de test_delivery_note_convert.py: aquel prueba el repositorio
contra una conexión doble. Éste llama al MISMO `DeliveryNoteRepository` +
`services.delivery_notes` (y `SalesRepository` / `SalesOrderRepository` para los
read models, el borrado y la edición) que usan los endpoints contra la base
real, con los claims del JWT puestos en la transacción y con `SET LOCAL ROLE
authenticated` como el Paso 2 del pool (la RLS aplica de verdad), y lee lo que
quedó persistido: stock, ledger, orden, caja, cuenta corriente, historial.

La propiedad central: la venta nacida de un remito NO vuelve a mover stock. Se
verifica con el ledger completo (`stock_movements`), no sólo con el saldo.
"""
from __future__ import annotations

import contextlib
import datetime
import uuid
from decimal import Decimal

import asyncpg
import pytest
from fastapi import HTTPException

from backend.repositories.delivery_note_repository import DeliveryNoteRepository
from backend.repositories.sales_order_repository import SalesOrderRepository
from backend.repositories.sales_repository import SalesRepository
from backend.schemas.delivery_notes import (
    DeliveryNoteCancelIn,
    DeliveryNoteConvertIn,
)
from backend.services import delivery_notes as svc
from backend.services import sales as sales_svc
from backend.tests.test_delivery_notes_module_integration import (  # noqa: F401  (fixtures y helpers reutilizados)
    World,
    _as,
    _auth,
    _issue,
    _line,
    _movements,
    _stock,
    _update,
    conn,
    world,
)

pytestmark = pytest.mark.integration


async def _payment_method(conn: asyncpg.Connection, account: uuid.UUID, kind: str) -> uuid.UUID:
    pm = await conn.fetchval(
        "SELECT id FROM public.payment_methods WHERE account_id = $1 AND kind = $2 AND is_active AND deleted_at IS NULL "
        "ORDER BY sort_order LIMIT 1", account, kind)
    assert pm, f"SETUP: handle_new_user no sembró una forma de pago '{kind}'"
    return pm


@contextlib.asynccontextmanager
async def _branch_inactive(conn: asyncpg.Connection, branch: uuid.UUID):
    """Desactiva la sucursal SALTEANDO el guard de baja (P0428: tiene existencias y
    un remito pendiente): lo que se prueba es el guard de la conversión y del
    borrado, que no pueden delegar en él. Se reactiva al salir."""
    await conn.execute("SET session_replication_role = replica")
    try:
        await conn.execute("UPDATE public.branches SET is_active = false WHERE id = $1", branch)
    finally:
        await conn.execute("SET session_replication_role = DEFAULT")
    try:
        yield
    finally:
        await conn.execute("SET session_replication_role = replica")
        try:
            await conn.execute("UPDATE public.branches SET is_active = true WHERE id = $1", branch)
        finally:
            await conn.execute("SET session_replication_role = DEFAULT")


@pytest.fixture
async def cash_session(conn: asyncpg.Connection, world: World):
    """Sesión de caja abierta en la sucursal del remito. `cash_sessions` no tiene
    `account_id` (cuelga de la caja), así que el barrido del `world` no la ve y su
    FK a `auth.users` trabaría el cleanup: la quita este fixture, que se desarma
    ANTES que `world`."""
    branch = world.branch_a
    cashbox = await conn.fetchval("SELECT id FROM public.cashboxes WHERE branch_id = $1 ORDER BY created_at LIMIT 1", branch)
    created_cashbox = cashbox is None
    if created_cashbox:
        cashbox = await conn.fetchval(
            "INSERT INTO public.cashboxes (branch_id, name) VALUES ($1, 'Caja Integ RV') RETURNING id", branch)
    session = await conn.fetchval(
        "INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by) "
        "VALUES ($1, 'open', 0, $2) RETURNING id", cashbox, world.owner_a)
    try:
        yield session
    finally:
        await conn.execute("SET session_replication_role = replica")
        try:
            await conn.execute("DELETE FROM public.cash_movements WHERE session_id = $1", session)
            await conn.execute("DELETE FROM public.cash_sessions WHERE id = $1", session)
            if created_cashbox:
                await conn.execute("DELETE FROM public.cashboxes WHERE id = $1", cashbox)
        finally:
            await conn.execute("SET session_replication_role = DEFAULT")


def _u(value: object) -> uuid.UUID:
    """Los ids llegan como `uuid.UUID`, `asyncpg` UUID o texto según de dónde vengan."""
    return uuid.UUID(str(value))


def _convert_payload(dn: dict, pm: uuid.UUID, **over) -> DeliveryNoteConvertIn:
    data = {"expected_revision": dn["revision"], "payment_method_id": pm}
    data.update(over)
    return DeliveryNoteConvertIn(**data)


async def _convert(conn, w: World, dn: dict, payload: DeliveryNoteConvertIn, key: str, *, user=None, account=None):
    user = user or w.cashier
    async with _as(conn, user, authenticated_role=True):
        return await svc.convert_delivery_note(
            DeliveryNoteRepository(conn), _auth(user), str(account or w.account_a), str(dn["id"]), payload, key, conn=conn,
        )


async def _detail(conn, w: World, dn_id: str, user=None) -> dict:
    user = user or w.owner_a
    async with _as(conn, user, authenticated_role=True):
        return await svc.get_delivery_note(DeliveryNoteRepository(conn), str(w.account_a), dn_id)


async def _effects(conn: asyncpg.Connection, w: World) -> tuple:
    """Huella de lo que una conversión escribe: si falla no debe cambiar."""
    return (
        await conn.fetchval("SELECT count(*) FROM public.sales_orders WHERE account_id = $1", w.account_a),
        await conn.fetchval("SELECT count(*) FROM public.sales WHERE account_id = $1", w.account_a),
        await conn.fetchval("SELECT COALESCE(sum(quantity), 0) FROM public.branch_stock WHERE account_id = $1", w.account_a),
        await conn.fetchval("SELECT count(*) FROM public.stock_movements WHERE account_id = $1", w.account_a),
        await conn.fetchval("SELECT count(*) FROM public.customer_account_movements WHERE account_id = $1", w.account_a),
        await conn.fetchval("SELECT count(*) FROM public.cash_movements cm JOIN public.cash_sessions cs ON cs.id = cm.session_id "
                            "JOIN public.cashboxes cb ON cb.id = cs.cashbox_id JOIN public.branches b ON b.id = cb.branch_id "
                            "WHERE b.account_id = $1", w.account_a),
        await conn.fetchval("SELECT count(*) FROM public.events WHERE account_id = $1", w.account_a),
        await conn.fetchval("SELECT count(*) FROM public.document_status_history WHERE account_id = $1", w.account_a),
        await conn.fetchval("SELECT string_agg(status || revision::text, ',' ORDER BY id) FROM public.delivery_notes WHERE account_id = $1", w.account_a),
    )


async def _sale_movements(conn: asyncpg.Connection, w: World, operation_id: str, order_id: str) -> int:
    """Movimientos de stock que apuntan a la venta o a su orden: tiene que ser 0
    (el remito es el único dueño del movimiento de esa mercadería)."""
    return await conn.fetchval(
        "SELECT count(*) FROM public.stock_movements WHERE account_id = $1 "
        "AND reference_id = ANY($2::uuid[])", w.account_a, [uuid.UUID(operation_id), uuid.UUID(order_id)])


# ══════════════════════════════════════════════════════════════════════════════
# La conversión: efectos, stock idéntico, replay
# ══════════════════════════════════════════════════════════════════════════════

async def test_convert_on_credit_creates_the_sale_without_touching_stock_and_replays(conn, world: World):
    w = world
    dn = await _issue(conn, w, [_line(w.product_a, "3", "1000", "3000")])
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(7)
    ledger_before = len(await _movements(conn, dn["id"]))
    pm = await _payment_method(conn, w.account_a, "credit")

    result = await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rv-convert-1")

    assert result["replayed"] is False and result["delivery_note_number"] == 1
    assert result["delivery_note_number_label"] == "R-00000001"
    assert Decimal(str(result["total"])) == Decimal("3000")

    # el stock NO vuelve a bajar y el ledger no suma una sola fila
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(7)
    assert len(await _movements(conn, dn["id"])) == ledger_before
    assert await _sale_movements(conn, w, result["operation_id"], result["sales_order_id"]) == 0
    assert await conn.fetchval(
        "SELECT count(*) FROM public.stock_movements WHERE account_id = $1 AND product_id = $2", w.account_a, w.product_a) == 1

    # la orden nace del remito, en su sucursal y con su cliente, ya confirmada
    order = await conn.fetchrow("SELECT * FROM public.sales_orders WHERE id = $1", uuid.UUID(result["sales_order_id"]))
    assert order["status"] == "confirmed" and order["source_delivery_note_id"] == _u(dn["id"])
    assert order["branch_id"] == w.branch_a and order["client_id"] == w.client_a
    assert str(order["sale_operation_id"]) == result["operation_id"]

    # la venta tiene la línea del remito con su precio y su snapshot
    sale = await conn.fetchrow(
        "SELECT product_id, quantity, amount, total, branch_id FROM public.sales WHERE operation_id = $1",
        uuid.UUID(result["operation_id"]))
    assert sale["product_id"] == w.product_a and Decimal(sale["quantity"]) == 3
    assert Decimal(sale["amount"]) == 1000 and Decimal(sale["total"]) == 3000 and sale["branch_id"] == w.branch_a
    assert await conn.fetchval(
        "SELECT si.name_snapshot FROM public.sale_items si JOIN public.sales s ON s.id = si.sale_id "
        "WHERE s.operation_id = $1", uuid.UUID(result["operation_id"])) == "__integ_rv_producto_a__"

    # el remito queda converted SIN subir la revisión, con los dos historiales
    assert await conn.fetchval("SELECT status FROM public.delivery_notes WHERE id = $1", _u(dn["id"])) == "converted"
    assert await conn.fetchval("SELECT revision FROM public.delivery_notes WHERE id = $1", _u(dn["id"])) == dn["revision"]
    assert [r["to_status"] for r in await conn.fetch(
        "SELECT to_status FROM public.document_status_history WHERE document_type = 'delivery_note_sale' "
        "AND document_id = $1 ORDER BY occurred_at, id", _u(dn["id"]))] == ["issued", "converted"]

    # a crédito: cargo en cuenta corriente, sin caja
    assert await conn.fetchval(
        "SELECT count(*) FROM public.customer_account_movements WHERE account_id = $1", w.account_a) == 1

    # el detalle del remito apunta a la venta viva
    detail = await _detail(conn, w, str(dn["id"]))
    assert detail["status"] == "converted"
    assert str(detail["converted_sales_order_id"]) == result["sales_order_id"]
    assert str(detail["converted_operation_id"]) == result["operation_id"]
    after_first = await _effects(conn, w)

    # reintento con la misma clave: replay sin efectos
    again = await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rv-convert-1")
    assert again["replayed"] is True and again["sales_order_id"] == result["sales_order_id"]
    assert await _effects(conn, w) == after_first

    # otra clave sobre el ya convertido: el estado manda
    with pytest.raises(HTTPException) as info:
        await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rv-convert-2")
    assert (info.value.status_code, info.value.code) == (409, "delivery_note_invalid_state")
    assert await _effects(conn, w) == after_first


async def test_convert_in_cash_posts_the_session_movement_and_still_leaves_stock_alone(
    conn, world: World, cash_session
):
    w = world
    dn = await _issue(conn, w, [_line(w.product_a, "2", "1500", "3000")])
    session = cash_session
    pm = await _payment_method(conn, w.account_a, "cash")

    result = await _convert(conn, w, dn, _convert_payload(dn, pm, cash_session_id=session), "integ-rv-cash")

    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(8)
    assert await _sale_movements(conn, w, result["operation_id"], result["sales_order_id"]) == 0
    movements = await conn.fetch(
        "SELECT movement_type, amount FROM public.cash_movements WHERE session_id = $1", session)
    assert [(m["movement_type"], Decimal(m["amount"])) for m in movements] == [("sale", Decimal(3000))]
    assert await conn.fetchval(
        "SELECT count(*) FROM public.customer_account_movements WHERE account_id = $1", w.account_a) == 0


async def test_convert_in_cash_without_a_session_is_rejected_and_changes_nothing(conn, world: World):
    w = world
    dn = await _issue(conn, w, [_line(w.product_a, "2", "1500", "3000")])
    pm = await _payment_method(conn, w.account_a, "cash")
    before = await _effects(conn, w)

    with pytest.raises(HTTPException) as info:
        await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rv-cash-nosession")

    assert info.value.status_code == 400 and info.value.code == "cash_requires_session"
    assert await _effects(conn, w) == before


async def test_convert_with_a_stale_revision_is_409_delivery_note_changed(conn, world: World):
    w = world
    dn = await _issue(conn, w, [_line(w.product_a, "1", "1000", "1000")])
    pm = await _payment_method(conn, w.account_a, "credit")
    before = await _effects(conn, w)

    with pytest.raises(HTTPException) as info:
        await _convert(conn, w, dn, _convert_payload(dn, pm, expected_revision=dn["revision"] + 1), "integ-rv-rev")

    assert (info.value.status_code, info.value.code) == (409, "delivery_note_changed")
    assert await _effects(conn, w) == before


async def test_the_price_that_travels_is_the_notes_even_after_the_catalog_changes(conn, world: World):
    """Precios y snapshots del remito: lo que se entregó es lo que se vende, aunque
    después se renombre el producto o se remarque su precio de lista."""
    w = world
    dn = await _issue(conn, w, [_line(w.product_a, "2", "750", "1500")])
    await conn.execute("UPDATE public.products SET name = 'Renombrado', price = 9999, cost = 8888 WHERE id = $1", w.product_a)
    pm = await _payment_method(conn, w.account_a, "credit")

    result = await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rv-price")

    assert Decimal(str(result["total"])) == Decimal("1500")
    sale = await conn.fetchrow(
        "SELECT amount, total FROM public.sales WHERE operation_id = $1", uuid.UUID(result["operation_id"]))
    assert Decimal(sale["amount"]) == 750 and Decimal(sale["total"]) == 1500
    assert await conn.fetchval(
        "SELECT si.name_snapshot FROM public.sale_items si JOIN public.sales s ON s.id = si.sale_id "
        "WHERE s.operation_id = $1", uuid.UUID(result["operation_id"])) == "__integ_rv_producto_a__"


# ══════════════════════════════════════════════════════════════════════════════
# Roles, tenencia, idempotencia cruzada
# ══════════════════════════════════════════════════════════════════════════════

async def test_roles_tenancy_and_foreign_payment_method(conn, world: World):
    w = world
    dn = await _issue(conn, w, [_line(w.product_a, "1", "1000", "1000")])
    pm = await _payment_method(conn, w.account_a, "credit")
    pm_b = await _payment_method(conn, w.account_b, "credit")
    before = await _effects(conn, w)

    # el rol de depósito emite pero no convierte
    with pytest.raises(HTTPException) as info:
        await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rv-r1", user=w.stocker)
    assert (info.value.status_code, info.value.code) == (403, "insufficient_role")

    # un remito ajeno es indistinguible de uno inexistente
    with pytest.raises(HTTPException) as info:
        await _convert(conn, w, dn, _convert_payload(dn, pm_b), "integ-rv-r2", user=w.owner_b, account=w.account_b)
    assert (info.value.status_code, info.value.code) == (404, "delivery_note_not_found")

    # la forma de pago de otra cuenta no se acepta
    with pytest.raises(HTTPException) as info:
        await _convert(conn, w, dn, _convert_payload(dn, pm_b), "integ-rv-r3")
    assert info.value.status_code == 404

    assert await _effects(conn, w) == before


async def test_the_same_key_on_another_note_is_409_idempotency_key_conflict(conn, world: World):
    w = world
    dn1 = await _issue(conn, w, [_line(w.product_a, "1", "1000", "1000")])
    dn2 = await _issue(conn, w, [_line(w.product_b, "1", "700", "700")])
    pm = await _payment_method(conn, w.account_a, "credit")
    await _convert(conn, w, dn1, _convert_payload(dn1, pm), "integ-rv-shared")
    after_first = await _effects(conn, w)

    with pytest.raises(HTTPException) as info:
        await _convert(conn, w, dn2, _convert_payload(dn2, pm), "integ-rv-shared")

    assert (info.value.status_code, info.value.code) == (409, "idempotency_key_conflict")
    assert await _effects(conn, w) == after_first
    assert await conn.fetchval("SELECT status FROM public.delivery_notes WHERE id = $1", _u(dn2["id"])) == "issued"


async def test_a_deleted_client_and_an_inactive_branch_block_the_conversion_with_zero_effects(conn, world: World):
    w = world
    dn = await _issue(conn, w, [_line(w.product_a, "1", "1000", "1000")])
    pm = await _payment_method(conn, w.account_a, "credit")
    before = await _effects(conn, w)

    await conn.execute("UPDATE public.clients SET deleted_at = now() WHERE id = $1", w.client_a)
    with pytest.raises(HTTPException) as info:
        await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rv-client")
    assert (info.value.status_code, info.value.code) == (404, "delivery_note_client_unavailable")
    await conn.execute("UPDATE public.clients SET deleted_at = NULL WHERE id = $1", w.client_a)

    async with _branch_inactive(conn, w.branch_a):
        with pytest.raises(HTTPException) as info:
            await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rv-branch")
        assert (info.value.status_code, info.value.code) == (422, "branch_closed")

    assert await _effects(conn, w) == before


# ══════════════════════════════════════════════════════════════════════════════
# Read models de ventas y órdenes
# ══════════════════════════════════════════════════════════════════════════════

async def test_sales_and_orders_read_models_expose_the_origin_note_and_the_reason(conn, world: World):
    w = world
    dn = await _issue(conn, w, [_line(w.product_a, "2", "1000", "2000"), _line(w.product_b, "1", "700", "700")])
    pm = await _payment_method(conn, w.account_a, "credit")
    result = await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rv-rm")

    # una venta suelta (formulario/POS): no debe heredar nada
    plain_op = uuid.uuid4()
    await conn.execute(
        "INSERT INTO public.sales (user_id, account_id, product_id, amount, quantity, total, currency, date, operation_id) "
        "VALUES ($1, $2, $3, 1000, 1, 1000, 'ARS', now(), $4)", w.owner_a, w.account_a, w.product_a, plain_op)

    async with _as(conn, w.owner_a, authenticated_role=True):
        rows, total = await SalesRepository(conn).list_paginated_by_operation(str(w.account_a), 0, 50)
        orders = await SalesOrderRepository(conn).list_orders(str(w.account_a))
        order = await SalesOrderRepository(conn).get_order(result["sales_order_id"], str(w.account_a))
    rows = [dict(r) for r in rows]

    assert total == 2
    converted = [r for r in rows if str(r["operation_id"]) == result["operation_id"]]
    plain = [r for r in rows if r["operation_id"] == plain_op]
    assert len(converted) == 2 and len(plain) == 1, "el JOIN al remito no debe duplicar ni perder filas"
    assert {str(r["source_delivery_note_id"]) for r in converted} == {str(dn["id"])}
    assert {r["source_delivery_note_number"] for r in converted} == {1}
    assert {r["edit_locked_reason"] for r in converted} == {"delivery_note_sale_locked"}
    assert plain[0]["source_delivery_note_id"] is None and plain[0]["source_delivery_note_number"] is None
    assert plain[0]["edit_locked_reason"] is None

    mine = [dict(o) for o in orders if str(o["id"]) == result["sales_order_id"]]
    assert len(mine) == 1 and mine[0]["source_delivery_note_number"] == 1
    assert str(mine[0]["source_delivery_note_id"]) == str(dn["id"])
    assert dict(order)["source_delivery_note_number"] == 1


async def test_the_origin_join_requires_the_same_account(conn, world: World):
    """El cruce con el remito exige la misma cuenta: aunque `source_delivery_note_id`
    apuntara a un remito de otra, nunca se muestra un número ajeno."""
    w = world
    dn = await _issue(conn, w, [_line(w.product_a, "1", "1000", "1000")])
    pm = await _payment_method(conn, w.account_a, "credit")
    result = await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rv-xacct")
    await conn.execute("UPDATE public.delivery_notes SET account_id = $1 WHERE id = $2", w.account_b, _u(dn["id"]))

    async with _as(conn, w.owner_a, authenticated_role=True):
        order = await SalesOrderRepository(conn).get_order(result["sales_order_id"], str(w.account_a))

    assert order["source_delivery_note_number"] is None


# ══════════════════════════════════════════════════════════════════════════════
# Borrar y editar la venta nacida de un remito (D9)
# ══════════════════════════════════════════════════════════════════════════════

async def _delete_sale(conn, w: World, operation_id: str, *, user=None):
    user = user or w.owner_a
    async with _as(conn, user, authenticated_role=True):
        await sales_svc.delete_sale_operation(SalesRepository(conn), _auth(user), str(w.account_a), operation_id)


async def test_deleting_the_sale_does_not_return_stock_and_reopens_the_note_for_a_new_conversion(conn, world: World):
    w = world
    dn = await _issue(conn, w, [_line(w.product_a, "3", "1000", "3000")])
    pm = await _payment_method(conn, w.account_a, "credit")
    first = await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rv-del-1")
    ledger = await conn.fetchval("SELECT count(*) FROM public.stock_movements WHERE account_id = $1", w.account_a)

    await _delete_sale(conn, w, first["operation_id"])

    # el stock NO vuelve (la mercadería quedó entregada) y el ledger no suma reversas
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(7)
    assert await conn.fetchval("SELECT count(*) FROM public.stock_movements WHERE account_id = $1", w.account_a) == ledger
    assert await conn.fetchval("SELECT count(*) FROM public.sales WHERE operation_id = $1", uuid.UUID(first["operation_id"])) == 0
    assert await conn.fetchval(
        "SELECT status FROM public.sales_orders WHERE id = $1", uuid.UUID(first["sales_order_id"])) == "canceled"
    # el remito vuelve a pendiente, con el motivo en el historial
    assert await conn.fetchval("SELECT status FROM public.delivery_notes WHERE id = $1", _u(dn["id"])) == "issued"
    last = await conn.fetchrow(
        "SELECT from_status, to_status, reason FROM public.document_status_history "
        "WHERE document_type = 'delivery_note_sale' AND document_id = $1 ORDER BY occurred_at DESC, id DESC LIMIT 1",
        _u(dn["id"]))
    assert (last["from_status"], last["to_status"]) == ("converted", "issued")
    assert first["operation_id"] in (last["reason"] or "")
    # la deuda de la venta borrada se compensó
    assert await conn.fetchval(
        "SELECT COALESCE(sum(amount), 0) FROM public.customer_account_movements WHERE account_id = $1", w.account_a) == 0
    detail = await _detail(conn, w, str(dn["id"]))
    assert detail["status"] == "issued"
    assert detail["converted_sales_order_id"] is None and detail["converted_operation_id"] is None

    # reconvertir: una venta nueva, y el stock sigue idéntico
    again = await _convert(conn, w, detail, _convert_payload(detail, pm), "integ-rv-del-2")
    assert again["replayed"] is False and again["sales_order_id"] != first["sales_order_id"]
    assert await conn.fetchval("SELECT status FROM public.delivery_notes WHERE id = $1", _u(dn["id"])) == "converted"
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(7)


async def test_deleting_with_the_notes_branch_deactivated_is_422_with_zero_effects(conn, world: World):
    w = world
    dn = await _issue(conn, w, [_line(w.product_a, "3", "1000", "3000")])
    pm = await _payment_method(conn, w.account_a, "credit")
    result = await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rv-del-branch")
    before = await _effects(conn, w)

    async with _branch_inactive(conn, w.branch_a):
        with pytest.raises(asyncpg.PostgresError) as info:
            await _delete_sale(conn, w, result["operation_id"])

        assert info.value.sqlstate == "P0422" and "delivery_note_branch_inactive" in str(info.value)
        assert await _effects(conn, w) == before
    assert await conn.fetchval("SELECT status FROM public.delivery_notes WHERE id = $1", _u(dn["id"])) == "converted"


async def test_editing_the_sale_is_locked_and_changes_neither_stock_nor_ledger(conn, world: World):
    w = world
    dn = await _issue(conn, w, [_line(w.product_a, "3", "1000", "3000")])
    pm = await _payment_method(conn, w.account_a, "other")  # sin dinero posteado: ningún guard de dinero frena
    result = await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rv-edit")
    sale_ids = [r["id"] for r in await conn.fetch(
        "SELECT id FROM public.sales WHERE operation_id = $1", uuid.UUID(result["operation_id"]))]
    before = await _effects(conn, w)

    with pytest.raises(asyncpg.PostgresError) as info:
        # quien convirtió (el cajero): editar una venta ajena corta antes, con P0403
        async with _as(conn, w.cashier, authenticated_role=True):
            await SalesRepository(conn).update_operation(
                [str(i) for i in sale_ids], None, datetime.date.today(), "ARS",
                [{"product_id": str(w.product_a), "quantity": "1", "amount": "1000"}])

    assert info.value.sqlstate == "P0423" and "delivery_note_sale_locked" in str(info.value)
    assert await _effects(conn, w) == before
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(7)


async def test_cancelling_a_converted_note_is_locked_until_the_sale_is_deleted(conn, world: World):
    w = world
    dn = await _issue(conn, w, [_line(w.product_a, "3", "1000", "3000")])
    pm = await _payment_method(conn, w.account_a, "credit")
    result = await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rv-cancel")

    async def cancel(user):
        async with _as(conn, user, authenticated_role=True):
            return await svc.cancel_delivery_note(
                DeliveryNoteRepository(conn), _auth(user), str(w.account_a), str(dn["id"]),
                DeliveryNoteCancelIn(revision=dn["revision"], reason="Se devolvió la mercadería"), conn=conn)

    with pytest.raises(HTTPException) as info:
        await cancel(w.admin)
    assert (info.value.status_code, info.value.code) == (409, "delivery_note_locked_converted")
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(7)

    # primero se borra la venta; recién entonces el remito se puede anular y repone el stock
    await _delete_sale(conn, w, result["operation_id"])
    cancelled = await cancel(w.admin)
    assert cancelled["status"] == "canceled"
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(10)


async def test_editing_the_note_after_reopening_and_reconverting_uses_the_new_lines(conn, world: World):
    """El ciclo completo del flujo "corregir": borrar la venta, editar el remito
    (par espejo en el ledger) y volver a convertir con lo corregido."""
    w = world
    dn = await _issue(conn, w, [_line(w.product_a, "3", "1000", "3000")])
    pm = await _payment_method(conn, w.account_a, "credit")
    first = await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rv-cycle-1")
    await _delete_sale(conn, w, first["operation_id"])
    reopened = await _detail(conn, w, str(dn["id"]))

    edited = await _update(conn, w, str(dn["id"]), reopened["revision"], [_line(w.product_a, "2", "1000", "2000")])
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(8)

    second = await _convert(conn, w, edited, _convert_payload(edited, pm), "integ-rv-cycle-2")
    assert Decimal(str(second["total"])) == Decimal("2000")
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(8)
    sale = await conn.fetchrow(
        "SELECT quantity, total FROM public.sales WHERE operation_id = $1", uuid.UUID(second["operation_id"]))
    assert Decimal(sale["quantity"]) == 2 and Decimal(sale["total"]) == 2000
