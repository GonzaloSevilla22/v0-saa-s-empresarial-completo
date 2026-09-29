"""
balanza-etiquetas-pos (task 2.1, "RED que persiste de verdad") — integración
contra el Postgres LOCAL real (stack de `supabase start`). Marcado
`@pytest.mark.integration`: excluido del gate de CI (`-m "not integration"`);
correr a mano con `-m integration` con el stack local levantado y
20261066000001 aplicada. La evidencia de CI del esquema es el gate SQL
supabase/tests/test_balanza_etiquetas_pos.sql.

Por qué además de test_products_scale_plu.py: aquel verifica el SQL que el
repository emite contra un asyncpg mockeado. Éste llama al MISMO
`ProductRepository.create`/`update` que usa el endpoint contra la base real y
lee la fila: el alta deja `scale_plu = 509` y la edición con `None` la borra
(con el repository anterior, INSERT de lista fija + UPDATE que descartaba los
`None`, las dos lecturas fallaban).
"""
from __future__ import annotations

import os
import uuid

import asyncpg
import pytest

from backend.repositories.product_repository import ProductRepository

DSN = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@127.0.0.1:54322/postgres")

pytestmark = pytest.mark.integration


async def _seed_account(conn: asyncpg.Connection) -> tuple[uuid.UUID, uuid.UUID]:
    user_id = uuid.uuid4()
    await conn.execute(
        """
        INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
        VALUES ($1, 'authenticated', 'authenticated', $2, now(), now(),
                jsonb_build_object('name', 'Integración Balanza', 'phone', '', 'locality', '', 'province', ''))
        """,
        user_id, f"balanza-integ-{user_id}@test.local",
    )
    account_id = await conn.fetchval(
        "SELECT account_id FROM public.account_members WHERE user_id = $1 ORDER BY created_at LIMIT 1", user_id,
    )
    assert account_id is not None, "SETUP: handle_new_user no creó la cuenta"
    return user_id, account_id


async def _cleanup(conn: asyncpg.Connection, user_id: uuid.UUID, account_id: uuid.UUID) -> None:
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
            await conn.execute(f'DELETE FROM public."{row["table_name"]}" WHERE account_id = $1', account_id)
        await conn.execute("DELETE FROM public.accounts WHERE id = $1", account_id)
    finally:
        await conn.execute("SET session_replication_role = DEFAULT")
    await conn.execute("DELETE FROM public.account_members WHERE user_id = $1", user_id)
    await conn.execute("DELETE FROM public.billing_events WHERE user_id = $1", user_id)
    await conn.execute("DELETE FROM public.email_logs WHERE user_id = $1", user_id)
    await conn.execute("DELETE FROM public.profiles WHERE id = $1", user_id)
    await conn.execute("DELETE FROM auth.users WHERE id = $1", user_id)


async def test_repository_persists_and_clears_scale_plu():
    conn = await asyncpg.connect(DSN)
    user_id, account_id = await _seed_account(conn)
    try:
        repo = ProductRepository(conn)

        created = await repo.create(str(user_id), str(account_id), {"name": "__integ_balanza_tomate__", "price": 4.8, "scale_plu": 509})
        assert created is not None
        assert created["scale_plu"] == 509
        stored = await conn.fetchval("SELECT scale_plu FROM public.products WHERE id = $1", created["id"])
        assert stored == 509

        # Ausente conserva.
        await repo.update(str(created["id"]), str(account_id), {"price": 5})
        assert await conn.fetchval("SELECT scale_plu FROM public.products WHERE id = $1", created["id"]) == 509

        # null desasigna.
        await repo.update(str(created["id"]), str(account_id), {"scale_plu": None})
        assert await conn.fetchval("SELECT scale_plu FROM public.products WHERE id = $1", created["id"]) is None
    finally:
        await _cleanup(conn, user_id, account_id)
        await conn.close()


async def test_duplicate_plu_in_account_raises_named_unique_violation():
    conn = await asyncpg.connect(DSN)
    user_id, account_id = await _seed_account(conn)
    try:
        repo = ProductRepository(conn)
        await repo.create(str(user_id), str(account_id), {"name": "__integ_balanza_a__", "price": 1, "scale_plu": 261})
        with pytest.raises(asyncpg.UniqueViolationError) as info:
            await repo.create(str(user_id), str(account_id), {"name": "__integ_balanza_b__", "price": 1, "scale_plu": 261})
        assert info.value.constraint_name == "idx_products_scale_plu_account_unique"
    finally:
        await _cleanup(conn, user_id, account_id)
        await conn.close()
