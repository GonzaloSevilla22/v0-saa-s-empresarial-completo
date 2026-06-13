from __future__ import annotations

import logging
import uuid

import asyncpg
from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response

from backend.core.auth import get_current_user
from backend.core.config import settings
from backend.core.database import get_service_conn
from backend.repositories.billing_repository import BillingRepository
from backend.schemas.payments import (
    MpNotification,
    PaymentReceiptOut,
    PaymentReceiptsPageOut,
    WebhookResponse,
)
from backend.services.payments import process_payment, verify_mp_signature
from backend.services.receipts import ReceiptData, build_receipt_pdf

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/payments", tags=["payments"])


async def require_admin(
    auth: dict = Depends(get_current_user),
    conn: asyncpg.Connection = Depends(get_service_conn),
) -> dict:
    """Gating de administrador de plataforma: profiles.role = 'admin'.

    El rol del JWT no refleja el admin de plataforma (vive en profiles.role),
    así que se verifica en la DB. Usa la conexión service para poder leer
    recibos de todas las cuentas una vez confirmado el admin.
    """
    role = await conn.fetchval(
        "SELECT role FROM profiles WHERE id = $1::uuid", auth["user_id"]
    )
    if role != "admin":
        raise HTTPException(status_code=403, detail="Requiere rol de administrador")
    return auth


def get_billing_repo(
    conn: asyncpg.Connection = Depends(get_service_conn),
) -> BillingRepository:
    return BillingRepository(conn)


@router.post("/webhook", response_model=WebhookResponse)
async def mercadopago_webhook(
    request: Request,
    shadow: bool = Query(False),
    conn: asyncpg.Connection = Depends(get_service_conn),
) -> WebhookResponse:
    raw_body = await request.body()

    x_signature = request.headers.get("x-signature")
    x_request_id = request.headers.get("x-request-id")

    if not verify_mp_signature(raw_body, x_signature, x_request_id, settings.mercadopago_webhook_secret):
        logger.warning("[payments/webhook] Invalid signature — rejecting")
        raise HTTPException(status_code=400, detail="Firma inválida")

    try:
        notification = MpNotification.model_validate_json(raw_body)
    except Exception:
        raise HTTPException(status_code=400, detail="Payload inválido")

    if notification.type != "payment" or not notification.data or not notification.data.id:
        return WebhookResponse(ok=True, skipped=True)

    return await process_payment(notification.data.id, conn, shadow=shadow)


# ── Recibos de pago (#4 comprobante — vista admin) ────────────────────────────

@router.get("/receipts", response_model=PaymentReceiptsPageOut)
async def list_payment_receipts(
    page: int = Query(0, ge=0),
    page_size: int = Query(50, ge=1, le=200),
    _admin: dict = Depends(require_admin),
    repo: BillingRepository = Depends(get_billing_repo),
) -> dict:
    """Lista los pagos aprobados (recibos) de todas las cuentas. Solo admin."""
    rows, total = await repo.list_receipts(page_size, page * page_size)
    return {"items": [dict(r) for r in rows], "total": total}


@router.get("/receipt/{billing_event_id}")
async def download_payment_receipt(
    billing_event_id: uuid.UUID,
    _admin: dict = Depends(require_admin),
    repo: BillingRepository = Depends(get_billing_repo),
) -> Response:
    """Genera y devuelve el PDF del recibo de un pago. Solo admin."""
    row = await repo.get_receipt(str(billing_event_id))
    if row is None:
        raise HTTPException(status_code=404, detail="Recibo no encontrado")

    receipt_number = row["receipt_number"] or f"RC-{billing_event_id}"
    data = ReceiptData(
        receipt_number=receipt_number,
        issued_at=row["created_at"],
        customer_email=row["customer_email"],
        customer_name=row["customer_name"],
        plan=row["plan"] or "",
        amount=row["amount"] or 0,
        payment_id=row["payment_id"] or "-",
    )
    pdf = build_receipt_pdf(data)
    return Response(
        content=pdf,
        media_type="application/pdf",
        headers={"Content-Disposition": f'inline; filename="recibo-{receipt_number}.pdf"'},
    )
