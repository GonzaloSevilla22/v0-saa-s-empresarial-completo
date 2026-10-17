from __future__ import annotations

import uuid

import asyncpg
from fastapi import Depends, Header, HTTPException

from backend.core.database import get_db_conn
from backend.core.errors import ProblemHTTPException

# multiusuario-operativo (D6): la cuenta que la pantalla del cliente está mostrando.
ACCOUNT_ID_HEADER = "X-Account-Id"

ACCOUNT_SWITCHED_CODE = "account_switched"


async def get_account_id(
    conn: asyncpg.Connection = Depends(get_db_conn),
    x_account_id: str | None = Header(default=None, alias=ACCOUNT_ID_HEADER),
) -> uuid.UUID:
    """FastAPI dependency: retorna el account_id ACTIVO del usuario autenticado.

    multiusuario-operativo (D4): lee `current_account_ids()` — la MISMA función
    de base que usan las RPCs y las policies de RLS (y los mismos claims, que
    `get_db_conn` empuja a SQL) —, nunca un criterio propio. Antes era
    `SELECT account_id FROM account_members ... ORDER BY created_at, id LIMIT 1`
    (v31-authz-token-hook, D4): "la membresía más antigua", que sólo coincidía
    con el hook y con SQL mientras nadie pudiera elegir otra. Con la cuenta activa
    elegible, un segundo criterio dejaba de poder coincidir con el del token: ahora
    hay UNO solo, en la base.

    La función devuelve a lo sumo UNA fila (la cuenta activa). Sin ninguna —usuario
    sin membresía, o un token que declara una cuenta de la que ya no es miembro
    (fail-closed)— lanza 403 "No active account found".

    Guard de pestaña desfasada (D6): si el request declara la cuenta que muestra la
    pantalla (`X-Account-Id`) y NO coincide con la resuelta, 409 RFC 7807
    `account_switched` ANTES de que el endpoint ejecute nada. El token es el mismo
    para todas las pestañas (cookies httpOnly compartidas): al cambiar de cuenta en
    una, la otra sigue mostrando la anterior pero sus requests ya salen con el token
    nuevo, y un alta sin entidad (gasto, venta de servicio) caería en la cuenta
    nueva EN SILENCIO. Sin header NO se compara (compatibilidad con scripts y
    clientes viejos).
    """
    account_id = await conn.fetchval("SELECT cai FROM public.current_account_ids() AS cai")
    if account_id is None:
        raise HTTPException(status_code=403, detail="No active account found")

    # Los llamadores directos (tests, scripts) no pasan por la inyección de FastAPI y
    # dejan acá el objeto `Header(...)`: sólo una cadena real cuenta como declaración.
    if isinstance(x_account_id, str) and x_account_id.strip():
        if not _same_account(x_account_id, account_id):
            raise ProblemHTTPException(
                status_code=409,
                detail=(
                    "La cuenta activa cambió: la pantalla muestra otra cuenta distinta "
                    "de la que está en uso. Se resincroniza sola."
                ),
                code=ACCOUNT_SWITCHED_CODE,
                type_=ACCOUNT_SWITCHED_CODE,
            )
    return account_id


def _same_account(declared: str, resolved: uuid.UUID | str) -> bool:
    """¿El header declara la cuenta resuelta? Comparación por UUID (no por texto);
    un valor que no es un UUID declara OTRA cuenta (fail-closed)."""
    try:
        return uuid.UUID(declared.strip()) == uuid.UUID(str(resolved))
    except ValueError:
        return False
