"""
C-29 v21-quote-salesorder — Schemas Pydantic v2 para Quote.

Reglas duras:
  - NUNCA usar `any` — tipos explícitos o `unknown`
  - Validaciones de no-vacío y montos > 0 en el schema
  - Enums para status (closed set de transiciones)
"""
from __future__ import annotations

import datetime
import uuid
from decimal import Decimal
from enum import Enum
from typing import Optional

from pydantic import BaseModel, ConfigDict, field_validator, model_validator


# ── Enums ─────────────────────────────────────────────────────────────────────

class QuoteStatus(str, Enum):
    draft    = "draft"
    sent     = "sent"
    accepted = "accepted"
    expired  = "expired"
    rejected = "rejected"


# ── Item ──────────────────────────────────────────────────────────────────────

class QuoteItemIn(BaseModel):
    """Línea de presupuesto para creación/edición."""
    product_id: Optional[uuid.UUID] = None  # nullable: líneas de servicio
    unit_id:    Optional[uuid.UUID] = None
    quantity:   Decimal
    price:      Decimal
    subtotal:   Decimal

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

    @field_validator("subtotal")
    @classmethod
    def validate_subtotal_non_negative(cls, v: Decimal) -> Decimal:
        if v < 0:
            raise ValueError("subtotal no puede ser negativo")
        return v


class QuoteItemOut(BaseModel):
    """Línea de presupuesto en respuesta."""
    model_config = ConfigDict(from_attributes=True)

    id:         uuid.UUID
    quote_id:   uuid.UUID
    account_id: uuid.UUID
    product_id: Optional[uuid.UUID] = None
    unit_id:    Optional[uuid.UUID] = None
    quantity:   Decimal
    price:      Decimal
    subtotal:   Decimal


# ── Quote ─────────────────────────────────────────────────────────────────────

class QuoteIn(BaseModel):
    """Payload para crear un presupuesto."""
    client_id:   Optional[uuid.UUID] = None
    branch_id:   Optional[uuid.UUID] = None
    valid_until: Optional[datetime.date] = None
    items:       list[QuoteItemIn]

    @model_validator(mode="after")
    def validate_items_not_empty(self) -> "QuoteIn":
        if not self.items:
            raise ValueError("el presupuesto debe tener al menos un ítem")
        return self


class QuoteOut(BaseModel):
    """Presupuesto serializado en respuesta."""
    model_config = ConfigDict(from_attributes=True)

    id:          uuid.UUID
    account_id:  uuid.UUID
    branch_id:   Optional[uuid.UUID] = None
    client_id:   Optional[uuid.UUID] = None
    status:      QuoteStatus
    valid_until: Optional[datetime.date] = None
    total:       Decimal
    created_by:  uuid.UUID
    created_at:  datetime.datetime
    items:       list[QuoteItemOut] = []


# ── Transiciones ──────────────────────────────────────────────────────────────

class QuoteTransitionIn(BaseModel):
    """
    Payload para transicionar el estado de un presupuesto.
    Transiciones válidas: draft→sent, sent→rejected, sent|draft→expired.
    accept() tiene su propio endpoint y no usa este schema.
    """
    action: str  # "send" | "reject" | "expire"

    @field_validator("action")
    @classmethod
    def validate_action(cls, v: str) -> str:
        allowed = {"send", "reject", "expire"}
        if v not in allowed:
            raise ValueError(f"action debe ser uno de: {', '.join(sorted(allowed))}")
        return v
