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

    v31-authz-token-hook (D4): ORDER BY created_at, id — la membresía más
    antigua, desempatada por la PK — es el MISMO criterio determinístico que
    usa la migración del hook (20260827000001) para elegir la cuenta activa
    al emitir el claim `account_role`/`plan`. Sin este orden explícito, bajo
    multi-membresía el hook y este resolver podrían elegir cuentas distintas
    para el mismo usuario (bug latente: 0 usuarios con 2+ membresías hoy,
    pero v3-rbac-multirole lo vuelve alcanzable).
    """
    account_id = await conn.fetchval(
        "SELECT account_id FROM account_members WHERE user_id = auth.uid() "
        "ORDER BY created_at, id LIMIT 1"
    )
    if account_id is None:
        raise HTTPException(status_code=403, detail="No active account found")
    return account_id
