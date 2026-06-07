from __future__ import annotations

import uuid
from decimal import Decimal

from pydantic import BaseModel, ConfigDict


class StockOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    product_id: uuid.UUID
    stock: Decimal


class StockTransferRequest(BaseModel):
    from_branch_id: str
    to_branch_id: str
    product_id: str
    quantity: Decimal
