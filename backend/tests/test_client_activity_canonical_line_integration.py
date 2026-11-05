"""
v31-document-lines-consistency (H-15, D8) — integración contra el Postgres LOCAL real.

Marcado `@pytest.mark.integration`: corre en el tier de integración de `KPI_Validation.yml`; a mano con
`-m integration` y el stack local levantado.

Por qué hace falta además de test_client_repository.py: aquel mockea asyncpg y sólo asserta que el SQL emitido
contiene el filtro. Acá se ejecuta la consulta REAL contra una venta que tiene la forma de las 23 de producción:
una línea canónica (`variant_id IS NULL`) MÁS una fila legacy de variante en `sale_items`, ambas con el mismo
subtotal. Antes del cambio el LEFT JOIN sin filtro multiplicaba la fila de `sales` por dos y la actividad del
cliente contaba el importe doble ($1.273.900 de más repartidos en 14 clientes).
"""
from __future__ import annotations

import uuid
from decimal import Decimal

import asyncpg
import pytest

from backend.repositories.client_repository import ClientRepository

from backend.tests.integration_db import connect, set_claims

pytestmark = pytest.mark.integration


async def _seed(conn: asyncpg.Connection) -> tuple[uuid.UUID, uuid.UUID, uuid.UUID, uuid.UUID]:
    """Anchor sintético + una venta de 3 × 100 a un cliente + la fila legacy de variante del mismo subtotal."""
    user_id = uuid.uuid4()
    await conn.execute(
        """
        INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
        VALUES ($1, 'authenticated', 'authenticated', $2, now(), now(),
                jsonb_build_object('name', 'Integración Clientes', 'phone', '', 'locality', '', 'province', ''))
        """,
        user_id, f"client-canonical-line-{user_id}@test.local",
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
        VALUES ($1, $2, '__integ_canonical_line__', 'CANON-INTEG', 50, 100) RETURNING id
        """,
        user_id, account_id,
    )
    await conn.execute("SELECT public.c21_apply_branch_stock_delta($1, $2, $3, 50)", account_id, product_id, branch_id)
    client_id = await conn.fetchval(
        "INSERT INTO public.clients (user_id, account_id, name) VALUES ($1, $2, 'Cliente canónico') RETURNING id",
        user_id, account_id,
    )
    async with conn.transaction():
        await set_claims(conn, user_id)
        await conn.fetchval(
            """
            SELECT public.rpc_create_sale_operation(
              'canon-integ-' || gen_random_uuid()::text, $1::uuid, CURRENT_DATE, 'ARS',
              jsonb_build_array(jsonb_build_object('product_id', $2::uuid, 'amount', 100.00, 'quantity', 3, 'unit_id', NULL)),
              $3::uuid, NULL, NULL)
            """,
            client_id, product_id, branch_id,
        )
    sale_id = await conn.fetchval("SELECT id FROM public.sales WHERE account_id = $1", account_id)
    variant_id = await conn.fetchval(
        "INSERT INTO public.product_variants (product_id, name) VALUES ($1, 'Variante legacy') RETURNING id", product_id,
    )
    await conn.execute(
        """
        INSERT INTO public.sale_items (sale_id, account_id, product_id, variant_id, quantity, price, subtotal, name_snapshot)
        VALUES ($1, $2, NULL, $3, 3, 100, 300, '__integ_canonical_line__')
        """,
        sale_id, account_id, variant_id,
    )
    return user_id, account_id, client_id, sale_id


async def _cleanup(conn: asyncpg.Connection, user_id: uuid.UUID, account_id: uuid.UUID) -> None:
    async with conn.transaction():
        for sql in (
            "DELETE FROM public.sale_items WHERE account_id = $1",
            "DELETE FROM public.stock_movements WHERE account_id = $1",
            "DELETE FROM public.sales WHERE account_id = $1",
            "DELETE FROM public.events WHERE account_id = $1",
            "DELETE FROM public.notifications WHERE account_id = $1",
            "DELETE FROM public.branch_stock WHERE account_id = $1",
            "DELETE FROM public.product_variants WHERE product_id IN (SELECT id FROM public.products WHERE account_id = $1)",
            "DELETE FROM public.products WHERE account_id = $1",
            "DELETE FROM public.clients WHERE account_id = $1",
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
    c = await connect()
    try:
        yield c
    finally:
        await c.close()


async def test_sale_with_legacy_variant_row_counts_once_in_client_activity(conn: asyncpg.Connection):
    """La venta de 300 con su fila legacy de variante suma 300 (no 600) en el resumen de actividad."""
    user_id, account_id, client_id, sale_id = await _seed(conn)
    try:
        assert await conn.fetchval("SELECT count(*) FROM public.sale_items WHERE sale_id = $1", sale_id) == 2

        repo = ClientRepository(conn)
        today = await repo.get_reference_today()
        row = await repo.get_activity_for(str(client_id), str(account_id), today=today)

        assert row is not None
        assert row["purchase_count"] == 1
        assert Decimal(row["total_spent"]) == Decimal("300")
    finally:
        await _cleanup(conn, user_id, account_id)


async def test_sale_with_legacy_variant_row_counts_once_in_listing_and_history(conn: asyncpg.Connection):
    """Mismo importe en el listado de actividad y en el historial de compras (las tres consultas comparten el JOIN)."""
    user_id, account_id, client_id, _sale_id = await _seed(conn)
    try:
        repo = ClientRepository(conn)
        today = await repo.get_reference_today()

        page = await repo.list_activity_page(str(account_id), today=today, page=0, size=25)
        mine = [r for r in page["items"] if r["id"] == client_id]
        assert len(mine) == 1
        assert Decimal(mine[0]["total_spent"]) == Decimal("300")

        history = await repo.list_purchases_page(str(client_id), str(account_id), page=0, size=25)
        assert history["total"] == 1
        assert Decimal(history["items"][0]["total"]) == Decimal("300")
        assert history["items"][0]["item_count"] == 1
    finally:
        await _cleanup(conn, user_id, account_id)


async def test_clean_sale_without_variant_row_is_unchanged(conn: asyncpg.Connection):
    """Triangulación: una venta sin fila de variante da el mismo importe (el filtro no recorta lo canónico)."""
    user_id, account_id, client_id, sale_id = await _seed(conn)
    try:
        await conn.execute("DELETE FROM public.sale_items WHERE sale_id = $1 AND variant_id IS NOT NULL", sale_id)
        assert await conn.fetchval("SELECT count(*) FROM public.sale_items WHERE sale_id = $1", sale_id) == 1

        repo = ClientRepository(conn)
        today = await repo.get_reference_today()
        row = await repo.get_activity_for(str(client_id), str(account_id), today=today)

        assert row is not None
        assert row["purchase_count"] == 1
        assert Decimal(row["total_spent"]) == Decimal("300")
    finally:
        await _cleanup(conn, user_id, account_id)
