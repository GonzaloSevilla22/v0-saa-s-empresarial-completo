from __future__ import annotations

import json
from collections.abc import AsyncGenerator

import asyncpg
from fastapi import Depends, HTTPException

from backend.core.auth import get_current_user
from backend.core.config import settings

pool: asyncpg.Pool | None = None


async def init_pool() -> None:
    global pool
    if not settings.database_url:
        raise ValueError("DATABASE_URL is required but not set")
    pool = await asyncpg.create_pool(
        settings.database_url,
        min_size=2,
        max_size=10,
        statement_cache_size=0,
    )


async def close_pool() -> None:
    global pool
    if pool is not None:
        await pool.close()
        pool = None


async def init_service_pool() -> None:
    """No-op: el webhook de pagos usa el pool regular (postgres tiene BYPASSRLS)."""


async def close_service_pool() -> None:
    """No-op: ver init_service_pool."""


async def get_db_conn(
    user: dict = Depends(get_current_user),
) -> AsyncGenerator[asyncpg.Connection, None]:
    """FastAPI dependency: yields an asyncpg connection con los claims del
    request inyectados para que `auth.uid()` y las RLS policies los lean.

    v31-tenancy-pool-rls Paso 1 (D1/D2/D4) — detrás de la palanca
    `settings.tenancy_tx_scope_enabled` (D8, apagada por defecto):

    - **Encendida**: la conexión se envuelve en una transacción explícita
      (`async with conn.transaction()`). `request.jwt.claims` — el ÚNICO
      GUC que `auth.uid()` y las RLS policies leen (barrido verificado
      sobre migraciones/backend/frontend/edge functions, ver design.md D2)
      — se setea con `set_config(..., true)`: alcance TRANSACCIONAL,
      equivalente a `SET LOCAL`. Bajo Supavisor en *transaction mode* esto
      garantiza que los claims y las queries de negocio corren en la MISMA
      conexión física, y que el GUC se deshace solo al COMMIT/ROLLBACK — la
      conexión vuelve al pool sin residuo para el siguiente request (D1).
      También se setea `idle_in_transaction_session_timeout` con el mismo
      alcance transaccional (D4), para que un request colgado no retenga la
      transacción indefinidamente. Consecuencia (D3): los `conn.transaction()`
      internos de los repositories quedan anidados como SAVEPOINTs bajo esta
      transacción externa — si el request falla después de escribir, ese
      trabajo se deshace junto con el request (antes quedaba comiteado de
      inmediato).
    - **Apagada (default)**: comportamiento previo a este change, byte a
      byte — incluido `app.jwt_claims`, alcance de SESIÓN
      (`set_config(..., false)`), sin transacción explícita. Es la causa
      mecánica documentada del bug intermitente K5 (500 en compras, ver
      design.md Context) y de por qué `app.jwt_claims` convivió dos años
      sin un solo lector real. Se conserva ÚNICAMENTE como palanca de
      rollback inmediato (D8, reinicio sin rebuild); se retira en un change
      de limpieza posterior, una vez el Paso 2 esté estable (tasks.md 9.7)
      — no agregar lectores nuevos de `app.jwt_claims` mientras tanto.

    `get_service_conn` (webhook de pagos, relay CAE del cron) es un camino
    de servicio explícitamente separado (D5): nunca pasa por acá, no recibe
    claims ni queda dentro de la transacción del request.
    """
    if pool is None:
        raise HTTPException(status_code=503, detail="Database pool not initialized")
    async with pool.acquire() as conn:
        if settings.tenancy_tx_scope_enabled:
            async with conn.transaction():
                await conn.execute(
                    """
                    SELECT
                        set_config('request.jwt.claims', $1, true),
                        set_config('idle_in_transaction_session_timeout', $2, true)
                    """,
                    json.dumps({"sub": user["user_id"], "role": "authenticated"}),
                    settings.tenancy_tx_idle_timeout,
                )
                yield conn
        else:
            # Camino legacy (palanca apagada, D8) — comportamiento idéntico
            # al de antes de v31-tenancy-pool-rls. NO agregar lectores
            # nuevos de app.jwt_claims: cero lectores reales (design.md D2).
            await conn.execute(
                """
                SELECT
                    set_config('app.jwt_claims',    $1, false),
                    set_config('request.jwt.claims', $2, false)
                """,
                json.dumps(user),
                json.dumps({"sub": user["user_id"], "role": "authenticated"}),
            )
            yield conn


async def get_service_conn() -> AsyncGenerator[asyncpg.Connection, None]:
    """FastAPI dependency: connection para el webhook de pagos.

    Usa el pool regular — el usuario postgres tiene BYPASSRLS en Supabase.
    El email del usuario se obtiene via Supabase Admin REST API (no auth.users).
    """
    if pool is None:
        raise HTTPException(status_code=503, detail="Database pool not initialized")
    async with pool.acquire() as conn:
        yield conn
