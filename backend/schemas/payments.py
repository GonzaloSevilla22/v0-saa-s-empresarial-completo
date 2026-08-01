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


# ── mp-real-subscriptions (D2bis) — alta/baja/estado de suscripción ──────────

class SubscriptionCreateIn(BaseModel):
    """Alta de suscripción (D2bis): el cliente solo elige el tier. El
    `payer_email` se resuelve server-side del usuario autenticado — nunca
    viaja en el body (evita que alguien pida el alta a nombre de otro
    email)."""
    plan: str


class SubscriptionCreateOut(BaseModel):
    """D2bis: NO hay `preapproval_id` propio en esta respuesta — el
    `preapproval` todavía no existe, lo crea MercadoPago cuando el pagador
    completa el checkout en `init_point`."""
    init_point: str
    intent_id: uuid.UUID
    plan: str
    expires_at: datetime.datetime


class SubscriptionOut(BaseModel):
    """Estado de la suscripción viva de la cuenta, para `/facturacion`."""
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    plan: str
    status: str
    next_payment_date: datetime.datetime | None = None
    amount: Decimal | None = None
    currency: str
    retry_state: str


class SubscriptionCancelOut(BaseModel):
    ok: bool
    plan_expires_at: datetime.datetime | None = None


class AmbiguousSubscriptionOut(BaseModel):
    """Cola de conciliación manual (D2bis): una fila de subscriptions con
    account_id NULL que ningún reintento automático pudo resolver."""
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    preapproval_id: str
    preapproval_plan_id: str
    plan: str
    ambiguous_reason: str
    amount: Decimal | None = None
    currency: str
    created_at: datetime.datetime


class ResolveAmbiguousSubscriptionIn(BaseModel):
    account_id: uuid.UUID
