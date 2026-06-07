from __future__ import annotations

import asyncpg
from fastapi import Request
from fastapi.responses import JSONResponse


async def asyncpg_error_handler(request: Request, exc: asyncpg.PostgresError) -> JSONResponse:
    code = exc.sqlstate if hasattr(exc, "sqlstate") else None
    if code == "23503":
        return JSONResponse(status_code=409, content={"detail": "Referencia inválida: el recurso relacionado no existe."})
    if code == "23505":
        return JSONResponse(status_code=409, content={"detail": "Ya existe un registro con esos datos."})
    if code == "23514":
        return JSONResponse(status_code=422, content={"detail": "Los datos no cumplen las restricciones de la base de datos."})
    return JSONResponse(status_code=500, content={"detail": "Error interno de base de datos."})
