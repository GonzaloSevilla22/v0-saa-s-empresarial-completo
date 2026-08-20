from __future__ import annotations

import datetime
import uuid
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, field_validator

from backend.schemas.common import PageOut


class PurchaseItemIn(BaseModel):
    product_id: str
    quantity: Decimal
    amount: Decimal
    description: str | None = None
    unit_id: str | None = None


class PurchaseOperationIn(BaseModel):
    # v3-api-standards §3.2: opcional+deprecado (ver SaleOperationIn).
    idempotency_key: str | None = None
    org_id: str
    items: list[PurchaseItemIn]
    date: datetime.date | None = None
    # cost-center-dimension: optional, shared by all lines of the operation
    cost_center_id: uuid.UUID | None = None
    # metodos-pago-operaciones: optional, shared by all lines of the operation
    payment_method_id: uuid.UUID | None = None


class PurchaseOperationOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    operation_id: uuid.UUID
    operation_kind: str | None = None


class PurchaseOperationUpdateItemIn(BaseModel):
    product_id: str
    quantity: Decimal
    amount: Decimal
    # edicion-preserva-contexto (F1 §D7): unit_id viaja pegado a la línea —
    # espejo de SaleOperationUpdateItemIn.unit_id.
    unit_id: str | None = None


class PurchaseOperationUpdateIn(BaseModel):
    """Payload del editor de compras: reemplaza los ítems de una operación.
    Lo consume rpc_atomic_update_purchase_operation (REVERSE + APPLY sobre branch_stock).

    metodos-pago-operaciones (D5): `payment_method_id` es tri-estado por
    AUSENCIA, no por valor — se distingue con `model_fields_set` en el router/
    service, NUNCA por `is None`. No incluir el campo en el JSON = preservar el
    vigente; incluirlo con `null` = desimputar explícito ("Sin especificar");
    incluirlo con un uuid = reimputar. Ver PaymentMethodSelect (frontend).

    edicion-preserva-contexto (F1 §D3): `branch_id` usa el mismo contrato
    tri-estado — `model_fields_set`, nunca `is None`. `supplier_id`/
    `cost_center_id` se preservan pero NO son parámetro acá (D2/OQ-1): el
    form de edición de compra no tiene selector para ninguno de los dos hoy.
    """
    purchase_ids: list[str]
    items: list[PurchaseOperationUpdateItemIn]
    date: datetime.date
    description: str | None = None
    payment_method_id: uuid.UUID | None = None
    branch_id: uuid.UUID | None = None


class PurchaseItemOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    date: datetime.date
    product_id: uuid.UUID | None = None
    product_name: str | None = None
    operation_id: uuid.UUID | None = None
    quantity: Decimal
    amount: Decimal
    total: Decimal | None = None
    description: str | None = None
    # cost-center-dimension: optional analytic dimension (nullable)
    cost_center_id: uuid.UUID | None = None
    # cost-center-surface: nombre del centro para el badge del listado, resuelto
    # en el mismo query (LEFT JOIN cost_centers) — evita un round-trip extra.
    cost_center_name: str | None = None
    # metodos-pago-operaciones: forma de pago opcional (nullable), resuelta en
    # el mismo query (LEFT JOIN payment_methods) para el badge del listado.
    payment_method_id: uuid.UUID | None = None
    payment_method_name: str | None = None
    payment_method_kind: str | None = None
    # edicion-preserva-contexto (D11): branch_id/unit_id expuestos para
    # prefillear el form de edición (espejo de SaleItemOut). supplier_id NO
    # se expone: sin selector en el form hoy (D2/OQ-1).
    branch_id: uuid.UUID | None = None
    unit_id: uuid.UUID | None = None
    # pagos-cableados-restantes (D6): derivado de lectura (mismo predicado
    # que el guard P0423 de rpc_atomic_update_purchase_operation), para que
    # la lista deshabilite "Editar" con motivo visible ANTES de que el
    # usuario llegue al error del backend.
    is_payment_locked: bool = False

    @field_validator("date", mode="before")
    @classmethod
    def _coerce_datetime_to_date(cls, v: object) -> object:
        # purchases.date es `timestamptz`: las filas con hora ≠ 00:00 llegan como
        # datetime y Pydantic las rechaza contra `date` (date_from_datetime_inexact)
        # → 500. Tomamos la parte de fecha. Espejo de SaleItemOut.
        if isinstance(v, datetime.datetime):
            return v.date()
        return v


# v3-api-standards §2: envelope estándar {items,total,page,pages}, reemplaza
# el PurchasesPageOut previo ({items,total_operations}) — BREAKING sancionado
# (OQ1 PO), frontend migrado en el mismo change.
PurchasesPageOut = PageOut[PurchaseItemOut]
