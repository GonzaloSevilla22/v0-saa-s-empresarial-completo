from __future__ import annotations

import datetime
import uuid
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from backend.schemas.common import PageOut


class SaleItemIn(BaseModel):
    product_id: str
    quantity: Decimal
    amount: Decimal
    unit_id: str | None = None


class SaleOperationIn(BaseModel):
    # v3-api-standards §3.2: opcional+deprecado — la clave viaja preferentemente
    # por el header `Idempotency-Key` (D4); fallback de body durante la
    # ventana de compatibilidad (OQ2).
    idempotency_key: str | None = None
    org_id: str
    items: list[SaleItemIn]
    date: datetime.date | None = None
    client_id: str | None = None
    currency: str = "ARS"
    # Canal de venta de la operación (instagram, mercadolibre, whatsapp, local,
    # otro). NULL = "Sin canal" — ventas legacy o sin canal elegido.
    canal: str | None = Field(default=None, max_length=40)
    # metodos-pago-operaciones: optional, shared by all lines of the operation
    payment_method_id: uuid.UUID | None = None


class SaleOperationOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    operation_id: uuid.UUID
    operation_kind: str | None = None


class SaleOperationUpdateItemIn(BaseModel):
    product_id: str
    quantity: Decimal
    amount: Decimal
    # edicion-preserva-contexto (F1 §D7): unit_id viaja pegado a la línea, no
    # al header — se preserva SIN exponerse re-enviando el valor que el form
    # prefilleó desde la lectura (SaleItemOut.unit_id), igual que quantity.
    unit_id: str | None = None


class SaleOperationUpdateIn(BaseModel):
    """Payload del editor de ventas: reemplaza los ítems de una operación.
    Lo consume rpc_atomic_update_sale_operation (REVERSE + APPLY sobre branch_stock).

    metodos-pago-operaciones (D5): `payment_method_id` es tri-estado por
    AUSENCIA, no por valor — se distingue con `model_fields_set` en el router/
    service, NUNCA por `is None`. No incluir el campo en el JSON = preservar el
    vigente; incluirlo con `null` = desimputar explícito ("Sin especificar");
    incluirlo con un uuid = reimputar. Ver PaymentMethodSelect (frontend).

    edicion-preserva-contexto (F1 §D3): `branch_id` y `canal` usan el MISMO
    contrato tri-estado por ausencia — `model_fields_set`, nunca `is None`.
    """
    sale_ids: list[str]
    items: list[SaleOperationUpdateItemIn]
    date: datetime.date
    client_id: str | None = None
    currency: str = "ARS"
    payment_method_id: uuid.UUID | None = None
    branch_id: uuid.UUID | None = None
    canal: str | None = Field(default=None, max_length=40)


class SaleItemOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    date: datetime.date
    product_id: uuid.UUID | None = None
    product_name: str | None = None
    client_id: uuid.UUID | None = None
    client_name: str | None = None
    operation_id: uuid.UUID | None = None
    quantity: Decimal
    amount: Decimal
    total: Decimal | None = None
    currency: str = "ARS"
    # metodos-pago-operaciones (D7): imputación explícita o, para ventas del
    # POS sin imputar, derivada de lectura desde sales_orders.payment_method
    # (LEFT JOIN, resuelto en el mismo query — ver SalesRepository).
    payment_method_id: uuid.UUID | None = None
    payment_method_name: str | None = None
    payment_method_kind: str | None = None
    # edicion-preserva-contexto (D11): expuestos para que el form de edición
    # pueda prefillear sucursal/canal/unidad — sin esto no hay con qué.
    branch_id: uuid.UUID | None = None
    canal: str | None = None
    unit_id: uuid.UUID | None = None
    # edicion-preserva-contexto (F2/D11): derivado de lectura (mismo
    # predicado que el guard P0423), para que el form se abra en solo-lectura
    # ANTES de que el usuario llegue al error del backend.
    is_invoiced: bool = False

    @field_validator("date", mode="before")
    @classmethod
    def _coerce_datetime_to_date(cls, v: object) -> object:
        # sales.date es `timestamptz`: las filas con hora ≠ 00:00 (ventas viejas
        # creadas con now()) llegan como datetime y Pydantic las rechaza contra
        # `date` (date_from_datetime_inexact) → 500. Tomamos la parte de fecha.
        if isinstance(v, datetime.datetime):
            return v.date()
        return v


# v3-api-standards §2: envelope estándar {items,total,page,pages}, reemplaza
# el SalesPageOut previo ({items,total_operations}) — BREAKING sancionado
# (OQ1 PO), frontend migrado en el mismo change.
SalesPageOut = PageOut[SaleItemOut]


# ── Promoción de venta legacy → SalesOrder (facturar-venta-manual) ───────────

class PromoteToOrderOut(BaseModel):
    """
    facturar-venta-manual (D6):
    Respuesta de POST /sales/{operation_id}/promote-to-order.
    """
    model_config = ConfigDict(from_attributes=True)

    sales_order_id:    uuid.UUID
    sale_operation_id: uuid.UUID
    replayed:          bool


# ── Comprobante de venta en PDF (para compartir por WhatsApp) ─────────────────

class SalesReceiptItemIn(BaseModel):
    name: str
    quantity: str
    unit_price: Decimal
    subtotal: Decimal


class SalesReceiptPdfIn(BaseModel):
    business_name: str
    receipt_number: str
    date_label: str
    items: list[SalesReceiptItemIn]
    total: Decimal
    currency: str = "ARS"
    client_name: str | None = None
    business_phone: str | None = None
    business_email: str | None = None
