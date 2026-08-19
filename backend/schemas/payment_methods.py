from __future__ import annotations

import datetime
import uuid

from pydantic import BaseModel, ConfigDict, Field

# metodos-pago-operaciones (D2): vocabulario cerrado, superset del CHECK de
# sales_orders.payment_method y de la taxonomía de cobro/pago — espejo del
# CHECK de la tabla payment_methods en la migración 20260928000001.
PAYMENT_METHOD_KINDS = ("cash", "transfer", "card", "check", "wallet", "credit", "other")


class PaymentMethodCreate(BaseModel):
    """Payload for POST /payment-methods."""

    name: str = Field(..., min_length=1, description="Nombre de la forma de pago")
    kind: str = Field(..., description=f"Vocabulario cerrado: {', '.join(PAYMENT_METHOD_KINDS)}")
    sort_order: int = Field(0, description="Orden del selector (menor = primero)")


class PaymentMethodUpdate(BaseModel):
    """Payload for PATCH /payment-methods/{id}."""

    name: str = Field(..., min_length=1, description="Nuevo nombre de la forma de pago")
    sort_order: int | None = Field(None, description="Nuevo orden del selector")


class PaymentMethodOut(BaseModel):
    """Response schema for payment method CRUD endpoints."""

    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    account_id: uuid.UUID
    name: str
    kind: str
    is_active: bool
    sort_order: int
    created_at: datetime.datetime


# ── Reporte de distribución por forma de pago ─────────────────────────────────

class PaymentMethodReportRow(BaseModel):
    """Una fila de GET /reports/payment-methods — espejo de CostCenterReportRow."""

    model_config = ConfigDict(from_attributes=True)

    payment_method_id: uuid.UUID | None = None
    payment_method_name: str
    payment_method_kind: str | None = None
    is_active: bool
    total_sold: float
    total_purchased: float
    operation_count: int
