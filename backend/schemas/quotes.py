"""
Schemas Pydantic v2 del presupuesto (C-29 v21-quote-salesorder; reescritos por
presupuestos-modulo D12 sobre el contrato de las RPCs).

Reglas duras:
  - NUNCA `any`: tipos explícitos o `unknown`.
  - Las reglas que la RPC también valida (cliente obligatorio, descripción de
    la línea de servicio, topes, validez) se repiten acá para rechazar con 422
    ANTES de tocar la base; la RPC las vuelve a validar (defensa en
    profundidad, igual que `rpc_quick_sale`).
  - El total NO viaja: lo calcula la RPC como `round(Σ subtotal, 2)`. El
    `subtotal` de cada línea sí (lleva el descuento).
  - `QuoteUpdateIn` es un REEMPLAZO completo: `branch_id`, `valid_until` y
    `notes` son campos requeridos (`branch_id` y `notes` admiten `null` = "sin
    sucursal" / "sin notas"; `valid_until` no: un NULL dejaría el presupuesto
    sin vencimiento, y ni el barrido ni `is_expired` lo verían).
"""
from __future__ import annotations

import datetime
import uuid
from decimal import Decimal
from enum import Enum
from typing import Literal, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from backend.schemas.common import PageOut

MAX_DESCRIPTION = 200
MAX_NOTES = 2000
MAX_REASON = 500
MAX_ITEMS = 500


# ── Enums ─────────────────────────────────────────────────────────────────────

class QuoteStatus(str, Enum):
    draft    = "draft"
    sent     = "sent"
    accepted = "accepted"
    expired  = "expired"
    rejected = "rejected"


# ── Item ──────────────────────────────────────────────────────────────────────

class QuoteItemIn(BaseModel):
    """Línea de presupuesto para el alta y la edición.

    `product_id` NULL = línea de servicio: exige `description`, que se guarda
    en `name_snapshot`. Con producto, la descripción es irrelevante (el nombre
    sale del maestro).
    """
    product_id:  Optional[uuid.UUID] = None
    unit_id:     Optional[uuid.UUID] = None
    quantity:    Decimal
    price:       Decimal
    subtotal:    Decimal
    description: Optional[str] = None

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

    @field_validator("description")
    @classmethod
    def normalize_description(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return None
        v = v.strip()
        if not v:
            return None
        if len(v) > MAX_DESCRIPTION:
            raise ValueError(f"description admite hasta {MAX_DESCRIPTION} caracteres")
        return v

    @model_validator(mode="after")
    def service_line_needs_description(self) -> "QuoteItemIn":
        if self.product_id is None and self.description is None:
            raise ValueError("una línea sin producto necesita una descripción")
        return self


class QuoteItemOut(BaseModel):
    """Línea de presupuesto en la respuesta."""
    model_config = ConfigDict(from_attributes=True)

    id:         uuid.UUID
    quote_id:   uuid.UUID
    account_id: uuid.UUID
    product_id: Optional[uuid.UUID] = None
    unit_id:    Optional[uuid.UUID] = None
    # Símbolo de la unidad de la línea (join con units_of_measure): el PDF y la
    # pantalla muestran "2 kg", no sólo "2".
    unit_symbol: Optional[str] = None
    quantity:   Decimal
    price:      Decimal
    subtotal:   Decimal
    line_no:    Optional[int] = None
    # v3-snapshot-pattern: fotografía del maestro al congelar la línea.
    name_snapshot:       Optional[str] = None
    sku_snapshot:        Optional[str] = None
    unit_cost_snapshot:  Optional[Decimal] = None
    iva_rate_snapshot:   Optional[Decimal] = None
    snapshot_backfilled: bool = False


class QuoteHistoryEntryOut(BaseModel):
    """Una transición de estado (`document_status_history`)."""
    model_config = ConfigDict(from_attributes=True)

    from_status:  Optional[str] = None
    to_status:    str
    performed_by: uuid.UUID
    reason:       Optional[str] = None
    occurred_at:  datetime.datetime


# ── Quote ─────────────────────────────────────────────────────────────────────

class QuoteIn(BaseModel):
    """Alta de un presupuesto. Cliente obligatorio (OQ-P1)."""
    client_id:   uuid.UUID
    branch_id:   Optional[uuid.UUID] = None
    valid_until: Optional[datetime.date] = None
    notes:       Optional[str] = Field(default=None, max_length=MAX_NOTES)
    items:       list[QuoteItemIn] = Field(min_length=1, max_length=MAX_ITEMS)


class QuoteUpdateIn(BaseModel):
    """Edición: reemplazo completo, con la versión que se editó (`revision`).

    Si la versión ya no es la vigente la RPC responde `quote_changed` sin
    modificar nada: dos editores simultáneos no se pisan en silencio.
    """
    revision:    int = Field(ge=1)
    client_id:   uuid.UUID
    branch_id:   Optional[uuid.UUID]
    valid_until: datetime.date
    notes:       Optional[str] = Field(max_length=MAX_NOTES)
    items:       list[QuoteItemIn] = Field(min_length=1, max_length=MAX_ITEMS)


class QuoteOut(BaseModel):
    """Presupuesto con sus líneas y su historial."""
    model_config = ConfigDict(from_attributes=True)

    id:           uuid.UUID
    account_id:   uuid.UUID
    branch_id:    Optional[uuid.UUID] = None
    client_id:    Optional[uuid.UUID] = None
    status:       QuoteStatus
    valid_until:  Optional[datetime.date] = None
    total:        Decimal
    created_by:   uuid.UUID
    created_at:   datetime.datetime
    number:       Optional[int] = None
    number_label: Optional[str] = None
    revision:     int
    notes:        Optional[str] = None
    sent_at:      Optional[datetime.datetime] = None
    updated_at:   Optional[datetime.datetime] = None
    updated_by:   Optional[uuid.UUID] = None
    # Derivado al leer: abierto con la validez ya pasada (día de negocio ART),
    # aunque el barrido todavía no lo haya marcado `expired`.
    is_expired:   bool = False
    client_name:  Optional[str] = None
    client_phone: Optional[str] = None
    client_tax_id: Optional[str] = None
    # Nombre del emisor tal como lo imprime el PDF (sólo en `GET /quotes/{id}`):
    # lo usa el texto de WhatsApp para firmar igual que el documento.
    issuer_name:  Optional[str] = None
    # La orden de venta nacida de la conversión (tanda B); null hasta entonces.
    sales_order_id: Optional[uuid.UUID] = None
    items:        list[QuoteItemOut] = []
    history:      list[QuoteHistoryEntryOut] = []


class QuoteListItemOut(BaseModel):
    """Fila del listado paginado (sin líneas ni historial)."""
    model_config = ConfigDict(from_attributes=True)

    id:           uuid.UUID
    branch_id:    Optional[uuid.UUID] = None
    client_id:    Optional[uuid.UUID] = None
    client_name:  Optional[str] = None
    client_phone: Optional[str] = None
    status:       QuoteStatus
    valid_until:  Optional[datetime.date] = None
    is_expired:   bool = False
    total:        Decimal
    number:       Optional[int] = None
    number_label: Optional[str] = None
    revision:     int
    created_at:   datetime.datetime
    sent_at:      Optional[datetime.datetime] = None
    updated_at:   Optional[datetime.datetime] = None


# Envelope estándar {items,total,page,pages} (v3-api-standards §2).
QuotePageOut = PageOut[QuoteListItemOut]


# ── Transiciones ──────────────────────────────────────────────────────────────

class QuoteTransitionIn(BaseModel):
    """Transición pedida desde la API: sólo `send` y `reject`.

    `accepted` va únicamente por la conversión a venta y `expired` únicamente
    por el barrido diario: pedirlos por acá es un 422.
    """
    action: Literal["send", "reject"]
    reason: Optional[str] = Field(default=None, max_length=MAX_REASON)


# ── Conversión a venta (tanda B, D6/D12) ──────────────────────────────────────

class QuoteConvertIn(BaseModel):
    """Conversión atómica del presupuesto en venta (`rpc_convert_quote_to_sale`).

    `expected_revision` es la versión del presupuesto que el usuario VIO al
    confirmar: si otro la editó mientras tanto, la RPC responde `quote_changed`
    (409) y no cobra un total que nadie confirmó. La forma de pago es del
    catálogo (`payment_method_id`): la conversión no usa el camino legacy por
    texto. Sucursal, caja y cuenta bancaria son opcionales y los guards de
    tenencia viven en la RPC. La clave de idempotencia viaja por el header
    `Idempotency-Key`; `idempotency_key` en el body es el fallback deprecado
    (v3-api-standards §3.3).
    """
    expected_revision: int = Field(ge=1)
    payment_method_id: uuid.UUID
    branch_id:         Optional[uuid.UUID] = None
    cash_session_id:   Optional[uuid.UUID] = None
    bank_account_id:   Optional[uuid.UUID] = None
    canal:             Optional[str] = None
    idempotency_key:   Optional[str] = None

    @field_validator("idempotency_key")
    @classmethod
    def validate_idempotency_key_not_empty(cls, v: Optional[str]) -> Optional[str]:
        if v is not None and not v.strip():
            raise ValueError("idempotency_key no puede estar vacío")
        return v


class QuoteConvertOut(BaseModel):
    """Resultado de la conversión: el presupuesto, la orden de venta confirmada y
    la operación de venta. `replayed = true` cuando la misma clave ya había
    convertido ESTE presupuesto (el reintento no escribe nada)."""
    model_config = ConfigDict(from_attributes=True)

    quote_id:           uuid.UUID
    quote_number:       Optional[int] = None
    quote_number_label: Optional[str] = None
    sales_order_id:     uuid.UUID
    operation_id:       uuid.UUID
    total:              Decimal
    replayed:           bool = False


# ── Configuración ─────────────────────────────────────────────────────────────

class QuoteSettingsIn(BaseModel):
    """Validez por defecto de los presupuestos de la cuenta, en días (1..365).

    El rango se rechaza acá (422) antes de la base; la RPC lo vuelve a validar.
    """
    default_quote_validity_days: int = Field(ge=1, le=365)


class QuoteSettingsOut(BaseModel):
    default_quote_validity_days: int
