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

import asyncpg
import pytest

from backend.repositories.product_repository import ProductRepository
from backend.tests.integration_db import cleanup_account as _cleanup
from backend.tests.integration_db import connect, seed_account

pytestmark = pytest.mark.integration


async def test_repository_persists_and_clears_scale_plu():
    conn = await connect()
    user_id, account_id = await seed_account(conn, "balanza-integ")
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
    conn = await connect()
    user_id, account_id = await seed_account(conn, "balanza-integ")
    try:
        repo = ProductRepository(conn)
        await repo.create(str(user_id), str(account_id), {"name": "__integ_balanza_a__", "price": 1, "scale_plu": 261})
        with pytest.raises(asyncpg.UniqueViolationError) as info:
            await repo.create(str(user_id), str(account_id), {"name": "__integ_balanza_b__", "price": 1, "scale_plu": 261})
        assert info.value.constraint_name == "idx_products_scale_plu_account_unique"
    finally:
        await _cleanup(conn, user_id, account_id)
        await conn.close()
