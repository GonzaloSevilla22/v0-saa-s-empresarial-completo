"""auth-hardening-jwt-cookies Parte A, grupo 4 (D10) — CORS por allow-list,
sin credenciales, con `"*"` prohibido en producción.

**Lo que reproduce.** El hallazgo **F5**, medido contra producción el
2026-09-14: `allow_origins=[settings.backend_allowed_origin]` con
`allow_credentials=True` sobre un default `"*"` hace que Starlette **refleje**
el Origin del llamador, y `backend/core/errors.py` reproduce la reflexión a
mano para los cuerpos RFC 7807. Un preflight con `Origin: https://evil.example`
volvía con `access-control-allow-origin: https://evil.example` **y**
`access-control-allow-credentials: true`.
"""
from __future__ import annotations

import pytest
from httpx import ASGITransport, AsyncClient

from backend.core.config import Settings
from backend.core.cors import (
    CORS_ORIGIN_REGEX,
    LOCAL_DEV_ORIGIN,
    allowed_origins,
    is_origin_allowed,
)

PROD_ORIGIN = "https://www.aliadata.com.ar"
PROD_ORIGIN_APEX = "https://aliadata.com.ar"
# Las tres formas REALES observadas del proyecto en Vercel (el slug del
# proyecto va primero y el del equipo, `eie`, al final — no al revés):
VERCEL_ALIAS = "https://v0-saa-s-empresarial-completo.vercel.app"
VERCEL_DEPLOY = "https://v0-saa-s-empresarial-completo-j0csgp0yn-eie.vercel.app"
VERCEL_BRANCH = "https://v0-saa-s-empresarial-completo-git-main-eie.vercel.app"
FOREIGN_ORIGIN = "https://evil.example"


def _settings(**overrides) -> Settings:
    # `backend_allowed_origin` por default VACÍO — el estado real de Render
    # hoy (F5 lo prueba indirectamente). No se usa `"*"` como default acá
    # porque con `app_env="production"` el arranque lo rechaza (4.6), así que
    # el caso del comodín se declara explícitamente en el test que lo trata.
    values = {
        "supabase_url": "https://gxdhpxvdjjkmxhdkkwyb.supabase.co",
        "auth_allow_hs256_fallback": False,
        "app_env": "development",
        "backend_allowed_origin": "",
    }
    values.update(overrides)
    return Settings(**values)


async def _preflight(origin: str, path: str = "/expenses") -> "object":
    from backend.main import app

    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        return await client.options(
            path,
            headers={
                "Origin": origin,
                "Access-Control-Request-Method": "GET",
                "Access-Control-Request-Headers": "authorization",
            },
        )


# ── 4.1 — un origen ajeno no recibe autorización ─────────────────────────


@pytest.mark.asyncio
async def test_foreign_origin_gets_no_acao():
    """4.1 RED — reproduce F5 tal como se midió en producción."""
    response = await _preflight(FOREIGN_ORIGIN)

    assert "access-control-allow-origin" not in response.headers


@pytest.mark.asyncio
async def test_foreign_origin_gets_no_credentials_header():
    """4.1 TRIANGULATE: el `access-control-allow-credentials: true` es la
    mitad del hallazgo que convierte la reflexión en aprovechable."""
    response = await _preflight(FOREIGN_ORIGIN)

    assert "access-control-allow-credentials" not in response.headers


# ── 4.2 — los orígenes reales siguen funcionando ─────────────────────────


@pytest.mark.asyncio
@pytest.mark.parametrize("origin", [PROD_ORIGIN, PROD_ORIGIN_APEX])
async def test_production_origin_allowed_with_and_without_www(origin):
    """4.2: `www.aliadata.com.ar` responde 200 en producción (verificado
    anónimamente el 2026-09-16) y el ápice redirige ahí. Los dos se admiten."""
    response = await _preflight(origin)

    assert response.headers.get("access-control-allow-origin") == origin


@pytest.mark.asyncio
@pytest.mark.parametrize("origin", [VERCEL_ALIAS, VERCEL_DEPLOY, VERCEL_BRANCH])
async def test_vercel_preview_origin_allowed(origin):
    """4.2: los previews tienen host variable, por eso van por expresión
    regular y no por lista. Los tres valores son formas reales observadas del
    proyecto, no inventadas."""
    response = await _preflight(origin)

    assert response.headers.get("access-control-allow-origin") == origin


@pytest.mark.parametrize(
    "origin",
    [
        # El peligro real de una regex de dominio mal anclada.
        "https://www.aliadata.com.ar.evil.example",
        "https://evil.example/https://www.aliadata.com.ar",
        "https://wwwaliadata.com.ar",
        "https://aliadata.com.ar.co",
        "https://sub.aliadata.com.ar",
        "http://www.aliadata.com.ar",  # sin TLS
        "https://v0-saa-s-empresarial-completo.vercel.app.evil.example",
        "https://otro-proyecto-eie.vercel.app",
    ],
)
def test_lookalike_origins_are_rejected(origin):
    """4.2 TRIANGULATE — el candado que hace que la regex valga algo. Sin
    estos casos, `https://(www\\.)?aliadata\\.com\\.ar` sin anclar aceptaría
    cualquier dominio que la CONTENGA, que es la forma clásica de escribir
    una allow-list que no lo es."""
    assert is_origin_allowed(origin, _settings()) is False


# ── 4.3 — localhost sólo fuera de producción ─────────────────────────────


def test_localhost_allowed_only_outside_production():
    """4.3: el origen de desarrollo no puede quedar admitido en producción."""
    assert LOCAL_DEV_ORIGIN in allowed_origins(_settings(app_env="development"))
    assert LOCAL_DEV_ORIGIN not in allowed_origins(_settings(app_env="production"))


def test_localhost_is_not_allowed_in_production_by_the_regex_either():
    """4.3 TRIANGULATE: sacarlo de la lista no sirve si la regex lo readmite."""
    assert is_origin_allowed(LOCAL_DEV_ORIGIN, _settings(app_env="production")) is False
    assert is_origin_allowed(LOCAL_DEV_ORIGIN, _settings(app_env="development")) is True


# ── 4.4 — sin credenciales ───────────────────────────────────────────────


@pytest.mark.asyncio
async def test_allow_credentials_is_false():
    """4.4: ninguna credencial ambiental viaja hacia el backend — cero
    lecturas de cookie en `backend/`, todo es `Authorization: Bearer`, y
    ningún caller manda `credentials:'include'`. Declarar credenciales es
    justamente lo que convierte una allow-list comodín en una reflexión."""
    response = await _preflight(PROD_ORIGIN)

    assert response.headers.get("access-control-allow-origin") == PROD_ORIGIN
    assert "access-control-allow-credentials" not in response.headers


# ── 4.5 — los cuerpos de error usan el MISMO criterio ────────────────────


@pytest.mark.asyncio
async def test_problem_body_does_not_reflect_foreign_origin():
    """4.5 RED: el catch-all de `backend/main.py` vive en el middleware de
    errores del servidor, **fuera** de `CORSMiddleware`, así que sus
    respuestas inyectan los encabezados a mano (`cors_error_headers`). Hoy ese
    criterio es `allowed == "*"`, es decir: refleja cualquier origen.

    `GET /auth/claims-status` sin `Authorization` levanta una `HTTPException`
    de FastAPI dentro de la dependencia — sin tocar la base —, que es
    exactamente el camino que produce un cuerpo de problema.
    """
    from backend.main import app

    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        response = await client.get(
            "/auth/claims-status", headers={"Origin": FOREIGN_ORIGIN}
        )

    assert response.status_code == 401
    assert "access-control-allow-origin" not in response.headers
    assert "access-control-allow-credentials" not in response.headers


def test_error_headers_allow_a_legitimate_origin_without_credentials():
    """4.5 TRIANGULATE — control positivo aislado del middleware: sin él, un
    `cors_error_headers` que devolviera `{}` SIEMPRE pasaría el test de
    arriba sin conservar ninguna función."""
    from starlette.datastructures import Headers
    from starlette.requests import Request

    from backend.core.errors import cors_error_headers

    def _request(origin: str) -> Request:
        scope = {
            "type": "http",
            "method": "GET",
            "path": "/",
            "headers": Headers({"origin": origin}).raw,
        }
        return Request(scope)

    allowed = cors_error_headers(_request(PROD_ORIGIN))
    assert allowed.get("access-control-allow-origin") == PROD_ORIGIN
    assert "access-control-allow-credentials" not in allowed

    assert cors_error_headers(_request(FOREIGN_ORIGIN)) == {}
    assert cors_error_headers(_request("")) == {}


# ── 4.7 — defaults seguros por sí solos ──────────────────────────────────


def test_defaults_are_safe_without_backend_allowed_origin_configured():
    """4.7: el estado REAL de Render hoy es la variable sin definir (F5 lo
    prueba indirectamente: por eso el comodín estaba activo). Producción
    tiene que seguir funcionando por la regex, no por el comodín — y el
    comodín no debe entrar nunca a la lista."""
    prod = _settings(app_env="production", backend_allowed_origin="")

    assert allowed_origins(prod) == []
    assert is_origin_allowed(PROD_ORIGIN, prod) is True
    assert is_origin_allowed(VERCEL_BRANCH, prod) is True
    assert is_origin_allowed(FOREIGN_ORIGIN, prod) is False


def test_wildcard_is_never_an_allowed_origin_entry():
    """4.7 TRIANGULATE: `"*"` es el default del campo. Aunque en producción el
    arranque lo rechaza (4.6), fuera de producción no puede colarse en la
    lista como si fuera un origen literal."""
    dev = _settings(app_env="development", backend_allowed_origin="*")

    assert "*" not in allowed_origins(dev)
    assert is_origin_allowed(FOREIGN_ORIGIN, dev) is False


def test_a_configured_concrete_origin_is_honoured():
    """4.7 TRIANGULATE: la variable sigue siendo una salida útil — poner un
    origen concreto en Render lo admite sin tocar código."""
    configured = "https://app.aliadata.com"
    prod = _settings(app_env="production", backend_allowed_origin=configured)

    assert configured in allowed_origins(prod)
    assert is_origin_allowed(configured, prod) is True


def test_the_origin_regex_is_fully_anchored():
    """Candado sobre la forma de la regex: sin anclas, todos los casos
    `lookalike` de arriba pasarían."""
    assert CORS_ORIGIN_REGEX.startswith("^")
    assert CORS_ORIGIN_REGEX.endswith("$")
