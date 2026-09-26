"""
factura-fiscal-imprimible — OQ-9: backfill de `fecha_comprobante` de los
comprobantes autorizados ANTES de este change (implementado y documentado; NO
se ejecuta en prod sin el OK del PO en el momento: escribe en producción y
consulta a ARCA real).

Contrato del procedimiento (`services/fiscal/fecha_backfill.py`):
  * lista los `authorized` con `fecha_comprobante IS NULL` (con CUIT y ambiente
    del perfil, como el relay);
  * por cada uno consulta ARCA con `FECompConsultar` (el mismo
    `reconcile_submitted` del relay, que desde este change devuelve la
    `ResultGet.CbteFch`);
  * escribe SÓLO si ARCA confirma el comprobante (`authorized`), con el MISMO
    CAE que el guardado y una fecha legible — nunca `created_at`, nunca "hoy";
  * por defecto es un ensayo (`apply=False`): consulta y reporta sin escribir.
"""
from __future__ import annotations

import datetime
from unittest.mock import AsyncMock, MagicMock

import pytest

DOC_A = "aaaaaaaa-0000-4000-8000-000000000001"
DOC_B = "aaaaaaaa-0000-4000-8000-000000000002"


def _doc(doc_id: str = DOC_A, **overrides) -> dict:
    base = {
        "id": doc_id,
        "account_id": "acc00000-0000-4000-8000-000000000000",
        "comprobante_type": "factura_c",
        "punto_de_venta": 3,
        "number": 501,
        "total": 32500,
        "cae": "71234567890123",
        "cuit": "20123456786",
        "ambiente": "produccion",
        "status": "authorized",
        "fecha_comprobante": None,
    }
    base.update(overrides)
    return base


def _repo(docs):
    repo = MagicMock()
    repo.list_authorized_without_fecha = AsyncMock(return_value=docs)
    repo.set_fecha_comprobante = AsyncMock(return_value=True)
    return repo


def _adapter(*responses):
    from backend.services.fiscal.fiscal_document_port import ReconcileResponse

    adapter = MagicMock()
    adapter.reconcile_submitted = AsyncMock(side_effect=[ReconcileResponse(**r) for r in responses])
    return adapter


OK = dict(outcome="authorized", cae="71234567890123", number=501,
          fecha_comprobante=datetime.date(2026, 9, 25))


class TestProcedimiento:

    @pytest.mark.asyncio
    async def test_ensayo_consulta_pero_no_escribe(self):
        from backend.services.fiscal.fecha_backfill import backfill_fecha_comprobante

        repo, adapter = _repo([_doc()]), _adapter(OK)

        report = await backfill_fecha_comprobante(repo, adapter)

        adapter.reconcile_submitted.assert_awaited_once()
        request, = adapter.reconcile_submitted.await_args.args
        assert adapter.reconcile_submitted.await_args.kwargs == {"requested_number": 501}
        assert (request.punto_de_venta, request.comprobante_type, request.cuit_emisor, request.ambiente) == (
            3, "factura_c", "20123456786", "produccion")
        repo.set_fecha_comprobante.assert_not_awaited()
        assert report == [{"doc_id": DOC_A, "comprobante": "0003-00000501",
                           "fecha": datetime.date(2026, 9, 25), "result": "would_write"}]

    @pytest.mark.asyncio
    async def test_con_apply_escribe_la_fecha_de_arca(self):
        from backend.services.fiscal.fecha_backfill import backfill_fecha_comprobante

        repo, adapter = _repo([_doc()]), _adapter(OK)

        report = await backfill_fecha_comprobante(repo, adapter, apply=True)

        repo.set_fecha_comprobante.assert_awaited_once_with(DOC_A, datetime.date(2026, 9, 25))
        assert report[0]["result"] == "written"

    @pytest.mark.asyncio
    async def test_la_rpc_que_no_escribe_se_reporta(self):
        """Otro proceso ya la completó (la RPC sólo escribe sobre NULL)."""
        from backend.services.fiscal.fecha_backfill import backfill_fecha_comprobante

        repo, adapter = _repo([_doc()]), _adapter(OK)
        repo.set_fecha_comprobante = AsyncMock(return_value=False)

        report = await backfill_fecha_comprobante(repo, adapter, apply=True)

        assert report[0]["result"] == "not_written"

    @pytest.mark.asyncio
    @pytest.mark.parametrize(
        ("respuesta", "motivo"),
        [
            (dict(outcome="unknown", error_code="RECONCILE_CALL_FAILED"), "not_confirmed"),
            (dict(outcome="not_found", ultimo_autorizado=500), "not_confirmed"),
            (dict(outcome="rejected"), "not_confirmed"),
            ({**OK, "cae": "79999999999999"}, "cae_mismatch"),
            ({**OK, "fecha_comprobante": None}, "fecha_unknown"),
        ],
    )
    async def test_nunca_escribe_sin_confirmacion_exacta(self, respuesta, motivo):
        from backend.services.fiscal.fecha_backfill import backfill_fecha_comprobante

        repo, adapter = _repo([_doc()]), _adapter(respuesta)

        report = await backfill_fecha_comprobante(repo, adapter, apply=True)

        repo.set_fecha_comprobante.assert_not_awaited()
        assert report[0]["result"] == motivo
        assert report[0]["fecha"] is None

    @pytest.mark.asyncio
    async def test_varios_documentos_independientes(self):
        from backend.services.fiscal.fecha_backfill import backfill_fecha_comprobante

        repo = _repo([_doc(DOC_A), _doc(DOC_B, number=2, punto_de_venta=1, cae="72222222222222")])
        adapter = _adapter(
            dict(outcome="unknown"),
            dict(outcome="authorized", cae="72222222222222", number=2,
                 fecha_comprobante=datetime.date(2026, 9, 20)),
        )

        report = await backfill_fecha_comprobante(repo, adapter, apply=True)

        assert [r["result"] for r in report] == ["not_confirmed", "written"]
        repo.set_fecha_comprobante.assert_awaited_once_with(DOC_B, datetime.date(2026, 9, 20))

    @pytest.mark.asyncio
    async def test_sin_pendientes_no_consulta_nada(self):
        from backend.services.fiscal.fecha_backfill import backfill_fecha_comprobante

        repo, adapter = _repo([]), _adapter()

        assert await backfill_fecha_comprobante(repo, adapter, apply=True) == []
        adapter.reconcile_submitted.assert_not_awaited()


class TestRepositorio:

    @pytest.mark.asyncio
    async def test_lista_los_autorizados_sin_fecha(self):
        from backend.repositories.fiscal_document_repository import FiscalDocumentRepository

        conn = AsyncMock()
        conn.fetch = AsyncMock(return_value=[])
        await FiscalDocumentRepository(conn).list_authorized_without_fecha()

        sql = " ".join(conn.fetch.await_args.args[0].split())
        assert "fd.status = 'authorized'" in sql
        assert "fd.fecha_comprobante IS NULL" in sql
        assert "JOIN public.fiscal_profiles fp ON fp.id = fd.fiscal_profile_id" in sql
        assert "fp.cuit" in sql and "fp.ambiente" in sql

    @pytest.mark.asyncio
    async def test_set_fecha_llama_la_rpc_interna(self):
        from backend.repositories.fiscal_document_repository import FiscalDocumentRepository

        conn = AsyncMock()
        conn.fetchval = AsyncMock(return_value=True)
        written = await FiscalDocumentRepository(conn).set_fecha_comprobante(DOC_A, datetime.date(2026, 9, 25))

        assert written is True
        query, *args = conn.fetchval.await_args.args
        assert "rpc_fiscal_document_set_fecha_comprobante($1::uuid, $2::date)" in query
        assert args == [DOC_A, datetime.date(2026, 9, 25)]
