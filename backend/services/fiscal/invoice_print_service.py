"""
factura-fiscal-imprimible (D9) — reglas del endpoint `GET /fiscal/documents/{id}/pdf`.

  * El comprobante se lee con `FiscalDocumentRepository.get_by_id(doc_id,
    account_id)`: filtro explícito por cuenta (además de la RLS de la conexión
    con JWT). Uno de otra cuenta llega como `None` y responde EXACTAMENTE igual
    que uno inexistente: 404 `fiscal_document_not_found`.
  * Sólo un `authorized` es una factura: `pending_cae` no tiene CAE;
    `rejected`/`voided` nunca la tendrán → 409 `fiscal_document_not_authorized`.
  * Todo lo que el generador rechaza (`InvoiceNotPrintable`) sale como 409 RFC
    7807 con su `code` estable, y `missing` cuando faltan datos del emisor.
  * Cualquier miembro de la cuenta que puede ver ventas puede imprimir (es
    una lectura): no hay guard de rol extra.
"""
from __future__ import annotations

import uuid

from backend.core.errors import ProblemHTTPException
from backend.repositories.fiscal_document_repository import FiscalDocumentRepository
from backend.repositories.fiscal_profile_repository import FiscalProfileRepository
from backend.services.fiscal.invoice_pdf import (
    InvoiceNotPrintable,
    build_invoice_view,
    render_invoice_pdf,
)


async def get_invoice_pdf(
    doc_repo: FiscalDocumentRepository,
    profile_repo: FiscalProfileRepository,
    account_id: str,
    doc_id: uuid.UUID,
    copy: str = "original",
) -> tuple[bytes, str]:
    """Devuelve (bytes del PDF, nombre de archivo) de la factura autorizada."""
    doc = await doc_repo.get_by_id(str(doc_id), account_id)
    if doc is None:
        raise ProblemHTTPException(
            status_code=404,
            detail="El comprobante no existe.",
            code="fiscal_document_not_found",
        )

    if doc.get("status") != "authorized":
        raise ProblemHTTPException(
            status_code=409,
            detail=(
                "El comprobante todavía no está autorizado por ARCA (o no lo estará): "
                "sin CAE no es una factura."
            ),
            code="fiscal_document_not_authorized",
        )

    invoice = await doc_repo.get_invoice_lines(str(doc_id), account_id)
    profile = await profile_repo.get_by_account_id(account_id)

    try:
        view = build_invoice_view(
            doc,
            profile,
            invoice["lines"],
            sale_condition_kind=invoice["sale_condition_kind"],
            copy=copy,
        )
    except InvoiceNotPrintable as exc:
        raise ProblemHTTPException(
            status_code=409,
            detail=exc.detail,
            code=exc.code,
            extensions={"missing": exc.missing} if exc.missing else None,
        ) from exc

    return render_invoice_pdf(view), view.filename
