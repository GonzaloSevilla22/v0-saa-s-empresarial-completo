from __future__ import annotations

import datetime
import uuid
from decimal import Decimal

from pydantic import BaseModel, ConfigDict


class MpNotificationData(BaseModel):
    id: str | None = None


class MpNotification(BaseModel):
    type: str | None = None
    data: MpNotificationData | None = None


class WebhookResponse(BaseModel):
    ok: bool
    idempotent: bool | None = None
    shadow: bool | None = None
    skipped: bool | None = None
    status: str | None = None
    error: str | None = None


# ── Recibos de pago (#4 comprobante) ──────────────────────────────────────────

class PaymentReceiptOut(BaseModel):
    """Una fila de la lista de pagos aprobados (vista admin de recibos)."""
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    receipt_number: str | None = None
    payment_id: str | None = None
    plan: str | None = None
    amount: Decimal | None = None
    created_at: datetime.datetime
    customer_email: str
    customer_name: str | None = None


class PaymentReceiptsPageOut(BaseModel):
    items: list[PaymentReceiptOut]
    total: int
