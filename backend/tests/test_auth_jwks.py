"""auth-hardening-jwt-cookies Parte A, grupo 2 (D8) — la rama JWKS/ES256.

**Por qué existe este archivo.** Es la rama que corre en PRODUCCIÓN (prod
firma ES256: JWKS con una sola clave EC P-256, kid
`cb5c6fc1-0196-4faa-b48c-c9190956381d`, hallazgo F4 de la auditoría del
2026-09-14) y hasta este change **no tenía un solo test**: el grep de
`jwks|ES256|RS256|get_signing_key|PyJWKClient` sobre `backend/tests/` daba
**0 hits** (§10 de la auditoría). Los 17 bloques de patch de `test_auth.py`
corren todos por el fallback HS256 con `"dev-secret"`, que en producción no
se ejecuta nunca.

La clave EC se genera **en el test** (nunca una clave fija en el repo) y
`PyJWKClient.get_signing_key_from_jwt` se parchea para devolver su mitad
pública, de modo que no se toca la red ni el JWKS real.
"""
from __future__ import annotations

import logging
import time
from contextlib import contextmanager
from unittest.mock import patch

import jwt as pyjwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import HTTPException
from jwt import PyJWKClient
from jwt.exceptions import PyJWKClientError

from backend.core import auth as auth_module
from backend.core.auth import get_claims_status, get_current_user

# El proyecto real de producción. Se usa como literal a propósito: el `iss`
# esperado es una función de esta URL, y el documento de descubrimiento OIDC
# leído anónimamente el 2026-09-16 declara exactamente
# "issuer":"https://gxdhpxvdjjkmxhdkkwyb.supabase.co/auth/v1".
SUPABASE_URL = "https://gxdhpxvdjjkmxhdkkwyb.supabase.co"
EXPECTED_ISSUER = f"{SUPABASE_URL}/auth/v1"
TEST_KID = "cb5c6fc1-0196-4faa-b48c-c9190956381d"
TEST_USER_ID = "11111111-1111-1111-1111-111111111111"


@pytest.fixture(autouse=True)
def _reset_jwks_client_singleton():
    """`get_jwks_client` cachea el cliente en un global de módulo. Sin este
    reset, el primer test fija la URL de JWKS para todos los siguientes — y
    justamente `test_trailing_slash_...` necesita construirlo de nuevo."""
    auth_module._jwks_client = None
    yield
    auth_module._jwks_client = None


@pytest.fixture(scope="module")
def ec_keypair():
    """Clave EC P-256 — la misma curva que usa el JWKS de producción."""
    private_key = ec.generate_private_key(ec.SECP256R1())
    return private_key, private_key.public_key()


@pytest.fixture(scope="module")
def foreign_ec_keypair():
    """Segunda clave EC, ajena al JWKS: sirve para forjar una firma inválida."""
    private_key = ec.generate_private_key(ec.SECP256R1())
    return private_key, private_key.public_key()


def make_es256_token(private_key, **overrides) -> str:
    """Token ES256 con la forma real que emite GoTrue.

    `aud="authenticated"` no es una suposición: en producción los 40 usuarios
    de `auth.users` tienen `aud='authenticated'` (medido el 2026-09-16), y esa
    columna es exactamente la que GoTrue copia al claim.
    """
    now = int(time.time())
    claims = {
        "sub": TEST_USER_ID,
        "role": "authenticated",
        "aud": "authenticated",
        "iss": EXPECTED_ISSUER,
        "iat": now,
        "exp": now + 3600,
    }
    claims.update(overrides)
    return pyjwt.encode(
        claims, private_key, algorithm="ES256", headers={"kid": TEST_KID}
    )


@contextmanager
def jwks_env(public_key, supabase_url: str = SUPABASE_URL):
    """Entorno de la rama JWKS: URL del proveedor configurada, palanca HS256
    apagada, y la clave de firma resuelta sin tocar la red."""
    with (
        patch("backend.core.auth.settings") as mock_settings,
        patch.object(
            PyJWKClient, "get_signing_key_from_jwt", return_value=public_key
        ) as signing_key_mock,
    ):
        mock_settings.supabase_url = supabase_url
        mock_settings.supabase_jwt_secret = "no-se-usa-en-esta-rama"
        mock_settings.auth_allow_hs256_fallback = False
        yield signing_key_mock


# ── 2.1 — la rama que corre en producción, ejercitada ────────────────────


@pytest.mark.asyncio
async def test_jwks_es256_token_is_accepted(ec_keypair):
    """2.1 RED: cierra el hueco de §10 — hasta acá ningún test tocaba ES256."""
    private_key, public_key = ec_keypair
    token = make_es256_token(private_key)

    with jwks_env(public_key) as signing_key_mock:
        result = await get_current_user(token=token)

    assert result["user_id"] == TEST_USER_ID
    assert result["role"] == "user"  # "authenticated" (Postgres) -> "user" (app)
    # Que haya resuelto la clave por el camino JWKS, y no por el secreto
    # compartido, es parte de lo que este test asserta.
    signing_key_mock.assert_called_once_with(token)


# ── 2.2 / 2.2b — emisor ──────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_token_from_other_issuer_is_rejected(ec_keypair):
    """2.2 RED: hoy `issuer=` nunca se pasa, así que un token firmado por otro
    emisor de Supabase (otro proyecto) se acepta si la firma valida."""
    private_key, public_key = ec_keypair
    token = make_es256_token(private_key, iss="https://otro-proyecto.supabase.co/auth/v1")

    with jwks_env(public_key):
        with pytest.raises(HTTPException) as exc:
            await get_current_user(token=token)

    assert exc.value.status_code == 401


@pytest.mark.asyncio
async def test_token_without_issuer_claim_is_rejected(ec_keypair):
    """2.2 TRIANGULATE: no basta con rechazar un emisor ajeno — un token que
    directamente no declara emisor tampoco puede pasar."""
    private_key, public_key = ec_keypair
    now = int(time.time())
    token = pyjwt.encode(
        {
            "sub": TEST_USER_ID,
            "role": "authenticated",
            "aud": "authenticated",
            "iat": now,
            "exp": now + 3600,
        },
        private_key,
        algorithm="ES256",
        headers={"kid": TEST_KID},
    )

    with jwks_env(public_key):
        with pytest.raises(HTTPException) as exc:
            await get_current_user(token=token)

    assert exc.value.status_code == 401


@pytest.mark.asyncio
async def test_trailing_slash_in_supabase_url_does_not_break_issuer(ec_keypair):
    """2.2b RED: una barra final en `SUPABASE_URL` es HOY invisible (la URL de
    JWKS la tolera). Sin normalizar, tras D8 convierte el emisor esperado en
    `https://…supabase.co//auth/v1` y produce **401 para el 100% del tráfico**
    legítimo. El repo no puede ver el valor de Render, así que la normalización
    es la defensa que sí controla."""
    private_key, public_key = ec_keypair
    token = make_es256_token(private_key)  # `iss` sin barra doble: el real

    with jwks_env(public_key, supabase_url=f"{SUPABASE_URL}/"):
        result = await get_current_user(token=token)

    assert result["user_id"] == TEST_USER_ID


def test_trailing_slash_does_not_leak_into_the_jwks_url():
    """2.2b TRIANGULATE: la MISMA URL normalizada gobierna el emisor y la
    dirección de las claves — si sólo se normalizara una, la otra quedaría con
    la barra doble y el bug simplemente se mudaría de lugar."""
    with patch("backend.core.auth.settings") as mock_settings:
        mock_settings.supabase_url = f"{SUPABASE_URL}/"
        client = auth_module.get_jwks_client()

    assert client.uri == f"{SUPABASE_URL}/auth/v1/.well-known/jwks.json"
    assert "//auth/v1" not in client.uri


# ── 2.3 / 2.3b — audiencia ───────────────────────────────────────────────


@pytest.mark.asyncio
async def test_token_with_expected_audience_is_accepted(ec_keypair):
    """2.3 RED (mitad positiva): encender `verify_aud` no debe romper el token
    real. `aud="authenticated"` no es una URL, y eso es exactamente lo que la
    spec vieja usaba como excusa para desactivar la comprobación — declarando
    el valor esperado, PyJWT lo compara sin exigir que sea una URL."""
    private_key, public_key = ec_keypair
    token = make_es256_token(private_key, aud="authenticated")

    with jwks_env(public_key):
        result = await get_current_user(token=token)

    assert result["user_id"] == TEST_USER_ID


@pytest.mark.asyncio
async def test_token_with_wrong_audience_is_rejected(ec_keypair):
    """2.3 RED (mitad negativa): hoy `options={"verify_aud": False}` en las dos
    ramas, así que un token emitido para otra audiencia se acepta."""
    private_key, public_key = ec_keypair
    token = make_es256_token(private_key, aud="anon")

    with jwks_env(public_key):
        with pytest.raises(HTTPException) as exc:
            await get_current_user(token=token)

    assert exc.value.status_code == 401


@pytest.mark.asyncio
async def test_audience_as_array_is_accepted(ec_keypair):
    """2.3b: el `aud` puede llegar como array. El valor real de producción está
    medido (`auth.users.aud='authenticated'`, 40/40); la FORMA no, porque
    exigiría decodificar un token real. Cubrir las dos formas hace que la
    incógnita no pueda sorprender en prod."""
    private_key, public_key = ec_keypair
    token = make_es256_token(private_key, aud=["authenticated", "otra-audiencia"])

    with jwks_env(public_key):
        result = await get_current_user(token=token)

    assert result["user_id"] == TEST_USER_ID


@pytest.mark.asyncio
async def test_audience_array_without_the_expected_value_is_rejected(ec_keypair):
    """2.3b TRIANGULATE: aceptar la forma array no puede degenerar en aceptar
    cualquier array."""
    private_key, public_key = ec_keypair
    token = make_es256_token(private_key, aud=["anon", "otra-audiencia"])

    with jwks_env(public_key):
        with pytest.raises(HTTPException) as exc:
            await get_current_user(token=token)

    assert exc.value.status_code == 401


# ── 2.7 / 2.8 — un fallo del JWKS no es un token forjado ─────────────────


@pytest.mark.asyncio
async def test_jwks_fetch_failure_logs_warning_and_returns_401(ec_keypair, caplog):
    """2.7 RED: `PyJWKClientError` hereda de `PyJWTError`, así que hoy sale por
    el mismo `except` y una caída del proveedor de claves es indistinguible de
    un token forjado — sin log propio. Son dos incidentes con respuestas
    operativas distintas."""
    private_key, _ = ec_keypair
    token = make_es256_token(private_key)

    with (
        patch("backend.core.auth.settings") as mock_settings,
        patch.object(
            PyJWKClient,
            "get_signing_key_from_jwt",
            side_effect=PyJWKClientError("Unable to find a signing key"),
        ),
        caplog.at_level(logging.WARNING, logger="backend.core.auth"),
    ):
        mock_settings.supabase_url = SUPABASE_URL
        mock_settings.supabase_jwt_secret = "no-se-usa-en-esta-rama"
        mock_settings.auth_allow_hs256_fallback = False
        with pytest.raises(HTTPException) as exc:
            await get_current_user(token=token)

    assert exc.value.status_code == 401
    jwks_warnings = [
        r for r in caplog.records if r.levelno == logging.WARNING and "JWKS" in r.message
    ]
    assert jwks_warnings, "un fallo de las JWKS debe dejar su propio rastro de advertencia"


@pytest.mark.asyncio
async def test_forged_token_does_not_log_jwks_warning(ec_keypair, foreign_ec_keypair, caplog):
    """2.8 — el control negativo de 2.7. Sin este test, un `logger.warning`
    puesto en el `except` genérico pasaría 2.7 sin distinguir nada."""
    _, public_key = ec_keypair
    foreign_private_key, _ = foreign_ec_keypair
    token = make_es256_token(foreign_private_key)  # firmado con una clave ajena

    with (
        jwks_env(public_key),
        caplog.at_level(logging.WARNING, logger="backend.core.auth"),
    ):
        with pytest.raises(HTTPException) as exc:
            await get_current_user(token=token)

    assert exc.value.status_code == 401
    jwks_warnings = [
        r for r in caplog.records if r.levelno == logging.WARNING and "JWKS" in r.message
    ]
    assert not jwks_warnings, (
        "una firma inválida NO es un fallo del proveedor de claves y no debe "
        "contaminar el rastro que sirve para detectar una caída del JWKS"
    )


# ── 2.9 — un solo decoder canónico ───────────────────────────────────────


@pytest.mark.asyncio
async def test_claims_status_uses_the_same_decoder(ec_keypair):
    """2.9: `GET /auth/claims-status` debe verificar EXACTAMENTE igual que
    `get_current_user` (intención declarada en el docstring de
    `_decode_supabase_jwt`). Se prueba por comportamiento observable: un token
    con emisor ajeno — endurecimiento nuevo de D8 — también lo rechaza."""
    private_key, public_key = ec_keypair
    good_token = make_es256_token(private_key)
    foreign_issuer_token = make_es256_token(
        private_key, iss="https://otro-proyecto.supabase.co/auth/v1"
    )

    with jwks_env(public_key):
        ok = await get_claims_status(token=good_token)
        with pytest.raises(HTTPException) as exc:
            await get_claims_status(token=foreign_issuer_token)

    assert ok["effective_role"] == "user"
    assert exc.value.status_code == 401


# El candado estructural de "un solo decoder canónico" (2.9 TRIANGULATE / 5.5)
# vive en `backend/tests/test_no_websocket_surface.py`: el segundo decoder que
# existe hoy es el del canal WebSocket (`routers/ws.py:12-34` — sin rama HS256,
# sin `iss`, sin `aud`, nunca ejercitado) y desaparece con el retiro de D11, así
# que el test pertenece al grupo que lo retira.
