from __future__ import annotations

import datetime
import uuid
from decimal import Decimal

from pydantic import BaseModel, ConfigDict


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


class SaleOperationOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    operation_id: uuid.UUID
    operation_kind: str | None = None
