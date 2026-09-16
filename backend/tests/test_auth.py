import time

import pytest
from fastapi import HTTPException
from unittest.mock import patch
from backend.core.auth import get_current_user, get_claims_status, AuthContext

TEST_SECRET = "test-secret-key-de-32-bytes-o-mas!!"


def make_token(payload: dict, secret: str = TEST_SECRET) -> str:
    """Token de test con los claims que el proveedor real SIEMPRE emite.

    auth-hardening-jwt-cookies D8: `aud` y `exp` se completan por default
    porque la verificación pasa a declarar la audiencia esperada y a exigir
    `exp`/`sub`. Cualquier test puede sobreescribirlos —`payload` gana— y el
    que necesite un token con un claim AUSENTE usa `make_raw_token`.
    """
    import jwt
    claims = {"aud": "authenticated", "exp": int(time.time()) + 3600}
    claims.update(payload)
    return jwt.encode(claims, secret, algorithm="HS256")


def make_raw_token(payload: dict, secret: str = TEST_SECRET) -> str:
    """Token SIN ningún claim completado: firma exactamente lo que se le pasa.

    Es lo que hace falta para probar que un claim OBLIGATORIO ausente se
    rechaza — con `make_token` sería imposible, porque los completa."""
    import jwt
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
    token = make_token({"sub": "user-123"}, secret="wrong-secret-de-32-bytes-o-mas!!!")
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


# ── v3-rbac-multirole Parte B, grupo 10 (D8, D10): claim del CONJUNTO ───────
# `account_roles` -- superset de `account_role`, mismo namespace de TENANT.


@pytest.mark.asyncio
async def test_get_current_user_keys_include_account_roles():
    """RED (10.4): AuthContext gana `account_roles` (el conjunto) — el
    contrato anti-deriva debe seguir cumpliéndose con la clave nueva. Debía
    fallar mientras `account_roles` no existiera ni en el TypedDict ni en
    get_current_user (antes de este change, `set(result.keys())` tenía una
    clave de menos que `AuthContext.__annotations__`)."""
    token = make_token({
        "sub": "user-998",
        "role": "authenticated",
        "app_metadata": {"role": "user", "account_role": "owner", "account_roles": ["owner"], "plan": "gratis"},
    })
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = TEST_SECRET
        result = await get_current_user(token=token)

    assert set(result.keys()) == set(AuthContext.__annotations__.keys())
    assert "account_roles" in AuthContext.__annotations__
    assert result["account_roles"] == ["owner"]


@pytest.mark.asyncio
async def test_get_current_user_account_roles_absent_defaults_to_none():
    """GREEN complementario: sin el claim `account_roles` en el token (token
    viejo, emitido antes de este change, o el hook degradado por D8's
    EXCEPTION WHEN OTHERS), la clave sigue presente con valor None — nunca
    se inventa un array vacío que un guard podría confundir con "sin roles
    activos resueltos por el hook" (D9: [] presente != ausente)."""
    token = make_token({"sub": "user-997", "role": "authenticated"})
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = TEST_SECRET
        result = await get_current_user(token=token)

    assert result["account_roles"] is None


@pytest.mark.asyncio
async def test_get_current_user_account_roles_empty_list_is_preserved_not_coerced_to_none():
    """TRIANGULATE: un claim `account_roles: []` presente (hook resolvió la
    membresía pero sin roles activos) debe preservarse como lista vacía —
    NO convertirse en None, porque None dispara el fallback a la DB en
    require_account_role y [] no debe (D9)."""
    token = make_token({
        "sub": "user-996",
        "role": "authenticated",
        "app_metadata": {"account_roles": []},
    })
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = TEST_SECRET
        result = await get_current_user(token=token)

    assert result["account_roles"] == []


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


# ── v31-authz-token-hook — Grupo 7 (D8): get_claims_status ──────────────────
# Diagnóstico de presencia de claims — soporte de GET /auth/claims-status.


@pytest.mark.asyncio
async def test_claims_status_all_present_reports_source_token():
    """RED (7.1): un JWT con los tres claims reporta las tres presencias en
    True, los valores efectivos, y source="token"."""
    token = make_token({
        "sub": "user-111",
        "role": "authenticated",
        "app_metadata": {"role": "admin", "account_role": "owner", "plan": "avanzado"},
    })
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = TEST_SECRET
        result = await get_claims_status(token=token)

    assert result == {
        "role_claim_present": True,
        "account_role_claim_present": True,
        "account_roles_claim_present": False,
        "plan_claim_present": True,
        "effective_role": "admin",
        "effective_account_role": "owner",
        "effective_account_roles": None,
        "effective_plan": "avanzado",
        "source": "token",
    }


# ── 7.3 TRIANGULATE ──────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_claims_status_none_present_reports_fallback_values():
    """TRIANGULATE (7.3a): un JWT SIN app_metadata reporta las tres
    presencias en False y los valores de fallback (los mismos que usaría
    get_current_user), con source="fallback"."""
    token = make_token({"sub": "user-222", "role": "authenticated"})
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = TEST_SECRET
        result = await get_claims_status(token=token)

    assert result["role_claim_present"] is False
    assert result["account_role_claim_present"] is False
    assert result["account_roles_claim_present"] is False
    assert result["plan_claim_present"] is False
    assert result["effective_role"] == "user"
    assert result["effective_account_role"] is None
    assert result["effective_account_roles"] is None
    assert result["effective_plan"] == "pro"
    assert result["source"] == "fallback"


@pytest.mark.asyncio
async def test_claims_status_partial_claims_reports_fallback_source():
    """TRIANGULATE: si SOLO falta uno de los tres claims (p.ej. account_role,
    usuario sin membresía), source sigue siendo "fallback" — no es
    all-or-nothing por accidente."""
    token = make_token({
        "sub": "user-333",
        "role": "authenticated",
        "app_metadata": {"role": "user", "plan": "gratis"},
    })
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = TEST_SECRET
        result = await get_claims_status(token=token)

    assert result["role_claim_present"] is True
    assert result["account_role_claim_present"] is False
    assert result["plan_claim_present"] is True
    assert result["source"] == "fallback"


@pytest.mark.asyncio
async def test_claims_status_reports_account_roles_set_claim_presence_and_value():
    """Ronda 1 adversarial (minor 4): con `account_roles` presente en el
    JWT (D8 de la Parte B), el diagnóstico debe reportarlo -- es el único
    instrumento que distingue "el hook corrió" (auth_logs) de "el hook
    emitió account_roles" (este endpoint). `source` NO cambia por este
    claim -- se sigue calculando sólo sobre los 3 claims legacy."""
    token = make_token({
        "sub": "user-555",
        "role": "authenticated",
        "app_metadata": {
            "role": "user",
            "account_role": "seller",
            "account_roles": ["seller", "stock"],
            "plan": "pro",
        },
    })
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = TEST_SECRET
        result = await get_claims_status(token=token)

    assert result["account_roles_claim_present"] is True
    assert result["effective_account_roles"] == ["seller", "stock"]
    assert result["source"] == "token"


@pytest.mark.asyncio
async def test_claims_status_never_exposes_raw_token_or_payload():
    """7.3c: la respuesta NUNCA debe contener el token ni el payload crudo —
    solo las 7 claves del contrato de diagnóstico."""
    token = make_token({
        "sub": "user-444",
        "role": "authenticated",
        "app_metadata": {"role": "user", "account_role": "member", "plan": "inicial"},
    })
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = TEST_SECRET
        result = await get_claims_status(token=token)

    assert set(result.keys()) == {
        "role_claim_present",
        "account_role_claim_present",
        "account_roles_claim_present",
        "plan_claim_present",
        "effective_role",
        "effective_account_role",
        "effective_account_roles",
        "effective_plan",
        "source",
    }
    assert token not in str(result)
    assert "sub" not in result
    assert "user_id" not in result


# ── auth-hardening-jwt-cookies Parte A, grupo 2 (D8) ──────────────────────
# `exp` y `sub` obligatorios, y tolerancia de reloj. Los tres casos de abajo
# describen comportamiento que HOY no existe: `require` está vacío y `leeway`
# es 0.
#
# Los bloques de este grupo fijan `auth_allow_hs256_fallback = True` de forma
# EXPLÍCITA (hallazgo m2 de la revisión adversarial del apply): sin eso corren
# por la rama del secreto compartido sólo porque
# `MagicMock().auth_allow_hs256_fallback` es truthy, así que no declaran por
# qué camino verifican y quitar la palanca los dejaría igual de verdes. Es el
# estándar que este mismo change fijó en `conftest.py`, `test_auth_jwks.py` y
# `test_config_auth_failfast.py`. Los 17 bloques PREEXISTENTES del archivo no
# se tocan: D9 decidió no reescribirlos, y su cobertura de la rama que corre
# en producción vive ahora en `test_auth_jwks.py` (2.4/2.5/2.6 en ES256).


@pytest.mark.asyncio
async def test_token_without_exp_is_rejected():
    """2.4 RED: hoy un token válidamente firmado SIN `exp` se acepta — es una
    credencial sin vencimiento. `make_raw_token` firma exactamente lo que se
    le pasa, sin completar claims."""
    token = make_raw_token({"sub": "user-123", "role": "authenticated", "aud": "authenticated"})
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = TEST_SECRET
        mock_settings.auth_allow_hs256_fallback = True
        with pytest.raises(HTTPException) as exc:
            await get_current_user(token=token)
    assert exc.value.status_code == 401


@pytest.mark.asyncio
async def test_token_without_sub_returns_401_not_500():
    """2.5 RED: hoy `payload["sub"]` da KeyError y sale como 500 por el
    catch-all de `backend/main.py`. Un token sin sujeto es un token inválido,
    no una falla del servidor. La aserción sobre el TIPO de excepción es la
    que distingue el 401 del 500: un KeyError es justamente lo que el
    catch-all convierte en "Error interno del servidor"."""
    token = make_raw_token(
        {"role": "authenticated", "aud": "authenticated", "exp": int(time.time()) + 3600}
    )
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = TEST_SECRET
        mock_settings.auth_allow_hs256_fallback = True
        with pytest.raises(HTTPException) as exc:
            await get_current_user(token=token)
    assert exc.value.status_code == 401


@pytest.mark.asyncio
async def test_token_without_sub_is_401_over_http_not_500():
    """2.5 TRIANGULATE — la mitad que prueba el hallazgo REAL de la auditoría:
    el 500 no lo producía `get_current_user`, lo producía el catch-all de
    `backend/main.py` al recibir el KeyError. Este caso monta una ruta mínima
    sobre los MISMOS manejadores de excepción de la app real, así que si
    alguien reintrodujera el acceso crudo al claim, el 500 volvería a verse
    acá y no sólo en producción."""
    from fastapi import Depends, FastAPI
    from httpx import ASGITransport, AsyncClient

    from backend.main import http_exception_handler, unhandled_exception_handler

    probe = FastAPI()
    probe.add_exception_handler(HTTPException, http_exception_handler)
    probe.add_exception_handler(Exception, unhandled_exception_handler)

    @probe.get("/probe")
    async def _probe(auth: dict = Depends(get_current_user)):  # pragma: no cover
        return auth

    token = make_raw_token(
        {"role": "authenticated", "aud": "authenticated", "exp": int(time.time()) + 3600}
    )
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = TEST_SECRET
        mock_settings.auth_allow_hs256_fallback = True
        async with AsyncClient(
            transport=ASGITransport(app=probe, raise_app_exceptions=False),
            base_url="http://test",
        ) as client:
            response = await client.get(
                "/probe", headers={"Authorization": f"Bearer {token}"}
            )

    assert response.status_code == 401
    assert response.status_code != 500


@pytest.mark.asyncio
async def test_clock_skew_within_leeway_is_accepted():
    """2.6 RED: hoy `leeway` es 0 con `verify_iat` activo, así que un host
    levemente atrasado respecto del emisor rechaza con 401 tokens recién
    emitidos (PyJWT levanta `ImmatureSignatureError` con un `iat` futuro —
    verificado contra PyJWT 2.13.0)."""
    now = int(time.time())
    token = make_token(
        {"sub": "user-123", "role": "authenticated", "iat": now + 10, "nbf": now + 10}
    )
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = TEST_SECRET
        mock_settings.auth_allow_hs256_fallback = True
        result = await get_current_user(token=token)
    assert result["user_id"] == "user-123"


@pytest.mark.asyncio
async def test_clock_skew_beyond_leeway_is_still_rejected():
    """2.6 TRIANGULATE: la tolerancia es ACOTADA. Sin este caso, un `leeway`
    desmedido (o `verify_iat: False`) pasaría 2.6 sin conservar el control."""
    now = int(time.time())
    token = make_token(
        {"sub": "user-123", "role": "authenticated", "iat": now + 3600, "nbf": now + 3600}
    )
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = TEST_SECRET
        mock_settings.auth_allow_hs256_fallback = True
        with pytest.raises(HTTPException) as exc:
            await get_current_user(token=token)
    assert exc.value.status_code == 401
