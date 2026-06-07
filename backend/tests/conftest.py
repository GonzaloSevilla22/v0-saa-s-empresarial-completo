import pytest
import time
from httpx import AsyncClient, ASGITransport
from jose import jwt
from unittest.mock import patch

TEST_SECRET = "test-secret-key"


def make_token(extra: dict = {}) -> str:
    payload = {
        "sub": "test-user-id",
        "role": "authenticated",
        "exp": int(time.time()) + 3600,
    }
    payload.update(extra)
    return jwt.encode(payload, TEST_SECRET, algorithm="HS256")


@pytest.fixture
def valid_token():
    return make_token()


@pytest.fixture
async def async_client():
    from backend.main import app
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_jwt_secret = TEST_SECRET
        async with AsyncClient(
            transport=ASGITransport(app=app), base_url="http://test"
        ) as client:
            yield client
