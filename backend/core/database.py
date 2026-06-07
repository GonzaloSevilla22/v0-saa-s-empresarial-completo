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
    )


async def close_pool() -> None:
    global pool
    if pool is not None:
        await pool.close()
        pool = None


async def get_db_conn(
    user: dict = Depends(get_current_user),
) -> AsyncGenerator[asyncpg.Connection, None]:
    """FastAPI dependency: yields an asyncpg connection with JWT-passthrough applied."""
    if pool is None:
        raise HTTPException(status_code=503, detail="Database pool not initialized")
    async with pool.acquire() as conn:
        await conn.execute("SET LOCAL app.jwt_claims = $1", json.dumps(user))
        yield conn
