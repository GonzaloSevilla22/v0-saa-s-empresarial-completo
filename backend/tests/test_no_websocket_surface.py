"""auth-hardening-jwt-cookies Parte A, grupo 5 (D11) — el canal WebSocket
propio se retira, y estos tests son el candado que impide que vuelva por
descuido.

**Por qué se retira en vez de endurecerlo.** `/ws/{room_id}` autenticaba el
handshake pero **no autorizaba la sala**: descartaba la identidad validada y
nunca comparaba `room_id` contra la cuenta del portador, así que cualquier
usuario válido podía suscribirse a la sala de cualquier cuenta. Recibía el JWT
por **query string** —que queda escrito en los registros de Render, con 7 días
de retención— y validaba **una sola vez** para toda la vida de la conexión.

Y no tenía productor ni consumidor: cero `new WebSocket`/`ws://`/`wss://` en
el fuente del frontend (verificado en el checkpoint 1.6), el único emisor de
difusión era el eco del propio cliente, DEC-16 lo declara fuera de producción
y `openspec/specs/in-app-notifications/spec.md` prohíbe usarlo. Endurecerlo
habría sido escribir autorización de sala, rotación de token y límites de
conexión para un canal muerto que una decisión vigente prohíbe usar.

El tiempo real de la aplicación es Supabase Realtime sobre tablas con RLS.
"""
from __future__ import annotations

import pathlib
import re

from starlette.routing import WebSocketRoute

from backend.core import auth as auth_module

BACKEND_ROOT = pathlib.Path(auth_module.__file__).resolve().parents[1]


def _app_source_files() -> list[pathlib.Path]:
    """Los `.py` de la APP — sin la suite y sin el entorno virtual."""
    return [
        path
        for path in sorted(BACKEND_ROOT.rglob("*.py"))
        if ".venv" not in path.parts and "tests" not in path.parts
    ]


# ── 5.1 — ninguna ruta ni router de WebSocket ────────────────────────────


def test_openapi_has_no_ws_route():
    """5.1 RED: hoy `app.include_router(ws.router)` deja `/ws/{room_id}` en la
    superficie. Un endpoint sin autorización de sala en la app es una
    invitación."""
    from backend.main import app

    paths = {getattr(route, "path", "") for route in app.routes}
    ws_paths = {p for p in paths if p.startswith("/ws")}

    assert ws_paths == set(), f"quedaron rutas de WebSocket registradas: {ws_paths}"

    openapi_paths = set(app.openapi().get("paths", {}))
    assert not any(p.startswith("/ws") for p in openapi_paths)


def test_no_ws_router_registered():
    """5.1 RED: ninguna ruta de la app puede ser una ruta de WebSocket —
    incluida una montada bajo cualquier otro prefijo. Chequear sólo el path
    `/ws` dejaría pasar un `/notifications/stream` idéntico."""
    from backend.main import app

    websocket_routes = [
        getattr(route, "path", repr(route))
        for route in app.routes
        if isinstance(route, WebSocketRoute)
    ]

    assert websocket_routes == [], (
        f"la app registró rutas WebSocket: {websocket_routes}. El tiempo real "
        "de esta aplicación es Supabase Realtime sobre tablas con RLS; un canal "
        "propio necesita su propio change, con autorización de sala."
    )


def test_no_connection_manager_module_exists():
    """5.1: el gestor de conexiones por salas tampoco sobrevive. No tenía tope
    de vida ni de conexiones y su único uso era el eco del propio cliente."""
    assert not (BACKEND_ROOT / "core" / "ws_manager.py").exists()
    assert not (BACKEND_ROOT / "routers" / "ws.py").exists()
    assert not (BACKEND_ROOT / "tests" / "test_ws.py").exists()


def test_the_backend_package_cannot_import_a_ws_module():
    """5.1 TRIANGULATE: borrar el archivo no alcanza si quedó un import vivo
    en algún lado — sería un `ModuleNotFoundError` en el arranque, no un
    candado. Este caso prueba que el módulo efectivamente no se puede importar
    **y** que nada lo intenta."""
    import importlib

    for module_name in ("backend.routers.ws", "backend.core.ws_manager"):
        try:
            importlib.import_module(module_name)
        except ModuleNotFoundError:
            continue
        raise AssertionError(f"{module_name} todavía existe")

    offenders = [
        path.relative_to(BACKEND_ROOT).as_posix()
        for path in _app_source_files()
        if re.search(r"\bws_manager\b|\brouters(\.|\s+import\s+)ws\b", path.read_text(encoding="utf-8"))
    ]
    assert offenders == [], f"quedaron referencias al canal retirado en: {offenders}"


# ── 5.3 — el token viaja sólo por el encabezado de autorización ──────────


def test_no_query_param_token_extraction():
    """5.3: cubre el requisito nuevo "El token viaja únicamente por el
    encabezado de autorización". `ws.py` lo tomaba de `?token=`, que queda
    escrito en los registros del proveedor de hosting y en cualquier
    intermediario; un encabezado no.

    El chequeo es sobre el FUENTE porque las rutas WebSocket no aparecen en
    el documento de OpenAPI: un canal nuevo que repitiera el patrón sería
    invisible para un chequeo puramente behavioral.
    """
    # `token: str = Query(...)`, `token=Query(...)`, `access_token: str | None = Query(...)`
    pattern = re.compile(r"\b\w*token\w*\s*(?::[^=\n]+)?=\s*Query\s*\(", re.IGNORECASE)

    offenders: list[str] = []
    for path in _app_source_files():
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if pattern.search(line):
                offenders.append(f"{path.relative_to(BACKEND_ROOT).as_posix()}:{lineno}")

    assert offenders == [], (
        "algún camino del backend extrae un token de un parámetro de consulta: "
        f"{offenders}"
    )


def test_the_query_param_detector_actually_detects():
    """5.3 TRIANGULATE — matriz de evasión del detector. Un detector de texto
    sin control positivo es una aserción trivial: si la regex no matchea
    nada, el test de arriba pasa para siempre sin controlar nada. Lección ya
    registrada en `tenancy-guard-caja-outbox`."""
    pattern = re.compile(r"\b\w*token\w*\s*(?::[^=\n]+)?=\s*Query\s*\(", re.IGNORECASE)

    # La forma literal que tenía `ws.py:41`, más variantes plausibles.
    must_detect = [
        "    token: str = Query(default=None),",
        "    token=Query(None),",
        "    access_token: str | None = Query(None),",
        "    TOKEN: str = Query(...),",
        "    ws_token: str = Query( default=None ),",
    ]
    for line in must_detect:
        assert pattern.search(line), f"el detector NO encuentra: {line!r}"

    # Y no puede ensuciarse con lo que sí es legítimo.
    must_not_detect = [
        "    page: int = Query(0, ge=0),",
        '    search: str | None = Query(None, description="token de búsqueda"),',
        "    token = request.headers.get('authorization')",
    ]
    for line in must_not_detect:
        assert not pattern.search(line), f"el detector tiene falso positivo: {line!r}"


# ── 5.5 — queda un solo decoder canónico de JWT ──────────────────────────


def test_there_is_a_single_jwt_decoder_in_the_backend():
    """5.5: el módulo retirado se llevaba un SEGUNDO decoder de JWT
    (`ws.py:12-34`) que divergía del canónico —sin rama HS256, sin `iss`, sin
    `aud`— y que nadie ejercitaba (`test_ws.py` sólo probaba el gestor de
    conexiones con `AsyncMock`). Dos decoders divergen en silencio: éste ya lo
    había hecho. Este test es la forma mecanizada de esa garantía."""
    decoders = [
        path.relative_to(BACKEND_ROOT).as_posix()
        for path in _app_source_files()
        if "jwt.decode(" in path.read_text(encoding="utf-8").replace("pyjwt.decode(", "jwt.decode(")
    ]

    assert decoders == ["core/auth.py"], (
        f"se esperaba un único decoder canónico de JWT, se encontraron: {decoders}"
    )
