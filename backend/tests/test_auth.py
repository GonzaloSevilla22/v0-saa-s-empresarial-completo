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


# ── v31-authz-token-hook — Grupo 5: contrato del contexto + rol de tenant ────
# D1: `role` (plataforma) y `account_role` (tenant) son namespaces separados,
# ambos declarados en AuthContext y verificados por el contrato anti-deriva.


@pytest.mark.asyncio
async def test_get_current_user_keys_include_account_role():
    """RED (5.1): AuthContext gana `account_role` — el contrato anti-deriva
    debe seguir cumpliéndose con la clave nueva. Debe fallar mientras
    `account_role` no exista ni en el TypedDict ni en get_current_user."""
    token = make_token({
        "sub": "user-999",
        "role": "authenticated",
        "app_metadata": {"role": "user", "account_role": "owner", "plan": "gratis"},
    })
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = TEST_SECRET
        result = await get_current_user(token=token)

    assert set(result.keys()) == set(AuthContext.__annotations__.keys())
    assert "account_role" in AuthContext.__annotations__
    assert result["account_role"] == "owner"


@pytest.mark.asyncio
async def test_get_current_user_account_role_absent_defaults_to_none():
    """GREEN complementario: sin el claim `account_role` en el token (token
    viejo, D6), la clave sigue presente en el contexto con valor None — nunca
    se inventa un rol de tenant permisivo por default."""
    token = make_token({"sub": "user-000", "role": "authenticated"})
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = TEST_SECRET
        result = await get_current_user(token=token)

    assert result["account_role"] is None


@pytest.mark.asyncio
async def test_role_and_account_role_do_not_share_namespace_no_op_for_existing_guards():
    """RED (5.3) — el riesgo central de D1: un JWT con `role="user"` (rol de
    PLATAFORMA) y `account_role="owner"` (rol de TENANT) NO debe cambiar el
    resultado de un guard `require_role(["user","admin"])` existente. Prueba
    la integración real get_current_user → require_role, no solo el shape."""
    from backend.core.guards import require_role

    token = make_token({
        "sub": "user-777",
        "role": "authenticated",
        "app_metadata": {"role": "user", "account_role": "owner", "plan": "gratis"},
    })
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = TEST_SECRET
        auth = await get_current_user(token=token)

    # No debe lanzar — "user" sigue pasando el guard de plataforma, sin
    # importar que la MISMA persona sea "owner" de su cuenta.
    require_role(auth, ["user", "admin"])


def test_role_and_account_role_namespace_mixup_is_actually_detected():
    """Prueba de que el test anterior NO es una tautología (5.3): si alguien
    cometiera el error catastrófico que D1 descarta explícitamente —escribir
    el rol de TENANT en la clave `role`— el guard SHALL rechazar. Construye
    a mano el contexto "roto" (como si el hook hubiera puesto account_role
    en vez de role) y confirma que require_role sí lo detecta con 403."""
    from fastapi import HTTPException

    from backend.core.guards import require_role

    broken_auth = {
        "user_id": "user-777",
        "role": "owner",  # BUG simulado: debía ser "user" (plataforma)
        "account_role": "owner",
        "plan": "gratis",
    }

    with pytest.raises(HTTPException) as exc_info:
        require_role(broken_auth, ["user", "admin"])
    assert exc_info.value.status_code == 403
