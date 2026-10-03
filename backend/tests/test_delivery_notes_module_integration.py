"""
remitos-venta (tanda A, task 2.1, "RED que persiste de verdad") — integración
contra el Postgres LOCAL real (stack de `supabase start`, con 20261069000001
aplicada). Marcado `@pytest.mark.integration`: excluido del gate de CI
(`-m "not integration"`); correr a mano con `-m integration`. La evidencia de CI
del esquema es el gate SQL supabase/tests/test_remitos_venta.sql.

Por qué además de test_delivery_notes_module.py: aquel prueba el repositorio
contra una conexión doble y sólo asserta que el SQL NOMBRA las RPCs. Éste llama
al MISMO `DeliveryNoteRepository` + `services.delivery_notes` que usa el
endpoint contra la base real, con los claims del JWT puestos en la transacción
como hace `backend/core/database.py`, y lee lo que quedó persistido: remito,
número, stock, ledger e idempotencia.
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import uuid
from decimal import Decimal

import asyncpg
import pytest
from fastapi import HTTPException
from pypdf import PdfReader

from backend.repositories.delivery_note_repository import DeliveryNoteRepository
from backend.schemas.delivery_notes import (
    DeliveryNoteCancelIn,
    DeliveryNoteCreateIn,
    DeliveryNoteItemIn,
    DeliveryNoteUpdateIn,
)
from backend.services import delivery_notes as svc

DSN = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@127.0.0.1:54322/postgres")

pytestmark = pytest.mark.integration


class World:
    """Dos cuentas con sus usuarios, sucursal por defecto, cliente y productos."""

    def __init__(self) -> None:
        self.owner_a = uuid.uuid4()
        self.owner_b = uuid.uuid4()
        self.admin = uuid.uuid4()
        self.seller = uuid.uuid4()
        self.stocker = uuid.uuid4()
        self.cashier = uuid.uuid4()
        self.account_a: uuid.UUID
        self.account_b: uuid.UUID
        self.accounts: list[uuid.UUID] = []
        self.branch_a: uuid.UUID
        self.branch_a2: uuid.UUID
        self.client_a: uuid.UUID
        self.client_b: uuid.UUID
        self.product_a: uuid.UUID
        self.product_b: uuid.UUID
        self.product_other: uuid.UUID

    @property
    def users(self) -> list[uuid.UUID]:
        return [self.owner_a, self.owner_b, self.admin, self.seller, self.stocker, self.cashier]


async def _claims(conn: asyncpg.Connection, user_id: uuid.UUID) -> None:
    await conn.execute(
        "SELECT set_config('request.jwt.claims', $1, true)",
        json.dumps({"sub": str(user_id), "role": "authenticated"}),
    )
    await conn.execute("SELECT set_config('request.jwt.claim.sub', $1, true)", str(user_id))


@contextlib.asynccontextmanager
async def _as(conn: asyncpg.Connection, user_id: uuid.UUID, *, authenticated_role: bool = False):
    """Una 'request': transacción + claims (+ SET LOCAL ROLE como el Paso 2)."""
    async with conn.transaction():
        await _claims(conn, user_id)
        if authenticated_role:
            await conn.execute("SET LOCAL ROLE authenticated")
        yield


def _auth(user_id: uuid.UUID) -> dict:
    # Sin claim `account_roles`: el guard resuelve el pivot en la base.
    return {"user_id": str(user_id), "sub": str(user_id), "role": "user"}


def _line(product_id: uuid.UUID, qty="2", price="750", subtotal="1500") -> DeliveryNoteItemIn:
    return DeliveryNoteItemIn(product_id=product_id, quantity=qty, price=price, subtotal=subtotal)


def _create_payload(w: World, items: list[DeliveryNoteItemIn], **over) -> DeliveryNoteCreateIn:
    data = {"client_id": w.client_a, "branch_id": w.branch_a, "delivery_address": "San Martín 123", "items": items}
    data.update(over)
    return DeliveryNoteCreateIn(**data)


def _update_payload(w: World, revision: int, items: list[DeliveryNoteItemIn], **over) -> DeliveryNoteUpdateIn:
    data = {
        "revision": revision, "client_id": w.client_a, "branch_id": w.branch_a,
        "delivery_address": None, "notes": None, "items": items,
    }
    data.update(over)
    return DeliveryNoteUpdateIn(**data)


async def _stock(conn: asyncpg.Connection, product: uuid.UUID, branch: uuid.UUID) -> Decimal:
    value = await conn.fetchval(
        "SELECT quantity FROM public.branch_stock WHERE product_id = $1 AND branch_id = $2", product, branch)
    return Decimal(value) if value is not None else Decimal(0)


async def _seed(conn: asyncpg.Connection) -> World:
    w = World()
    for tag, uid in (("owner-a", w.owner_a), ("owner-b", w.owner_b), ("admin", w.admin),
                     ("seller", w.seller), ("stock", w.stocker), ("cashier", w.cashier)):
        await conn.execute(
            """
            INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
            VALUES ($1, 'authenticated', 'authenticated', $2, now(), now(),
                    jsonb_build_object('name', $3::text, 'phone', '', 'locality', '', 'province', ''))
            """,
            uid, f"remitos-integ-{tag}-{uid}@test.local", f"Integración Remitos {tag}",
        )
    w.account_a = await conn.fetchval(
        "SELECT account_id FROM public.account_members WHERE user_id = $1 ORDER BY created_at LIMIT 1", w.owner_a)
    w.account_b = await conn.fetchval(
        "SELECT account_id FROM public.account_members WHERE user_id = $1 ORDER BY created_at LIMIT 1", w.owner_b)
    assert w.account_a and w.account_b, "SETUP: handle_new_user no creó las cuentas"
    w.accounts = [
        r["account_id"] for r in await conn.fetch(
            "SELECT DISTINCT account_id FROM public.account_members WHERE user_id = ANY($1::uuid[])", w.users)
    ]

    staff = (w.admin, w.seller, w.stocker, w.cashier)
    await conn.execute("SET session_replication_role = replica")
    try:
        await conn.execute(
            "DELETE FROM public.account_member_roles WHERE member_id IN "
            "(SELECT id FROM public.account_members WHERE user_id = ANY($1::uuid[]))", list(staff))
        await conn.execute("DELETE FROM public.account_members WHERE user_id = ANY($1::uuid[])", list(staff))
    finally:
        await conn.execute("SET session_replication_role = DEFAULT")
    for uid, role in ((w.admin, "admin"), (w.seller, "seller"), (w.stocker, "stock"), (w.cashier, "cashier")):
        member_id = await conn.fetchval(
            "INSERT INTO public.account_members (account_id, user_id, role) VALUES ($1, $2, 'member') RETURNING id",
            w.account_a, uid)
        await conn.execute(
            "INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES ($1, $2, $3)",
            w.account_a, member_id, role)

    await conn.execute(
        "UPDATE public.profiles SET business_name = 'Almacén Integración', phone = '2615550101' WHERE id = $1",
        w.owner_a)

    w.branch_a = await conn.fetchval(
        "SELECT id FROM public.branches WHERE account_id = $1 ORDER BY created_at LIMIT 1", w.account_a)
    w.branch_a2 = await conn.fetchval(
        "INSERT INTO public.branches (account_id, name, is_active, status, opened_at) "
        "VALUES ($1, 'Sucursal Dos Integ', true, 'active', now()) RETURNING id", w.account_a)
    w.client_a = await conn.fetchval(
        "INSERT INTO public.clients (user_id, account_id, name, phone) "
        "VALUES ($1, $2, 'Cliente Integ A', '2615550202') RETURNING id", w.owner_a, w.account_a)
    w.client_b = await conn.fetchval(
        "INSERT INTO public.clients (user_id, account_id, name) VALUES ($1, $2, 'Cliente Integ B') RETURNING id",
        w.owner_b, w.account_b)
    w.product_a = await conn.fetchval(
        "INSERT INTO public.products (user_id, account_id, name, sku, cost, price) "
        "VALUES ($1, $2, '__integ_rv_producto_a__', 'IRV-A', 500, 1000) RETURNING id", w.owner_a, w.account_a)
    w.product_b = await conn.fetchval(
        "INSERT INTO public.products (user_id, account_id, name, sku, cost, price) "
        "VALUES ($1, $2, '__integ_rv_producto_b__', 'IRV-B', 300, 700) RETURNING id", w.owner_a, w.account_a)
    w.product_other = await conn.fetchval(
        "INSERT INTO public.products (user_id, account_id, name, sku, cost, price) "
        "VALUES ($1, $2, '__integ_rv_SECRETO_B__', 'IRV-X', 777, 999) RETURNING id", w.owner_b, w.account_b)
    await conn.execute("SELECT public.c21_apply_branch_stock_delta($1, $2, $3, 10)", w.account_a, w.product_a, w.branch_a)
    await conn.execute("SELECT public.c21_apply_branch_stock_delta($1, $2, $3, 10)", w.account_a, w.product_b, w.branch_a)
    return w


async def _cleanup(conn: asyncpg.Connection, w: World) -> None:
    await conn.execute("SET session_replication_role = replica")
    try:
        tables = await conn.fetch(
            """
            SELECT c.table_name FROM information_schema.columns c
            JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
            WHERE c.table_schema = 'public' AND c.column_name = 'account_id'
              AND t.table_type = 'BASE TABLE' AND c.table_name <> 'accounts'
            """
        )
        for row in tables:
            await conn.execute(f'DELETE FROM public."{row["table_name"]}" WHERE account_id = ANY($1::uuid[])', w.accounts)
        await conn.execute("DELETE FROM public.accounts WHERE id = ANY($1::uuid[])", w.accounts)
    finally:
        await conn.execute("SET session_replication_role = DEFAULT")
    await conn.execute("DELETE FROM public.operation_idempotency WHERE user_id = ANY($1::uuid[])", w.users)
    await conn.execute("DELETE FROM public.account_members WHERE user_id = ANY($1::uuid[])", w.users)
    await conn.execute("DELETE FROM public.billing_events WHERE user_id = ANY($1::uuid[])", w.users)
    await conn.execute("DELETE FROM public.email_logs WHERE user_id = ANY($1::uuid[])", w.users)
    await conn.execute("DELETE FROM public.profiles WHERE id = ANY($1::uuid[])", w.users)
    await conn.execute("DELETE FROM auth.users WHERE id = ANY($1::uuid[])", w.users)


@pytest.fixture
async def conn():
    try:
        c = await asyncpg.connect(DSN)
    except (OSError, asyncpg.PostgresError) as exc:  # pragma: no cover - depende del entorno
        pytest.skip(f"Postgres local no disponible ({exc}); levantá `supabase start`")
    try:
        yield c
    finally:
        await c.close()


@pytest.fixture
async def world(conn: asyncpg.Connection):
    w = await _seed(conn)
    try:
        yield w
    finally:
        await _cleanup(conn, w)


async def _issue(conn, w: World, items: list[DeliveryNoteItemIn], *, key: str | None = None, user=None, **over) -> dict:
    user = user or w.seller
    async with _as(conn, user):
        return await svc.create_delivery_note(
            DeliveryNoteRepository(conn), _auth(user), str(w.account_a), _create_payload(w, items, **over),
            key or f"integ-{uuid.uuid4()}", conn=conn,
        )


async def _movements(conn, dn_id: str, product: uuid.UUID | None = None) -> list[asyncpg.Record]:
    return await conn.fetch(
        "SELECT type, reference_type, quantity_delta, product_id, branch_id, operation_group_id "
        "FROM public.stock_movements WHERE reference_id = $1::uuid AND ($2::uuid IS NULL OR product_id = $2::uuid) "
        "ORDER BY created_at, id", dn_id, product)


# ══════════════════════════════════════════════════════════════════════════════
# Emisión
# ══════════════════════════════════════════════════════════════════════════════

async def test_issue_persists_the_note_numbers_it_and_moves_the_stock(conn, world):
    w = world
    dn = await _issue(conn, w, [_line(w.product_a, "3", "1000", "3000")], notes="Entrega mañana")

    assert dn["number"] == 1 and dn["number_label"] == "R-00000001"
    assert dn["status"] == "issued" and dn["revision"] == 1 and dn["replayed"] is False
    assert dn["branch_name"] and dn["client_name"] == "Cliente Integ A"
    assert Decimal(str(dn["total"])) == Decimal("3000")
    assert [i["name_snapshot"] for i in dn["items"]] == ["__integ_rv_producto_a__"]
    assert [h["to_status"] for h in dn["history"]] == ["issued"]

    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(7)
    moves = await _movements(conn, dn["id"])
    assert [(m["type"], m["reference_type"], Decimal(m["quantity_delta"])) for m in moves] == [
        ("sale", "delivery_note", Decimal(-3))]


async def test_the_same_key_twice_is_one_note_one_discount_and_a_replay(conn, world):
    w = world
    first = await _issue(conn, w, [_line(w.product_a, "3", "1000", "3000")], key="integ-same-key")
    second = await _issue(conn, w, [_line(w.product_a, "3", "1000", "3000")], key="integ-same-key")

    assert second["id"] == first["id"] and second["replayed"] is True
    assert await conn.fetchval("SELECT count(*) FROM public.delivery_notes WHERE account_id = $1", w.account_a) == 1
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(7)
    assert len(await _movements(conn, first["id"])) == 1


async def test_a_shortage_is_a_409_with_zero_effects(conn, world):
    w = world
    with pytest.raises(HTTPException) as info:
        await _issue(conn, w, [_line(w.product_a, "11", "1000", "11000")])

    assert info.value.status_code == 409 and info.value.code == "stock_insuficiente"
    assert await conn.fetchval("SELECT count(*) FROM public.delivery_notes WHERE account_id = $1", w.account_a) == 0
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(10)
    # un fallo no consume número: el siguiente remito es el 1
    ok = await _issue(conn, w, [_line(w.product_a, "1", "1000", "1000")])
    assert ok["number"] == 1


@pytest.mark.parametrize("role,status,code", [("cashier", 403, "insufficient_role")])
async def test_the_cashier_cannot_issue(conn, world, role, status, code):
    w = world
    with pytest.raises(HTTPException) as info:
        await _issue(conn, w, [_line(w.product_a)], user=w.cashier)
    assert info.value.status_code == status and info.value.code == code
    assert await conn.fetchval("SELECT count(*) FROM public.delivery_notes WHERE account_id = $1", w.account_a) == 0


async def test_foreign_client_and_foreign_product_are_404s_from_the_rpc(conn, world):
    w = world
    with pytest.raises(HTTPException) as info:
        await _issue(conn, w, [_line(w.product_a)], client_id=w.client_b)
    assert info.value.status_code == 404 and info.value.code == "client_not_found"

    with pytest.raises(HTTPException) as info:
        await _issue(conn, w, [_line(w.product_other)])
    assert info.value.status_code == 404 and info.value.code == "product_not_found"
    assert await conn.fetchval("SELECT count(*) FROM public.delivery_notes WHERE account_id = $1", w.account_a) == 0


# ══════════════════════════════════════════════════════════════════════════════
# Edición
# ══════════════════════════════════════════════════════════════════════════════

async def _update(conn, w: World, dn_id: str, revision: int, items: list[DeliveryNoteItemIn], *, user=None, **over) -> dict:
    user = user or w.seller
    async with _as(conn, user):
        return await svc.update_delivery_note(
            DeliveryNoteRepository(conn), _auth(user), str(w.account_a), dn_id,
            _update_payload(w, revision, items, **over), conn=conn,
        )


async def test_editing_only_the_price_leaves_the_ledger_alone(conn, world):
    w = world
    dn = await _issue(conn, w, [_line(w.product_a, "2", "1000", "2000")])
    before = len(await _movements(conn, dn["id"]))

    edited = await _update(conn, w, dn["id"], dn["revision"], [_line(w.product_a, "2", "1200", "2400")])

    assert edited["revision"] == 2 and Decimal(str(edited["total"])) == Decimal("2400")
    assert len(await _movements(conn, dn["id"])) == before
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(8)


async def test_a_change_in_one_product_mirrors_only_that_pair(conn, world):
    """A=2/B=1 -> A=2/B=3: un par espejo sobre B y NINGÚN movimiento sobre A."""
    w = world
    dn = await _issue(conn, w, [_line(w.product_a, "2", "1000", "2000"), _line(w.product_b, "1", "700", "700")])
    a_before = len(await _movements(conn, dn["id"], w.product_a))
    b_before = len(await _movements(conn, dn["id"], w.product_b))

    await _update(conn, w, dn["id"], 1, [_line(w.product_a, "2", "1000", "2000"), _line(w.product_b, "3", "700", "2100")])

    assert len(await _movements(conn, dn["id"], w.product_a)) == a_before
    assert len(await _movements(conn, dn["id"], w.product_b)) == b_before + 2
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(8)
    assert await _stock(conn, w.product_b, w.branch_a) == Decimal(7)


async def test_a_stale_revision_is_a_409_and_changes_nothing(conn, world):
    w = world
    dn = await _issue(conn, w, [_line(w.product_a)])
    await _update(conn, w, dn["id"], 1, [_line(w.product_a, "1", "1000", "1000")])

    with pytest.raises(HTTPException) as info:
        await _update(conn, w, dn["id"], 1, [_line(w.product_a, "5", "1000", "5000")])

    assert info.value.status_code == 409 and info.value.code == "delivery_note_changed"
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(9)


async def test_moving_the_note_to_another_branch_moves_the_stock(conn, world):
    w = world
    await conn.execute("SELECT public.c21_apply_branch_stock_delta($1, $2, $3, 5)", w.account_a, w.product_a, w.branch_a2)
    dn = await _issue(conn, w, [_line(w.product_a, "2", "1000", "2000")])

    await _update(conn, w, dn["id"], 1, [_line(w.product_a, "2", "1000", "2000")], branch_id=w.branch_a2)

    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(10)
    assert await _stock(conn, w.product_a, w.branch_a2) == Decimal(3)


# ══════════════════════════════════════════════════════════════════════════════
# Anulación
# ══════════════════════════════════════════════════════════════════════════════

async def _cancel(conn, w: World, dn_id: str, revision: int, *, user=None, reason="Se devolvió la mercadería") -> dict:
    user = user or w.admin
    async with _as(conn, user):
        return await svc.cancel_delivery_note(
            DeliveryNoteRepository(conn), _auth(user), str(w.account_a), dn_id,
            DeliveryNoteCancelIn(revision=revision, reason=reason), conn=conn,
        )


async def test_cancel_restores_the_stock_and_records_the_reason(conn, world):
    w = world
    dn = await _issue(conn, w, [_line(w.product_a, "4", "1000", "4000")])
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(6)

    canceled = await _cancel(conn, w, dn["id"], dn["revision"])

    assert canceled["status"] == "canceled"
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(10)
    last = canceled["history"][-1]
    assert (last["from_status"], last["to_status"], last["reason"]) == ("issued", "canceled", "Se devolvió la mercadería")
    moves = await _movements(conn, dn["id"])
    assert sum(Decimal(m["quantity_delta"]) for m in moves) == 0
    assert [m["reference_type"] for m in moves] == ["delivery_note", "delivery_note_reversal"]


async def test_the_seller_and_the_stock_role_cannot_cancel_and_nothing_changes(conn, world):
    w = world
    dn = await _issue(conn, w, [_line(w.product_a, "4", "1000", "4000")])
    for user in (w.seller, w.stocker):
        with pytest.raises(HTTPException) as info:
            await _cancel(conn, w, dn["id"], dn["revision"], user=user)
        assert info.value.status_code == 403
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(6)


async def test_canceling_twice_is_a_409_and_does_not_restore_twice(conn, world):
    w = world
    dn = await _issue(conn, w, [_line(w.product_a, "4", "1000", "4000")])
    await _cancel(conn, w, dn["id"], dn["revision"])

    with pytest.raises(HTTPException) as info:
        await _cancel(conn, w, dn["id"], dn["revision"])
    assert info.value.status_code == 409 and info.value.code == "delivery_note_invalid_state"
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(10)


# ══════════════════════════════════════════════════════════════════════════════
# Lecturas: tenencia, listado, resumen, PDF
# ══════════════════════════════════════════════════════════════════════════════

async def test_a_note_of_another_account_reads_as_missing(conn, world):
    w = world
    dn = await _issue(conn, w, [_line(w.product_a)])

    async with _as(conn, w.owner_b):
        repo = DeliveryNoteRepository(conn)
        assert await repo.get_delivery_note(dn["id"], str(w.account_b)) is None
        with pytest.raises(HTTPException) as info:
            await svc.get_delivery_note(repo, str(w.account_b), dn["id"])
        assert info.value.status_code == 404 and info.value.code == "delivery_note_not_found"
        with pytest.raises(HTTPException) as info_pdf:
            await svc.get_delivery_note_pdf(repo, str(w.account_b), dn["id"])
        assert info_pdf.value.status_code == 404


async def test_a_foreign_account_cannot_edit_or_cancel_through_the_rpcs(conn, world):
    w = world
    dn = await _issue(conn, w, [_line(w.product_a, "2", "1000", "2000")])
    branch_b = await conn.fetchval("SELECT id FROM public.branches WHERE account_id = $1 LIMIT 1", w.account_b)
    repo = DeliveryNoteRepository(conn)
    # cada intento en su propia 'request': un error aborta la transacción
    async with _as(conn, w.owner_b):
        with pytest.raises(HTTPException) as e1:
            await svc.update_delivery_note(
                repo, _auth(w.owner_b), str(w.account_b), dn["id"],
                DeliveryNoteUpdateIn(revision=1, client_id=w.client_b, branch_id=branch_b,
                                     delivery_address=None, notes=None, items=[_line(w.product_other)]),
                conn=conn)
    assert e1.value.status_code == 404
    async with _as(conn, w.owner_b):
        with pytest.raises(HTTPException) as e2:
            await svc.cancel_delivery_note(
                repo, _auth(w.owner_b), str(w.account_b), dn["id"],
                DeliveryNoteCancelIn(revision=1, reason="Intento ajeno"), conn=conn)
    assert e2.value.status_code == 404
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(8)
    assert await conn.fetchval("SELECT status FROM public.delivery_notes WHERE id = $1::uuid", dn["id"]) == "issued"


async def test_list_filters_search_by_number_and_the_pending_summary(conn, world):
    w = world
    one = await _issue(conn, w, [_line(w.product_a, "1", "1000", "1000")])
    two = await _issue(conn, w, [_line(w.product_a, "1", "2000", "2000")])
    await _issue(conn, w, [_line(w.product_b, "1", "700", "700")], branch_id=w.branch_a)
    await _cancel(conn, w, two["id"], two["revision"])

    async with _as(conn, w.seller):
        repo = DeliveryNoteRepository(conn)
        account = str(w.account_a)
        everything = await svc.list_delivery_notes(
            repo, account, page=0, page_size=25, direction="sale", status=None, client_id=None, branch_id=None, q=None)
        pending = await svc.list_delivery_notes(
            repo, account, page=0, page_size=25, direction=None, status="issued",
            client_id=str(w.client_a), branch_id=str(w.branch_a), q=None)
        by_number = await svc.list_delivery_notes(
            repo, account, page=0, page_size=25, direction=None, status=None, client_id=None, branch_id=None, q="R-2")
        by_name = await svc.list_delivery_notes(
            repo, account, page=0, page_size=25, direction=None, status="canceled", client_id=None,
            branch_id=None, q="Integ A")
        paged = await svc.list_delivery_notes(
            repo, account, page=1, page_size=2, direction=None, status=None, client_id=None, branch_id=None, q=None)

    assert everything["total"] == 3 and everything["pages"] == 1
    assert everything["summary"]["pending_count"] == 2
    assert Decimal(str(everything["summary"]["pending_total"])) == Decimal("1700")
    assert pending["total"] == 2 and all(i["status"] == "issued" for i in pending["items"])
    assert [i["id"] for i in by_number["items"]] == [two["id"]]
    assert by_number["items"][0]["number_label"] == "R-00000002"
    # el resumen no depende de la pestaña: con status=canceled sigue contando los 2 pendientes
    assert by_name["total"] == 1 and by_name["summary"]["pending_count"] == 2
    assert paged["pages"] == 2 and len(paged["items"]) == 1
    assert {i["id"] for i in everything["items"]} >= {one["id"], two["id"]}
    assert all(i["item_count"] == 1 for i in everything["items"])


def _pdf_text(pdf: bytes) -> str:
    return "\n".join(page.extract_text() for page in PdfReader(io.BytesIO(pdf)).pages)


async def test_pdf_by_default_has_no_prices_and_with_the_flag_it_does(conn, world):
    w = world
    dn = await _issue(conn, w, [_line(w.product_a, "2", "1234.50", "2469")])

    async with _as(conn, w.cashier):
        repo = DeliveryNoteRepository(conn)
        plain, plain_name = await svc.get_delivery_note_pdf(repo, str(w.account_a), dn["id"])
        priced, priced_name = await svc.get_delivery_note_pdf(repo, str(w.account_a), dn["id"], show_prices=True)

    plain_text, priced_text = _pdf_text(plain), _pdf_text(priced)
    for needle in ("REMITO", "R-00000001", "no válido como factura", "__integ_rv_producto_a__"):
        assert needle in plain_text, needle
    assert "2.469" not in plain_text and "1.234" not in plain_text and "TOTAL" not in plain_text
    assert "2.469" in priced_text and "TOTAL" in priced_text
    assert plain_name == "remito-R-00000001.pdf" and priced_name == "remito-R-00000001-con-precios.pdf"


async def test_the_pdf_of_a_canceled_note_carries_the_stamp(conn, world):
    w = world
    dn = await _issue(conn, w, [_line(w.product_a)])
    await _cancel(conn, w, dn["id"], dn["revision"])
    async with _as(conn, w.seller):
        pdf, _ = await svc.get_delivery_note_pdf(DeliveryNoteRepository(conn), str(w.account_a), dn["id"])
    assert "ANULADO" in _pdf_text(pdf)


# ══════════════════════════════════════════════════════════════════════════════
# PostgREST: el documento no admite escritura directa
# ══════════════════════════════════════════════════════════════════════════════

async def test_the_application_role_cannot_write_the_tables_directly(conn, world):
    w = world
    dn = await _issue(conn, w, [_line(w.product_a)])
    statements = [
        ("INSERT INTO public.delivery_notes (account_id, direction, branch_id, client_id, status, issued_on) "
         f"VALUES ('{w.account_a}', 'sale', '{w.branch_a}', '{w.client_a}', 'issued', current_date)"),
        f"UPDATE public.delivery_notes SET status = 'canceled' WHERE id = '{dn['id']}'",
        f"UPDATE public.delivery_note_items SET quantity = 999 WHERE delivery_note_id = '{dn['id']}'",
        f"DELETE FROM public.delivery_notes WHERE id = '{dn['id']}'",
    ]
    for sql in statements:
        with pytest.raises(asyncpg.PostgresError):
            async with _as(conn, w.owner_a, authenticated_role=True):
                result = await conn.execute(sql)
                # una escritura que no falla por permiso tendría que no afectar ninguna fila
                if result.endswith(" 0"):
                    raise asyncpg.PostgresError("0 filas (RLS)")
    still = await conn.fetchval("SELECT status FROM public.delivery_notes WHERE id = $1::uuid", dn["id"])
    assert still == "issued"
    assert await _stock(conn, w.product_a, w.branch_a) == Decimal(8)
