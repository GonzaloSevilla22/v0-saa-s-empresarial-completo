"""
Comprobante interno de venta en PDF (`POST /sales/receipt-pdf`) —
documentos-marca-empresa D7, capability `document-branding`.

Antes el router armaba el `SalesReceiptData` con lo que MANDABA EL NAVEGADOR: el
nombre, el teléfono y el email de login del usuario logueado. Resultado: el mismo
comprobante salía distinto según quién lo descargara (un vendedor imprimía su
teléfono personal) e imprimía el email de acceso, justo lo que el presupuesto
prohíbe para un documento a terceros.

Ahora la MARCA —emisor resuelto por la cascada única, paleta, logo y leyenda al
pie— se resuelve acá, en el servidor, por la CUENTA del usuario autenticado
(`resolve_document_branding`, siempre por `rpc_commercial_issuer`). Los campos
`business_name`/`business_phone`/`business_email` del cuerpo se aceptan e IGNORAN
(contrato compatible: una pestaña abierta con el frontend anterior no recibe 422).

Qué se arma del cuerpo y qué no: las líneas, el total, el cliente y el número son
datos de la venta que el cliente de la API ya conoce (el comprobante es stateless
respecto de las ventas); el emisor NUNCA sale del cuerpo.
"""
from __future__ import annotations

import contextlib
import re

import asyncpg

from backend.core.errors import problem_from_pg_error
from backend.schemas.sales import SalesReceiptPdfIn
from backend.services.commercial_documents.branding import resolve_document_branding
from backend.services.receipts import SalesReceiptData, SalesReceiptItem, build_sales_receipt_pdf

_FILENAME_UNSAFE = re.compile(r"[^A-Za-z0-9_-]")
_DEFAULT_FILENAME_STEM = "comprobante"


@contextlib.contextmanager
def _pg_errors_as_problems():
    """Traduce los errores de negocio de la RPC a RFC 7807 (mismo patrón que presupuesto y remito)."""
    try:
        yield
    except asyncpg.PostgresError as exc:
        problem = problem_from_pg_error(exc)
        if problem is None:
            raise
        raise problem from exc


def _file_name(receipt_number: str) -> str:
    """`comprobante-<número>.pdf` con el número reducido a letras, dígitos, `_` y `-`:
    viene del navegador y va a una cabecera HTTP."""
    stem = _FILENAME_UNSAFE.sub("", receipt_number)
    return f"{_DEFAULT_FILENAME_STEM}-{stem}.pdf" if stem else f"{_DEFAULT_FILENAME_STEM}.pdf"


async def build_sale_receipt(repo, account_id: str, payload: SalesReceiptPdfIn) -> tuple[bytes, str]:
    """(bytes del PDF, nombre de archivo) del comprobante de venta de la cuenta."""
    with _pg_errors_as_problems():
        branding = await resolve_document_branding(repo, account_id)
    data = SalesReceiptData(
        branding=branding,
        receipt_number=payload.receipt_number,
        date_label=payload.date_label,
        items=[
            SalesReceiptItem(name=i.name, quantity=i.quantity, unit_price=i.unit_price, subtotal=i.subtotal)
            for i in payload.items
        ],
        total=payload.total,
        currency=payload.currency,
        client_name=payload.client_name,
    )
    return build_sales_receipt_pdf(data), _file_name(payload.receipt_number)
