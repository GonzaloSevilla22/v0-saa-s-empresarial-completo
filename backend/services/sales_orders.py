"""
C-29 v21-quote-salesorder — Service layer para SalesOrder / quickSale.

Regla dura: NO lógica de negocio en routers.
Todos los guards (rol, dominio) viven aquí.
Los repositories manejan solo acceso a datos (RPCs + SELECT).
"""
from __future__ import annotations

import asyncpg
from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.sales_order_repository import SalesOrderRepository
from backend.schemas.sales_orders import ConfirmIn, QuickSaleIn


async def list_orders(
    repo: SalesOrderRepository,
    account_id: str,
) -> list:
    """Lista las órdenes de venta de la cuenta."""
    return await repo.list_orders(account_id)


async def get_order(
    repo: SalesOrderRepository,
    sales_order_id: str,
) -> dict:
    """Obtiene una orden de venta por id. 404 si no existe."""
    record = await repo.get_order(sales_order_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Orden de venta no encontrada")
    return dict(record)


async def confirm(
    repo: SalesOrderRepository,
    auth: dict,
    sales_order_id: str,
    payload: ConfirmIn,
) -> dict:
    """
    Confirma una SalesOrder existente.
    Hot path transaccional: stock + caja + fiscal + outbox en un commit.
    Guard: writer.
    """
    require_role(auth, ["user", "admin"])

    try:
        result = await repo.confirm(
            idempotency_key=payload.idempotency_key,
            sales_order_id=sales_order_id,
            payment_method=payload.payment_method.value,
            cash_session_id=str(payload.cash_session_id) if payload.cash_session_id else None,
            comprobante_type=payload.comprobante_type,
            point_of_sale_id=str(payload.point_of_sale_id) if payload.point_of_sale_id else None,
            branch_id=str(payload.branch_id) if payload.branch_id else None,
            canal=payload.canal,
        )
    except asyncpg.PostgresError as exc:
        _map_postgres_error(exc)

    return result


async def quick_sale(
    repo: SalesOrderRepository,
    auth: dict,
    payload: QuickSaleIn,
    account_id: str,
) -> dict:
    """
    Crea + confirma una SalesOrder en un solo paso (POS).
    Idempotente por idempotency_key (DEC-06).
    Guard: writer.
    """
    require_role(auth, ["user", "admin"])

    # Serializar ítems para el RPC
    items = [
        {
            "product_id": str(item.product_id) if item.product_id else None,
            "unit_id":    str(item.unit_id) if item.unit_id else None,
            "quantity":   float(item.quantity),
            "price":      float(item.price),
            "subtotal":   float(item.subtotal) if item.subtotal is not None
                          else float(item.price * item.quantity),
        }
        for item in payload.items
    ]

    try:
        result = await repo.quick_sale(
            idempotency_key=payload.idempotency_key,
            client_id=str(payload.client_id) if payload.client_id else None,
            items=items,
            payment_method=payload.payment_method.value,
            cash_session_id=str(payload.cash_session_id) if payload.cash_session_id else None,
            comprobante_type=payload.comprobante_type,
            point_of_sale_id=str(payload.point_of_sale_id) if payload.point_of_sale_id else None,
            branch_id=str(payload.branch_id) if payload.branch_id else None,
            canal=payload.canal,
        )
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
        raise HTTPException(status_code=409, detail=f"Conflicto: {message}")

    raise HTTPException(status_code=500, detail=f"Error de base de datos: {message}")
