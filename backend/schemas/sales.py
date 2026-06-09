from __future__ import annotations

import datetime
import uuid
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, Field


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


class SalesPageOut(BaseModel):
    items: list[SaleItemOut]
    total_operations: int
