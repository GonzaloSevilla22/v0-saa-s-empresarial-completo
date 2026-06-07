from contextlib import asynccontextmanager

from fastapi import FastAPI

from backend.core.database import close_pool, init_pool
from backend.core.redis_client import close_redis, init_redis
from backend.routers import health, ws


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_pool()
    await init_redis()
    yield
    await close_pool()
    await close_redis()


app = FastAPI(title="EmprendeSmart Backend", version="0.1.0", lifespan=lifespan)

app.include_router(health.router)
app.include_router(ws.router)
