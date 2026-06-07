from __future__ import annotations

import datetime
from decimal import Decimal

from pydantic import BaseModel, ConfigDict


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

    operation_id: str
    operation_kind: str | None = None
