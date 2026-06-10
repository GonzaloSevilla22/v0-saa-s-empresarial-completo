from __future__ import annotations

import uuid

import asyncpg
from fastapi import Depends, HTTPException

from backend.core.database import get_db_conn


async def get_account_id(
    conn: asyncpg.Connection = Depends(get_db_conn),
) -> uuid.UUID:
    """FastAPI dependency: retorna el account_id activo del usuario autenticado.

    Consulta account_members usando auth.uid() (seteado por get_db_conn JWT-passthrough).
    Lanza 403 si el usuario no tiene cuenta activa.
    """
    account_id = await conn.fetchval(
        "SELECT account_id FROM account_members WHERE user_id = auth.uid() LIMIT 1"
    )
    if account_id is None:
        raise HTTPException(status_code=403, detail="No active account found")
    return account_id
