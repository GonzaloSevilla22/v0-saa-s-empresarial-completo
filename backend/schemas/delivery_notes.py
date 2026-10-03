"""
Schemas Pydantic v2 del remito de venta (remitos-venta tanda A, D13) y del de
compra (remitos-compra tanda A, D13).

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
  - Dos sentidos, dos clases por operación (venta: cliente y domicilio; compra:
    proveedor y número de SU remito) bajo una unión discriminada por `direction`
    (`DeliveryNoteCreateBody` / `DeliveryNoteUpdateBody`). Un cuerpo SIN
    `direction` sigue siendo de venta: así la API vigente no cambia para ningún
    cliente que ya la use. Un sentido desconocido es un 422.
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
from typing import Annotated, Any, Literal, Optional, Union

from pydantic import BaseModel, ConfigDict, Discriminator, Field, Tag, field_validator, model_serializer

from backend.schemas.common import PageOut

MAX_ADDRESS = 500
MAX_NOTES = 2000
MAX_SUPPLIER_REFERENCE = 100
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
    direction:        Literal["sale"] = "sale"
    revision:         int = Field(ge=1)
    client_id:        uuid.UUID
    branch_id:        uuid.UUID
    delivery_address: Optional[str] = Field(max_length=MAX_ADDRESS)
    notes:            Optional[str] = Field(max_length=MAX_NOTES)
    items:            list[DeliveryNoteItemIn] = Field(min_length=1, max_length=MAX_ITEMS)


class PurchaseDeliveryNoteCreateIn(BaseModel):
    """Alta (recepción) de un remito de COMPRA: proveedor y sucursal de destino
    obligatorios, número del remito del proveedor opcional (hasta 100 caracteres).

    No hay cliente ni domicilio de entrega. El `price` de cada línea es el precio
    de compra por unidad de la línea y admite 0 (el proveedor suele mandar el
    remito sin precios y la factura después: se completan editando; la conversión
    en compra los exige). El `subtotal` que mande el cliente lo ignora el
    servidor (lo recalcula como `round(price x quantity, 2)`, design D1).
    """
    direction:          Literal["purchase"]
    supplier_id:        uuid.UUID
    branch_id:          uuid.UUID
    supplier_reference: Optional[str] = Field(default=None, max_length=MAX_SUPPLIER_REFERENCE)
    notes:              Optional[str] = Field(default=None, max_length=MAX_NOTES)
    items:              list[DeliveryNoteItemIn] = Field(min_length=1, max_length=MAX_ITEMS)


class PurchaseDeliveryNoteUpdateIn(BaseModel):
    """Edición de un remito de compra: reemplazo completo con la versión que se
    editó (`revision`). `supplier_reference` y `notes` son requeridos y admiten
    `null` (= "sin número del proveedor" / "sin notas"), para que una edición
    nunca vacíe un dato por omisión."""
    direction:          Literal["purchase"]
    revision:           int = Field(ge=1)
    supplier_id:        uuid.UUID
    branch_id:          uuid.UUID
    supplier_reference: Optional[str] = Field(max_length=MAX_SUPPLIER_REFERENCE)
    notes:              Optional[str] = Field(max_length=MAX_NOTES)
    items:              list[DeliveryNoteItemIn] = Field(min_length=1, max_length=MAX_ITEMS)


def _direction_of_body(value: Any) -> str:
    """Etiqueta de la unión: el `direction` del cuerpo, o `sale` si no vino (la
    API de venta no lo exigía). Un valor desconocido no tiene etiqueta y la
    validación lo rechaza con 422."""
    if isinstance(value, dict):
        direction = value.get("direction")
    else:
        direction = getattr(value, "direction", None)
    return direction if direction is not None else "sale"


DeliveryNoteCreateBody = Annotated[
    Union[
        Annotated[DeliveryNoteCreateIn, Tag("sale")],
        Annotated[PurchaseDeliveryNoteCreateIn, Tag("purchase")],
    ],
    Discriminator(_direction_of_body),
]

DeliveryNoteUpdateBody = Annotated[
    Union[
        Annotated[DeliveryNoteUpdateIn, Tag("sale")],
        Annotated[PurchaseDeliveryNoteUpdateIn, Tag("purchase")],
    ],
    Discriminator(_direction_of_body),
]


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
    supplier_name:      Optional[str] = None
    supplier_phone:     Optional[str] = None
    supplier_tax_id:    Optional[str] = None
    # El proveedor se dio de baja después de recibir: el detalle lo avisa y la
    # conversión en compra queda deshabilitada hasta elegir uno vigente.
    supplier_deleted:   bool = False
    supplier_reference: Optional[str] = None
    # Líneas con precio 0 (compra): el remito todavía no se puede convertir y su
    # total subestima lo recibido.
    missing_price_count: int = 0
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
    supplier_id:        Optional[uuid.UUID] = None
    supplier_name:      Optional[str] = None
    supplier_phone:     Optional[str] = None
    supplier_reference: Optional[str] = None
    missing_price_count: int = 0
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
    """Remitos pendientes (`issued`) del recorte del listado.

    `pending_missing_price_count` es sólo del sentido compra (cuántos de los
    pendientes tienen alguna línea con precio 0: su importe está incompleto y no
    se pueden convertir). En venta no existe y NO SE SERIALIZA: la respuesta de
    venta sigue siendo `{pending_count, pending_total}`, byte a byte.
    """
    pending_count: int = 0
    pending_total: Decimal = Decimal("0")
    pending_missing_price_count: Optional[int] = None

    @model_serializer(mode="wrap")
    def _omit_the_purchase_only_count(self, handler: Any) -> dict[str, Any]:
        data = handler(self)
        if data.get("pending_missing_price_count") is None:
            data.pop("pending_missing_price_count", None)
        return data


class DeliveryNotePageOut(PageOut[DeliveryNoteListItemOut]):
    """Envelope estándar {items,total,page,pages} (v3-api-standards §2) más el
    resumen de pendientes del encabezado de `/remitos`."""
    summary: DeliveryNoteSummaryOut
