from fastapi import FastAPI
from backend.routers import health, ws

app = FastAPI(title="EmprendeSmart Backend", version="0.1.0")

app.include_router(health.router)
app.include_router(ws.router)
