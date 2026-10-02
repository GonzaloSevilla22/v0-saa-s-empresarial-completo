"""
presupuestos-modulo (tanda A, task 2.1, "RED que persiste de verdad") —
integración contra el Postgres LOCAL real (stack de `supabase start`, con
20261067000001 aplicada). Marcado `@pytest.mark.integration`: excluido del gate
de CI (`-m "not integration"`); correr a mano con `-m integration`. La
evidencia de CI del esquema es el gate SQL
supabase/tests/test_presupuestos_modulo.sql.

Por qué además de test_quotes_module.py: aquel prueba el repositorio contra una
conexión doble y sólo asserta que el SQL NOMBRA las RPCs. Éste llama al MISMO
`QuoteRepository` + `services.quotes` que usa el endpoint contra la base real,
con los claims del JWT puestos en la transacción como hace
`backend/core/database.py`, y lee lo que quedó persistido. El repositorio
anterior escribía `quotes`/`quote_items` con INSERT directo (sin número, con
snapshots de un producto ajeno): contra la base nueva, sin políticas de
escritura, ese camino ya no existe.
"""
from __future__ import annotations

import contextlib
import datetime
import io
import json
import os
import uuid

import asyncpg
import pytest
from fastapi import HTTPException
from pypdf import PdfReader

from backend.repositories.quote_repository import QuoteRepository
from backend.schemas.quotes import (
    QuoteConvertIn,
    QuoteIn,
    QuoteItemIn,
    QuoteSettingsIn,
    QuoteTransitionIn,
    QuoteUpdateIn,
)
from backend.services import quotes as svc

DSN = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@127.0.0.1:54322/postgres")

pytestmark = pytest.mark.integration


class World:
    """Dos cuentas con sus usuarios, cliente y productos."""

    def __init__(self) -> None:
        self.owner_a = uuid.uuid4()
        self.owner_b = uuid.uuid4()
        self.seller = uuid.uuid4()
        self.cashier = uuid.uuid4()
        self.account_a: uuid.UUID
        self.account_b: uuid.UUID
        self.accounts: list[uuid.UUID] = []
        self.client_a: uuid.UUID
        self.client_b: uuid.UUID
        self.product_a: uuid.UUID
        self.product_b: uuid.UUID
        self.unit_a: uuid.UUID

    @property
    def users(self) -> list[uuid.UUID]:
        return [self.owner_a, self.owner_b, self.seller, self.cashier]


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
    # Sin claim `account_roles`: el guard resuelve el pivot en la base (D10).
    return {"user_id": str(user_id), "sub": str(user_id), "role": "user"}


def _line(product_id: uuid.UUID | None, qty="2", price="750", subtotal="1500", **extra) -> QuoteItemIn:
    return QuoteItemIn(product_id=product_id, quantity=qty, price=price, subtotal=subtotal, **extra)


async def _seed(conn: asyncpg.Connection) -> World:
    w = World()
    for tag, uid in (("owner-a", w.owner_a), ("owner-b", w.owner_b), ("seller", w.seller), ("cashier", w.cashier)):
        await conn.execute(
            """
            INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
            VALUES ($1, 'authenticated', 'authenticated', $2, now(), now(),
                    jsonb_build_object('name', $3::text, 'phone', '', 'locality', '', 'province', ''))
            """,
            uid, f"quotes-integ-{tag}-{uid}@test.local", f"Integración Presupuestos {tag}",
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

    # seller y cashier: empleados de A con UNA sola membresía (la propia que
    # les provisionó handle_new_user se quita, para que current_account_ids()
    # sea determinista).
    await conn.execute("SET session_replication_role = replica")
    try:
        await conn.execute(
            "DELETE FROM public.account_member_roles WHERE member_id IN "
            "(SELECT id FROM public.account_members WHERE user_id = ANY($1::uuid[]))", [w.seller, w.cashier])
        await conn.execute("DELETE FROM public.account_members WHERE user_id = ANY($1::uuid[])", [w.seller, w.cashier])
    finally:
        await conn.execute("SET session_replication_role = DEFAULT")
    for uid, role in ((w.seller, "seller"), (w.cashier, "cashier")):
        member_id = await conn.fetchval(
            "INSERT INTO public.account_members (account_id, user_id, role) VALUES ($1, $2, 'member') RETURNING id",
            w.account_a, uid)
        await conn.execute(
            "INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES ($1, $2, $3)",
            w.account_a, member_id, role)

    await conn.execute(
        "UPDATE public.profiles SET business_name = 'Almacén Integración', phone = '2615550101' WHERE id = $1",
        w.owner_a)

    w.client_a = await conn.fetchval(
        "INSERT INTO public.clients (user_id, account_id, name, phone) VALUES ($1, $2, 'Cliente Integ A', '2615550202') RETURNING id",
        w.owner_a, w.account_a)
    w.client_b = await conn.fetchval(
        "INSERT INTO public.clients (user_id, account_id, name) VALUES ($1, $2, 'Cliente Integ B') RETURNING id",
        w.owner_b, w.account_b)
    w.unit_a = await conn.fetchval(
        "INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system) "
        "VALUES ($1, 'Unidad Integ', 'u', 'unit', 1, false) RETURNING id", w.account_a)
    w.product_a = await conn.fetchval(
        "INSERT INTO public.products (user_id, account_id, name, sku, cost, price) "
        "VALUES ($1, $2, '__integ_pm_producto_a__', 'IPM-A', 500, 1000) RETURNING id", w.owner_a, w.account_a)
    w.product_b = await conn.fetchval(
        "INSERT INTO public.products (user_id, account_id, name, sku, cost, price) "
        "VALUES ($1, $2, '__integ_pm_SECRETO_B__', 'IPM-B', 777, 999) RETURNING id", w.owner_b, w.account_b)
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


async def _create(conn, w: World, *, user=None, account=None, client=None, items=None, **extra) -> dict:
    user = user or w.owner_a
    payload = QuoteIn(
        client_id=client or w.client_a,
        items=items or [_line(w.product_a)],
        **extra,
    )
    async with _as(conn, user):
        return await svc.create_quote(
            QuoteRepository(conn), _auth(user), str(account or w.account_a), payload, conn=conn,
        )


def _update_payload(quote: dict, w: World, **over) -> QuoteUpdateIn:
    data = {
        "revision": quote["revision"], "client_id": w.client_a, "branch_id": None,
        "valid_until": quote["valid_until"] + datetime.timedelta(days=5), "notes": None,
        "items": [_line(w.product_a)],
    }
    data.update(over)
    return QuoteUpdateIn(**data)


# ══════════════════════════════════════════════════════════════════════════════

async def test_create_persists_numbered_quote_with_server_total_and_snapshots(conn, world: World):
    quote = await _create(
        conn, world,
        notes="Entrega en 48 hs",
        items=[
            _line(world.product_a, qty="2", price="750", subtotal="1500", unit_id=world.unit_a),
            QuoteItemIn(quantity="1", price="300.50", subtotal="300.50", description="Instalación"),
        ],
    )

    assert quote["number"] == 1 and quote["number_label"] == "P-00000001"
    assert quote["status"] == "draft" and quote["revision"] == 1
    assert quote["total"] == 1800.50  # lo calcula el servidor: Σ subtotal
    today = await conn.fetchval("SELECT public.reporting_local_today()")
    assert quote["valid_until"] == today + datetime.timedelta(days=15)
    assert quote["client_name"] == "Cliente Integ A" and quote["client_phone"] == "2615550202"

    first, second = quote["items"]
    assert first["name_snapshot"] == "__integ_pm_producto_a__" and first["sku_snapshot"] == "IPM-A"
    assert first["unit_cost_snapshot"] == 500 and first["unit_symbol"] == "u"
    assert second["product_id"] is None and second["name_snapshot"] == "Instalación"

    assert [(h["from_status"], h["to_status"], str(h["performed_by"])) for h in quote["history"]] == [
        (None, "draft", str(world.owner_a)),
    ]
    stored = await conn.fetchval("SELECT count(*) FROM public.quote_items WHERE quote_id = $1", quote["id"])
    assert stored == 2


async def test_numbers_are_correlative_per_account(conn, world: World):
    a1 = await _create(conn, world)
    a2 = await _create(conn, world)
    b1 = await _create(
        conn, world, user=world.owner_b, account=world.account_b, client=world.client_b,
        items=[_line(world.product_b)],
    )

    assert (a1["number"], a2["number"]) == (1, 2)
    assert b1["number"] == 1  # cuentas independientes


async def test_foreign_product_and_client_are_rejected_without_leaking(conn, world: World):
    with pytest.raises(HTTPException) as info:
        await _create(conn, world, items=[_line(world.product_b)])
    assert (info.value.status_code, info.value.code) == (404, "product_not_found")

    with pytest.raises(HTTPException) as info:
        await _create(conn, world, client=world.client_b)
    assert (info.value.status_code, info.value.code) == (404, "client_not_found")

    leaked = await conn.fetchval("SELECT count(*) FROM public.quote_items WHERE name_snapshot = '__integ_pm_SECRETO_B__'")
    assert leaked == 0
    assert await conn.fetchval("SELECT count(*) FROM public.quotes WHERE account_id = $1", world.account_a) == 0


async def test_cashier_is_rejected_before_any_write(conn, world: World):
    with pytest.raises(HTTPException) as info:
        await _create(conn, world, user=world.cashier)
    assert (info.value.status_code, info.value.code) == (403, "insufficient_role")
    assert await conn.fetchval("SELECT count(*) FROM public.quotes WHERE account_id = $1", world.account_a) == 0


async def test_cashier_is_also_rejected_by_the_rpc_itself(conn, world: World):
    """Defensa en profundidad: aunque el service se salteara su guard, la RPC
    verifica el rol antes de escribir."""
    async with _as(conn, world.cashier):
        with pytest.raises(asyncpg.PostgresError) as info:
            await QuoteRepository(conn).create_quote(
                client_id=str(world.client_a), branch_id=None, valid_until=None, notes=None,
                items=[{"product_id": str(world.product_a), "unit_id": None, "quantity": "1",
                        "price": "10", "subtotal": "10", "description": None}],
            )
    assert info.value.sqlstate == "P0403"


async def test_update_replaces_lines_retakes_snapshots_and_bumps_revision(conn, world: World):
    quote = await _create(conn, world)
    await conn.execute("UPDATE public.products SET name = '__integ_pm_renombrado__' WHERE id = $1", world.product_a)

    async with _as(conn, world.seller):
        updated = await svc.update_quote(
            QuoteRepository(conn), _auth(world.seller), str(world.account_a), str(quote["id"]),
            _update_payload(
                quote, world, notes="nueva",
                items=[_line(world.product_a, qty="3", price="600", subtotal="1800")],
            ),
            conn=conn,
        )

    assert updated["revision"] == 2 and updated["status"] == "draft"
    assert updated["total"] == 1800 and updated["notes"] == "nueva"
    assert [i["name_snapshot"] for i in updated["items"]] == ["__integ_pm_renombrado__"]
    assert updated["updated_by"] == world.seller and updated["updated_at"] is not None
    assert await conn.fetchval("SELECT count(*) FROM public.quote_items WHERE quote_id = $1", quote["id"]) == 1


async def test_update_with_a_stale_revision_is_409_quote_changed_and_changes_nothing(conn, world: World):
    quote = await _create(conn, world)
    async with _as(conn, world.owner_a):
        await svc.update_quote(
            QuoteRepository(conn), _auth(world.owner_a), str(world.account_a), str(quote["id"]),
            _update_payload(quote, world), conn=conn,
        )

    with pytest.raises(HTTPException) as info:
        async with _as(conn, world.owner_a):
            await svc.update_quote(
                QuoteRepository(conn), _auth(world.owner_a), str(world.account_a), str(quote["id"]),
                _update_payload(quote, world, notes="pisada"), conn=conn,  # sigue en la versión 1
            )

    assert (info.value.status_code, info.value.code) == (409, "quote_changed")
    assert await conn.fetchval("SELECT notes FROM public.quotes WHERE id = $1", quote["id"]) is None
    assert await conn.fetchval("SELECT revision FROM public.quotes WHERE id = $1", quote["id"]) == 2


async def test_editing_a_rejected_quote_reopens_it_with_history(conn, world: World):
    quote = await _create(conn, world)
    qid = str(quote["id"])
    async with _as(conn, world.seller):
        await svc.transition_quote(
            QuoteRepository(conn), _auth(world.seller), str(world.account_a), qid,
            QuoteTransitionIn(action="reject", reason="precio alto"), conn=conn,
        )
    async with _as(conn, world.seller):
        reopened = await svc.update_quote(
            QuoteRepository(conn), _auth(world.seller), str(world.account_a), qid,
            _update_payload(quote, world), conn=conn,
        )

    assert reopened["status"] == "draft"
    steps = [(h["from_status"], h["to_status"], h["reason"]) for h in reopened["history"]]
    assert steps == [(None, "draft", None), ("draft", "rejected", "precio alto"), ("rejected", "draft", None)]
    assert reopened["history"][-1]["performed_by"] == world.seller


async def test_accepted_quote_cannot_be_edited(conn, world: World):
    quote = await _create(conn, world)
    # `accepted` sólo se alcanza por la conversión (tanda B); acá se fuerza
    # como `postgres` para probar el guard de la edición.
    await conn.execute("SET session_replication_role = replica")
    await conn.execute("UPDATE public.quotes SET status = 'accepted' WHERE id = $1", quote["id"])
    await conn.execute("SET session_replication_role = DEFAULT")

    with pytest.raises(HTTPException) as info:
        async with _as(conn, world.owner_a):
            await svc.update_quote(
                QuoteRepository(conn), _auth(world.owner_a), str(world.account_a), str(quote["id"]),
                _update_payload(quote, world), conn=conn,
            )
    assert (info.value.status_code, info.value.code) == (409, "quote_locked_converted")


async def test_send_is_idempotent_and_blocks_deletion(conn, world: World):
    quote = await _create(conn, world)
    qid = str(quote["id"])
    repo = QuoteRepository(conn)
    for _ in range(2):
        async with _as(conn, world.seller):
            sent = await svc.transition_quote(
                repo, _auth(world.seller), str(world.account_a), qid, QuoteTransitionIn(action="send"), conn=conn,
            )
    assert sent["status"] == "sent" and sent["sent_at"] is not None
    assert [h["to_status"] for h in sent["history"]] == ["draft", "sent"], "reenviar no duplica el historial"

    with pytest.raises(HTTPException) as info:
        async with _as(conn, world.seller):
            await svc.delete_quote(repo, _auth(world.seller), str(world.account_a), qid, conn=conn)
    assert (info.value.status_code, info.value.code) == (409, "quote_not_deletable")


async def test_delete_removes_a_never_sent_draft_but_keeps_its_history(conn, world: World):
    quote = await _create(conn, world)
    qid = str(quote["id"])
    async with _as(conn, world.owner_a):
        await svc.delete_quote(QuoteRepository(conn), _auth(world.owner_a), str(world.account_a), qid, conn=conn)

    async with _as(conn, world.owner_a):
        assert await QuoteRepository(conn).get_quote(qid, str(world.account_a)) is None
    assert await conn.fetchval("SELECT count(*) FROM public.quote_items WHERE quote_id = $1", quote["id"]) == 0
    assert await conn.fetchval(
        "SELECT count(*) FROM public.document_status_history WHERE document_type = 'quote' AND document_id = $1",
        quote["id"]) == 1


async def test_other_account_cannot_read_or_edit_a_quote(conn, world: World):
    quote = await _create(conn, world)
    qid = str(quote["id"])
    repo = QuoteRepository(conn)

    async with _as(conn, world.owner_b):
        assert await repo.get_quote(qid, str(world.account_b)) is None

    with pytest.raises(HTTPException) as info:
        async with _as(conn, world.owner_b):
            await svc.update_quote(
                repo, _auth(world.owner_b), str(world.account_b), qid,
                _update_payload(quote, world), conn=conn,
            )
    assert (info.value.status_code, info.value.code) == (404, "quote_not_found")


async def test_listing_filters_search_and_derived_expiry(conn, world: World):
    repo = QuoteRepository(conn)
    await _create(conn, world)
    q2 = await _create(conn, world)
    q3 = await _create(conn, world)
    async with _as(conn, world.seller):
        await svc.transition_quote(repo, _auth(world.seller), str(world.account_a), str(q2["id"]),
                                   QuoteTransitionIn(action="send"), conn=conn)
    # q3 vencido pero el barrido todavía no corrió (estado materializado draft)
    await conn.execute("UPDATE public.quotes SET valid_until = CURRENT_DATE - 3 WHERE id = $1", q3["id"])

    async def listing(**filters):
        async with _as(conn, world.cashier):  # lectura abierta a cualquier miembro
            return await svc.list_quotes(
                repo, str(world.account_a),
                **{"page": 0, "page_size": 25, "status": None, "client_id": None, "q": None, **filters},
            )

    everything = await listing()
    assert everything["total"] == 3 and everything["pages"] == 1
    assert [i["number"] for i in everything["items"]] == [3, 2, 1], "más nuevos primero"

    drafts = await listing(status="draft")
    assert [i["number"] for i in drafts["items"]] == [1], "un borrador vencido NO es borrador en la pestaña"
    sent = await listing(status="sent")
    assert [i["number"] for i in sent["items"]] == [2]
    expired = await listing(status="expired")
    assert [i["number"] for i in expired["items"]] == [3]
    assert expired["items"][0]["is_expired"] is True and expired["items"][0]["status"] == "draft"
    assert drafts["items"][0]["is_expired"] is False

    # búsqueda por número en los tres formatos y por nombre de cliente
    for text in ("P-2", "2", "00000002", "P-00000002", "p-2"):
        assert [i["number"] for i in (await listing(q=text))["items"]] == [2], text
    by_name = await listing(q="integ a")
    assert by_name["total"] == 3
    by_client = await listing(client_id=str(world.client_a))
    assert by_client["total"] == 3
    other_client = await listing(client_id=str(world.client_b))
    assert other_client["total"] == 0

    # paginación
    page = await listing(page=1, page_size=2)
    assert (page["total"], page["pages"], len(page["items"])) == (3, 2, 1)
    assert [i["number"] for i in page["items"]] == [1]


async def test_listing_never_leaks_another_account(conn, world: World):
    await _create(conn, world)
    async with _as(conn, world.owner_b):
        page = await svc.list_quotes(
            QuoteRepository(conn), str(world.account_b),
            page=0, page_size=25, status=None, client_id=None, q=None,
        )
    assert page["total"] == 0


async def test_default_validity_setting_requires_owner_or_admin_and_drives_new_quotes(conn, world: World):
    repo = QuoteRepository(conn)
    async with _as(conn, world.seller):
        with pytest.raises(HTTPException) as info:
            await svc.set_quote_settings(
                repo, _auth(world.seller), str(world.account_a), QuoteSettingsIn(default_quote_validity_days=30), conn=conn,
            )
    assert info.value.status_code == 403

    async with _as(conn, world.owner_a):
        assert await svc.set_quote_settings(
            repo, _auth(world.owner_a), str(world.account_a), QuoteSettingsIn(default_quote_validity_days=30), conn=conn,
        ) == {"default_quote_validity_days": 30}
        assert await svc.get_quote_settings(repo, str(world.account_a)) == {"default_quote_validity_days": 30}

    quote = await _create(conn, world)
    today = await conn.fetchval("SELECT public.reporting_local_today()")
    assert quote["valid_until"] == today + datetime.timedelta(days=30)


async def test_commercial_issuer_is_complete_for_a_seller_who_is_not_the_owner(conn, world: World):
    """Con la lectura directa de `profiles` (su RLS sólo deja ver el perfil
    propio) el vendedor recibiría el emisor vacío: la RPC definer lo resuelve."""
    async with _as(conn, world.seller, authenticated_role=True):
        issuer = await QuoteRepository(conn).get_commercial_issuer(str(world.account_a))

    assert issuer["business_name"] == "Almacén Integración"
    assert issuer["phone"] == "2615550101"
    assert set(issuer) == {"nombre_fantasia", "razon_social", "cuit", "domicilio_comercial", "business_name", "phone"}

    with pytest.raises(asyncpg.PostgresError) as info:
        async with _as(conn, world.owner_b, authenticated_role=True):
            await QuoteRepository(conn).get_commercial_issuer(str(world.account_a))
    assert info.value.sqlstate == "P0404"


async def test_direct_writes_are_no_longer_possible_for_the_app_role(conn, world: World):
    quote = await _create(conn, world)
    with pytest.raises(asyncpg.PostgresError):
        async with _as(conn, world.owner_a, authenticated_role=True):
            await conn.execute("UPDATE public.quotes SET notes = 'directo' WHERE id = $1", quote["id"])
    assert await conn.fetchval("SELECT notes FROM public.quotes WHERE id = $1", quote["id"]) is None


def _pdf_text(pdf: bytes) -> str:
    return "\n".join(page.extract_text() for page in PdfReader(io.BytesIO(pdf)).pages)


async def test_pdf_of_a_seller_who_is_not_the_owner_carries_the_owners_business(conn, world: World):
    """El PDF lo descarga un vendedor (rol `authenticated`, como en producción
    con el Paso 2 de tenencia): el emisor es el del DUEÑO, no "Mi Negocio"."""
    quote = await _create(conn, world, items=[_line(world.product_a, unit_id=world.unit_a)])

    async with _as(conn, world.seller, authenticated_role=True):
        pdf, filename = await svc.get_quote_pdf(QuoteRepository(conn), str(world.account_a), str(quote["id"]))

    text = _pdf_text(pdf)
    assert filename == "presupuesto-P-00000001.pdf"
    assert "Almacén Integración" in text and "2615550101" in text
    assert "Mi Negocio" not in text
    assert "Cliente Integ A" in text and "__integ_pm_producto_a__" in text
    assert "no válido como factura" in text


async def test_pdf_of_another_account_is_a_404_identical_to_a_missing_one(conn, world: World):
    quote = await _create(conn, world)
    repo = QuoteRepository(conn)

    async with _as(conn, world.owner_b):
        with pytest.raises(HTTPException) as foreign:
            await svc.get_quote_pdf(repo, str(world.account_b), str(quote["id"]))
        with pytest.raises(HTTPException) as missing:
            await svc.get_quote_pdf(repo, str(world.account_b), str(uuid.uuid4()))

    assert (foreign.value.status_code, foreign.value.code) == (404, "quote_not_found")
    assert (missing.value.status_code, missing.value.code) == (404, "quote_not_found")
    assert foreign.value.detail == missing.value.detail


async def test_pdf_of_a_rejected_quote_is_stamped(conn, world: World):
    quote = await _create(conn, world)
    qid = str(quote["id"])
    async with _as(conn, world.owner_a):
        await svc.transition_quote(
            QuoteRepository(conn), _auth(world.owner_a), str(world.account_a), qid,
            QuoteTransitionIn(action="reject"), conn=conn,
        )

    async with _as(conn, world.cashier):  # lectura abierta a cualquier miembro
        pdf, _ = await svc.get_quote_pdf(QuoteRepository(conn), str(world.account_a), qid)

    assert "RECHAZADO" in _pdf_text(pdf)


# ══════════════════════════════════════════════════════════════════════════════
# Tanda B (6.5): conversión atómica a venta, contra la base real y con el rol
# `authenticated` adoptado como en prod (tenancy Paso 2).
# ══════════════════════════════════════════════════════════════════════════════

async def _stock(conn: asyncpg.Connection, w: World, qty: int) -> uuid.UUID:
    """Deja `qty` unidades de `product_a` en la sucursal por defecto de A."""
    branch = await conn.fetchval("SELECT public.c26_default_branch($1)", w.account_a)
    await conn.execute("SELECT public.c21_apply_branch_stock_delta($1, $2, $3, $4)", w.account_a, w.product_a, branch, qty)
    return branch


async def _payment_method(conn: asyncpg.Connection, account: uuid.UUID, kind: str) -> uuid.UUID:
    pm = await conn.fetchval(
        "SELECT id FROM public.payment_methods WHERE account_id = $1 AND kind = $2 AND is_active AND deleted_at IS NULL "
        "ORDER BY sort_order LIMIT 1", account, kind)
    assert pm, f"SETUP: handle_new_user no sembró una forma de pago '{kind}'"
    return pm


def _convert_payload(quote: dict, pm: uuid.UUID, **over) -> QuoteConvertIn:
    data = {"expected_revision": quote["revision"], "payment_method_id": pm}
    data.update(over)
    return QuoteConvertIn(**data)


async def _convert(conn, w: World, quote: dict, payload: QuoteConvertIn, *, user=None):
    user = user or w.owner_a
    async with _as(conn, user, authenticated_role=True):
        return await svc.convert_quote(
            QuoteRepository(conn), _auth(user), str(w.account_a), str(quote["id"]), payload, conn=conn,
        )


async def _effects(conn: asyncpg.Connection, w: World) -> tuple:
    """Huella de lo que una conversión escribe: si falla no debe cambiar."""
    return (
        await conn.fetchval("SELECT count(*) FROM public.sales_orders WHERE account_id = $1", w.account_a),
        await conn.fetchval("SELECT count(*) FROM public.sales WHERE account_id = $1", w.account_a),
        await conn.fetchval("SELECT COALESCE(sum(quantity), 0) FROM public.branch_stock WHERE account_id = $1", w.account_a),
        await conn.fetchval("SELECT count(*) FROM public.customer_account_movements WHERE account_id = $1", w.account_a),
        await conn.fetchval("SELECT count(*) FROM public.events WHERE account_id = $1", w.account_a),
        await conn.fetchval("SELECT count(*) FROM public.document_status_history WHERE account_id = $1", w.account_a),
    )


async def test_convert_creates_the_confirmed_sale_in_one_transaction_and_replays(conn, world: World):
    branch = await _stock(conn, world, 5)
    quote = await _create(conn, world, items=[_line(world.product_a, qty="2", price="1000", subtotal="2000")])
    pm = await _payment_method(conn, world.account_a, "credit")
    payload = _convert_payload(quote, pm, idempotency_key="integ-convert-1")

    result = await _convert(conn, world, quote, payload)

    assert result["replayed"] is False and result["quote_number"] == 1 and result["quote_number_label"] == "P-00000001"
    assert result["total"] == 2000
    order = await conn.fetchrow("SELECT * FROM public.sales_orders WHERE id = $1", result["sales_order_id"])
    assert order["status"] == "confirmed" and order["source_quote_id"] == quote["id"]
    assert str(order["sale_operation_id"]) == result["operation_id"] and order["branch_id"] == branch
    assert await conn.fetchval("SELECT status FROM public.quotes WHERE id = $1", quote["id"]) == "accepted"
    assert await conn.fetchval(
        "SELECT quantity FROM public.branch_stock WHERE product_id = $1 AND branch_id = $2", world.product_a, branch) == 3
    assert await conn.fetchval(
        "SELECT count(*) FROM public.sales WHERE operation_id = $1 AND account_id = $2",
        result["operation_id"], world.account_a) == 1
    assert await conn.fetchval(
        "SELECT count(*) FROM public.customer_account_movements WHERE account_id = $1", world.account_a) == 1
    assert {r["event_type"] for r in await conn.fetch(
        "SELECT event_type FROM public.events WHERE account_id = $1", world.account_a)} >= {"QuoteAccepted", "SaleConfirmed"}
    after_first = await _effects(conn, world)

    # Reintento con la misma clave sobre el mismo presupuesto: replay sin efectos.
    again = await _convert(conn, world, quote, payload)
    assert again["replayed"] is True and again["sales_order_id"] == result["sales_order_id"]
    assert await _effects(conn, world) == after_first

    # Otra clave sobre el ya convertido: el estado manda.
    with pytest.raises(HTTPException) as info:
        await _convert(conn, world, quote, _convert_payload(quote, pm, idempotency_key="integ-convert-2"))
    assert (info.value.status_code, info.value.code) == (409, "quote_invalid_state")
    assert await _effects(conn, world) == after_first


async def test_convert_with_insufficient_stock_is_409_and_changes_nothing(conn, world: World):
    await _stock(conn, world, 1)
    quote = await _create(conn, world, items=[_line(world.product_a, qty="2", price="1000", subtotal="2000")])
    pm = await _payment_method(conn, world.account_a, "credit")
    before = await _effects(conn, world)

    with pytest.raises(HTTPException) as info:
        await _convert(conn, world, quote, _convert_payload(quote, pm, idempotency_key="integ-convert-stock"))

    assert (info.value.status_code, info.value.code) == (409, "stock_insuficiente")
    assert await _effects(conn, world) == before
    assert await conn.fetchval("SELECT status FROM public.quotes WHERE id = $1", quote["id"]) == "draft"


async def test_convert_with_a_stale_revision_is_409_quote_changed(conn, world: World):
    await _stock(conn, world, 5)
    quote = await _create(conn, world)
    pm = await _payment_method(conn, world.account_a, "credit")
    before = await _effects(conn, world)

    with pytest.raises(HTTPException) as info:
        await _convert(conn, world, quote, _convert_payload(quote, pm, expected_revision=quote["revision"] + 1,
                                                            idempotency_key="integ-convert-rev"))

    assert (info.value.status_code, info.value.code) == (409, "quote_changed")
    assert await _effects(conn, world) == before


async def test_convert_rejects_a_cashier_a_foreign_quote_and_a_foreign_payment_method(conn, world: World):
    await _stock(conn, world, 5)
    quote = await _create(conn, world)
    pm = await _payment_method(conn, world.account_a, "credit")
    pm_b = await _payment_method(conn, world.account_b, "credit")
    before = await _effects(conn, world)

    with pytest.raises(HTTPException) as info:
        await _convert(conn, world, quote, _convert_payload(quote, pm, idempotency_key="integ-c-1"), user=world.cashier)
    assert (info.value.status_code, info.value.code) == (403, "insufficient_role")

    # Un presupuesto ajeno es indistinguible de uno inexistente.
    with pytest.raises(HTTPException) as info:
        async with _as(conn, world.owner_b, authenticated_role=True):
            await svc.convert_quote(
                QuoteRepository(conn), _auth(world.owner_b), str(world.account_b), str(quote["id"]),
                _convert_payload(quote, pm_b, idempotency_key="integ-c-2"), conn=conn,
            )
    assert (info.value.status_code, info.value.code) == (404, "quote_not_found")

    # La forma de pago de otra cuenta no se acepta.
    with pytest.raises(HTTPException) as info:
        await _convert(conn, world, quote, _convert_payload(quote, pm_b, idempotency_key="integ-c-3"))
    assert info.value.status_code == 404

    assert await _effects(conn, world) == before


async def test_the_same_key_on_another_quote_is_409_idempotency_key_conflict(conn, world: World):
    await _stock(conn, world, 5)
    q1 = await _create(conn, world)
    q2 = await _create(conn, world)
    pm = await _payment_method(conn, world.account_a, "credit")
    await _convert(conn, world, q1, _convert_payload(q1, pm, idempotency_key="integ-shared-key"))
    after_first = await _effects(conn, world)

    with pytest.raises(HTTPException) as info:
        await _convert(conn, world, q2, _convert_payload(q2, pm, idempotency_key="integ-shared-key"))

    assert (info.value.status_code, info.value.code) == (409, "idempotency_key_conflict")
    assert await _effects(conn, world) == after_first
    assert await conn.fetchval("SELECT status FROM public.quotes WHERE id = $1", q2["id"]) == "draft"
