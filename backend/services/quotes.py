"""
C-29 v21-quote-salesorder — Service layer para Quote.

Regla dura: NO lógica de negocio en routers.
Todos los guards (rol, dominio) viven aquí.
Los repositories manejan solo acceso a datos.
"""
from __future__ import annotations

from decimal import Decimal

import asyncpg
from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.quote_repository import QuoteRepository
from backend.schemas.quotes import QuoteIn, QuoteTransitionIn


# ── Guards de estado válidos ───────────────────────────────────────────────────

_VALID_TRANSITIONS: dict[str, set[str]] = {
    "draft":    {"sent", "expired"},
    "sent":     {"rejected", "expired"},
    # accepted / rejected / expired son terminales
}


# ── Funciones de servicio ─────────────────────────────────────────────────────

async def create_quote(
    repo: QuoteRepository,
    auth: dict,
    payload: QuoteIn,
    created_by: str,
    account_id: str,
) -> dict:
    """Crea un presupuesto con sus ítems. Guard: writer."""
    require_role(auth, ["user", "admin"])

    # Calcular total como suma de subtotals
    total = sum(item.subtotal for item in payload.items)

    # Serializar ítems
    items = [
        {
            "product_id": str(item.product_id) if item.product_id else None,
            "unit_id":    str(item.unit_id) if item.unit_id else None,
            "quantity":   str(item.quantity),
            "price":      str(item.price),
            "subtotal":   str(item.subtotal),
        }
        for item in payload.items
    ]

    record = await repo.create_quote(
        account_id=account_id,
        branch_id=str(payload.branch_id) if payload.branch_id else None,
        client_id=str(payload.client_id) if payload.client_id else None,
        valid_until=payload.valid_until,
        total=total,
        items=items,
        created_by=created_by,
    )

    if record is None:
        raise HTTPException(status_code=500, detail="Error al crear el presupuesto")

    return dict(record)


async def list_quotes(
    repo: QuoteRepository,
    account_id: str,
) -> list:
    """Lista los presupuestos de la cuenta. Sin guard de rol (lectura)."""
    return await repo.list_quotes(account_id)


async def get_quote(
    repo: QuoteRepository,
    quote_id: str,
) -> dict:
    """Obtiene un presupuesto por id. 404 si no existe."""
    record = await repo.get_quote(quote_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Presupuesto no encontrado")
    return dict(record)


async def transition_quote(
    repo: QuoteRepository,
    auth: dict,
    quote_id: str,
    payload: QuoteTransitionIn,
) -> dict:
    """
    Transiciona el estado de un presupuesto.
    Acciones: send → sent; reject → rejected; expire → expired.
    Guard: writer.
    """
    require_role(auth, ["user", "admin"])

    # Mapeo acción → status destino
    action_to_status = {
        "send":   "sent",
        "reject": "rejected",
        "expire": "expired",
    }
    new_status = action_to_status[payload.action]

    # Verificar estado actual
    current = await repo.get_quote(quote_id)
    if current is None:
        raise HTTPException(status_code=404, detail="Presupuesto no encontrado")

    current_status = current["status"]
    valid_targets = _VALID_TRANSITIONS.get(current_status, set())
    if new_status not in valid_targets:
        raise HTTPException(
            status_code=409,
            detail=f"Transición inválida: {current_status} → {new_status}",
        )

    try:
        record = await repo.transition_quote(quote_id, new_status)
    except asyncpg.PostgresError as exc:
        _map_postgres_error(exc)

    if record is None:
        raise HTTPException(status_code=404, detail="Presupuesto no encontrado")

    return dict(record)


async def accept_quote(
    repo: QuoteRepository,
    auth: dict,
    quote_id: str,
) -> dict:
    """
    Acepta un presupuesto y crea un SalesOrder con los mismos ítems.
    Guard: writer. Atómico vía RPC SECURITY DEFINER.
    """
    require_role(auth, ["user", "admin"])

    try:
        result = await repo.accept_quote(quote_id)
    except asyncpg.PostgresError as exc:
        _map_postgres_error(exc)

    return result


# ── Error mapping ─────────────────────────────────────────────────────────────

def _map_postgres_error(exc: asyncpg.PostgresError) -> None:
    """Mapea errores PostgreSQL → HTTPException con código HTTP apropiado."""
    sqlstate = getattr(exc, "sqlstate", None)
    message  = str(exc)

    if sqlstate == "P0401":
        raise HTTPException(status_code=403, detail=f"Sin permiso: {message}")
    if sqlstate == "P0400":
        raise HTTPException(status_code=400, detail=f"Payload inválido: {message}")
    if sqlstate == "P0404":
        raise HTTPException(status_code=404, detail=f"No encontrado: {message}")
    if sqlstate in ("P0409", "P0422"):
        raise HTTPException(status_code=409, detail=f"Conflicto de estado: {message}")

    # Genérico
    raise HTTPException(status_code=500, detail=f"Error de base de datos: {message}")
