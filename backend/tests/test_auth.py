import pytest
from fastapi import HTTPException
from unittest.mock import patch
from backend.core.auth import get_current_user

TEST_SECRET = "test-secret-key"


def make_token(payload: dict, secret: str = TEST_SECRET) -> str:
    from jose import jwt
    return jwt.encode(payload, secret, algorithm="HS256")


@pytest.mark.asyncio
async def test_valid_token_returns_user():
    token = make_token({"sub": "user-123", "role": "authenticated"})
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_jwt_secret = TEST_SECRET
        result = await get_current_user(token=token)
    assert result["user_id"] == "user-123"
    assert result["role"] == "authenticated"


@pytest.mark.asyncio
async def test_invalid_signature_raises_401():
    token = make_token({"sub": "user-123"}, secret="wrong-secret")
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_jwt_secret = TEST_SECRET
        with pytest.raises(HTTPException) as exc:
            await get_current_user(token=token)
    assert exc.value.status_code == 401


@pytest.mark.asyncio
async def test_expired_token_raises_401():
    import time
    token = make_token({"sub": "user-123", "exp": int(time.time()) - 100})
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_jwt_secret = TEST_SECRET
        with pytest.raises(HTTPException) as exc:
            await get_current_user(token=token)
    assert exc.value.status_code == 401


# T-11 [TRIANGULATE] — payload without role defaults to "authenticated"
@pytest.mark.asyncio
async def test_token_without_role_defaults_authenticated():
    token = make_token({"sub": "user-456"})  # no "role" field
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_jwt_secret = TEST_SECRET
        result = await get_current_user(token=token)
    assert result["role"] == "authenticated"
