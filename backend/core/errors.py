from __future__ import annotations

import asyncpg
from fastapi import Request
from fastapi.responses import JSONResponse

from backend.core.config import settings


def cors_error_headers(request: Request) -> dict[str, str]:
    """Return CORS headers for error responses.

    @app.exception_handler responses bypass Starlette's CORSMiddleware, so
    we inject the headers manually here.
    """
    origin = request.headers.get("origin", "")
    allowed = settings.backend_allowed_origin
    if origin and (allowed == "*" or origin == allowed):
        return {
            "access-control-allow-origin": origin,
            "access-control-allow-credentials": "true",
        }
    return {}


# Códigos de negocio custom de los RPCs (RAISE ... USING ERRCODE). El mensaje
# del RAISE lo escriben nuestras propias funciones SQL — es seguro mostrarlo.
# (Los códigos de 4 chars 'P4xx' eran inválidos y degradaban a 42704; se
# normalizaron a 'P04xx' en la migración 20260624000001.)
_BUSINESS_ERRCODE_STATUS = {
    "P0400": 400,
    "P0401": 403,
    "P0403": 403,
    "P0404": 404,
    "P0409": 409,
    "P0422": 422,
}


async def asyncpg_error_handler(request: Request, exc: asyncpg.PostgresError) -> JSONResponse:
    headers = cors_error_headers(request)
    code = exc.sqlstate if hasattr(exc, "sqlstate") else None
    if code in _BUSINESS_ERRCODE_STATUS:
        return JSONResponse(
            status_code=_BUSINESS_ERRCODE_STATUS[code],
            content={"detail": str(exc)},
            headers=headers,
        )
    if code == "23503":
        return JSONResponse(status_code=409, content={"detail": "Referencia inválida: el recurso relacionado no existe."}, headers=headers)
    if code == "23505":
        return JSONResponse(status_code=409, content={"detail": "Ya existe un registro con esos datos."}, headers=headers)
    if code == "23514":
        return JSONResponse(status_code=422, content={"detail": "Los datos no cumplen las restricciones de la base de datos."}, headers=headers)
    return JSONResponse(status_code=500, content={"detail": "Error interno de base de datos."}, headers=headers)
