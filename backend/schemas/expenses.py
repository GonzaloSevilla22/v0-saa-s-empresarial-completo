from __future__ import annotations

import datetime
import uuid
from decimal import Decimal

from pydantic import BaseModel, ConfigDict


class ExpenseCreate(BaseModel):
    category: str
    amount: Decimal
    description: str | None = None
    date: datetime.date


class ExpenseUpdate(BaseModel):
    category: str | None = None
    amount: Decimal | None = None
    description: str | None = None
    date: datetime.date | None = None


class ExpenseOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    user_id: uuid.UUID
    category: str
    amount: Decimal
    description: str | None
    date: datetime.date
    created_at: datetime.datetime
