"""
Schemas Pydantic v2 del remito de venta (remitos-venta tanda A, D13).

Reglas duras:
  - NUNCA `any`: tipos explícitos o `unknown`.
  - Las reglas que la RPC también valida (cliente y sucursal obligatorios,
    producto en cada línea, topes) se repiten acá para rechazar con 422 ANTES de
    tocar la base; la RPC las vuelve a validar (defensa en profundidad).
  - El total NO viaja: lo calcula la RPC como `round(Σ subtotal, 2)`. El
    `subtotal` de cada línea sí (lleva el descuento).
  - La clave de idempotencia viaja SIEMPRE por el header `Idempotency-Key`
    (nunca en el cuerpo: el remito nace con el contrato nuevo, sin el fallback
    deprecado).
  - Sólo existe el sentido venta (`direction: Literal["sale"]`): el de compra es
    de `remitos-compra` y ninguna RPC de este change lo acepta.
  - `DeliveryNoteUpdateIn` es un REEMPLAZO completo: `delivery_address` y
    `notes` son campos requeridos que admiten `null` (= "sin domicilio" / "sin
    notas"), para que una edición nunca vacíe un dato por omisión.

Contrato del listado (para el frontend): `GET /delivery-notes` devuelve el
envelope estándar `{items, total, page, pages}` MÁS un `summary`
(`{pending_count, pending_total}`) con los remitos `issued` del mismo recorte
(sentido, cliente, sucursal y búsqueda) SIN importar el estado pedido: el
encabezado "N remitos pendientes por $ X" no cambia al cambiar de pestaña.
"""
from __future__ import annotations

import datetime
import uuid
from decimal import Decimal
from enum import Enum
from typing import Literal, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator

from backend.schemas.common import PageOut

MAX_ADDRESS = 500
MAX_NOTES = 2000
MIN_REASON = 3
MAX_REASON = 500
MAX_ITEMS = 500


# ── Enums ─────────────────────────────────────────────────────────────────────

class DeliveryNoteStatus(str, Enum):
    issued    = "issued"
    converted = "converted"
    canceled  = "canceled"


# ── Líneas ────────────────────────────────────────────────────────────────────

class DeliveryNoteItemIn(BaseModel):
    """Línea de remito para el alta y la edición. `product_id` es OBLIGATORIO:
    un remito documenta mercadería que sale del depósito (OQ-RV11), así que no
    hay líneas de servicio."""
    product_id: uuid.UUID
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


class DeliveryNoteItemOut(BaseModel):
    """Línea de remito en la respuesta."""
    model_config = ConfigDict(from_attributes=True)

    id:               uuid.UUID
    delivery_note_id: uuid.UUID
    account_id:       uuid.UUID
    line_no:          int
    product_id:       uuid.UUID
    unit_id:          Optional[uuid.UUID] = None
    # Símbolo de la unidad (join con units_of_measure): "2 kg", no sólo "2".
    unit_symbol:      Optional[str] = None
    quantity:         Decimal
    # Lo que la línea retiene del stock, normalizado a la unidad base del
    # producto (lo que efectivamente se descontó). Lo usa el editor para calcular
    # el disponible de la sucursal sin contar dos veces lo ya retenido.
    quantity_base:    Decimal
    price:            Decimal
    subtotal:         Decimal
    name_snapshot:      Optional[str] = None
    sku_snapshot:       Optional[str] = None
    unit_cost_snapshot: Optional[Decimal] = None
    iva_rate_snapshot:  Optional[Decimal] = None
    # El producto fue dado de baja después de emitir: se conserva lo entregado.
    product_deleted:  bool = False


class DeliveryNoteHistoryEntryOut(BaseModel):
    """Una transición de estado (`document_status_history`)."""
    model_config = ConfigDict(from_attributes=True)

    from_status:  Optional[str] = None
    to_status:    str
    performed_by: Optional[uuid.UUID] = None
    reason:       Optional[str] = None
    occurred_at:  datetime.datetime


# ── Remito ────────────────────────────────────────────────────────────────────

class DeliveryNoteCreateIn(BaseModel):
    """Alta (emisión) de un remito de venta: cliente y sucursal obligatorios."""
    direction:        Literal["sale"] = "sale"
    client_id:        uuid.UUID
    branch_id:        uuid.UUID
    delivery_address: Optional[str] = Field(default=None, max_length=MAX_ADDRESS)
    notes:            Optional[str] = Field(default=None, max_length=MAX_NOTES)
    items:            list[DeliveryNoteItemIn] = Field(min_length=1, max_length=MAX_ITEMS)


class DeliveryNoteUpdateIn(BaseModel):
    """Edición: reemplazo completo, con la versión que se editó (`revision`).

    Si la versión ya no es la vigente la RPC responde `delivery_note_changed`
    sin modificar nada: dos editores simultáneos no se pisan en silencio.
    """
    revision:         int = Field(ge=1)
    client_id:        uuid.UUID
    branch_id:        uuid.UUID
    delivery_address: Optional[str] = Field(max_length=MAX_ADDRESS)
    notes:            Optional[str] = Field(max_length=MAX_NOTES)
    items:            list[DeliveryNoteItemIn] = Field(min_length=1, max_length=MAX_ITEMS)


class DeliveryNoteCancelIn(BaseModel):
    """Anulación: motivo obligatorio (3 a 500 caracteres) y la versión vista."""
    revision: int = Field(ge=1)
    reason:   str = Field(min_length=MIN_REASON, max_length=MAX_REASON)

    @field_validator("reason", mode="before")
    @classmethod
    def strip_reason(cls, v: object) -> object:
        # Se recorta ANTES de validar el largo: "  " no es un motivo.
        return v.strip() if isinstance(v, str) else v


class DeliveryNoteConvertIn(BaseModel):
    """Conversión del remito en venta con un toque (`rpc_convert_delivery_note_to_sale`).

    `expected_revision` es la versión del remito que el usuario VIO al
    confirmar: si otro lo editó mientras tanto, la RPC responde
    `delivery_note_changed` (409) y no cobra un total que nadie confirmó. La
    forma de pago es del catálogo (`payment_method_id`). Caja y cuenta bancaria
    son opcionales y los guards de tenencia viven en la RPC.

    NO hay `branch_id`: la venta se imputa a la sucursal del remito, que es de
    donde salió el stock (D7). Tampoco `idempotency_key`: viaja SIEMPRE por el
    header `Idempotency-Key`, sin el fallback deprecado del body.
    """
    expected_revision: int = Field(ge=1)
    payment_method_id: uuid.UUID
    cash_session_id:   Optional[uuid.UUID] = None
    bank_account_id:   Optional[uuid.UUID] = None
    canal:             Optional[str] = Field(default=None, max_length=40)


class DeliveryNoteConvertOut(BaseModel):
    """Resultado de la conversión: el remito, la orden de venta confirmada y la
    operación de venta. `replayed = true` cuando la misma clave ya había
    convertido ESTE remito (el reintento no escribe nada)."""
    model_config = ConfigDict(from_attributes=True)

    delivery_note_id:           uuid.UUID
    delivery_note_number:       Optional[int] = None
    delivery_note_number_label: Optional[str] = None
    sales_order_id:             uuid.UUID
    operation_id:               uuid.UUID
    total:                      Decimal
    replayed:                   bool = False


class DeliveryNoteOut(BaseModel):
    """Remito con sus líneas y su historial."""
    model_config = ConfigDict(from_attributes=True)

    id:                 uuid.UUID
    account_id:         uuid.UUID
    direction:          str
    branch_id:          uuid.UUID
    branch_name:        Optional[str] = None
    client_id:          Optional[uuid.UUID] = None
    client_name:        Optional[str] = None
    client_phone:       Optional[str] = None
    client_tax_id:      Optional[str] = None
    # El cliente se dio de baja después de emitir: el detalle lo avisa y la
    # conversión en venta queda deshabilitada hasta elegir uno vigente.
    client_deleted:     bool = False
    supplier_id:        Optional[uuid.UUID] = None
    supplier_reference: Optional[str] = None
    number:             Optional[int] = None
    number_label:       Optional[str] = None
    status:             DeliveryNoteStatus
    issued_on:          datetime.date
    delivery_address:   Optional[str] = None
    notes:              Optional[str] = None
    total:              Decimal
    revision:           int
    created_by:         Optional[uuid.UUID] = None
    created_at:         datetime.datetime
    updated_by:         Optional[uuid.UUID] = None
    updated_at:         Optional[datetime.datetime] = None
    # La orden y la operación de venta VIVAS nacidas de la conversión (tanda B,
    # derivadas de `sales_orders.source_delivery_note_id`); null mientras el remito
    # no esté convertido o si la venta se borró y volvió a `issued`.
    converted_sales_order_id: Optional[uuid.UUID] = None
    converted_operation_id:   Optional[uuid.UUID] = None
    # Nombre del emisor tal como lo imprime el PDF (sólo en `GET /delivery-notes/{id}`):
    # lo usa el texto de WhatsApp para firmar igual que el documento.
    issuer_name:        Optional[str] = None
    # `true` cuando la misma `Idempotency-Key` ya había emitido ESTE remito (el
    # reintento no escribe nada).
    replayed:           bool = False
    items:              list[DeliveryNoteItemOut] = []
    history:            list[DeliveryNoteHistoryEntryOut] = []


class DeliveryNoteListItemOut(BaseModel):
    """Fila del listado paginado (sin líneas ni historial)."""
    model_config = ConfigDict(from_attributes=True)

    id:           uuid.UUID
    direction:    str
    branch_id:    uuid.UUID
    branch_name:  Optional[str] = None
    client_id:    Optional[uuid.UUID] = None
    client_name:  Optional[str] = None
    client_phone: Optional[str] = None
    status:       DeliveryNoteStatus
    issued_on:    datetime.date
    total:        Decimal
    number:       Optional[int] = None
    number_label: Optional[str] = None
    revision:     int
    item_count:   int = 0
    created_at:   datetime.datetime
    updated_at:   Optional[datetime.datetime] = None


class DeliveryNoteSummaryOut(BaseModel):
    """Remitos pendientes (`issued`) del recorte del listado."""
    pending_count: int = 0
    pending_total: Decimal = Decimal("0")


class DeliveryNotePageOut(PageOut[DeliveryNoteListItemOut]):
    """Envelope estándar {items,total,page,pages} (v3-api-standards §2) más el
    resumen de pendientes del encabezado de `/remitos`."""
    summary: DeliveryNoteSummaryOut
