from __future__ import annotations

import datetime
import uuid
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, field_validator


class PurchaseItemIn(BaseModel):
    product_id: str
    quantity: Decimal
    amount: Decimal
    description: str | None = None
    unit_id: str | None = None


class PurchaseOperationIn(BaseModel):
    idempotency_key: str
    org_id: str
    items: list[PurchaseItemIn]
    date: datetime.date | None = None


class PurchaseOperationOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    operation_id: uuid.UUID
    operation_kind: str | None = None


class PurchaseOperationUpdateItemIn(BaseModel):
    product_id: str
    quantity: Decimal
    amount: Decimal


class PurchaseOperationUpdateIn(BaseModel):
    """Payload del editor de compras: reemplaza los ítems de una operación.
    Lo consume rpc_atomic_update_purchase_operation (REVERSE + APPLY sobre branch_stock)."""
    purchase_ids: list[str]
    items: list[PurchaseOperationUpdateItemIn]
    date: datetime.date
    description: str | None = None


class PurchaseItemOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    date: datetime.date
    product_id: uuid.UUID | None = None
    product_name: str | None = None
    operation_id: uuid.UUID | None = None
    quantity: Decimal
    amount: Decimal
    total: Decimal | None = None
    description: str | None = None

    @field_validator("date", mode="before")
    @classmethod
    def _coerce_datetime_to_date(cls, v: object) -> object:
        # purchases.date es `timestamptz`: las filas con hora ≠ 00:00 llegan como
        # datetime y Pydantic las rechaza contra `date` (date_from_datetime_inexact)
        # → 500. Tomamos la parte de fecha. Espejo de SaleItemOut.
        if isinstance(v, datetime.datetime):
            return v.date()
        return v


class PurchasesPageOut(BaseModel):
    items: list[PurchaseItemOut]
    total_operations: int
