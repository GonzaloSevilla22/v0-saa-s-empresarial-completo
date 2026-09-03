from __future__ import annotations

import datetime
import uuid
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, Field

# productos-categorias-sku (D14): tope de ids por request de recategorización
# en lote — límite de TRANSPORTE, no de producto: el cliente trocea y agrega.
BULK_CATEGORY_MAX_IDS = 500


class ProductCreate(BaseModel):
    name: str
    category: str | None = None
    # productos-categorias-sku (D1/D11): fuente de verdad de la categoría. Para
    # una VARIANTE (parent_id informado) el servidor la resuelve desde el padre
    # e ignora este campo.
    category_id: uuid.UUID | None = None
    price: Decimal | None = None
    cost: Decimal | None = None
    stock: Decimal = Decimal("0")
    min_stock: int = 0
    barcode: str | None = None
    sku: str | None = None
    parent_id: str | None = None
    is_variant: bool = False
    stock_control_type: str = "unit"


class ProductUpdate(BaseModel):
    """productos-categorias-sku (D12): `sku` y `category_id` son TRI-ESTADO por
    AUSENCIA de la clave, nunca por `is None` — se distinguen con
    `model_fields_set` en el router (precedente exacto: `bank_account_id` en
    PaymentMethodUpdate). Campo ausente conserva; con valor asigna; en `null`
    desasigna. El resto de los campos conserva el comportamiento previo
    (`exclude_none`) para no ampliar el alcance."""

    name: str | None = None
    category: str | None = None
    category_id: uuid.UUID | None = None
    price: Decimal | None = None
    cost: Decimal | None = None
    stock: Decimal | None = None
    min_stock: int | None = None
    barcode: str | None = None
    sku: str | None = None
    stock_control_type: str | None = None


class ProductOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    user_id: uuid.UUID
    name: str
    category: str | None
    # productos-categorias-sku: llega desde v_products_with_stock (última
    # columna). Default None para lecturas de una base sin la migración — y
    # porque el response_model FILTRA la salida: sin esta línea el cliente
    # nunca vería la categoría imputada.
    category_id: uuid.UUID | None = None
    price: Decimal | None
    cost: Decimal | None
    stock: Decimal
    min_stock: Decimal | None
    barcode: str | None
    sku: str | None
    parent_id: uuid.UUID | None
    is_variant: bool | None
    stock_control_type: str | None
    created_at: datetime.datetime


# ── productos-categorias-sku (D14): recategorización en lote ─────────────────

class ProductBulkCategoryIn(BaseModel):
    """Payload for PATCH /products/bulk-category."""

    product_ids: list[uuid.UUID] = Field(
        ..., min_length=1, max_length=BULK_CATEGORY_MAX_IDS,
        description="Productos a recategorizar (padres y simples; una variante suelta se normaliza a su padre)",
    )
    category_id: uuid.UUID = Field(..., description="Categoría destino (viva y activa, de la cuenta)")


class ProductBulkCategoryOut(BaseModel):
    """`requested` = ids distintos solicitados; `updated` = filas realmente
    cambiadas (incluye las variantes expandidas desde un padre y excluye lo que
    ya tenía la categoría — contador honesto, D14)."""

    requested: int
    updated: int
