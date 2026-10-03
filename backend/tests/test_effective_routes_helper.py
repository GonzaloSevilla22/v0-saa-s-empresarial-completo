"""
Candado del helper `effective_routes` (backend/tests/conftest.py).

Por qué existe: FastAPI >= 0.14x dejó de APLANAR `include_router`. Hasta 0.136,
`app.routes` devolvía cada `APIRoute` con su prefijo ya aplicado; desde 0.142
devuelve un contenedor opaco (`_IncludedRouter`) por cada `include_router`, sin
`path` ni `methods` propios, y las rutas efectivas hay que pedirlas por
`fastapi.routing.iter_route_contexts`. `requirements.txt` declara
`fastapi>=0.111`, así que CI instala siempre la última: el test de registro del
router de remitos pasaba en local (0.136) y fallaba en CI (0.142) con un
`app.routes` que sólo mostraba `/docs`, `/redoc` y `/openapi.json`. No era
contaminación entre tests: era un contrato de `app.routes` que cambió de
versión.

Este archivo fija que el helper devuelve las rutas EFECTIVAS (prefijo aplicado,
métodos, tipo de ruta subyacente) tanto en el contrato viejo como en el nuevo, y
que no inventa rutas que no están: sin esas dos mitades, un test de registro que
lo use sería trivial (siempre verde) o siempre rojo.
"""
from __future__ import annotations

import pytest
from fastapi import APIRouter, FastAPI, WebSocket
from starlette.routing import WebSocketRoute

from backend.tests.conftest import effective_routes


def _app_with(router: APIRouter, *, prefix: str = "") -> FastAPI:
    app = FastAPI()
    app.include_router(router, prefix=prefix)
    return app


def _router() -> APIRouter:
    router = APIRouter()

    @router.get("/things")
    async def list_things():
        return []

    @router.post("/things")
    async def create_thing():
        return {}

    @router.get("/things/{thing_id}")
    async def get_thing(thing_id: str):
        return {}

    return router


def _pairs(app: FastAPI) -> set[tuple[str, str]]:
    return {(m, r.path) for r in effective_routes(app) for m in r.methods}


class TestEffectiveRoutes:
    def test_included_routes_are_visible_with_their_verbs(self):
        pairs = _pairs(_app_with(_router()))

        assert ("GET", "/things") in pairs
        assert ("POST", "/things") in pairs
        assert ("GET", "/things/{thing_id}") in pairs

    def test_the_include_prefix_is_applied_to_the_path(self):
        pairs = _pairs(_app_with(_router(), prefix="/api/v1"))

        assert ("GET", "/api/v1/things") in pairs
        assert ("GET", "/things") not in pairs

    def test_a_router_that_was_never_included_contributes_nothing(self):
        app = FastAPI()
        _router()  # existe, pero nadie lo incluyó

        pairs = _pairs(app)

        assert ("GET", "/things") not in pairs
        # lo único que queda es la documentación autogenerada de la app
        assert {p for _, p in pairs} <= {"/openapi.json", "/docs", "/docs/oauth2-redirect", "/redoc"}

    def test_verbs_are_not_invented(self):
        pairs = _pairs(_app_with(_router()))

        assert ("DELETE", "/things") not in pairs
        assert ("PUT", "/things/{thing_id}") not in pairs

    def test_a_nested_include_accumulates_both_prefixes(self):
        inner = _router()
        outer = APIRouter()
        outer.include_router(inner, prefix="/inner")
        pairs = _pairs(_app_with(outer, prefix="/outer"))

        assert ("GET", "/outer/inner/things") in pairs

    def test_websocket_routes_are_exposed_as_websocket_routes(self):
        # Es lo que hace no-vacuo a `test_no_websocket_surface`: con el contrato
        # nuevo de FastAPI, `app.routes` esconde las rutas WebSocket de un
        # router incluido y el candado de "no hay WebSocket" pasaría siempre.
        router = APIRouter()

        @router.websocket("/stream")
        async def stream(ws: WebSocket):  # pragma: no cover - sólo se registra
            await ws.close()

        routes = effective_routes(_app_with(router, prefix="/live"))
        websocket_paths = [r.path for r in routes if isinstance(r.route, WebSocketRoute)]

        assert websocket_paths == ["/live/stream"]

    def test_http_routes_are_not_reported_as_websocket_routes(self):
        routes = effective_routes(_app_with(_router()))

        assert [r for r in routes if isinstance(r.route, WebSocketRoute)] == []


class TestTheRealAppIsInspectable:
    def test_the_real_app_exposes_more_than_its_docs_routes(self):
        # El síntoma exacto de CI: un `app.routes` sin ninguna ruta de negocio.
        from backend.main import app

        pairs = _pairs(app)

        assert ("GET", "/health") in pairs
        assert ("GET", "/clients") in pairs
        assert ("GET", "/sales") in pairs
        assert len({p for _, p in pairs}) > 50


@pytest.mark.parametrize("prefix", ["", "/p"])
def test_every_effective_route_has_a_path(prefix):
    for r in effective_routes(_app_with(_router(), prefix=prefix)):
        assert isinstance(r.path, str) and r.path.startswith("/")
