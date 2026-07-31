from __future__ import annotations

from unittest.mock import AsyncMock

import pytest

from backend.repositories.plan_limits_repository import PlanLimitsRepository, clear_cache


@pytest.fixture(autouse=True)
def _reset_cache():
    clear_cache()
    yield
    clear_cache()


async def test_get_limits_reads_from_plan_limits_table():
    conn = AsyncMock()
    conn.fetchrow = AsyncMock(
        return_value={"max_products": 2000, "max_clients": 1000, "max_suppliers": 300}
    )
    repo = PlanLimitsRepository(conn)

    limits = await repo.get_limits("avanzado")

    assert limits == {"max_products": 2000, "max_clients": 1000, "max_suppliers": 300}
    conn.fetchrow.assert_awaited_once()
    assert conn.fetchrow.await_args.args[1] == "avanzado"


async def test_get_limits_caches_within_ttl_second_call_does_not_query():
    """D5: caché en proceso — una segunda lectura del mismo plan dentro del TTL
    no dispara un segundo SELECT."""
    conn = AsyncMock()
    conn.fetchrow = AsyncMock(
        return_value={"max_products": 100, "max_clients": 50, "max_suppliers": 20}
    )
    repo = PlanLimitsRepository(conn)

    await repo.get_limits("gratis")
    await repo.get_limits("gratis")

    conn.fetchrow.assert_awaited_once()


async def test_get_limits_unknown_plan_falls_back_to_gratis_defaults():
    """Fail-safe: un plan que no existe en plan_limits no lanza — devuelve
    los límites conservadores de gratis en vez de 500 o de un límite abierto."""
    conn = AsyncMock()
    conn.fetchrow = AsyncMock(return_value=None)
    repo = PlanLimitsRepository(conn)

    limits = await repo.get_limits("plan-inexistente")

    assert limits == {"max_products": 100, "max_clients": 50, "max_suppliers": 20}


async def test_get_limits_different_plans_cached_independently():
    conn = AsyncMock()

    async def fetchrow_side_effect(query, plan):
        return {
            "gratis": {"max_products": 100, "max_clients": 50, "max_suppliers": 20},
            "pro": {"max_products": 5000, "max_clients": 3000, "max_suppliers": 1000},
        }[plan]

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    repo = PlanLimitsRepository(conn)

    gratis = await repo.get_limits("gratis")
    pro = await repo.get_limits("pro")

    assert gratis["max_products"] == 100
    assert pro["max_products"] == 5000
    assert conn.fetchrow.await_count == 2
