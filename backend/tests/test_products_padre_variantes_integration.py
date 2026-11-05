"""
productos-padre-variantes (tanda A, task 6.3, "RED que persiste de verdad") — integración contra el
Postgres LOCAL real (stack de `supabase start`, con 20261093000001 aplicada). Marcado
`@pytest.mark.integration`: corre en el tier de integración de `KPI_Validation.yml`; a mano con
`-m integration`. La evidencia de CI de la base es el gate SQL supabase/tests/test_productos_padre_variantes.sql.

Por qué además de test_products_padre_variantes.py / test_products_unit_relabel_bulk_price.py: aquellos
prueban el servicio contra dobles. Éste llama al MISMO `ProductRepository` + `services.products` que usan
los endpoints contra la base real, con los claims del JWT puestos en la transacción como hace
`backend/core/database.py` y como el rol `authenticated` (Paso 2), y lee lo que quedó persistido:
la unidad de la familia, el stock sin convertir, los precios, la auditoría y el CHECK del padre.
"""
from __future__ import annotations

import contextlib
import json
import uuid
from decimal import Decimal

import asyncpg
import pytest
from fastapi import HTTPException

from backend.core.errors import ProblemHTTPException
from backend.repositories.plan_limits_repository import PlanLimitsRepository
from backend.repositories.product_category_repository import ProductCategoryRepository
from backend.repositories.product_repository import ProductRepository
from backend.schemas.products import ProductCreate
from backend.services import products as svc

from backend.tests.integration_db import connect

pytestmark = pytest.mark.integration


class World:
    """Dos cuentas: A con dueño y depósito (rol stock); B con su dueño."""

    def __init__(self) -> None:
        self.owner_a = uuid.uuid4()
        self.owner_b = uuid.uuid4()
        self.stocker = uuid.uuid4()
        self.account_a: uuid.UUID
        self.account_b: uuid.UUID
        self.accounts: list[uuid.UUID] = []
        self.branch_a: uuid.UUID
        self.kg: uuid.UUID
        self.g: uuid.UUID
        self.u: uuid.UUID
        self.unit_b: uuid.UUID

    @property
    def users(self) -> list[uuid.UUID]:
        return [self.owner_a, self.owner_b, self.stocker]


async def _claims(conn: asyncpg.Connection, user_id: uuid.UUID) -> None:
    await conn.execute(
        "SELECT set_config('request.jwt.claims', $1, true)",
        json.dumps({"sub": str(user_id), "role": "authenticated"}),
    )
    await conn.execute("SELECT set_config('request.jwt.claim.sub', $1, true)", str(user_id))


@contextlib.asynccontextmanager
async def _as(conn: asyncpg.Connection, user_id: uuid.UUID):
    """Una 'request': transacción + claims + SET LOCAL ROLE authenticated (como el Paso 2)."""
    async with conn.transaction():
        await _claims(conn, user_id)
        await conn.execute("SET LOCAL ROLE authenticated")
        yield


def _auth(user_id: uuid.UUID) -> dict:
    # Sin claim `account_roles`: los guards resuelven el pivot en la base.
    return {"user_id": str(user_id), "sub": str(user_id), "role": "user", "plan": "pro"}


async def _new_product(conn, w: World, name: str, *, price="100", cost="50", ptype="tracked", parent=None, base_unit=None) -> uuid.UUID:
    return await conn.fetchval(
        "INSERT INTO public.products (user_id, account_id, name, price, cost, stock_control_type, parent_id, is_variant, base_unit_id) "
        "VALUES ($1, $2, $3, $4::numeric, $5::numeric, $6, $7, $8, $9) RETURNING id",
        w.owner_a, w.account_a, name, Decimal(price), None if cost is None else Decimal(cost), ptype, parent,
        parent is not None, base_unit,
    )


async def _stock_in(conn, w: World, product: uuid.UUID, qty: str) -> None:
    await conn.execute(
        "SELECT public.op_stock_movement($1, $2, $3, 'p', $4, $5::numeric, 'adjustment', NULL, NULL, NULL, NULL, 'integ', NULL)",
        w.account_a, w.owner_a, product, w.branch_a, Decimal(qty),
    )


async def _seed(conn: asyncpg.Connection) -> World:
    w = World()
    for tag, uid in (("owner-a", w.owner_a), ("owner-b", w.owner_b), ("stock", w.stocker)):
        await conn.execute(
            """
            INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
            VALUES ($1, 'authenticated', 'authenticated', $2, now(), now(),
                    jsonb_build_object('name', $3::text, 'phone', '', 'locality', '', 'province', ''))
            """,
            uid, f"ppv-integ-{tag}-{uid}@test.local", f"Integración Padre {tag}",
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

    # El depósito es miembro de A con rol `stock` (no puede corregir unidades ni modificar precios).
    await conn.execute("SET session_replication_role = replica")
    try:
        await conn.execute(
            "DELETE FROM public.account_member_roles WHERE member_id IN "
            "(SELECT id FROM public.account_members WHERE user_id = $1)", w.stocker)
        await conn.execute("DELETE FROM public.account_members WHERE user_id = $1", w.stocker)
    finally:
        await conn.execute("SET session_replication_role = DEFAULT")
    member_id = await conn.fetchval(
        "INSERT INTO public.account_members (account_id, user_id, role) VALUES ($1, $2, 'member') RETURNING id",
        w.account_a, w.stocker)
    await conn.execute(
        "INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES ($1, $2, 'stock')",
        w.account_a, member_id)

    w.branch_a = await conn.fetchval("SELECT public.c26_default_branch($1)", w.account_a)
    w.kg = await conn.fetchval(
        "INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system) "
        "VALUES ($1, 'Kilogramo Integ', 'kg', 'weight', 1, false) RETURNING id", w.account_a)
    w.g = await conn.fetchval(
        "INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, base_unit_id, is_system) "
        "VALUES ($1, 'Gramo Integ', 'g', 'weight', 0.001, $2, false) RETURNING id", w.account_a, w.kg)
    w.u = await conn.fetchval(
        "INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system) "
        "VALUES ($1, 'Unidad Integ', 'u', 'unit', 1, false) RETURNING id", w.account_a)
    w.unit_b = await conn.fetchval(
        "INSERT INTO public.units_of_measure (account_id, name, symbol, type, factor, is_system) "
        "VALUES ($1, 'Kilogramo B Integ', 'kg', 'weight', 1, false) RETURNING id", w.account_b)
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
    c = await connect()
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


async def _family(conn, w: World, *, stock="12", base_unit=None) -> tuple[uuid.UUID, uuid.UUID, uuid.UUID]:
    """Padre variant_only (sin precio/costo) con dos variantes; la primera con stock y movimientos."""
    parent = await _new_product(conn, w, "__integ_ppv_padre__", price="0", cost=None, ptype="variant_only", base_unit=base_unit)
    v1 = await _new_product(conn, w, "__integ_ppv_v1__", parent=parent)
    v2 = await _new_product(conn, w, "__integ_ppv_v2__", price="200", cost="80", parent=parent)
    if Decimal(stock) != 0:
        await _stock_in(conn, w, v1, stock)
    return parent, v1, v2


async def _unit_of(conn, product: uuid.UUID):
    return await conn.fetchval("SELECT base_unit_id FROM public.products WHERE id = $1", product)


async def _price_of(conn, product: uuid.UUID) -> Decimal:
    return Decimal(await conn.fetchval("SELECT price FROM public.products WHERE id = $1", product))


# ══════════════════════════════════════════════════════════════════════════════
# Relabel de la unidad de una familia
# ══════════════════════════════════════════════════════════════════════════════

async def test_relabel_with_history_changes_the_label_and_converts_nothing(conn, world):
    w = world
    parent, v1, v2 = await _family(conn, w, stock="12")
    movements = await conn.fetchval("SELECT count(*) FROM public.stock_movements WHERE product_id = $1", v1)

    async with _as(conn, w.owner_a):
        preview = await svc.relabel_product_unit(ProductRepository(conn), _auth(w.owner_a), conn, str(parent), str(w.kg), True)
    assert preview["changed"] is True and preview["variants"] == 2 and preview["products_with_stock"] == 1
    assert preview["movements"] == movements and preview["conflict_unit"] is None
    assert await _unit_of(conn, parent) is None, "el dry-run no escribe"

    async with _as(conn, w.owner_a):
        applied = await svc.relabel_product_unit(ProductRepository(conn), _auth(w.owner_a), conn, str(parent), str(w.kg), False)
    assert applied["changed"] is True and str(applied["root_id"]) == str(parent)
    assert await _unit_of(conn, parent) == w.kg
    assert await _unit_of(conn, v1) is None and await _unit_of(conn, v2) is None
    assert Decimal(await conn.fetchval("SELECT quantity FROM public.branch_stock WHERE product_id = $1", v1)) == Decimal(12)
    assert await conn.fetchval("SELECT count(*) FROM public.stock_movements WHERE product_id = $1", v1) == movements
    assert await conn.fetchval(
        "SELECT count(*) FROM public.audit_logs WHERE action = 'product.unit_relabel' AND entity_id = $1", parent) == 1


async def test_the_ordinary_path_is_still_locked_after_a_relabel(conn, world):
    w = world
    parent, v1, _ = await _family(conn, w, stock="5", base_unit=None)
    async with _as(conn, w.owner_a):
        await svc.relabel_product_unit(ProductRepository(conn), _auth(w.owner_a), conn, str(parent), str(w.kg), False)

    with pytest.raises(asyncpg.PostgresError) as info:
        async with _as(conn, w.owner_a):
            await conn.execute("UPDATE public.products SET base_unit_id = $1 WHERE id = $2", w.u, parent)
    assert info.value.sqlstate == "P0409" and str(info.value).startswith("base_unit_locked")
    assert await _unit_of(conn, parent) == w.kg


async def test_a_line_in_another_unit_is_a_409_conflict_and_the_preview_names_it(conn, world):
    w = world
    parent, v1, _ = await _family(conn, w, stock="5")
    await conn.execute(
        "INSERT INTO public.sales (user_id, account_id, product_id, amount, quantity, unit_id) VALUES ($1, $2, $3, 100, 1, $4)",
        w.owner_a, w.account_a, v1, w.g)

    async with _as(conn, w.owner_a):
        preview = await svc.relabel_product_unit(ProductRepository(conn), _auth(w.owner_a), conn, str(parent), str(w.kg), True)
    assert str(preview["conflict_unit"]) == str(w.g)

    with pytest.raises(ProblemHTTPException) as info:
        async with _as(conn, w.owner_a):
            await svc.relabel_product_unit(ProductRepository(conn), _auth(w.owner_a), conn, str(parent), str(w.kg), False)
    assert info.value.status_code == 409 and info.value.code == "unit_relabel_conflict"
    assert await _unit_of(conn, parent) is None

    async with _as(conn, w.owner_a):
        ok = await svc.relabel_product_unit(ProductRepository(conn), _auth(w.owner_a), conn, str(parent), str(w.g), False)
    assert ok["changed"] is True and await _unit_of(conn, parent) == w.g


async def test_a_stock_role_member_cannot_relabel_and_nothing_changes(conn, world):
    w = world
    parent, _, _ = await _family(conn, w)
    with pytest.raises(HTTPException) as info:
        async with _as(conn, w.stocker):
            await svc.relabel_product_unit(ProductRepository(conn), _auth(w.stocker), conn, str(parent), str(w.kg), False)
    assert info.value.status_code == 403 and getattr(info.value, "code", None) == "insufficient_role"
    assert await _unit_of(conn, parent) is None
    assert await conn.fetchval("SELECT count(*) FROM public.audit_logs WHERE action = 'product.unit_relabel' AND entity_id = $1", parent) == 0


async def test_the_database_rejects_a_stock_role_even_if_the_service_guard_is_skipped(conn, world):
    """Defensa en profundidad: la RPC repite el rol (P0403), no depende del guard del servicio."""
    w = world
    parent, _, _ = await _family(conn, w)
    with pytest.raises(asyncpg.PostgresError) as info:
        async with _as(conn, w.stocker):
            await ProductRepository(conn).relabel_unit(str(parent), str(w.kg), False)
    assert info.value.sqlstate == "P0403" and str(info.value).startswith("insufficient_role")


async def test_a_product_of_another_account_is_a_404(conn, world):
    w = world
    parent, _, _ = await _family(conn, w)
    with pytest.raises(ProblemHTTPException) as info:
        async with _as(conn, w.owner_b):
            await svc.relabel_product_unit(ProductRepository(conn), _auth(w.owner_b), conn, str(parent), str(w.unit_b), False)
    assert info.value.status_code == 404 and info.value.code == "product_not_found"
    assert await _unit_of(conn, parent) is None


# ══════════════════════════════════════════════════════════════════════════════
# Precios en lote
# ══════════════════════════════════════════════════════════════════════════════

async def test_bulk_price_preview_then_apply_persists_and_audits(conn, world):
    w = world
    p1 = await _new_product(conn, w, "__integ_ppv_a__", price="1000", cost="600")
    p2 = await _new_product(conn, w, "__integ_ppv_b__", price="2345", cost="900")
    ids = [str(p1), str(p2)]

    async with _as(conn, w.owner_a):
        preview = await svc.bulk_adjust_prices(
            ProductRepository(conn), _auth(w.owner_a), conn, ids, "percent", "increase", Decimal("10"), True)
    assert preview["changed"] == 2 and preview["requested"] == 2
    assert await _price_of(conn, p1) == Decimal(1000), "la vista previa no escribe"

    async with _as(conn, w.owner_a):
        applied = await svc.bulk_adjust_prices(
            ProductRepository(conn), _auth(w.owner_a), conn, ids, "percent", "increase", Decimal("10"), False)
    assert applied == preview
    assert await _price_of(conn, p1) == Decimal(1100) and await _price_of(conn, p2) == Decimal(2580)
    assert Decimal(await conn.fetchval("SELECT cost FROM public.products WHERE id = $1", p1)) == Decimal(600), "el costo no cambia"
    assert await conn.fetchval(
        "SELECT count(*) FROM public.audit_logs WHERE account_id = $1 AND action = 'product.bulk_price_adjusted'", w.account_a) == 1


async def test_bulk_price_expands_a_parent_and_skips_it(conn, world):
    w = world
    parent, v1, v2 = await _family(conn, w, stock="0")
    async with _as(conn, w.owner_a):
        out = await svc.bulk_adjust_prices(
            ProductRepository(conn), _auth(w.owner_a), conn, [str(parent)], "amount", "increase", Decimal("50"), False)
    assert out["eligible"] == 2 and out["skipped_parents"] == 1 and out["changed"] == 2
    assert await _price_of(conn, v1) == Decimal(150) and await _price_of(conn, v2) == Decimal(250)
    assert await _price_of(conn, parent) == Decimal(0)


async def test_bulk_price_ignores_ids_of_another_account_without_error(conn, world):
    w = world
    mine = await _new_product(conn, w, "__integ_ppv_mine__", price="100")
    theirs = await conn.fetchval(
        "INSERT INTO public.products (user_id, account_id, name, price, cost) VALUES ($1, $2, '__integ_ppv_SECRETO__', 500, 100) RETURNING id",
        w.owner_b, w.account_b)
    async with _as(conn, w.owner_a):
        out = await svc.bulk_adjust_prices(
            ProductRepository(conn), _auth(w.owner_a), conn, [str(mine), str(theirs)], "percent", "increase", Decimal("10"), False)
    assert out["requested"] == 2 and out["eligible"] == 1 and out["changed"] == 1
    assert await _price_of(conn, theirs) == Decimal(500)


async def test_a_stock_role_member_cannot_change_prices_in_bulk(conn, world):
    w = world
    p1 = await _new_product(conn, w, "__integ_ppv_x__", price="100")
    with pytest.raises(HTTPException) as info:
        async with _as(conn, w.stocker):
            await svc.bulk_adjust_prices(
                ProductRepository(conn), _auth(w.stocker), conn, [str(p1)], "percent", "increase", Decimal("10"), False)
    assert info.value.status_code == 403 and getattr(info.value, "code", None) == "insufficient_role"
    assert await _price_of(conn, p1) == Decimal(100)

    with pytest.raises(asyncpg.PostgresError) as db_info:
        async with _as(conn, w.stocker):
            await ProductRepository(conn).bulk_adjust_prices([str(p1)], "percent", "increase", Decimal("10"), False)
    assert db_info.value.sqlstate == "P0403"
    assert await _price_of(conn, p1) == Decimal(100)


async def test_bulk_price_range_error_from_the_database_is_a_422(conn, world):
    w = world
    p1 = await _new_product(conn, w, "__integ_ppv_r__", price="100")
    with pytest.raises(ProblemHTTPException) as info:
        async with _as(conn, w.owner_a):
            await svc.bulk_adjust_prices(
                ProductRepository(conn), _auth(w.owner_a), conn, [str(p1)], "percent", "decrease", Decimal("95"), False)
    assert info.value.status_code == 422 and info.value.code == "bulk_price_out_of_range"
    assert await _price_of(conn, p1) == Decimal(100)


# ══════════════════════════════════════════════════════════════════════════════
# Contrato del padre, de punta a punta
# ══════════════════════════════════════════════════════════════════════════════

async def _create(conn, w: World, payload: ProductCreate) -> dict:
    async with _as(conn, w.owner_a):
        return await svc.create_product(
            ProductRepository(conn), _auth(w.owner_a), str(w.account_a), payload,
            PlanLimitsRepository(conn), ProductCategoryRepository(conn), conn=conn)


async def test_a_parent_is_created_without_price_and_a_variant_inherits_the_unit(conn, world):
    w = world
    parent = await _create(conn, w, ProductCreate(name="__integ_ppv_new_parent__", stock_control_type="variant_only", base_unit_id=w.kg))
    assert Decimal(str(parent["price"])) == 0 and parent["cost"] is None and parent["barcode"] is None
    assert str(parent["base_unit_id"]) == str(w.kg)

    variant = await _create(conn, w, ProductCreate(
        name="__integ_ppv_new_variant__", parent_id=str(parent["id"]), is_variant=True, stock_control_type="tracked",
        base_unit_id=w.u, price=Decimal("1200"), cost=Decimal("700")))
    assert await _unit_of(conn, variant["id"]) is None, "la variante hereda: base_unit_id propio NULL"
    assert str(variant["base_unit_id"]) == str(w.kg), "la vista expone la unidad efectiva (la del padre)"
    assert Decimal(str(variant["price"])) == 1200 and Decimal(str(variant["cost"])) == 700, "sin herencia de precio/costo"


async def test_a_parent_with_a_price_is_a_422_and_nothing_is_created(conn, world):
    w = world
    before = await conn.fetchval("SELECT count(*) FROM public.products WHERE account_id = $1", w.account_a)
    with pytest.raises(ProblemHTTPException) as info:
        await _create(conn, w, ProductCreate(name="__integ_ppv_bad_parent__", stock_control_type="variant_only", price=Decimal("1500")))
    assert info.value.status_code == 422 and info.value.code == "parent_field_not_allowed" and info.value.field == "price"
    assert await conn.fetchval("SELECT count(*) FROM public.products WHERE account_id = $1", w.account_a) == before


async def test_the_database_check_rejects_a_price_on_a_parent_and_the_service_translates_it(conn, world):
    w = world
    parent = await _new_product(conn, w, "__integ_ppv_check__", price="0", cost=None, ptype="variant_only")
    with pytest.raises(asyncpg.CheckViolationError) as info:
        async with _as(conn, w.owner_a):
            await ProductRepository(conn).update(str(parent), str(w.account_a), {"price": Decimal("10")})
    problem = svc._translate_check_violation(info.value)
    assert info.value.constraint_name == "products_variant_only_no_price_cost"
    assert isinstance(problem, ProblemHTTPException) and problem.status_code == 422 and problem.code == "parent_field_not_allowed"
    assert await _price_of(conn, parent) == Decimal(0)
