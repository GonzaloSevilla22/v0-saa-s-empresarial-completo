from __future__ import annotations

import datetime
import uuid
from decimal import Decimal

from pydantic import BaseModel, ConfigDict

from backend.schemas.common import PageOut


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


# v3-api-standards §2: envelope estándar {items,total,page,pages}, reemplaza
# el PaymentReceiptsPageOut previo ({items,total}) — BREAKING sancionado
# (OQ1 PO), frontend migrado en el mismo change.
PaymentReceiptsPageOut = PageOut[PaymentReceiptOut]
