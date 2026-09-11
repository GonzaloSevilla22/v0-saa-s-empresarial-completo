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


# ── importador-productos-fastapi ──────────────────────────────────────────
#
# El lote es UNA SOLA unidad de trabajo de servidor (rpc_import_products,
# SECURITY DEFINER, DEC-24) que invoca rpc_bulk_upsert_products UNA VEZ con
# el archivo completo — este módulo NO evalúa ninguna regla de negocio nueva
# (D1 del design): sólo valida la FORMA del payload y delega.
#
# Tope 2.500 (D6/OQ-2, bajado del 5.000 original tras medir en la base local
# post-apply: 5.000 filas tardó 33,1s de simulación + 34,2s de confirmación,
# con escalado SUPERLINEAL (4,0 → 6,6 ms/fila entre 200 y 5.000) — el propio
# design dejaba esto como el criterio de baja si la medición no acompañaba.
# 2.500 sigue cubriendo el mayor lote real medido (1.393) y el catálogo más
# grande (2.372) con margen.
#
# La re-medición independiente de la revisión de código no reprodujo la
# degradación (escalado ~lineal); el tope se mantiene en 2.500 de todos
# modos, por cobertura de uso real y no por esa medición — ver design.md §D6.

PRODUCT_IMPORT_MAX_ROWS = 2500


class ProductImportAttributeIn(BaseModel):
    key: str
    value: str
    sort_order: int = 0


class ProductImportRowIn(BaseModel):
    """Una fila del archivo, ya parseada y resuelta por el cliente.

    D12 (contrato null-preserving, coexistencia con `productos-costo-
    nullable`): NINGÚN campo opcional tiene un default numérico. `price`,
    `cost`, `stock` y `min_stock` son `None` cuando la celda vino vacía —
    nunca `0` — porque la RPC usa `COALESCE` para distinguir "conservar/sin
    valor" de "cero declarado" (mismo contrato que el alta/edición de a uno).
    """

    row_no: int = Field(gt=0)
    name: str
    category: str | None = None
    price: Decimal | None = None
    cost: Decimal | None = None
    stock: Decimal | None = None
    min_stock: int | None = None
    barcode: str | None = None
    sku: str | None = None
    # Referencias de jerarquía (D9): resueltas por el SERVIDOR contra la
    # cuenta — sku_parent/parent_name que no resuelven en el lote NI en el
    # catálogo de la cuenta son error de fila, nunca un default silencioso.
    sku_parent: str | None = None
    parent_name: str | None = None
    is_variant: bool | None = None
    stock_control_type: str | None = None
    attributes: list[ProductImportAttributeIn] = Field(default_factory=list)


class ProductImportIn(BaseModel):
    """Payload de `POST /products/import`.

    El body NO lleva `user_id` ni `account_id` (spec product-import): la
    tenencia la deriva `rpc_import_products` desde `auth.uid()` de la
    sesión — es el punto entero del change.
    """

    idempotency_key: str | None = None
    file_name: str
    file_hash: str
    dry_run: bool = False
    rows: list[ProductImportRowIn] = Field(min_length=1, max_length=PRODUCT_IMPORT_MAX_ROWS)


class ProductImportRowErrorOut(BaseModel):
    row: int | None
    sku: str | None = None
    name: str | None = None
    message: str


class ProductImportNewCategoryOut(BaseModel):
    name: str
    rows: int


# ── importador-gate-plan (OQ-1 de importador-productos-fastapi, sign-off del
# PO 2026-09-11) ──────────────────────────────────────────────────────────
#
# Regla exacta del PO: "las cuentas que hoy superan el máximo de su plan
# conservan sus productos, pero no pueden agregar más; si quieren agregar,
# tienen que eliminar productos hasta no exceder el máximo de su plan".
# `rpc_import_products` evalúa el gate SIEMPRE sobre el estado RESULTANTE
# (después de invocar rpc_bulk_upsert_products, nunca a priori — D5 del
# design archivado) y devuelve `plan` en TODO RETURN (committed=true,
# committed=false por errores/plan/dry_run, y las dos ramas de replay) desde
# la migración `20261046000001`.
class ProductImportPlanVerdictOut(BaseModel):
    plan: str
    limit: int | None
    before: int
    after: int
    added: int
    exceeded: bool


class ProductImportOut(BaseModel):
    """Reporte del lote — `200` cuando el rechazo es por REGLAS DE FILA o por
    el LÍMITE DE PLAN, aplicado o no (D3 del design + importador-gate-plan).

    Un lote rechazado por reglas de fila o por plan NO es un error de
    protocolo: es un resultado del procesamiento (el rechazo por plan viaja
    como `committed: false` + `plan.exceeded: true`, nunca como una
    excepción — `P0430` sigue reservado en `backend/core/errors.py` pero no
    se emite). Los `4xx` quedan para lo que impide procesar (forma del
    payload, tope de filas, sin rol de escritura, sin clave de
    idempotencia) — y el tope de categorías nuevas (cuota) viaja ahí
    también: `rpc_bulk_upsert_products` lo levanta como `P0400` DENTRO de
    la llamada que `rpc_import_products` hace, sin capturarlo, así que
    escapa igual que el tope de filas (`P0427`) y nunca llega a este schema.

    Corrección de revisión (ronda 1 adversarial, minor): `plan` es
    `Optional` con default `None`, NUNCA requerido sin default, pese a que
    `rpc_import_products` lo garantiza en todo `RETURN` desde
    `20261046000001`. Motivo: `deploy.yml` redeploya el backend (push a
    Render) y aplica la migración (`supabase db push`) por caminos
    INDEPENDIENTES — si el backend nuevo queda vivo antes de que la
    migración corra, la RPC vieja devuelve un jsonb sin `plan` y, con el
    campo requerido, Pydantic levantaría `ResponseValidationError` (500) en
    TODA importación durante esa ventana, no sólo las que tocan el límite.
    Con el default, esa ventana degrada a "sin veredicto de plan" (el
    diálogo no bloquea por plan, tal como antes de este fix) en vez de
    romper el endpoint entero.
    """

    committed: bool
    import_id: uuid.UUID | None
    inserted: int
    updated: int
    errors: list[ProductImportRowErrorOut]
    new_categories: list[ProductImportNewCategoryOut]
    plan: ProductImportPlanVerdictOut | None = None
    replayed: bool
    dry_run: bool
