"""
factura-fiscal-imprimible — OQ-9: backfill de `fiscal_documents.fecha_comprobante`.

Los comprobantes autorizados ANTES de este change no tienen la fecha con la que
ARCA los autorizó (no se persistía en ningún lado), y sin ella la factura no se
imprime (409 `invoice_date_unknown`): nunca con una fecha adivinada.

Este procedimiento la completa preguntándole a ARCA (`FECompConsultar`, vía el
mismo `reconcile_submitted` que usa el relay y que desde este change devuelve
`ResultGet.CbteFch`) y la escribe con la RPC interna
`rpc_fiscal_document_set_fecha_comprobante`, que sólo completa una fecha NULL
de un `authorized`.

Reglas (fail-closed): se escribe SÓLO si ARCA confirma el comprobante
(`authorized`), con el MISMO CAE que el guardado y una fecha legible. Cualquier
otra respuesta se reporta y no escribe nada.

⚠ GOVERNANCE (sign-off del PO 2026-09-26, OQ-9): implementado y documentado,
**NO ejecutado en prod** en el apply. Escribe en producción y consulta a ARCA
real con el certificado de plataforma: requiere el OK explícito del PO EN EL
MOMENTO (task 9.2). Por defecto corre en modo ensayo (`apply=False`). El
punto de entrada es `backend/scripts/backfill_fecha_comprobante.py`.
"""
from __future__ import annotations

import datetime
import logging
from typing import Protocol

from backend.services.fiscal.fiscal_document_port import CAERequest, FiscalDocumentPort

logger = logging.getLogger(__name__)


class _BackfillRepo(Protocol):
    async def list_authorized_without_fecha(self) -> list[dict]: ...

    async def set_fecha_comprobante(self, doc_id: str, fecha: datetime.date) -> bool: ...


def _cae_request(doc: dict) -> CAERequest:
    """El mismo pedido de dominio que arma el relay, para consultar a ARCA."""
    return CAERequest(
        account_id=str(doc["account_id"]),
        fiscal_document_id=str(doc["id"]),
        comprobante_type=doc["comprobante_type"],
        punto_de_venta=int(doc["punto_de_venta"]),
        number=int(doc["number"]),
        total=float(doc.get("total") or 0),
        cuit_emisor=str(doc.get("cuit") or ""),
        ambiente=doc.get("ambiente") or "homologacion",
    )


async def backfill_fecha_comprobante(
    repo: _BackfillRepo,
    adapter: FiscalDocumentPort,
    *,
    apply: bool = False,
) -> list[dict]:
    """Consulta ARCA por cada autorizado sin fecha y (con `apply`) la escribe.

    Devuelve un renglón por documento: `result` ∈ {`would_write`, `written`,
    `not_written`, `not_confirmed`, `cae_mismatch`, `fecha_unknown`}.
    """
    report: list[dict] = []
    for doc in await repo.list_authorized_without_fecha():
        doc_id = str(doc["id"])
        row = {
            "doc_id": doc_id,
            "comprobante": f"{int(doc['punto_de_venta']):04d}-{int(doc['number']):08d}",
            "fecha": None,
            "result": "not_confirmed",
        }
        rec = await adapter.reconcile_submitted(_cae_request(doc), requested_number=int(doc["number"]))

        if rec.outcome != "authorized":
            logger.warning("backfill fecha: %s no confirmado por ARCA (%s %s)",
                           row["comprobante"], rec.outcome, rec.error_code)
        elif str(rec.cae or "") != str(doc.get("cae") or ""):
            # ARCA tiene OTRO CAE para ese número: no es este comprobante.
            row["result"] = "cae_mismatch"
            logger.critical("backfill fecha: %s — el CAE de ARCA no coincide con el guardado; NO se escribe.",
                            row["comprobante"])
        elif rec.fecha_comprobante is None:
            row["result"] = "fecha_unknown"
        else:
            row["fecha"] = rec.fecha_comprobante
            if apply:
                written = await repo.set_fecha_comprobante(doc_id, rec.fecha_comprobante)
                row["result"] = "written" if written else "not_written"
            else:
                row["result"] = "would_write"
        report.append(row)
    return report
