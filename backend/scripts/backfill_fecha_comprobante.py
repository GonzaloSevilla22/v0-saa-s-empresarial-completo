"""factura-fiscal-imprimible — OQ-9: backfill de `fecha_comprobante` (procedimiento).

Completa la fecha con la que ARCA autorizó cada comprobante `authorized` que
no la tiene (los anteriores a este change), consultando `FECompConsultar`. La
lógica vive en `backend/services/fiscal/fecha_backfill.py` (con tests); este
archivo sólo arma la conexión y el adapter.

⚠ NO correr en producción sin el OK EXPLÍCITO del PO en el momento (task 9.2
del change): con `--apply` ESCRIBE en la base de producción y consulta a ARCA
real con el certificado de plataforma. Sin `--apply` es un ensayo: consulta y
reporta qué escribiría, sin tocar la base. El ensayo TAMBIÉN consulta ARCA
producción (sólo lectura: FECompConsultar vía `consultar_comprobante`, que no
autoriza nada ni loguea en CRITICAL): pedir el OK del PO también para el
ensayo.

Uso (la conexión es la del backend: DATABASE_URL; el adapter real se arma con
AFIP_PLATFORM_CERT/KEY/CUIT como el relay — sin certificado, el stub, que se
niega a consultar comprobantes de producción):

    python -m backend.scripts.backfill_fecha_comprobante            # ensayo
    python -m backend.scripts.backfill_fecha_comprobante --apply    # escribe

Salida: una línea por comprobante con su resultado (`would_write`, `written`,
`not_written`, `not_confirmed`, `cae_mismatch`, `fecha_unknown`). Exit code 0
si todos quedaron con fecha (o se escribirían); 1 si alguno quedó sin
confirmar. Anotar cada fecha obtenida en la ficha del change.
"""
from __future__ import annotations

import argparse
import asyncio
import os
import sys

import asyncpg

from backend.repositories.fiscal_document_repository import FiscalDocumentRepository
from backend.services.fiscal.adapter_factory import build_cae_adapter_from_settings
from backend.services.fiscal.fecha_backfill import backfill_fecha_comprobante

_OK = {"would_write", "written"}


async def _run(apply: bool) -> int:
    dsn = os.environ.get("DATABASE_URL")
    if not dsn:
        print("Falta DATABASE_URL.")
        return 2
    # DATABASE_URL apunta al pooler de Supabase (transaction mode): sin
    # `statement_cache_size=0` el segundo statement preparado choca con
    # DuplicatePreparedStatementError (mismo motivo que el pool de core/database.py).
    conn = await asyncpg.connect(dsn, statement_cache_size=0)
    try:
        report = await backfill_fecha_comprobante(
            FiscalDocumentRepository(conn), build_cae_adapter_from_settings(), apply=apply,
        )
    finally:
        await conn.close()

    print(f"{'APLICADO (escribe)' if apply else 'ENSAYO (sólo lectura: FECompConsultar, sin escribir)'} — {len(report)} comprobante(s) autorizados sin fecha")
    for row in report:
        print(f"  {row['comprobante']}  {row['doc_id']}  fecha={row['fecha']}  -> {row['result']}")
    return 0 if all(row["result"] in _OK for row in report) else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--apply", action="store_true", help="escribir las fechas confirmadas (default: ensayo)")
    args = parser.parse_args()
    return asyncio.run(_run(args.apply))


if __name__ == "__main__":
    sys.exit(main())
