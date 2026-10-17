"""
remitos-compra (tanda B, tareas 7.1-7.2, "RED que persiste de verdad") — la
conversión del remito de compra en compra contra el Postgres LOCAL real (stack de
`supabase start`, con 20261081000001 aplicada). Marcado
`@pytest.mark.integration`: excluido del gate de CI (`-m "not integration"`);
correr a mano con `-m integration`. La evidencia de CI del esquema es el gate SQL
supabase/tests/test_remito_a_compra.sql.

Por qué además de test_delivery_note_purchase_convert.py: aquel prueba el
repositorio contra una conexión doble. Éste llama al MISMO `DeliveryNoteRepository`
+ `services.delivery_notes` (y `PurchaseRepository` / `services.purchases` para el
read model, el borrado y la edición) que usan los endpoints contra la base real,
con los claims del JWT puestos en la transacción y con `SET LOCAL ROLE
authenticated` como el Paso 2 del pool (la RLS aplica de verdad), y lee lo que
quedó persistido: stock, ledger, compra, caja, cuenta corriente del proveedor,
historial.

La propiedad central: la compra nacida de un remito NO vuelve a SUMAR stock (el
remito ya lo sumó al recibir). Se verifica con el ledger completo
(`stock_movements`), no sólo con el saldo. Y el borrado de esa compra no lo
resta: para sacar la mercadería se anula el remito.
"""
from __future__ import annotations

import datetime
import uuid
from decimal import Decimal

import asyncpg
import pytest
from fastapi import HTTPException

from backend.repositories.delivery_note_repository import DeliveryNoteRepository
from backend.repositories.purchase_repository import PurchaseRepository
from backend.schemas.delivery_notes import DeliveryNoteCancelIn, PurchaseDeliveryNoteConvertIn
from backend.services import delivery_notes as svc
from backend.services import purchases as purchases_svc
from backend.tests.test_delivery_note_convert_integration import (  # noqa: F401  (fixtures y helpers reutilizados)
    _branch_inactive,
    _payment_method,
    _u,
    cash_session,
)
from backend.tests.test_delivery_notes_module_integration import (  # noqa: F401
    World,
    _as,
    _auth,
    _consume,
    _line,
    _movements,
    _purchase_update,
    _receive,
    _stock,
    conn,
    pworld,
    world,
)

pytestmark = pytest.mark.integration


def _convert_payload(dn: dict, pm: uuid.UUID, **over) -> PurchaseDeliveryNoteConvertIn:
    data = {"expected_revision": dn["revision"], "payment_method_id": pm}
    data.update(over)
    return PurchaseDeliveryNoteConvertIn(**data)


async def _convert(conn, w: World, dn: dict, payload: PurchaseDeliveryNoteConvertIn, key: str, *, user=None, account=None):
    user = user or w.stocker
    async with _as(conn, user, authenticated_role=True):
        return await svc.convert_delivery_note_to_purchase(
            DeliveryNoteRepository(conn), _auth(user), str(account or w.account_a), str(dn["id"]), payload, key, conn=conn,
        )


async def _detail(conn, w: World, dn_id: str, user=None) -> dict:
    user = user or w.owner_a
    async with _as(conn, user, authenticated_role=True):
        return await svc.get_delivery_note(DeliveryNoteRepository(conn), str(w.account_a), dn_id)


async def _effects(conn: asyncpg.Connection, w: World) -> tuple:
    """Huella de lo que una conversión, un borrado o una edición escriben: si
    falla no debe cambiar."""
    return (
        await conn.fetchval("SELECT count(*) FROM public.purchases WHERE account_id = $1", w.account_a),
        await conn.fetchval("SELECT count(*) FROM public.purchase_items WHERE account_id = $1", w.account_a),
        await conn.fetchval("SELECT COALESCE(sum(quantity), 0) FROM public.branch_stock WHERE account_id = $1", w.account_a),
        await conn.fetchval("SELECT count(*) FROM public.stock_movements WHERE account_id = $1", w.account_a),
        await conn.fetchval("SELECT count(*) FROM public.supplier_account_movements WHERE account_id = $1", w.account_a),
        await conn.fetchval("SELECT count(*) FROM public.cash_movements cm JOIN public.cash_sessions cs ON cs.id = cm.session_id "
                            "JOIN public.cashboxes cb ON cb.id = cs.cashbox_id JOIN public.branches b ON b.id = cb.branch_id "
                            "WHERE b.account_id = $1", w.account_a),
        await conn.fetchval("SELECT count(*) FROM public.events WHERE account_id = $1", w.account_a),
        await conn.fetchval("SELECT count(*) FROM public.document_status_history WHERE account_id = $1", w.account_a),
        await conn.fetchval("SELECT string_agg(status || revision::text, ',' ORDER BY id) FROM public.delivery_notes WHERE account_id = $1", w.account_a),
    )


async def _purchase_moves(conn: asyncpg.Connection, w: World, operation_id: str) -> int:
    """Movimientos de stock que apuntan a alguna fila de la compra: tiene que ser 0
    (el remito es el único dueño del movimiento de esa mercadería)."""
    return await conn.fetchval(
        "SELECT count(*) FROM public.stock_movements WHERE account_id = $1 AND reference_id IN "
        "(SELECT id FROM public.purchases WHERE operation_id = $2)", w.account_a, uuid.UUID(operation_id))


async def _supplier_balance(conn: asyncpg.Connection, supplier: uuid.UUID) -> Decimal:
    value = await conn.fetchval("SELECT COALESCE((SELECT balance FROM public.supplier_accounts WHERE supplier_id = $1), 0)", supplier)
    return Decimal(value)


async def _delete_purchase(conn, w: World, operation_id: str, *, user=None):
    user = user or w.owner_a
    async with _as(conn, user, authenticated_role=True):
        await purchases_svc.delete_purchase_operation(
            PurchaseRepository(conn), _auth(user), str(w.account_a), operation_id, conn=conn
        )


# ══════════════════════════════════════════════════════════════════════════════
# La conversión: efectos, stock idéntico, replay
# ══════════════════════════════════════════════════════════════════════════════

async def test_convert_on_credit_creates_the_purchase_without_touching_stock_and_replays(conn, pworld: World):
    w = pworld
    dn = await _receive(conn, w, [_line(w.product_a, "3", "100", "300")])
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(13)
    ledger_before = len(await _movements(conn, dn["id"]))
    pm = await _payment_method(conn, w.account_a, "credit")

    result = await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rcb-convert-1")

    assert result["replayed"] is False and result["delivery_note_number"] == 1
    assert result["delivery_note_number_label"] == "RC-00000001"
    assert Decimal(str(result["total"])) == Decimal("300")

    # el stock NO vuelve a subir y el ledger no suma una sola fila
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(13)
    assert len(await _movements(conn, dn["id"])) == ledger_before
    assert await _purchase_moves(conn, w, result["operation_id"]) == 0
    assert await conn.fetchval(
        "SELECT count(*) FROM public.stock_movements WHERE account_id = $1 AND product_id = $2", w.account_a, w.product_a) == 1

    # la compra nace del remito, en su sucursal y con su proveedor, con la línea y los snapshots del remito
    row = await conn.fetchrow(
        "SELECT product_id, quantity, amount, total, branch_id, supplier_id, source_delivery_note_id, name_snapshot "
        "FROM public.purchases WHERE operation_id = $1", uuid.UUID(result["operation_id"]))
    assert row["product_id"] == w.product_a and Decimal(row["quantity"]) == 3
    assert Decimal(row["amount"]) == 100 and Decimal(row["total"]) == 300
    assert row["branch_id"] == w.branch_a and row["supplier_id"] == w.supplier_a
    assert row["source_delivery_note_id"] == _u(dn["id"]) and row["name_snapshot"] == "__integ_rv_producto_a__"

    # el remito queda converted SIN subir la revisión, con los dos historiales
    assert await conn.fetchval("SELECT status FROM public.delivery_notes WHERE id = $1", _u(dn["id"])) == "converted"
    assert await conn.fetchval("SELECT revision FROM public.delivery_notes WHERE id = $1", _u(dn["id"])) == dn["revision"]
    assert [r["to_status"] for r in await conn.fetch(
        "SELECT to_status FROM public.document_status_history WHERE document_type = 'delivery_note_purchase' "
        "AND document_id = $1 ORDER BY occurred_at, id", _u(dn["id"]))] == ["issued", "converted"]

    # a crédito: cargo en la cuenta corriente del proveedor, sin caja
    assert await _supplier_balance(conn, w.supplier_a) == Decimal("300")

    # el detalle del remito apunta a la compra viva
    detail = await _detail(conn, w, str(dn["id"]))
    assert detail["status"] == "converted"
    assert str(detail["converted_operation_id"]) == result["operation_id"]
    assert detail["converted_sales_order_id"] is None
    after_first = await _effects(conn, w)

    # reintento con la misma clave: replay sin efectos
    again = await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rcb-convert-1")
    assert again["replayed"] is True and again["operation_id"] == result["operation_id"]
    assert await _effects(conn, w) == after_first

    # otra clave sobre el ya convertido: el estado manda
    with pytest.raises(HTTPException) as info:
        await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rcb-convert-2")
    assert (info.value.status_code, info.value.code) == (409, "delivery_note_invalid_state")
    assert await _effects(conn, w) == after_first


async def test_convert_in_cash_posts_the_session_movement_and_still_leaves_stock_alone(
    conn, pworld: World, cash_session
):
    w = pworld
    dn = await _receive(conn, w, [_line(w.product_a, "2", "150", "300")])
    session = cash_session
    pm = await _payment_method(conn, w.account_a, "cash")

    result = await _convert(conn, w, dn, _convert_payload(dn, pm, cash_session_id=session), "integ-rcb-cash")

    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(12)
    assert await _purchase_moves(conn, w, result["operation_id"]) == 0
    movements = await conn.fetch(
        "SELECT movement_type, amount FROM public.cash_movements WHERE session_id = $1", session)
    assert [(m["movement_type"], Decimal(m["amount"])) for m in movements] == [("purchase_payment", Decimal(-300))]
    assert await conn.fetchval("SELECT count(*) FROM public.supplier_account_movements WHERE account_id = $1", w.account_a) == 0


async def test_convert_in_cash_without_the_optin_writes_no_cash_movement(conn, pworld: World, cash_session):
    """La caja es opt-in en la compra: sin `cash_session_id` convierte igual y no
    toca la caja (las tres condiciones sólo se exigen si se pide)."""
    w = pworld
    dn = await _receive(conn, w, [_line(w.product_a, "2", "150", "300")])
    pm = await _payment_method(conn, w.account_a, "cash")

    await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rcb-cash-nooptin")

    assert await conn.fetchval("SELECT count(*) FROM public.cash_movements WHERE session_id = $1", cash_session) == 0
    assert await conn.fetchval("SELECT status FROM public.delivery_notes WHERE id = $1", _u(dn["id"])) == "converted"


async def test_a_line_without_a_price_blocks_the_conversion_with_zero_effects(conn, pworld: World):
    w = pworld
    dn = await _receive(conn, w, [_line(w.product_a, "2", "100", "200"), _line(w.product_b, "1", "0", "0")])
    pm = await _payment_method(conn, w.account_a, "credit")
    before = await _effects(conn, w)

    with pytest.raises(HTTPException) as info:
        await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rcb-noprice")

    assert (info.value.status_code, info.value.code) == (400, "delivery_note_price_required")
    assert await _effects(conn, w) == before


async def test_convert_with_a_stale_revision_is_409_delivery_note_changed(conn, pworld: World):
    w = pworld
    dn = await _receive(conn, w, [_line(w.product_a, "1", "100", "100")])
    pm = await _payment_method(conn, w.account_a, "credit")
    before = await _effects(conn, w)

    with pytest.raises(HTTPException) as info:
        await _convert(conn, w, dn, _convert_payload(dn, pm, expected_revision=dn["revision"] + 1), "integ-rcb-rev")

    assert (info.value.status_code, info.value.code) == (409, "delivery_note_changed")
    assert await _effects(conn, w) == before


async def test_the_date_cannot_precede_the_receipt(conn, pworld: World):
    w = pworld
    dn = await _receive(conn, w, [_line(w.product_a, "1", "100", "100")])
    pm = await _payment_method(conn, w.account_a, "credit")
    before = await _effects(conn, w)

    with pytest.raises(HTTPException) as info:
        await _convert(conn, w, dn, _convert_payload(dn, pm, date=datetime.date.today() - datetime.timedelta(days=3)),
                       "integ-rcb-date")

    assert (info.value.status_code, info.value.code) == (400, "delivery_note_purchase_date_before_receipt")
    assert await _effects(conn, w) == before


async def test_the_snapshots_and_the_price_that_travel_are_the_notes_even_after_the_catalog_changes(conn, pworld: World):
    """Lo que se recibió es lo que se compra, aunque después se renombre el
    producto o se remarque su costo de lista."""
    w = pworld
    dn = await _receive(conn, w, [_line(w.product_a, "2", "75", "150")])
    await conn.execute("UPDATE public.products SET name = 'Renombrado', price = 9999, cost = 8888 WHERE id = $1", w.product_a)
    pm = await _payment_method(conn, w.account_a, "credit")

    result = await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rcb-price")

    assert Decimal(str(result["total"])) == Decimal("150")
    row = await conn.fetchrow(
        "SELECT amount, total, name_snapshot FROM public.purchases WHERE operation_id = $1", uuid.UUID(result["operation_id"]))
    assert Decimal(row["amount"]) == 75 and Decimal(row["total"]) == 150 and row["name_snapshot"] == "__integ_rv_producto_a__"
    assert await conn.fetchval(
        "SELECT pi.name_snapshot FROM public.purchase_items pi JOIN public.purchases p ON p.id = pi.purchase_id "
        "WHERE p.operation_id = $1", uuid.UUID(result["operation_id"])) == "__integ_rv_producto_a__"


# ══════════════════════════════════════════════════════════════════════════════
# Roles, tenencia, idempotencia cruzada
# ══════════════════════════════════════════════════════════════════════════════

async def test_roles_tenancy_and_foreign_payment_method(conn, pworld: World):
    w = pworld
    dn = await _receive(conn, w, [_line(w.product_a, "1", "100", "100")])
    pm = await _payment_method(conn, w.account_a, "credit")
    pm_b = await _payment_method(conn, w.account_b, "credit")
    before = await _effects(conn, w)

    # el vendedor y el cajero no convierten una compra
    for user in (w.seller, w.cashier):
        with pytest.raises(HTTPException) as info:
            await _convert(conn, w, dn, _convert_payload(dn, pm), f"integ-rcb-r1-{user}", user=user)
        assert (info.value.status_code, info.value.code) == (403, "insufficient_role")

    # un remito ajeno es indistinguible de uno inexistente
    with pytest.raises(HTTPException) as info:
        await _convert(conn, w, dn, _convert_payload(dn, pm_b), "integ-rcb-r2", user=w.owner_b, account=w.account_b)
    assert (info.value.status_code, info.value.code) == (404, "delivery_note_not_found")

    # la forma de pago de otra cuenta no se acepta
    with pytest.raises(HTTPException) as info:
        await _convert(conn, w, dn, _convert_payload(dn, pm_b), "integ-rcb-r3")
    assert info.value.status_code == 404

    assert await _effects(conn, w) == before


async def test_the_same_key_on_another_note_is_409_idempotency_key_conflict(conn, pworld: World):
    w = pworld
    dn1 = await _receive(conn, w, [_line(w.product_a, "1", "100", "100")])
    dn2 = await _receive(conn, w, [_line(w.product_b, "1", "70", "70")])
    pm = await _payment_method(conn, w.account_a, "credit")
    await _convert(conn, w, dn1, _convert_payload(dn1, pm), "integ-rcb-shared")
    after_first = await _effects(conn, w)

    with pytest.raises(HTTPException) as info:
        await _convert(conn, w, dn2, _convert_payload(dn2, pm), "integ-rcb-shared")

    assert (info.value.status_code, info.value.code) == (409, "idempotency_key_conflict")
    assert await _effects(conn, w) == after_first
    assert await conn.fetchval("SELECT status FROM public.delivery_notes WHERE id = $1", _u(dn2["id"])) == "issued"


async def test_a_deleted_supplier_and_an_inactive_branch_block_the_conversion_with_zero_effects(conn, pworld: World):
    w = pworld
    dn = await _receive(conn, w, [_line(w.product_a, "1", "100", "100")])
    pm = await _payment_method(conn, w.account_a, "credit")
    before = await _effects(conn, w)

    await conn.execute("UPDATE public.suppliers SET deleted_at = now() WHERE id = $1", w.supplier_a)
    with pytest.raises(HTTPException) as info:
        await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rcb-supplier")
    assert (info.value.status_code, info.value.code) == (404, "delivery_note_supplier_unavailable")
    await conn.execute("UPDATE public.suppliers SET deleted_at = NULL WHERE id = $1", w.supplier_a)

    async with _branch_inactive(conn, w.branch_a):
        with pytest.raises(HTTPException) as info:
            await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rcb-branch")
        assert (info.value.status_code, info.value.code) == (422, "branch_closed")

    assert await _effects(conn, w) == before


async def test_a_product_deleted_after_the_receipt_still_converts(conn, pworld: World):
    """Los productos dados de baja después de recibir SE CONVIERTEN: la
    mercadería ya entró."""
    w = pworld
    dn = await _receive(conn, w, [_line(w.product_a, "1", "100", "100")])
    # RN-B4 impide dar de baja un producto con stock (y el remito acaba de sumarlo): se saltea el guard
    # del catálogo, que es otra regla; lo que se prueba es que la CONVERSIÓN no revalida el producto.
    await conn.execute("SET session_replication_role = replica")
    try:
        await conn.execute("UPDATE public.products SET deleted_at = now() WHERE id = $1", w.product_a)
    finally:
        await conn.execute("SET session_replication_role = DEFAULT")
    pm = await _payment_method(conn, w.account_a, "credit")

    result = await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rcb-deadprod")

    assert Decimal(str(result["total"])) == Decimal("100")


# ══════════════════════════════════════════════════════════════════════════════
# Read model de compras
# ══════════════════════════════════════════════════════════════════════════════

async def test_the_purchases_read_model_exposes_the_origin_note_and_the_reason(conn, pworld: World):
    w = pworld
    dn = await _receive(conn, w, [_line(w.product_a, "2", "100", "200"), _line(w.product_b, "1", "70", "70")])
    pm = await _payment_method(conn, w.account_a, "credit")
    result = await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rcb-rm")

    # una compra suelta (formulario): no debe heredar nada
    plain_op = uuid.uuid4()
    await conn.execute(
        "INSERT INTO public.purchases (user_id, account_id, product_id, amount, quantity, total, date, operation_id) "
        "VALUES ($1, $2, $3, 50, 1, 50, now(), $4)", w.owner_a, w.account_a, w.product_a, plain_op)

    async with _as(conn, w.owner_a, authenticated_role=True):
        rows, total = await PurchaseRepository(conn).list_paginated_by_operation(str(w.account_a), 0, 50)
    rows = [dict(r) for r in rows]

    assert total == 2
    converted = [r for r in rows if str(r["operation_id"]) == result["operation_id"]]
    plain = [r for r in rows if r["operation_id"] == plain_op]
    assert len(converted) == 2 and len(plain) == 1, "el JOIN al remito no debe duplicar ni perder filas"
    assert {str(r["source_delivery_note_id"]) for r in converted} == {str(dn["id"])}
    assert {r["source_delivery_note_number"] for r in converted} == {1}
    assert {r["source_delivery_note_branch_active"] for r in converted} == {True}
    assert {r["edit_locked_reason"] for r in converted} == {"delivery_note_purchase_locked"}
    assert plain[0]["source_delivery_note_id"] is None and plain[0]["source_delivery_note_number"] is None
    assert plain[0]["source_delivery_note_branch_active"] is None and plain[0]["edit_locked_reason"] is None

    # con la sucursal del remito desactivada, el listado lo anticipa (mismo predicado que el borrado)
    async with _branch_inactive(conn, w.branch_a):
        async with _as(conn, w.owner_a, authenticated_role=True):
            rows2, _ = await PurchaseRepository(conn).list_paginated_by_operation(str(w.account_a), 0, 50)
        flags = {r["source_delivery_note_branch_active"] for r in rows2 if r["operation_id"] and str(r["operation_id"]) == result["operation_id"]}
        assert flags == {False}


async def test_the_origin_join_requires_the_same_account(conn, pworld: World):
    """El cruce con el remito exige la misma cuenta: aunque `source_delivery_note_id`
    apuntara a un remito de otra, nunca se muestra un número ajeno."""
    w = pworld
    dn = await _receive(conn, w, [_line(w.product_a, "1", "100", "100")])
    pm = await _payment_method(conn, w.account_a, "credit")
    await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rcb-xacct")
    await conn.execute("SET session_replication_role = replica")
    try:
        await conn.execute("UPDATE public.delivery_notes SET account_id = $1 WHERE id = $2", w.account_b, _u(dn["id"]))
    finally:
        await conn.execute("SET session_replication_role = DEFAULT")

    async with _as(conn, w.owner_a, authenticated_role=True):
        rows, _ = await PurchaseRepository(conn).list_paginated_by_operation(str(w.account_a), 0, 50)

    assert {r["source_delivery_note_number"] for r in rows} == {None}


# ══════════════════════════════════════════════════════════════════════════════
# Borrar y editar la compra nacida de un remito (D9)
# ══════════════════════════════════════════════════════════════════════════════

async def test_deleting_the_purchase_keeps_the_stock_compensates_the_debt_and_reopens_the_note(conn, pworld: World):
    w = pworld
    dn = await _receive(conn, w, [_line(w.product_a, "3", "100", "300")])
    pm = await _payment_method(conn, w.account_a, "credit")
    first = await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rcb-del-1")
    ledger = await conn.fetchval("SELECT count(*) FROM public.stock_movements WHERE account_id = $1", w.account_a)
    assert await _supplier_balance(conn, w.supplier_a) == Decimal("300")

    await _delete_purchase(conn, w, first["operation_id"])

    # el stock NO se toca (la mercadería quedó recibida) y el ledger no suma reversas
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(13)
    assert await conn.fetchval("SELECT count(*) FROM public.stock_movements WHERE account_id = $1", w.account_a) == ledger
    assert await conn.fetchval("SELECT count(*) FROM public.purchases WHERE operation_id = $1", uuid.UUID(first["operation_id"])) == 0
    # el remito vuelve a pendiente, con el motivo en el historial
    assert await conn.fetchval("SELECT status FROM public.delivery_notes WHERE id = $1", _u(dn["id"])) == "issued"
    last = await conn.fetchrow(
        "SELECT from_status, to_status, reason FROM public.document_status_history "
        "WHERE document_type = 'delivery_note_purchase' AND document_id = $1 ORDER BY occurred_at DESC, id DESC LIMIT 1",
        _u(dn["id"]))
    assert (last["from_status"], last["to_status"]) == ("converted", "issued")
    assert first["operation_id"] in (last["reason"] or "")
    # la deuda de la compra borrada se compensó
    assert await _supplier_balance(conn, w.supplier_a) == Decimal("0")
    detail = await _detail(conn, w, str(dn["id"]))
    assert detail["status"] == "issued" and detail["converted_operation_id"] is None

    # reconvertir: una compra nueva, y el stock sigue idéntico
    again = await _convert(conn, w, detail, _convert_payload(detail, pm), "integ-rcb-del-2")
    assert again["replayed"] is False and again["operation_id"] != first["operation_id"]
    assert await conn.fetchval("SELECT status FROM public.delivery_notes WHERE id = $1", _u(dn["id"])) == "converted"
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(13)
    assert await _supplier_balance(conn, w.supplier_a) == Decimal("300")


async def test_only_admin_or_owner_deletes_the_purchase_of_a_note(conn, pworld: World):
    """Borrar la compra reabre el remito y lo deja anulable: exige el rol de
    anularlo (admin/owner), no el de convertir (`stock` convierte pero no borra)."""
    w = pworld
    dn = await _receive(conn, w, [_line(w.product_a, "3", "100", "300")])
    pm = await _payment_method(conn, w.account_a, "credit")
    result = await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rcb-del-role")
    before = await _effects(conn, w)

    # multiusuario-operativo (tanda B, D9): borrar una compra exige CAN_PURCHASE ANTES de llegar al remito. El depósito
    # (`stock`) convierte pero NO compra: el guard de FastAPI lo corta con un 403 sin ejecutar la RPC…
    with pytest.raises(HTTPException) as info_api:
        await _delete_purchase(conn, w, result["operation_id"], user=w.stocker)
    assert info_api.value.status_code == 403
    assert await _effects(conn, w) == before

    # …y la base lo rechaza igual si se la invoca directo (defensa en dos capas): P0403 insufficient_role.
    with pytest.raises(asyncpg.PostgresError) as info:
        async with _as(conn, w.stocker, authenticated_role=True):
            await conn.fetchval("SELECT public.rpc_delete_purchase_operation(NULL, $1::uuid, NULL)", _u(result["operation_id"]))

    assert info.value.sqlstate == "P0403" and "insufficient_role" in str(info.value)
    assert await _effects(conn, w) == before
    assert await conn.fetchval("SELECT status FROM public.delivery_notes WHERE id = $1", _u(dn["id"])) == "converted"

    await _delete_purchase(conn, w, result["operation_id"], user=w.admin)
    assert await conn.fetchval("SELECT status FROM public.delivery_notes WHERE id = $1", _u(dn["id"])) == "issued"


async def test_deleting_with_the_notes_branch_deactivated_is_422_with_zero_effects(conn, pworld: World):
    w = pworld
    dn = await _receive(conn, w, [_line(w.product_a, "3", "100", "300")])
    pm = await _payment_method(conn, w.account_a, "credit")
    result = await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rcb-del-branch")
    before = await _effects(conn, w)

    async with _branch_inactive(conn, w.branch_a):
        with pytest.raises(asyncpg.PostgresError) as info:
            await _delete_purchase(conn, w, result["operation_id"])

        assert info.value.sqlstate == "P0422" and "delivery_note_branch_inactive" in str(info.value)
        assert await _effects(conn, w) == before
    assert await conn.fetchval("SELECT status FROM public.delivery_notes WHERE id = $1", _u(dn["id"])) == "converted"


async def test_editing_the_purchase_is_locked_and_changes_neither_stock_nor_ledger(conn, pworld: World):
    w = pworld
    dn = await _receive(conn, w, [_line(w.product_a, "3", "100", "300")])
    pm = await _payment_method(conn, w.account_a, "other")  # sin dinero posteado: ningún guard de dinero frena
    result = await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rcb-edit")
    purchase_ids = [r["id"] for r in await conn.fetch(
        "SELECT id FROM public.purchases WHERE operation_id = $1", uuid.UUID(result["operation_id"]))]
    before = await _effects(conn, w)

    # multiusuario-operativo (tanda B, D9): editar una compra exige CAN_PURCHASE (el depósito, que convirtió, no
    # compra: P0403 insufficient_role) y, sobre la compra de OTRO miembro, dueño o administrador. El P0423 del remito
    # —el primer guard de la edición después de esos— se prueba con el administrador, que sí puede editarla.
    with pytest.raises(asyncpg.PostgresError) as stocker_info:
        async with _as(conn, w.stocker, authenticated_role=True):
            await PurchaseRepository(conn).update_operation(
                [str(i) for i in purchase_ids], datetime.date.today(), None,
                [{"product_id": str(w.product_a), "quantity": "1", "amount": "100"}])
    assert stocker_info.value.sqlstate == "P0403" and "insufficient_role" in str(stocker_info.value)

    with pytest.raises(asyncpg.PostgresError) as info:
        async with _as(conn, w.admin, authenticated_role=True):
            await PurchaseRepository(conn).update_operation(
                [str(i) for i in purchase_ids], datetime.date.today(), None,
                [{"product_id": str(w.product_a), "quantity": "1", "amount": "100"}])

    assert info.value.sqlstate == "P0423" and "delivery_note_purchase_locked" in str(info.value)
    assert await _effects(conn, w) == before
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(13)


async def test_cancelling_a_converted_note_is_locked_until_the_purchase_is_deleted(conn, pworld: World):
    w = pworld
    dn = await _receive(conn, w, [_line(w.product_a, "3", "100", "300")])
    pm = await _payment_method(conn, w.account_a, "credit")
    result = await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rcb-cancel")

    async def cancel(user):
        async with _as(conn, user, authenticated_role=True):
            return await svc.cancel_delivery_note(
                DeliveryNoteRepository(conn), _auth(user), str(w.account_a), str(dn["id"]),
                DeliveryNoteCancelIn(revision=dn["revision"], reason="El proveedor se llevó la mercadería"), conn=conn)

    with pytest.raises(HTTPException) as info:
        await cancel(w.admin)
    assert (info.value.status_code, info.value.code) == (409, "delivery_note_locked_converted")
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(13)

    # primero se borra la compra; recién entonces el remito se puede anular y RESTA el stock recibido
    await _delete_purchase(conn, w, result["operation_id"])
    cancelled = await cancel(w.admin)
    assert cancelled["status"] == "canceled"
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(10)


async def test_the_stock_consumed_after_receiving_blocks_the_cancellation_of_the_reopened_note(conn, pworld: World):
    """Borrar la compra no devuelve el stock: si la mercadería ya se vendió, el
    remito reabierto no se puede anular (la salida no vuelve a restar lo que ya
    no está)."""
    w = pworld
    dn = await _receive(conn, w, [_line(w.product_a, "3", "100", "300")])
    pm = await _payment_method(conn, w.account_a, "credit")
    result = await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rcb-consumed")
    await _delete_purchase(conn, w, result["operation_id"])
    await _consume(conn, w, w.product_a, "12")  # 13 recibidos y vendidos casi todos: quedan 1

    async with _as(conn, w.admin, authenticated_role=True):
        with pytest.raises(HTTPException) as info:
            await svc.cancel_delivery_note(
                DeliveryNoteRepository(conn), _auth(w.admin), str(w.account_a), str(dn["id"]),
                DeliveryNoteCancelIn(revision=dn["revision"], reason="Se devolvió la mercadería"), conn=conn)
    assert (info.value.status_code, info.value.code) == (409, "delivery_note_stock_consumed")


async def test_editing_the_note_after_reopening_and_reconverting_uses_the_new_lines(conn, pworld: World):
    """El ciclo completo del flujo "corregir": borrar la compra, editar el remito
    (par espejo en el ledger) y volver a convertir con lo corregido."""
    w = pworld
    dn = await _receive(conn, w, [_line(w.product_a, "3", "100", "300")])
    pm = await _payment_method(conn, w.account_a, "credit")
    first = await _convert(conn, w, dn, _convert_payload(dn, pm), "integ-rcb-cycle-1")
    await _delete_purchase(conn, w, first["operation_id"])
    reopened = await _detail(conn, w, str(dn["id"]))

    edited = await _purchase_update(conn, w, str(dn["id"]), reopened["revision"], [_line(w.product_a, "2", "110", "220")])
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(12)

    second = await _convert(conn, w, edited, _convert_payload(edited, pm), "integ-rcb-cycle-2")
    assert Decimal(str(second["total"])) == Decimal("220")
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(12)
    row = await conn.fetchrow(
        "SELECT quantity, total FROM public.purchases WHERE operation_id = $1", uuid.UUID(second["operation_id"]))
    assert Decimal(row["quantity"]) == 2 and Decimal(row["total"]) == 220


# ══════════════════════════════════════════════════════════════════════════════
# La compra directa NO cambia (regresión de la extracción del núcleo)
# ══════════════════════════════════════════════════════════════════════════════

async def test_a_direct_purchase_still_adds_stock_and_the_bridge_stays_empty(conn, pworld: World):
    w = pworld
    pm = await _payment_method(conn, w.account_a, "other")
    async with _as(conn, w.owner_a, authenticated_role=True):
        res = await conn.fetchval(
            "SELECT public.rpc_create_purchase_operation('integ-rcb-direct', current_date, 'directa', "
            "jsonb_build_array(jsonb_build_object('product_id', $1::text, 'quantity', 2, 'amount', 100)), "
            "$2::uuid, NULL, $3::uuid, NULL, NULL, NULL, NULL)", str(w.product_a), w.branch_a, pm)
    import json as _json
    op = _json.loads(res)["operation_id"] if isinstance(res, str) else res["operation_id"]

    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(12)
    assert await _purchase_moves(conn, w, str(op)) == 1
    assert await conn.fetchval(
        "SELECT count(*) FROM public.purchases WHERE operation_id = $1 AND source_delivery_note_id IS NOT NULL",
        uuid.UUID(str(op))) == 0
