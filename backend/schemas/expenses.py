from __future__ import annotations

import datetime
import uuid
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, field_validator


class ExpenseCreate(BaseModel):
    category: str
    amount: Decimal
    description: str | None = None
    date: datetime.date
    # cost-center-dimension: optional analytic dimension
    cost_center_id: uuid.UUID | None = None


class ExpenseUpdate(BaseModel):
    category: str | None = None
    amount: Decimal | None = None
    description: str | None = None
    date: datetime.date | None = None
    # cost-center-dimension: optional analytic dimension
    cost_center_id: uuid.UUID | None = None


class ExpenseOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    user_id: uuid.UUID
    category: str
    amount: Decimal
    description: str | None
    date: datetime.date
    created_at: datetime.datetime
    # cost-center-dimension: optional analytic dimension (nullable)
    cost_center_id: uuid.UUID | None = None

    @field_validator("date", mode="before")
    @classmethod
    def _coerce_datetime_to_date(cls, v: object) -> object:
        # expenses.date es `timestamptz`: las filas con hora ≠ 00:00 llegan como
        # datetime y Pydantic las rechaza contra `date` (date_from_datetime_inexact)
        # → 500. Tomamos la parte de fecha. Espejo de SaleItemOut/PurchaseItemOut.
        if isinstance(v, datetime.datetime):
            return v.date()
        return v
