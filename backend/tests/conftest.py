import time
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from httpx import ASGITransport, AsyncClient
from jose import jwt

TEST_SECRET = "test-secret-key"


TEST_USER_ID = "11111111-1111-1111-1111-111111111111"


def make_token(extra: dict = {}) -> str:
    payload = {
        "sub": TEST_USER_ID,
        "role": "authenticated",
        "exp": int(time.time()) + 3600,
    }
    payload.update(extra)
    return jwt.encode(payload, TEST_SECRET, algorithm="HS256")


@pytest.fixture
def valid_token():
    return make_token()


@pytest.fixture
def mock_pool():
    """Reusable mock asyncpg pool for tests that need DB interaction."""
    pool = MagicMock()
    conn = AsyncMock()
    pool.acquire.return_value.__aenter__ = AsyncMock(return_value=conn)
    pool.acquire.return_value.__aexit__ = AsyncMock(return_value=False)
    conn.execute = AsyncMock(return_value="SET")
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchrow = AsyncMock(return_value=None)
    return pool, conn


@pytest.fixture
async def async_client():
    from backend.main import app

    with (
        patch("backend.core.auth.settings") as mock_settings,
        patch("backend.core.database.init_pool", new_callable=AsyncMock),
        patch("backend.core.database.close_pool", new_callable=AsyncMock),
        patch("backend.core.database.init_service_pool", new_callable=AsyncMock),
        patch("backend.core.database.close_service_pool", new_callable=AsyncMock),
        patch("backend.core.redis_client.init_redis", new_callable=AsyncMock),
        patch("backend.core.redis_client.close_redis", new_callable=AsyncMock),
    ):
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = TEST_SECRET
        async with AsyncClient(
            transport=ASGITransport(app=app), base_url="http://test"
        ) as client:
            yield client
