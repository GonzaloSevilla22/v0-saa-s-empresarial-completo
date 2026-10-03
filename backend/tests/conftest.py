# ─────────────────────────────────────────────────────────────────────────
# auth-hardening-jwt-cookies D9 (bloqueante B2 de la revisión adversarial).
# ESTO TIENE QUE IR ARRIBA DE TODO, por encima del bloque de imports.
#
# `settings = Settings()` es la ÚLTIMA línea de `backend/core/config.py` y
# se ejecuta en el **import** del módulo. El validator de D9 aborta cuando no
# hay `SUPABASE_URL` y la palanca está apagada — que es exactamente el
# entorno de esta suite (`mock_settings.supabase_url = ""`) y el del job de
# CI. Sin esta línea, el primer test que importe `backend.*` revienta durante
# la RECOLECCIÓN: 0 tests recolectados y `--cov-fail-under=87` nunca
# evaluado, es decir CI y local en rojo por algo que no es un test fallando.
#
# Un fixture NO alcanza: corre mucho después del import. `setdefault` y no
# `=` para que un entorno que ya la declare (o un test que quiera probar el
# camino contrario) gane. El candado automático de esto vive en
# `backend/tests/test_config_auth_failfast.py::test_pytest_still_collects_from_a_clean_environment`.
# ─────────────────────────────────────────────────────────────────────────
import os

os.environ.setdefault("AUTH_ALLOW_HS256_FALLBACK", "true")

import re
import time
import uuid
from typing import Any, NamedTuple
from unittest.mock import AsyncMock, MagicMock, patch

import jwt
import pytest
from httpx import ASGITransport, AsyncClient

TEST_SECRET = "test-secret-key-de-32-bytes-o-mas!!"
TEST_USER_ID = "11111111-1111-1111-1111-111111111111"
TEST_ACCOUNT_ID = uuid.UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")


def make_token(extra: dict = {}) -> str:
    """Token de test por el camino HS256 (dev/CI).

    auth-hardening-jwt-cookies D8: el payload incluye `aud="authenticated"`
    porque la verificación pasa a declarar la audiencia esperada en vez de
    apagar la comprobación. No es un ajuste para "que pasen los tests": es
    la forma real del token que emite GoTrue —los 40 usuarios de producción
    tienen `auth.users.aud='authenticated'`, columna que GoTrue copia al
    claim—, así que el doble se vuelve MÁS fiel, no menos. `extra` sigue
    pudiendo sobreescribir cualquier claim, incluido `aud`.
    """
    payload = {
        "sub": TEST_USER_ID,
        "role": "authenticated",
        "aud": "authenticated",
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


def account_roles_fetchval(roles, *, otherwise=None):
    """Doble de `conn.fetchval` que distingue las consultas que lo comparten.

    auth-hardening-jwt-cookies D12: con el re-chequeo en base para las
    acciones de configuración, `fetchval` atiende ahora DOS consultas
    distintas en el mismo request — `rpc_my_active_account_roles()` (el
    guard) y la que el endpoint ya hacía (típicamente `get_account_id`). Un
    `return_value` único no puede servir a las dos, y un `side_effect`
    posicional ata el test al ORDEN en que se emiten, que es un detalle de
    implementación: cualquier reordenamiento lo rompería sin que cambie el
    comportamiento.

    Despachar por el texto de la consulta hace el doble independiente del
    orden y explícito sobre qué responde a quién.

    `otherwise` admite una lista/tupla cuando el endpoint hace VARIAS
    consultas distintas con `fetchval` (p. ej. escribir y releer): se
    consumen en orden, sin contar la del guard.
    """
    rest = iter(otherwise) if isinstance(otherwise, (list, tuple)) else None

    async def _fetchval(query, *args, **kwargs):
        if "rpc_my_active_account_roles" in query:
            return roles
        return next(rest) if rest is not None else otherwise

    return AsyncMock(side_effect=_fetchval)


def named_rpc_arg(captured: dict, name: str):
    """Valor ligado al argumento NOMBRADO `name` de una llamada a una RPC.

    `captured` es `{"query": <sql>, "args": <args de asyncpg>}`. Parsea
    `name => $N` del SQL y devuelve `args[N-1]`: el test queda independiente del
    ORDEN en que el repositorio emite los parámetros. `rpc_create_sale_operation`
    acumuló cinco parámetros opcionales con el tiempo y cada uno corrió los
    índices de los tests que miraban `args[-k]` (ventas-formulario-sucursal).
    """
    match = re.search(rf"\b{name}\s*=>\s*\$(\d+)", captured["query"])
    assert match is not None, f"{name} no viaja como argumento nombrado en la RPC"
    return captured["args"][int(match.group(1)) - 1]


class EffectiveRoute(NamedTuple):
    """Una ruta tal como la sirve la app: con prefijo y verbos ya resueltos.

    `route` es la ruta SUBYACENTE (`APIRoute`, `WebSocketRoute`, ...) para poder
    discriminar por tipo; `path`/`methods` son los EFECTIVOS (con el prefijo del
    `include_router`). `methods` es vacío en una ruta que no es HTTP.
    """

    route: Any
    path: str | None
    methods: frozenset[str]


def effective_routes(app) -> list[EffectiveRoute]:
    """Rutas EFECTIVAS de `app`, igual en FastAPI viejo y nuevo.

    FastAPI <= 0.136 aplanaba `include_router`: `app.routes` traía cada ruta
    con su prefijo. Desde 0.142 trae un contenedor opaco (`_IncludedRouter`) por
    cada `include_router`, sin `path` ni `methods`, y lo efectivo se pide por
    `fastapi.routing.iter_route_contexts`. `requirements.txt` declara
    `fastapi>=0.111`, así que CI corre la última y local puede correr otra:
    el test de registro de remitos pasaba en local y fallaba en CI porque un
    `{(m, r.path) for r in app.routes if hasattr(r, "methods")}` filtra los
    contenedores y deja sólo `/docs`, `/redoc` y `/openapi.json`.

    Peor que fallar: un candado del tipo "no hay rutas WebSocket" que itera
    `app.routes` pasa a ser vacuo (siempre verde) bajo el contrato nuevo. Todo
    test que inspeccione la tabla de rutas de la app pasa por acá.
    Candado de este helper: `test_effective_routes_helper.py`.
    """
    from fastapi import routing as fastapi_routing

    iter_route_contexts = getattr(fastapi_routing, "iter_route_contexts", None)
    if iter_route_contexts is None:
        # FastAPI con `include_router` aplanado: `app.routes` ya es lo efectivo.
        return [
            EffectiveRoute(route, getattr(route, "path", None), frozenset(getattr(route, "methods", None) or ()))
            for route in app.routes
        ]
    effective: list[EffectiveRoute] = []
    for context in iter_route_contexts(app.routes):
        # Un `APIRoute` trae `path`/`methods` efectivos en el propio contexto;
        # el resto (WebSocket, `Route`, `Mount`) los trae en `starlette_route`
        # —el contexto deja `path=""` para ésos— y ése es el que tiene el
        # prefijo del `include_router`.
        source = getattr(context, "starlette_route", None) or context
        effective.append(
            EffectiveRoute(
                context.original_route,
                source.path,
                frozenset(getattr(source, "methods", None) or ()),
            )
        )
    return effective


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
        # D9: explícito, no por la verdad accidental de un atributo de
        # MagicMock. Este fixture declara que corre por la rama HS256.
        mock_settings.auth_allow_hs256_fallback = True
        app.dependency_overrides[get_account_id] = _mock_account_id
        async with AsyncClient(
            transport=ASGITransport(app=app), base_url="http://test"
        ) as client:
            yield client
        app.dependency_overrides.pop(get_account_id, None)
