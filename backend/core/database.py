from __future__ import annotations

import json
import logging
from collections.abc import AsyncGenerator

import asyncpg
from fastapi import Depends, HTTPException

from backend.core.auth import get_current_user
from backend.core.config import settings

logger = logging.getLogger(__name__)

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

      v31-tenancy-pool-rls Paso 2 (D6) — detrás de la palanca INDEPENDIENTE
      `settings.tenancy_rls_role_enabled` (apagada por defecto, requiere
      `tenancy_tx_scope_enabled=True`, ver config.py): inmediatamente
      después de setear claims/timeout — mismo lugar, misma transacción,
      no pueden divergir (D6, mitigación del "falla abierto") — se ejecuta
      `SET LOCAL ROLE authenticated`. `authenticated` tiene
      `rolbypassrls=false` (verificado en prod): a partir de ahí, TODAS las
      queries que corren sobre `conn` (incluidas las que el caller ejecute
      después del `yield`) quedan sujetas a RLS de verdad, en vez de
      ignorarla como `postgres` (`rolbypassrls=true`). `SET LOCAL` —no
      `SET ROLE` de sesión— es la distinción que hace esto seguro bajo
      Supavisor en *transaction mode* (design.md, "La nota de C-17,
      corregida"): el cambio de rol se deshace solo al COMMIT/ROLLBACK, la
      conexión vuelve al pool como `postgres` sin residuo para el próximo
      request. `postgres` alcanza a hacer este cambio porque en este
      proyecto es miembro de `authenticated` con `ADMIN OPTION` (verificado
      en prod vía `pg_auth_members` — NO es superusuario en este Supabase
      gestionado, pero la membresía de rol alcanza para `SET ROLE`).
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
    claims, no queda dentro de la transacción del request y NUNCA adopta el
    rol `authenticated` sin importar el estado de ninguna de las dos
    palancas — son los 3 consumidores que dependen de BYPASSRLS.
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
                if settings.tenancy_rls_role_enabled:
                    # Paso 2 (D6) — SET LOCAL ROLE, no SET ROLE de sesión
                    # (design.md, "La nota de C-17, corregida"): se deshace
                    # solo al COMMIT/ROLLBACK, la conexión vuelve al pool
                    # como `postgres` sin residuo. "authenticated" es un
                    # literal fijo (no interpolación de user input): SET
                    # ROLE no admite parámetros bind de asyncpg — el nombre
                    # de rol debe ser un identificador SQL, no un valor.
                    await conn.execute("SET LOCAL ROLE authenticated")
                    # D6 bis — verificación del cambio de rol (cierra el
                    # "falla abierto" que design.md D6 nombra como riesgo):
                    # hasta acá el SET LOCAL ROLE se emitía sin comprobar
                    # que tomara. Si no toma (un pooler que rutea el
                    # statement a otra conexión física, una revocación de
                    # la membresía de rol de `postgres`, un statement
                    # tragado), el request correría como `postgres`
                    # (BYPASSRLS) creyendo estar bajo RLS — sin ninguna
                    # señal. Igualdad estricta, no "distinto de postgres":
                    # cualquier otra respuesta (None incluido) también
                    # falla CERRADO, antes de exponer la conexión al
                    # código de negocio. Cuesta un round-trip extra por
                    # request, sólo con el Paso 2 encendido.
                    effective_role = await conn.fetchval("SELECT current_user")
                    if effective_role != "authenticated":
                        logger.critical(
                            "v31-tenancy-pool-rls Paso 2: SET LOCAL ROLE "
                            "NO tomó — current_user=%r (esperaba "
                            "'authenticated') para request.jwt.claims.sub"
                            "=%s. Se rechaza el request (503) para no "
                            "correr con BYPASSRLS creyendo estar bajo RLS.",
                            effective_role,
                            user["user_id"],
                        )
                        raise HTTPException(
                            status_code=503,
                            detail="Database session isolation could not be verified",
                        )
                    logger.debug(
                        "v31-tenancy-pool-rls Paso 2: rol adoptado y "
                        "verificado como authenticated para "
                        "request.jwt.claims.sub=%s",
                        user["user_id"],
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
