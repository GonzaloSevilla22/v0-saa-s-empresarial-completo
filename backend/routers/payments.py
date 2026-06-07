from __future__ import annotations

import logging
from collections.abc import AsyncGenerator

import asyncpg
from fastapi import APIRouter, Depends, HTTPException, Query, Request

from backend.core.config import settings
from backend.core.database import get_service_conn
from backend.schemas.payments import MpNotification, WebhookResponse
from backend.services.payments import process_payment, verify_mp_signature

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/payments", tags=["payments"])


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
