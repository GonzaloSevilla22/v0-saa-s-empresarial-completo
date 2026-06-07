from __future__ import annotations

import redis.asyncio as aioredis

from backend.core.config import settings

redis: aioredis.Redis | None = None


async def init_redis() -> None:
    global redis
    if not settings.redis_url:
        raise ValueError("REDIS_URL is required but not set")
    redis = aioredis.from_url(settings.redis_url, decode_responses=True)


async def close_redis() -> None:
    global redis
    if redis is not None:
        await redis.aclose()
        redis = None
