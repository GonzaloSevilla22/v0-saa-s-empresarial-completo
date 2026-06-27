from __future__ import annotations

import uuid

import asyncpg
from fastapi import APIRouter, Depends, Query, Response

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.repositories.sales_repository import SalesRepository
from backend.schemas.sales import (
    PromoteToOrderOut,
    SaleOperationIn,
    SaleOperationOut,
    SaleOperationUpdateIn,
    SalesPageOut,
    SalesReceiptPdfIn,
)
from backend.services import sales as sales_service
from backend.services.receipts import (
    SalesReceiptData,
    SalesReceiptItem,
    build_sales_receipt_pdf,
)

router = APIRouter(prefix="/sales", tags=["sales"])


@router.post("/receipt-pdf")
async def sales_receipt_pdf(
    payload: SalesReceiptPdfIn,
    auth: dict = Depends(get_current_user),
) -> Response:
    """Genera el PDF del comprobante de venta a partir de los datos provistos
    (para compartirlo por WhatsApp). No toca la DB: render stateless."""
    data = SalesReceiptData(
        business_name=payload.business_name,
        receipt_number=payload.receipt_number,
        date_label=payload.date_label,
        items=[
            SalesReceiptItem(
                name=i.name,
                quantity=i.quantity,
                unit_price=i.unit_price,
                subtotal=i.subtotal,
            )
            for i in payload.items
        ],
        total=payload.total,
        currency=payload.currency,
        client_name=payload.client_name,
        business_phone=payload.business_phone,
        business_email=payload.business_email,
    )
    pdf = build_sales_receipt_pdf(data)
    return Response(
        content=pdf,
        media_type="application/pdf",
        headers={
            "Content-Disposition": f'inline; filename="comprobante-{payload.receipt_number}.pdf"'
        },
    )


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> SalesRepository:
    return SalesRepository(conn)


@router.get("", response_model=SalesPageOut)
async def list_sales(
    page: int = Query(0, ge=0),
    page_size: int = Query(25, ge=1, le=100),
    date_from: str | None = Query(None),
    date_to: str | None = Query(None),
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: SalesRepository = Depends(get_repo),
):
    return await sales_service.list_sales_paginated(
        repo, str(account_id), page, page_size, date_from, date_to,
    )


@router.post("", response_model=SaleOperationOut, status_code=201)
async def create_sale(
    payload: SaleOperationIn,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: SalesRepository = Depends(get_repo),
):
    return await sales_service.create_sale_operation(repo, auth, str(account_id), payload)


@router.put("/operation")
async def update_sale_operation(
    payload: SaleOperationUpdateIn,
    auth: dict = Depends(get_current_user),
    repo: SalesRepository = Depends(get_repo),
):
    """Edita una operación de venta: reemplaza sus ítems vía
    rpc_atomic_update_sale_operation (REVERSE + APPLY de stock, atómico)."""
    await sales_service.update_sale_operation(repo, auth, payload)
    return {"ok": True}


@router.delete("", status_code=204)
async def delete_sales_by_operation(
    operation_id: str = Query(...),
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: SalesRepository = Depends(get_repo),
):
    await sales_service.delete_sale_operation(repo, auth, str(account_id), operation_id)


@router.post("/{operation_id}/promote-to-order", response_model=PromoteToOrderOut)
async def promote_to_order(
    operation_id: str,
    auth: dict = Depends(get_current_user),
    repo: SalesRepository = Depends(get_repo),
):
    """
    facturar-venta-manual (D6):
    Materializa una SalesOrder confirmada a partir de una venta legacy
    (identificada por operation_id), habilitando la facturación AFIP vía emit-invoice.

    Side-effect-free: no descuenta stock, no toca caja, no dispara el outbox.
    Idempotente: doble llamada devuelve la orden existente con replayed=true.

    Governance: FISCAL = CRÍTICO.
    """
    return await sales_service.promote_to_order(repo, auth, operation_id)


@router.delete("/{sale_id}", status_code=204)
async def delete_sale(
    sale_id: str,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: SalesRepository = Depends(get_repo),
):
    await sales_service.delete_sale(repo, auth, str(account_id), sale_id)
