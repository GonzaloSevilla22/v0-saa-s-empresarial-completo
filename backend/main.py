from __future__ import annotations

import logging
from contextlib import asynccontextmanager

import asyncpg
from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from backend.core.config import settings
from backend.core.database import close_pool, close_service_pool, init_pool, init_service_pool
from backend.core.errors import asyncpg_error_handler, cors_error_headers, problem_response
from backend.core.redis_client import close_redis, init_redis
from backend.routers import (
    bank_accounts,
    bank_reconciliation,
    branches,
    cash,
    client_addresses,
    clients,
    cost_centers,
    customer_accounts,
    expenses,
    fiscal,
    health,
    journal_entries,
    organizations,
    outbox,
    payments,
    products,
    purchases,
    quotes,
    sales,
    sales_orders,
    stock,
    supplier_accounts,
    ws,
)

logger = logging.getLogger("app")


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_pool()
    await init_service_pool()
    await init_redis()
    yield
    await close_pool()
    await close_service_pool()
    await close_redis()


app = FastAPI(title="Aliadata Backend", version="0.1.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[settings.backend_allowed_origin],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.add_exception_handler(asyncpg.PostgresError, asyncpg_error_handler)


# v3-api-standards §1.3 — los 422 de validación de Pydantic salían con el
# shape default de FastAPI ({"detail":[{loc,msg,type}]}). Se emite 7807 con
# `field` (= loc[-1]) por cada violación; si hay más de una, se listan bajo
# `errors` y el `detail` top-level resume la primera para mantener un string.
# Tipos de violación con un `code` propio en vez del genérico
# "validation_error" (p. ej. v3-api-standards §3: falta Idempotency-Key).
_VALIDATION_ERROR_CODES: dict[str, str] = {
    "idempotency_key_required": "idempotency_key_required",
}


@app.exception_handler(RequestValidationError)
async def validation_error_handler(request: Request, exc: RequestValidationError) -> JSONResponse:
    violations = exc.errors()
    fields = [str(v["loc"][-1]) if v.get("loc") else None for v in violations]
    first_msg = violations[0]["msg"] if violations else "Error de validación"
    first_type = violations[0].get("type") if violations else None
    code = _VALIDATION_ERROR_CODES.get(first_type, "validation_error")

    content = {
        "type": "about:blank",
        "title": "Error de validación",
        "status": 422,
        "detail": first_msg,
        "code": code,
        "field": fields[0] if fields else None,
    }
    if len(violations) > 1:
        content["errors"] = [
            {"field": f, "detail": v["msg"]} for f, v in zip(fields, violations)
        ]

    return JSONResponse(
        status_code=422,
        content=content,
        headers=cors_error_headers(request),
        media_type="application/problem+json",
    )


# v3-api-standards §1.4 — los `raise HTTPException(...)` dispersos en services
# también deben salir en 7807, no en el shape default de Starlette.
@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException) -> JSONResponse:
    return problem_response(
        status=exc.status_code,
        detail=str(exc.detail),
        code="http_error",
        headers={**cors_error_headers(request), **(exc.headers or {})},
    )


# v3-api-standards §1.5 — catch-all a 7807 genérico, sin filtrar internals.
@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    logger.exception("Unhandled %s on %s %s", type(exc).__name__, request.method, request.url.path)
    return problem_response(
        status=500,
        detail="Error interno del servidor",
        code="internal_error",
        headers=cors_error_headers(request),
    )

app.include_router(health.router)
app.include_router(ws.router)
# cost-center-dimension (V2.5 Finanzas)
app.include_router(cost_centers.router)
app.include_router(fiscal.router)
app.include_router(expenses.router)
app.include_router(clients.router)
# v3-catalog-masters (V3 §7.3) — direcciones operativas anidadas bajo cliente
app.include_router(client_addresses.router)
app.include_router(products.router)
app.include_router(branches.router)
app.include_router(stock.router)
app.include_router(sales.router)
app.include_router(purchases.router)
app.include_router(organizations.router)
app.include_router(payments.router)
# C-28 v21-cash-session
app.include_router(cash.router)
# C-29 v21-quote-salesorder
app.include_router(quotes.router)
app.include_router(sales_orders.router)
# C-25 v20-outbox-activation
app.include_router(outbox.router)
# C-30 v21-customer-supplier-accounts
app.include_router(customer_accounts.router)
app.include_router(supplier_accounts.router)
# journal-entry-outbox (V2.5 Finanzas — read-only; writes via relay SECURITY DEFINER)
app.include_router(journal_entries.router)
# bank-payment-routing C2 (V2.5 BankReconciliation) — read-only picker de cuenta bancaria
app.include_router(bank_accounts.router)
app.include_router(bank_reconciliation.router)
