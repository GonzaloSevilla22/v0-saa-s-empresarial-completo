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
    # productos-categorias-sku (D1/D11): fuente de verdad de la categoría. Para
    # una VARIANTE (parent_id informado) el servidor la resuelve desde el padre
    # e ignora este campo. productos-categoria-text-retiro: el campo `category`
    # (nombre libre) se retiró del schema de entrada — un cliente viejo que
    # todavía lo mande no rompe (Pydantic ignora el extra en silencio, D6).
    category_id: uuid.UUID | None = None
    price: Decimal | None = None
    # productos-costo-nullable: `cost` es un dato OPCIONAL del catálogo.
    # `None` = no se cargó el costo (ausente); `Decimal("0")` = costo cero
    # declarado explícitamente. Los dos son hechos distintos del negocio
    # (capability `product-cost`) — ya era `Decimal | None` en el schema,
    # sólo faltaba el camino de escritura (ver ProductUpdate).
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
    desasigna. productos-costo-nullable extiende el mismo tri-estado a
    `cost` (mismo molde exacto, `cost_provided` en el router/service): un
    costo ausente en el payload conserva el que el producto tenía, y sólo un
    `null` explícito lo desasigna. El resto de los campos conserva el
    comportamiento previo (`exclude_none`) para no ampliar el alcance."""

    name: str | None = None
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
    # productos-categoria-text-retiro: `category` es ahora DERIVADA por
    # v_products_with_stock (LEFT JOIN product_categories por category_id) —
    # ya no es una columna física de products. El nombre de campo y su
    # significado ("nombre legible de la categoría") no cambian (D1/D2).
    category: str | None
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
