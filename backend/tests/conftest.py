import time
import uuid
from unittest.mock import AsyncMock, MagicMock, patch

import jwt
import pytest
from httpx import ASGITransport, AsyncClient

TEST_SECRET = "test-secret-key-de-32-bytes-o-mas!!"
TEST_USER_ID = "11111111-1111-1111-1111-111111111111"
TEST_ACCOUNT_ID = uuid.UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")


def make_token(extra: dict = {}) -> str:
    payload = {
        "sub": TEST_USER_ID,
        "role": "authenticated",
        "exp": int(time.time()) + 3600,
    }
    payload.update(extra)
    return jwt.encode(payload, TEST_SECRET, algorithm="HS256")


class FakeAsyncpgRecord:
    """Test double for `asyncpg.Record` (fix/ambiguous-subscriptions-record-
    serialization, 2026-09-04): supports `__getitem__`/`keys()`/iteration
    like a real Record, but — crucially — NO attribute access and no
    `collections.abc.Mapping` registration.

    Mocking a repo's return value with a plain `dict` (as most existing
    tests do) does NOT reproduce the 500 seen in prod: pydantic's
    `from_attributes=True` validates a real `dict` (or a
    `collections.abc.Mapping`) via item access and succeeds, but falls back
    to `getattr()` for anything else — which is exactly what a real
    `asyncpg.Record` triggers, and exactly what silently passed every
    existing test that mocked `conn.fetch`/`conn.fetchrow` with dicts.
    `dict(FakeAsyncpgRecord(...))` round-trips correctly (Python's `dict()`
    uses the `keys()` + `__getitem__` mapping protocol), matching
    `dict(record)` on a real asyncpg.Record — so this is the right double
    for asserting BOTH the RED (raw return → 500) and the GREEN (`dict(r)`
    conversion → 200) shape of this bug class.
    """

    def __init__(self, data: dict):
        self._data = data

    def __getitem__(self, key):
        return self._data[key]

    def __iter__(self):
        return iter(self._data)

    def __len__(self):
        return len(self._data)

    def keys(self):
        return self._data.keys()


@pytest.fixture
def valid_token():
    return make_token()


@pytest.fixture(autouse=True)
def _clear_plan_limits_cache():
    """billing-pro-trial: PlanLimitsRepository cachea en proceso (D5). Sin este
    reset, un valor mockeado en un test filtraría al siguiente (mismo proceso
    pytest, mismo dict a nivel de módulo)."""
    from backend.repositories.plan_limits_repository import clear_cache

    clear_cache()
    yield
    clear_cache()


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
    conn.fetchval = AsyncMock(return_value=None)
    transaction_ctx = AsyncMock()
    transaction_ctx.__aenter__ = AsyncMock(return_value=None)
    transaction_ctx.__aexit__ = AsyncMock(return_value=False)
    conn.transaction = MagicMock(return_value=transaction_ctx)
    return pool, conn


@pytest.fixture
async def async_client():
    from backend.main import app
    from backend.core.deps import get_account_id

    async def _mock_account_id():
        return TEST_ACCOUNT_ID

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
        app.dependency_overrides[get_account_id] = _mock_account_id
        async with AsyncClient(
            transport=ASGITransport(app=app), base_url="http://test"
        ) as client:
            yield client
        app.dependency_overrides.pop(get_account_id, None)
