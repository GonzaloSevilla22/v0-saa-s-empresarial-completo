from __future__ import annotations

import datetime
import uuid
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, Field, field_validator


class SaleItemIn(BaseModel):
    product_id: str
    quantity: Decimal
    amount: Decimal
    unit_id: str | None = None


class SaleOperationIn(BaseModel):
    idempotency_key: str
    org_id: str
    items: list[SaleItemIn]
    date: datetime.date | None = None
    client_id: str | None = None
    currency: str = "ARS"
    # Canal de venta de la operación (instagram, mercadolibre, whatsapp, local,
    # otro). NULL = "Sin canal" — ventas legacy o sin canal elegido.
    canal: str | None = Field(default=None, max_length=40)


class SaleOperationOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    operation_id: uuid.UUID
    operation_kind: str | None = None


class SaleOperationUpdateItemIn(BaseModel):
    product_id: str
    quantity: Decimal
    amount: Decimal


class SaleOperationUpdateIn(BaseModel):
    """Payload del editor de ventas: reemplaza los ítems de una operación.
    Lo consume rpc_atomic_update_sale_operation (REVERSE + APPLY sobre branch_stock)."""
    sale_ids: list[str]
    items: list[SaleOperationUpdateItemIn]
    date: datetime.date
    client_id: str | None = None
    currency: str = "ARS"


class SaleItemOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    date: datetime.date
    product_id: uuid.UUID | None = None
    product_name: str | None = None
    client_id: uuid.UUID | None = None
    client_name: str | None = None
    operation_id: uuid.UUID | None = None
    quantity: Decimal
    amount: Decimal
    total: Decimal | None = None
    currency: str = "ARS"

    @field_validator("date", mode="before")
    @classmethod
    def _coerce_datetime_to_date(cls, v: object) -> object:
        # sales.date es `timestamptz`: las filas con hora ≠ 00:00 (ventas viejas
        # creadas con now()) llegan como datetime y Pydantic las rechaza contra
        # `date` (date_from_datetime_inexact) → 500. Tomamos la parte de fecha.
        if isinstance(v, datetime.datetime):
            return v.date()
        return v


class SalesPageOut(BaseModel):
    items: list[SaleItemOut]
    total_operations: int


# ── Comprobante de venta en PDF (para compartir por WhatsApp) ─────────────────

class SalesReceiptItemIn(BaseModel):
    name: str
    quantity: str
    unit_price: Decimal
    subtotal: Decimal


class SalesReceiptPdfIn(BaseModel):
    business_name: str
    receipt_number: str
    date_label: str
    items: list[SalesReceiptItemIn]
    total: Decimal
    currency: str = "ARS"
    client_name: str | None = None
    business_phone: str | None = None
    business_email: str | None = None
