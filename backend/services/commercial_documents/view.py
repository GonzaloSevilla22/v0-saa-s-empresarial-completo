"""
Vista pura de un documento comercial (presupuestos-modulo D8).

`CommercialDocumentView` es lo que el render dibuja, ya resuelto: textos,
fechas, importes y el sello. `build_quote_view` y `build_delivery_note_view` son
funciones PURAS (sin I/O, sin reloj propio: reciben `today`) que la arman desde
el documento, sus líneas, el cliente y el emisor. El remito (`kind =
'delivery_note'`) suma dos campos opcionales a la vista, con default
retrocompatible para el presupuesto: `signature_block` (el bloque "Recibí
conforme") y `origin_label` ("Sale de: Sucursal Centro"); y su `show_prices`
sale del pedido de cada descarga, no del documento (remitos-venta D8).

Remito de compra (remitos-compra D10): la MISMA vista parametrizada por el
sentido del documento, con dos campos aditivos más (default retrocompatible):
`recipient_label` ("Cliente" por defecto, "Recibido de" en compra) y
`reference_label` ("Remito del proveedor N° …", sólo en compra y si el proveedor
dio su número). La contraparte (`client` en la firma) es el proveedor y el
origen es "Ingresa a: <sucursal>".
"""
from __future__ import annotations

import datetime
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from decimal import Decimal
from typing import Any

from backend.core.timezone import today_in_argentina
from backend.services.commercial_documents.issuer import CommercialIssuer
from backend.services.commercial_documents.numbering import format_internal_document_number

QUOTE_TITLE = "PRESUPUESTO"
NO_CLIENT_NAME = "Sin cliente"
NO_DESCRIPTION = "Sin descripción"

_LEGEND_BASE = "Presupuesto — documento no válido como factura."

DELIVERY_NOTE_TITLE = "REMITO"
PURCHASE_DELIVERY_NOTE_TITLE = "REMITO DE COMPRA"
NO_SUPPLIER_NAME = "Sin proveedor"
_DELIVERY_NOTE_LEGEND = "Remito — documento no válido como factura."
_DEFAULT_RECIPIENT_LABEL = "Cliente"
_PURCHASE_RECIPIENT_LABEL = "Recibido de"

# Estados en los que el presupuesto todavía se puede aceptar: si su validez ya
# pasó (el barrido todavía no lo marcó), para el usuario ya venció.
_OPEN_STATUSES = frozenset({"draft", "sent"})

_STAMP_BY_STATUS = {
    "expired": "VENCIDO",
    "rejected": "RECHAZADO",
    "accepted": "ACEPTADO",
}


@dataclass(frozen=True)
class CommercialRecipient:
    name: str
    tax_id: str | None = None
    phone: str | None = None
    address: str | None = None


@dataclass(frozen=True)
class CommercialLine:
    description: str
    quantity_label: str
    # RN-24-bis: el precio unitario viaja SIN redondear; el render lo muestra con
    # su precisión y el subtotal al centavo.
    unit_price: Decimal
    subtotal: Decimal


@dataclass(frozen=True)
class CommercialDocumentView:
    kind: str                         # 'quote' | 'delivery_note'
    title: str
    number_label: str | None
    issued_on: datetime.date
    valid_until: datetime.date | None
    status_stamp: str | None
    issuer: CommercialIssuer
    recipient: CommercialRecipient
    lines: tuple[CommercialLine, ...]
    show_prices: bool
    total: Decimal
    notes: str | None
    legend: str
    # Aditivos del remito (default retrocompatible: el presupuesto no cambia).
    signature_block: bool = False     # recuadro "Recibí conforme" que no se parte entre páginas
    origin_label: str | None = None   # "Sale de: Sucursal Centro" / "Ingresa a: Sucursal Centro"
    # Rótulo del bloque de la contraparte ("Cliente"; "Recibido de" en el remito
    # de compra) y la línea con el número del remito del proveedor.
    recipient_label: str = _DEFAULT_RECIPIENT_LABEL
    reference_label: str | None = None


def format_quantity(quantity: Decimal | int | float | str) -> str:
    """`2.5000` -> `2,5`; `1250` -> `1.250` (formato AR, hasta 4 decimales)."""
    value = Decimal(str(quantity)).quantize(Decimal("0.0001")).normalize()
    integer, _, fraction = format(value, "f").partition(".")
    grouped = f"{int(integer):,}".replace(",", ".")
    return f"{grouped},{fraction}" if fraction else grouped


def _status_stamp(status: str, valid_until: datetime.date | None, today: datetime.date) -> str | None:
    if status in _STAMP_BY_STATUS:
        return _STAMP_BY_STATUS[status]
    if status in _OPEN_STATUSES and valid_until is not None and valid_until < today:
        return "VENCIDO"
    return None


def _legend(valid_until: datetime.date | None) -> str:
    if valid_until is None:
        return _LEGEND_BASE
    return f"{_LEGEND_BASE} Precios válidos hasta el {valid_until:%d/%m/%Y}."


def _text(value: object) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _line(raw: Mapping[str, Any]) -> CommercialLine:
    quantity = format_quantity(raw["quantity"])
    symbol = _text(raw.get("unit_symbol"))
    return CommercialLine(
        description=_text(raw.get("name_snapshot")) or NO_DESCRIPTION,
        quantity_label=f"{quantity} {symbol}" if symbol else quantity,
        unit_price=Decimal(str(raw["price"])),
        subtotal=Decimal(str(raw["subtotal"])),
    )


def build_quote_view(
    quote: Mapping[str, Any],
    lines: Sequence[Mapping[str, Any]],
    client: Mapping[str, Any],
    issuer: CommercialIssuer,
    today: datetime.date,
) -> CommercialDocumentView:
    """Vista del PDF de un presupuesto. Pura: el sello "VENCIDO" de un abierto
    se decide contra `today` (el día de negocio argentino que el caller pasa),
    con la misma regla que `is_expired` en la base."""
    valid_until = quote.get("valid_until")
    return CommercialDocumentView(
        kind="quote",
        title=QUOTE_TITLE,
        number_label=format_internal_document_number("quote", quote.get("number")),
        # `created_at` es un instante: el día de emisión es el de Argentina, no
        # el del reloj UTC del servidor.
        issued_on=today_in_argentina(quote["created_at"]),
        valid_until=valid_until,
        status_stamp=_status_stamp(quote["status"], valid_until, today),
        issuer=issuer,
        recipient=CommercialRecipient(
            name=_text(client.get("name")) or NO_CLIENT_NAME,
            tax_id=_text(client.get("tax_id")),
            phone=_text(client.get("phone")),
            address=_text(client.get("address")),
        ),
        lines=tuple(_line(raw) for raw in lines),
        show_prices=True,
        total=Decimal(str(quote["total"])),
        notes=_text(quote.get("notes")),
        legend=_legend(valid_until),
    )


def build_delivery_note_view(
    delivery_note: Mapping[str, Any],
    lines: Sequence[Mapping[str, Any]],
    client: Mapping[str, Any],
    branch: Mapping[str, Any],
    issuer: CommercialIssuer,
    show_prices: bool,
    today: datetime.date,
) -> CommercialDocumentView:
    """Vista del PDF de un remito, de venta o de compra. Pura.

    Sin precios por defecto: el documento que viaja con la mercadería no los
    muestra, y `show_prices` los incluye sólo cuando se pide explícitamente (la
    tabla y el total siguen ese flag). El número se formatea desde el SENTIDO
    del remito (`delivery_note_<direction>`), nunca con un prefijo fijo. El sello
    "ANULADO" es sólo del estado `canceled`: un remito convertido es la misma
    entrega, no un documento distinto. `issued_on` es la fecha de negocio de la
    emisión (un `date`, sin zona); `today` sólo cubre un remito sin ella.

    En compra (`direction = 'purchase'`) el título es "REMITO DE COMPRA", el
    bloque de la contraparte se rotula "Recibido de" con el proveedor (que llega
    en `client`) y su CUIT, la línea de referencia nombra el número del remito del
    proveedor si lo hay, no hay domicilio de entrega y el origen es "Ingresa a:".
    """
    direction = delivery_note.get("direction") or "sale"
    purchase = direction == "purchase"
    branch_name = _text(branch.get("name"))
    supplier_reference = _text(delivery_note.get("supplier_reference")) if purchase else None
    origin_verb = "Ingresa a" if purchase else "Sale de"
    return CommercialDocumentView(
        kind="delivery_note",
        title=PURCHASE_DELIVERY_NOTE_TITLE if purchase else DELIVERY_NOTE_TITLE,
        number_label=format_internal_document_number(f"delivery_note_{direction}", delivery_note.get("number")),
        issued_on=delivery_note.get("issued_on") or today,
        valid_until=None,
        status_stamp="ANULADO" if delivery_note["status"] == "canceled" else None,
        issuer=issuer,
        recipient=CommercialRecipient(
            name=_text(client.get("name")) or (NO_SUPPLIER_NAME if purchase else NO_CLIENT_NAME),
            tax_id=_text(client.get("tax_id")),
            phone=_text(client.get("phone")),
            address=None if purchase else _text(delivery_note.get("delivery_address")),
        ),
        lines=tuple(_line(raw) for raw in lines),
        show_prices=show_prices,
        total=Decimal(str(delivery_note["total"])),
        notes=_text(delivery_note.get("notes")),
        legend=_DELIVERY_NOTE_LEGEND,
        signature_block=True,
        origin_label=f"{origin_verb}: {branch_name}" if branch_name else None,
        recipient_label=_PURCHASE_RECIPIENT_LABEL if purchase else _DEFAULT_RECIPIENT_LABEL,
        reference_label=f"Remito del proveedor N° {supplier_reference}" if supplier_reference else None,
    )
