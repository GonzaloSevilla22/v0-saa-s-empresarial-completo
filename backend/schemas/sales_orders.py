"""
C-29 v21-quote-salesorder — Schemas Pydantic v2 para SalesOrder / quickSale.
facturar-venta-afip — EmitInvoiceIn / EmitInvoiceOut (task 2.2).

Reglas duras:
  - NUNCA usar `any` — tipos explícitos o `unknown`
  - Validación cross-field: cash ⇒ cash_session_id requerido
  - Enums para payment_method (solo cash|other en C-29; crédito→C-30)
"""
from __future__ import annotations

import datetime
import uuid
from decimal import Decimal
from enum import Enum
from typing import Optional

from pydantic import BaseModel, ConfigDict, field_validator, model_validator


# ── Enums ─────────────────────────────────────────────────────────────────────

class PaymentMethod(str, Enum):
    cash   = "cash"
    other  = "other"
    credit = "credit"   # C-30: venta a crédito — postea cargo en CustomerAccount


class SalesOrderStatus(str, Enum):
    draft     = "draft"
    confirmed = "confirmed"
    canceled  = "canceled"


# ── Items ─────────────────────────────────────────────────────────────────────

class SalesOrderItemIn(BaseModel):
    """Línea de orden de venta para quickSale."""
    product_id: Optional[uuid.UUID] = None
    unit_id:    Optional[uuid.UUID] = None
    quantity:   Decimal
    price:      Decimal
    subtotal:   Optional[Decimal] = None  # calculado si no se pasa: price * quantity

    @field_validator("quantity")
    @classmethod
    def validate_quantity_positive(cls, v: Decimal) -> Decimal:
        if v <= 0:
            raise ValueError("quantity debe ser mayor que cero")
        return v

    @field_validator("price")
    @classmethod
    def validate_price_non_negative(cls, v: Decimal) -> Decimal:
        if v < 0:
            raise ValueError("price no puede ser negativo")
        return v


class SalesOrderItemOut(BaseModel):
    """Línea de orden de venta en respuesta."""
    model_config = ConfigDict(from_attributes=True)

    id:             uuid.UUID
    sales_order_id: uuid.UUID
    account_id:     uuid.UUID
    product_id:     Optional[uuid.UUID] = None
    unit_id:        Optional[uuid.UUID] = None
    quantity:       Decimal
    price:          Decimal
    subtotal:       Decimal


# ── SalesOrder Output ─────────────────────────────────────────────────────────

class SalesOrderOut(BaseModel):
    """Orden de venta serializada en respuesta."""
    model_config = ConfigDict(from_attributes=True)

    id:                 uuid.UUID
    account_id:         uuid.UUID
    branch_id:          uuid.UUID
    client_id:          Optional[uuid.UUID] = None
    source_quote_id:    Optional[uuid.UUID] = None
    status:             SalesOrderStatus
    payment_method:     PaymentMethod
    total:              Decimal
    sale_operation_id:  Optional[uuid.UUID] = None
    fiscal_document_id: Optional[uuid.UUID] = None
    created_by:         uuid.UUID
    created_at:         datetime.datetime
    items:              list[SalesOrderItemOut] = []


# ── Confirm ───────────────────────────────────────────────────────────────────

class ConfirmIn(BaseModel):
    """
    Payload para confirmar una SalesOrder existente.

    Validación cross-field (OQ-2 resuelto):
      payment_method='cash' ⇒ cash_session_id REQUERIDO (no puede ser None).
    """
    idempotency_key:   str
    payment_method:    PaymentMethod
    cash_session_id:   Optional[uuid.UUID] = None
    comprobante_type:  Optional[str] = None  # nullable = sin comprobante (OQ-1)
    point_of_sale_id:  Optional[uuid.UUID] = None
    branch_id:         Optional[uuid.UUID] = None
    canal:             Optional[str] = None

    @model_validator(mode="after")
    def validate_cash_requires_session(self) -> "ConfirmIn":
        if self.payment_method == PaymentMethod.cash and self.cash_session_id is None:
            raise ValueError(
                "cash_session_id es requerido cuando payment_method='cash'"
            )
        return self

    @field_validator("idempotency_key")
    @classmethod
    def validate_idempotency_key_not_empty(cls, v: str) -> str:
        if not v or not v.strip():
            raise ValueError("idempotency_key no puede estar vacío")
        return v


# ── QuickSale ─────────────────────────────────────────────────────────────────

class QuickSaleIn(BaseModel):
    """
    Payload para crear + confirmar una SalesOrder en un solo paso (POS).

    Validación cross-field: cash ⇒ cash_session_id requerido.
    """
    idempotency_key:   str
    client_id:         Optional[uuid.UUID] = None
    items:             list[SalesOrderItemIn]
    payment_method:    PaymentMethod = PaymentMethod.other
    cash_session_id:   Optional[uuid.UUID] = None
    comprobante_type:  Optional[str] = None  # nullable (OQ-1)
    point_of_sale_id:  Optional[uuid.UUID] = None
    branch_id:         Optional[uuid.UUID] = None
    canal:             Optional[str] = None

    @model_validator(mode="after")
    def validate_cash_requires_session(self) -> "QuickSaleIn":
        if self.payment_method == PaymentMethod.cash and self.cash_session_id is None:
            raise ValueError(
                "cash_session_id es requerido cuando payment_method='cash'"
            )
        return self

    @model_validator(mode="after")
    def validate_items_not_empty(self) -> "QuickSaleIn":
        if not self.items:
            raise ValueError("la venta debe tener al menos un ítem")
        return self

    @field_validator("idempotency_key")
    @classmethod
    def validate_idempotency_key_not_empty(cls, v: str) -> str:
        if not v or not v.strip():
            raise ValueError("idempotency_key no puede estar vacío")
        return v


# C-30: alias para los tests (el schema original se llama ConfirmIn)
ConfirmSalesOrderIn = ConfirmIn


# ── Emit Invoice (facturar-venta-afip) ────────────────────────────────────────

class EmitInvoiceIn(BaseModel):
    """
    Payload para emitir un comprobante AFIP sobre una SalesOrder confirmada.

    El tipo de comprobante NO se acepta del cliente (D3): se resuelve en el
    backend según la condición IVA del emisor.

    Campos opcionales: point_of_sale_id puede omitirse si la cuenta tiene
    un único PV activo (el RPC lo auto-selecciona).
    """
    point_of_sale_id: Optional[uuid.UUID] = None


class EmitInvoiceOut(BaseModel):
    """
    Respuesta de POST /sales-orders/{id}/emit-invoice (OQ-3: HTTP 200).

    Retorna el comprobante en estado 'pending_cae' (emisión asíncrona).
    El CAE lo obtiene el relay vía pg_cron; el front sigue con FiscalDocumentBadge + Realtime.
    """
    model_config = ConfigDict(from_attributes=True)

    fiscal_document_id: uuid.UUID
    comprobante_type:   str
    status:             str   # 'pending_cae'
    punto_de_venta:     Optional[int] = None
    number:             Optional[int] = None
    sales_order_id:     Optional[uuid.UUID] = None

# ── Accept Quote Output ───────────────────────────────────────────────────────

class AcceptQuoteOut(BaseModel):
    """Respuesta de rpc_accept_quote."""
    sales_order_id: uuid.UUID
    quote_id:       uuid.UUID
    status:         str  # 'accepted'


# ── Confirm / QuickSale Output ────────────────────────────────────────────────

class ConfirmOut(BaseModel):
    """Respuesta de rpc_confirm_sales_order / rpc_quick_sale."""
    sales_order_id: uuid.UUID
    operation_id:   uuid.UUID
    total:          Decimal
    fiscal_doc_id:  Optional[uuid.UUID] = None
    replayed:       bool = False
