from __future__ import annotations

import datetime
import uuid
from decimal import Decimal

from pydantic import BaseModel, ConfigDict


class BranchCreate(BaseModel):
    name: str


class BranchUpdate(BaseModel):
    name: str | None = None


class BranchOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    user_id: uuid.UUID
    name: str
    created_at: datetime.datetime
    # C-26: lifecycle operacional
    status: str | None = None
    opened_at: datetime.datetime | None = None
    closed_at: datetime.datetime | None = None


class BranchLifecycleOut(BaseModel):
    branch_id: uuid.UUID
    status: str
    changed: bool


class StockTransferOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    product_id: uuid.UUID
    product_name: str
    from_branch_id: uuid.UUID
    from_branch_name: str
    to_branch_id: uuid.UUID
    to_branch_name: str
    quantity: Decimal
    status: str
    created_at: datetime.datetime
