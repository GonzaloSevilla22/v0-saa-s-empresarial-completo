from __future__ import annotations

from contextlib import asynccontextmanager

import asyncpg
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from backend.core.config import settings
from backend.core.database import close_pool, close_service_pool, init_pool, init_service_pool
from backend.core.errors import asyncpg_error_handler
from backend.core.redis_client import close_redis, init_redis
from backend.routers import (
    branches,
    clients,
    expenses,
    health,
    organizations,
    payments,
    products,
    purchases,
    sales,
    stock,
    ws,
)


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

app.include_router(health.router)
app.include_router(ws.router)
app.include_router(expenses.router)
app.include_router(clients.router)
app.include_router(products.router)
app.include_router(branches.router)
app.include_router(stock.router)
app.include_router(sales.router)
app.include_router(purchases.router)
app.include_router(organizations.router)
app.include_router(payments.router)
