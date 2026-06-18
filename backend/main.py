from __future__ import annotations

import logging
from contextlib import asynccontextmanager

import asyncpg
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from backend.core.config import settings
from backend.core.database import close_pool, close_service_pool, init_pool, init_service_pool
from backend.core.errors import asyncpg_error_handler, cors_error_headers
from backend.core.redis_client import close_redis, init_redis
from backend.routers import (
    branches,
    cash,
    clients,
    expenses,
    fiscal,
    health,
    organizations,
    outbox,
    payments,
    products,
    purchases,
    quotes,
    sales,
    sales_orders,
    stock,
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


app = FastAPI(title="EmprendeSmart Backend", version="0.1.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[settings.backend_allowed_origin],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.add_exception_handler(asyncpg.PostgresError, asyncpg_error_handler)


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    logger.exception("Unhandled %s on %s %s", type(exc).__name__, request.method, request.url.path)
    return JSONResponse(
        status_code=500,
        content={"detail": "Error interno del servidor"},
        headers=cors_error_headers(request),
    )

app.include_router(health.router)
app.include_router(ws.router)
app.include_router(fiscal.router)
app.include_router(expenses.router)
app.include_router(clients.router)
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
