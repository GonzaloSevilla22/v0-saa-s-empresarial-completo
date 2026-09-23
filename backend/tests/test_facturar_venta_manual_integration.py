"""
venta-editable-vs-promocion-legacy (20261061000001) — integración contra el
Postgres LOCAL real (stack de `supabase start`). Marcado
`@pytest.mark.integration`: excluido del gate de CI (`pytest backend/tests -m
"not integration"`, Backend_Tests.yml); correr a mano con `-m integration`
con el stack local levantado. La evidencia de CI de que la RPC corre es el
gate SQL supabase/tests/test_facturar_venta_manual.sql.

Por qué hace falta además de test_facturar_venta_manual.py: aquel mockea
asyncpg y sólo asserta que el query string NOMBRA la RPC. Así vivió tres
meses un 42883 ("function min(uuid) does not exist") que abortaba la
promoción en CADA llamada — lo detecta Postgres al ejecutar la función, nunca
un mock. Este test llama `SalesRepository.promote_to_order` (el mismo código
que usa el endpoint) contra la base real, con los claims del JWT puestos en
la transacción como hace `backend/core/database.py`.
"""
from __future__ import annotations

import json
import os
import uuid

import asyncpg
import pytest

from backend.repositories.sales_repository import SalesRepository

DSN = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@127.0.0.1:54322/postgres")

pytestmark = pytest.mark.integration


async def _set_claims(conn: asyncpg.Connection, user_id: uuid.UUID) -> None:
    claims = json.dumps({"sub": str(user_id), "role": "authenticated"})
    await conn.execute("SELECT set_config('request.jwt.claims', $1, true)", claims)
    await conn.execute("SELECT set_config('request.jwt.claim.sub', $1, true)", str(user_id))


async def _seed(conn: asyncpg.Connection) -> tuple[uuid.UUID, uuid.UUID, uuid.UUID]:
    """Anchor sintético (handle_new_user crea cuenta + sucursal) y una venta
    cargada a mano de 2 líneas: 500 × 2 + un servicio sin producto 150 × 1."""
    user_id = uuid.uuid4()
    await conn.execute(
        """
        INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
        VALUES ($1, 'authenticated', 'authenticated', $2, now(), now(),
                jsonb_build_object('name', 'Integración Facturar', 'phone', '', 'locality', '', 'province', ''))
        """,
        user_id, f"facturar-venta-integ-{user_id}@test.local",
    )
    account_id = await conn.fetchval(
        "SELECT account_id FROM public.account_members WHERE user_id = $1 ORDER BY created_at LIMIT 1", user_id,
    )
    branch_id = await conn.fetchval(
        "SELECT id FROM public.branches WHERE account_id = $1 ORDER BY created_at LIMIT 1", account_id,
    )
    assert account_id is not None and branch_id is not None, "SETUP: handle_new_user no creó cuenta/sucursal"
    product_id = await conn.fetchval(
        """
        INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
        VALUES ($1, $2, '__integ_fvm_product__', 'FVM-INTEG', 300, 500) RETURNING id
        """,
        user_id, account_id,
    )
    await conn.execute("SELECT public.c21_apply_branch_stock_delta($1, $2, $3, 50)", account_id, product_id, branch_id)
    async with conn.transaction():
        await _set_claims(conn, user_id)
        raw = await conn.fetchval(
            """
            SELECT public.rpc_create_sale_operation(
              'fvm-integ-' || gen_random_uuid()::text, NULL, CURRENT_DATE, 'ARS',
              jsonb_build_array(
                jsonb_build_object('product_id', $1::uuid, 'amount', 500.00, 'quantity', 2, 'unit_id', NULL),
                jsonb_build_object('product_id', NULL, 'amount', 150.00, 'quantity', 1, 'unit_id', NULL)),
              $2::uuid, NULL, NULL)::text
            """,
            product_id, branch_id,
        )
    operation_id = uuid.UUID(json.loads(raw)["operation_id"])
    return user_id, account_id, operation_id


async def _cleanup(conn: asyncpg.Connection, user_id: uuid.UUID, account_id: uuid.UUID) -> None:
    async with conn.transaction():
        for sql in (
            "DELETE FROM public.sales_orders WHERE account_id = $1",
            "DELETE FROM public.sale_items WHERE account_id = $1",
            "DELETE FROM public.stock_movements WHERE account_id = $1",
            "DELETE FROM public.sales WHERE account_id = $1",
            "DELETE FROM public.events WHERE account_id = $1",
            "DELETE FROM public.notifications WHERE account_id = $1",
            "DELETE FROM public.branch_stock WHERE account_id = $1",
            "DELETE FROM public.products WHERE account_id = $1",
            "DELETE FROM public.payment_methods WHERE account_id = $1",
            "DELETE FROM public.product_categories WHERE account_id = $1",
            "DELETE FROM public.account_member_roles WHERE account_id = $1",
            "DELETE FROM public.cashboxes WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = $1)",
        ):
            await conn.execute(sql, account_id)
        await conn.execute("SET LOCAL session_replication_role = replica")
        await conn.execute("DELETE FROM public.audit_logs WHERE account_id = $1", account_id)
        await conn.execute("DELETE FROM public.branches WHERE account_id = $1", account_id)
        await conn.execute("DELETE FROM public.account_members WHERE account_id = $1", account_id)
        await conn.execute("DELETE FROM public.accounts WHERE id = $1", account_id)
        await conn.execute("SET LOCAL session_replication_role = DEFAULT")
        await conn.execute("DELETE FROM public.analytics_events WHERE user_id = $1", user_id)
        await conn.execute("DELETE FROM public.profiles WHERE id = $1", user_id)
        await conn.execute("DELETE FROM public.email_logs WHERE user_id = $1", user_id)
        await conn.execute("DELETE FROM public.operation_idempotency WHERE user_id = $1", user_id)
        await conn.execute("DELETE FROM auth.users WHERE id = $1", user_id)


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


async def test_promote_to_order_runs_against_real_postgres(conn: asyncpg.Connection):
    """El repositorio del endpoint promueve de verdad: en main esto levantaba
    asyncpg.exceptions.UndefinedFunctionError (42883, min(uuid))."""
    user_id, account_id, operation_id = await _seed(conn)
    try:
        async with conn.transaction():
            await _set_claims(conn, user_id)
            result = await SalesRepository(conn).promote_to_order(str(operation_id))

        assert result["replayed"] is False
        assert result["sale_operation_id"] == str(operation_id)
        order = await conn.fetchrow(
            "SELECT status, total, account_id, sale_operation_id FROM public.sales_orders WHERE id = $1",
            uuid.UUID(result["sales_order_id"]),
        )
        assert order is not None
        assert order["status"] == "confirmed"
        assert str(order["total"]) == "1150.00"
        assert order["account_id"] == account_id
        assert order["sale_operation_id"] == operation_id
        n_lines = await conn.fetchval(
            "SELECT count(*) FROM public.sales_order_items WHERE sales_order_id = $1",
            uuid.UUID(result["sales_order_id"]),
        )
        assert n_lines == 2

        # TRIANGULATE: la segunda llamada es replay de la MISMA orden.
        async with conn.transaction():
            await _set_claims(conn, user_id)
            again = await SalesRepository(conn).promote_to_order(str(operation_id))
        assert again["replayed"] is True
        assert again["sales_order_id"] == result["sales_order_id"]
    finally:
        await _cleanup(conn, user_id, account_id)


async def test_promote_to_order_foreign_operation_is_p0404(conn: asyncpg.Connection):
    """Tenencia contra la base real: otro usuario no puede promover la venta
    (P0404 operation_not_found), y no se crea ninguna orden."""
    user_id, account_id, operation_id = await _seed(conn)
    stranger = uuid.uuid4()
    try:
        with pytest.raises(asyncpg.PostgresError) as exc_info:
            async with conn.transaction():
                await _set_claims(conn, stranger)
                await SalesRepository(conn).promote_to_order(str(operation_id))
        assert exc_info.value.sqlstate == "P0404"
        assert "operation_not_found" in str(exc_info.value)
        n = await conn.fetchval(
            "SELECT count(*) FROM public.sales_orders WHERE sale_operation_id = $1", operation_id,
        )
        assert n == 0
    finally:
        await _cleanup(conn, user_id, account_id)
