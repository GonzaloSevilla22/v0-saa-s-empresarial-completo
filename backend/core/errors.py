from __future__ import annotations

import asyncpg
from fastapi import Request
from fastapi.responses import JSONResponse

from backend.core.config import settings

# v3-api-standards §1 — RFC 7807 (application/problem+json)
PROBLEM_JSON_MEDIA_TYPE = "application/problem+json"

# Título legible por status HTTP — usado cuando no se pasa uno explícito.
_STATUS_TITLES: dict[int, str] = {
    400: "Solicitud inválida",
    403: "Prohibido",
    404: "No encontrado",
    409: "Conflicto",
    422: "Error de validación",
    500: "Error interno del servidor",
}


def problem_detail(
    *,
    status: int,
    detail: str,
    code: str,
    title: str | None = None,
    type_: str = "about:blank",
    field: str | None = None,
) -> dict:
    """v3-api-standards D1/D2 — construye el shape RFC 7807.

    Campos base: `type`, `title`, `status`, `detail`.
    Extensiones: `code` (código de negocio: sqlstate P04xx o slug estable) y
    `field` (nombre del campo ofensor, solo en errores de validación).
    """
    body: dict = {
        "type": type_,
        "title": title or _STATUS_TITLES.get(status, "Error"),
        "status": status,
        "detail": detail,
        "code": code,
    }
    if field is not None:
        body["field"] = field
    return body


def problem_response(
    *,
    status: int,
    detail: str,
    code: str,
    title: str | None = None,
    field: str | None = None,
    headers: dict[str, str] | None = None,
) -> JSONResponse:
    """Envuelve `problem_detail` en un `JSONResponse` con el media type 7807."""
    return JSONResponse(
        status_code=status,
        content=problem_detail(status=status, detail=detail, code=code, title=title, field=field),
        headers=headers,
        media_type=PROBLEM_JSON_MEDIA_TYPE,
    )


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
    # bank-account-ledger C1 (gap: no estaban mapeados y caían en 500)
    "P0410": 422,  # movement_type reservado en la carga manual
    "P0411": 422,  # CBU inválido
    "P0412": 404,  # cuenta bancaria no encontrada / inactiva
    # bank-reconciliation C3
    "P0431": 422,  # motivo requerido (cierre con diferencia / undo) — RN-A5
    "P0432": 409,  # sesión cerrada (CLOSED es terminal)
    "P0433": 422,  # Σ montos de líneas ≠ Σ montos de movimientos
    "P0434": 409,  # línea/movimiento ya participa de un match activo
    # edicion-preserva-contexto (F2): la operación tiene un comprobante fiscal
    # pending_cae/authorized — 409 porque el conflicto es de ESTADO (misma
    # familia que P0409), no de payload; el detail del RAISE ya nombra el
    # camino correcto (nota de crédito + venta nueva).
    "P0423": 409,
    # pos-banco-movimientos (D4): value_date cae dentro de un período de
    # conciliación bancaria ya CERRADO — mismo tratamiento 409 que P0423
    # (conflicto de estado, no de payload). El mensaje del RAISE indica el
    # ajuste manual como vía de corrección.
    "P0424": 409,
    # delete-guard-ledgers: borrar una operación revertiría un cargo de
    # cuenta corriente por debajo de cero (el cliente/proveedor ya pagó) —
    # 409, misma familia que P0423 (conflicto de estado). El mensaje del
    # RAISE ya nombra la acción que destraba (registrar la devolución).
    "P0425": 409,
    # delete-guard-ledgers: hay que compensar un movimiento de caja y no hay
    # sesión abierta en esa caja — 409, mismo criterio. El mensaje del RAISE
    # ya nombra la acción que destraba (abrir la caja).
    "P0426": 409,
    # banco-caja-historial-ajustes: ajuste bancario manual_adjustment sin
    # motivo — 422 porque es un error de VALIDACIÓN de payload (falta un
    # campo requerido condicionalmente), no un conflicto de estado.
    "P0413": 422,
    # cuentas-billetera-tipo: rpc_create_bank_account.p_account_kind fuera del
    # dominio cerrado ('bank'|'wallet') — 422, validación de payload (mismo
    # tratamiento que P0411/P0410). P0412 ya estaba tomado por
    # bank-account-ledger (cuenta no encontrada/inactiva); censo re-corrido.
    "P0414": 422,
    # compras-proveedor-cuenta-corriente (task 8.2, D3): límite de
    # proveedores por plan alcanzado. Lo lanza el trigger
    # fn_guard_supplier_plan_limit (20260817000001) — la ÚNICA capa que ve
    # TODOS los inserts de suppliers (el service de proveedores NO precuenta,
    # a diferencia de create_client). Antes de este mapeo salía 500 genérico.
    "P0B10": 403,
}

# banco-caja-historial-ajustes (task 6.4): errcodes cuyo 7807 debe llevar
# `field` — el nombre del campo ofensor, mismo criterio que usa ya
# validation_error_handler (main.py) para los 422 de Pydantic. P0413 es el
# único con esta necesidad hoy; el resto de _BUSINESS_ERRCODE_STATUS no
# apunta a un campo concreto del payload.
_FIELD_BY_ERRCODE: dict[str, str] = {
    "P0413": "description",
}

# bank-account-crud: mapeo específico por endpoint para POST /bank-accounts.
# rpc_create_bank_account lanza P0400 (name requerido) como error de VALIDACIÓN
# de payload — 422 es más correcto ahí que el 400 genérico de _BUSINESS_ERRCODE_STATUS
# (que otras RPCs usan para "bad request" no-validación). Se resuelve en el
# service/router de bank_accounts, no acá, para no romper el mapeo global de P0400.
BANK_ACCOUNT_CREATE_ERRCODE_STATUS = {
    **_BUSINESS_ERRCODE_STATUS,
    "P0400": 422,  # name requerido (validación de payload)
}


async def asyncpg_error_handler(request: Request, exc: asyncpg.PostgresError) -> JSONResponse:
    """v3-api-standards D1 — envuelve el mapeo sqlstate->status existente en 7807.

    `code` = sqlstate (el P04xx del RPC); `detail` = mensaje del RPC/constraint,
    preservado tal cual (ya es texto seguro escrito por nuestro propio SQL).
    """
    headers = cors_error_headers(request)
    code = exc.sqlstate if hasattr(exc, "sqlstate") else None
    if code in _BUSINESS_ERRCODE_STATUS:
        status = _BUSINESS_ERRCODE_STATUS[code]
        return problem_response(
            status=status, detail=str(exc), code=code,
            field=_FIELD_BY_ERRCODE.get(code), headers=headers,
        )
    if code == "23503":
        return problem_response(
            status=409,
            detail="Referencia inválida: el recurso relacionado no existe.",
            code=code,
            headers=headers,
        )
    if code == "23505":
        return problem_response(
            status=409,
            detail="Ya existe un registro con esos datos.",
            code=code,
            headers=headers,
        )
    if code == "23514":
        return problem_response(
            status=422,
            detail="Los datos no cumplen las restricciones de la base de datos.",
            code=code,
            headers=headers,
        )
    return problem_response(
        status=500,
        detail="Error interno de base de datos.",
        code="internal_error",
        headers=headers,
    )
