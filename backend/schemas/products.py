from __future__ import annotations

import datetime
from decimal import Decimal

from pydantic import BaseModel, ConfigDict


class ProductCreate(BaseModel):
    name: str
    category: str | None = None
    price: Decimal | None = None
    cost: Decimal | None = None
    stock: Decimal = Decimal("0")
    min_stock: int = 0
    barcode: str | None = None
    sku: str | None = None
    is_variant: bool = False
    stock_control_type: str = "unit"


class ProductUpdate(BaseModel):
    name: str | None = None
    category: str | None = None
    price: Decimal | None = None
    cost: Decimal | None = None
    stock: Decimal | None = None
    min_stock: int | None = None
    barcode: str | None = None
    sku: str | None = None
    stock_control_type: str | None = None


class ProductOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    user_id: str
    name: str
    category: str | None
    price: Decimal | None
    cost: Decimal | None
    stock: Decimal
    min_stock: int | None
    barcode: str | None
    sku: str | None
    is_variant: bool | None
    stock_control_type: str | None
    created_at: datetime.datetime
