import pytest
from fastapi import HTTPException
from unittest.mock import patch
from backend.core.auth import get_current_user, AuthContext

TEST_SECRET = "test-secret-key"


def make_token(payload: dict, secret: str = TEST_SECRET) -> str:
    from jose import jwt
    return jwt.encode(payload, secret, algorithm="HS256")


@pytest.mark.asyncio
async def test_valid_token_returns_user():
    token = make_token({"sub": "user-123", "role": "authenticated"})
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = TEST_SECRET
        result = await get_current_user(token=token)
    assert result["user_id"] == "user-123"
    # "authenticated" (Postgres role) maps to "user" (app role)
    assert result["role"] == "user"


@pytest.mark.asyncio
async def test_invalid_signature_raises_401():
    token = make_token({"sub": "user-123"}, secret="wrong-secret")
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = TEST_SECRET
        with pytest.raises(HTTPException) as exc:
            await get_current_user(token=token)
    assert exc.value.status_code == 401


@pytest.mark.asyncio
async def test_expired_token_raises_401():
    import time
    token = make_token({"sub": "user-123", "exp": int(time.time()) - 100})
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = TEST_SECRET
        with pytest.raises(HTTPException) as exc:
            await get_current_user(token=token)
    assert exc.value.status_code == 401


# T-11 [TRIANGULATE] — payload without role defaults to "user"
@pytest.mark.asyncio
async def test_token_without_role_defaults_user():
    token = make_token({"sub": "user-456"})  # no "role" field
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = TEST_SECRET
        result = await get_current_user(token=token)
    assert result["role"] == "user"


# ── Task 2.1/2.3 — Contrato anti-deriva del AuthContext (v31-fix-auth-shape-500) ──
# El shape real que produce get_current_user NUNCA debe divergir del TypedDict
# declarado. Esta es la red que atrapa el próximo "auth.get('sub', '')".

@pytest.mark.asyncio
async def test_get_current_user_keys_match_authcontext_contract():
    """RED (2.1): las claves del dict producido == las claves declaradas en AuthContext."""
    token = make_token({"sub": "user-123", "role": "authenticated"})
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = TEST_SECRET
        result = await get_current_user(token=token)

    assert set(result.keys()) == set(AuthContext.__annotations__.keys())


@pytest.mark.asyncio
async def test_get_current_user_with_app_metadata_keeps_same_shape():
    """TRIANGULATE (2.3) caso 1: un JWT con app_metadata.role/plan explícitos
    produce el MISMO conjunto de claves (los valores cambian, el shape no)."""
    token = make_token({
        "sub": "user-789",
        "role": "authenticated",
        "app_metadata": {"role": "admin", "plan": "premium"},
    })
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = TEST_SECRET
        result = await get_current_user(token=token)

    assert set(result.keys()) == set(AuthContext.__annotations__.keys())
    assert result["role"] == "admin"
    assert result["plan"] == "premium"


def test_authcontext_key_set_comparison_detects_extra_key():
    """TRIANGULATE (2.3) caso 2 (negativo, anti-deriva): un dict con una clave
    extra respecto del contrato NO debe pasar la comparación de conjuntos —
    prueba que la aserción de 2.1 no es una tautología."""
    divergent = {"user_id": "x", "role": "user", "plan": "pro", "account_id": "leaked"}

    assert set(divergent.keys()) != set(AuthContext.__annotations__.keys())
