"""
factura-fiscal-imprimible — OQ-9: backfill de `fecha_comprobante` de los
comprobantes autorizados ANTES de este change (implementado y documentado; NO
se ejecuta en prod sin el OK del PO en el momento: escribe en producción y
consulta a ARCA real).

Contrato del procedimiento (`services/fiscal/fecha_backfill.py`):
  * lista los `authorized` con `fecha_comprobante IS NULL` (con CUIT y ambiente
    del perfil, como el relay);
  * por cada uno consulta ARCA con `FECompConsultar` vía
    `consultar_comprobante` (la misma consulta que la reconciliación del relay,
    que desde este change devuelve la `ResultGet.CbteFch`, pero de sólo lectura:
    sin el CRITICAL de "se autoriza con ese CAE");
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
    adapter.consultar_comprobante = AsyncMock(side_effect=[ReconcileResponse(**r) for r in responses])
    # El backfill NO usa la reconciliación del relay (loguea CRITICAL "se
    # autoriza con ese CAE", falso acá): si la llamara, el test lo ve.
    adapter.reconcile_submitted = AsyncMock(side_effect=AssertionError("el backfill no reconcilia: consulta"))
    return adapter


OK = dict(outcome="authorized", cae="71234567890123", number=501,
          fecha_comprobante=datetime.date(2026, 9, 25))


class TestProcedimiento:

    @pytest.mark.asyncio
    async def test_ensayo_consulta_pero_no_escribe(self):
        from backend.services.fiscal.fecha_backfill import backfill_fecha_comprobante

        repo, adapter = _repo([_doc()]), _adapter(OK)

        report = await backfill_fecha_comprobante(repo, adapter)

        adapter.consultar_comprobante.assert_awaited_once()
        request, = adapter.consultar_comprobante.await_args.args
        assert adapter.consultar_comprobante.await_args.kwargs == {"number": 501}
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
        adapter.consultar_comprobante.assert_not_awaited()


class TestEnsayoEsSoloLectura:
    """Hallazgo del red team (2026-09-26): el ensayo reutilizaba
    `reconcile_submitted`, que loguea en CRITICAL que el documento "se autoriza
    con ese CAE" — falso en un backfill, y contamina la señal CRITICAL de la
    que depende la verificación de prod. El backfill usa
    `consultar_comprobante` (el mismo FECompConsultar, sin esa línea) y deja
    escrito en el log que es una consulta de sólo lectura."""

    @staticmethod
    async def _backfill_contra_wsfe(apply: bool):
        import types
        from unittest.mock import patch

        from backend.services.fiscal.fecha_backfill import backfill_fecha_comprobante
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        ns = types.SimpleNamespace
        adapter = WSFEAdapter(platform_provider=MagicMock())
        repo = _repo([_doc()])
        with (
            patch.object(WSFEAdapter, "_get_wsaa_token", AsyncMock(return_value=("tok", "sig"))),
            patch("zeep.Client") as mock_client_cls,
        ):
            client = MagicMock()
            mock_client_cls.return_value = client
            client.service.FECompConsultar.return_value = ns(ResultGet=ns(
                Resultado="A", CodAutorizacion="71234567890123", FchVto="20261005",
                CbteDesde=501, CbteFch="20260925",
            ))
            report = await backfill_fecha_comprobante(repo, adapter, apply=apply)
        return report, repo

    @pytest.mark.asyncio
    async def test_el_ensayo_no_loguea_critical_ni_dice_que_autoriza(self, caplog):
        import logging

        caplog.set_level(logging.DEBUG)
        report, repo = await self._backfill_contra_wsfe(apply=False)

        assert report[0]["result"] == "would_write"
        repo.set_fecha_comprobante.assert_not_awaited()
        assert [r.getMessage() for r in caplog.records if r.levelno >= logging.CRITICAL] == []
        assert not any("se autoriza con ese CAE" in r.getMessage() for r in caplog.records)
        mensajes = " | ".join(r.getMessage() for r in caplog.records)
        assert "ENSAYO" in mensajes and "sólo lectura" in mensajes and "FECompConsultar" in mensajes
        assert "no se escribe nada" in mensajes

    @pytest.mark.asyncio
    async def test_con_apply_el_log_dice_que_escribe(self, caplog):
        import logging

        caplog.set_level(logging.INFO)
        report, repo = await self._backfill_contra_wsfe(apply=True)

        assert report[0]["result"] == "written"
        repo.set_fecha_comprobante.assert_awaited_once_with(DOC_A, datetime.date(2026, 9, 25))
        assert [r.getMessage() for r in caplog.records if r.levelno >= logging.CRITICAL] == []
        mensajes = " | ".join(r.getMessage() for r in caplog.records)
        assert "APLICADO" in mensajes and "escribe" in mensajes

    @pytest.mark.asyncio
    async def test_la_reconciliacion_del_relay_sigue_en_critical(self, caplog):
        """Control: la señal CRITICAL del relay no se tocó."""
        import logging
        import types
        from unittest.mock import patch

        from backend.services.fiscal.wsfe_adapter import WSFEAdapter
        from backend.services.fiscal.fecha_backfill import _cae_request

        ns = types.SimpleNamespace
        adapter = WSFEAdapter(platform_provider=MagicMock())
        caplog.set_level(logging.DEBUG)
        with (
            patch.object(WSFEAdapter, "_get_wsaa_token", AsyncMock(return_value=("tok", "sig"))),
            patch("zeep.Client") as mock_client_cls,
        ):
            client = MagicMock()
            mock_client_cls.return_value = client
            client.service.FECompConsultar.return_value = ns(ResultGet=ns(
                Resultado="A", CodAutorizacion="71234567890123", FchVto="20261005",
                CbteDesde=501, CbteFch="20260925",
            ))
            rec = await adapter.reconcile_submitted(_cae_request(_doc()), requested_number=501)

        assert rec.outcome == "authorized"
        criticos = [r.getMessage() for r in caplog.records if r.levelno >= logging.CRITICAL]
        assert len(criticos) == 1 and "se autoriza con ese CAE" in criticos[0]

    @pytest.mark.asyncio
    async def test_la_consulta_por_defecto_del_port_es_fail_closed(self):
        """Un adapter que no la sobreescribe cae en su `reconcile_submitted`
        (y el default de ésta es `unknown`): nunca una fecha inventada."""
        from backend.services.fiscal.fecha_backfill import _cae_request
        from backend.services.fiscal.fiscal_document_port import FiscalDocumentPort

        class AdapterMinimo(FiscalDocumentPort):
            async def request_cae(self, invoice_data):  # pragma: no cover - no se llama
                raise NotImplementedError

        rec = await AdapterMinimo().consultar_comprobante(_cae_request(_doc()), number=501)

        assert rec.outcome == "unknown"
        assert rec.fecha_comprobante is None


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
