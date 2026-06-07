from __future__ import annotations

import logging

import redis.asyncio as aioredis

from backend.core.config import settings

logger = logging.getLogger(__name__)

redis: aioredis.Redis | None = None


async def init_redis() -> None:
    global redis
    if not settings.redis_url:
        logger.warning("REDIS_URL not set — Redis disabled (rate limiting unavailable)")
        return
    redis = aioredis.from_url(settings.redis_url, decode_responses=True)


async def close_redis() -> None:
    global redis
    if redis is not None:
        await redis.aclose()
        redis = None
