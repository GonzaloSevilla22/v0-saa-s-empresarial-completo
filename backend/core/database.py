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
    """FastAPI dependency: yields an asyncpg connection with JWT-passthrough applied."""
    if pool is None:
        raise HTTPException(status_code=503, detail="Database pool not initialized")
    async with pool.acquire() as conn:
        # Set both configs in one round-trip:
        # - app.jwt_claims: leído por RLS policies y código app
        # - request.jwt.claims: leído por auth.uid() de Supabase en RPCs SECURITY DEFINER
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
