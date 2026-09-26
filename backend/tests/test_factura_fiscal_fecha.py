"""
factura-fiscal-imprimible — grupo 2: la fecha del comprobante la confirma ARCA.

Hasta este change la fecha del comprobante (`CbteFch`) no se persistía en
ningún lado: el adapter armaba `datetime.date.today()` con el reloj del
servidor (UTC en Render) y la respuesta de ARCA se descartaba. La factura
impresa y su QR (RG 4892) necesitan esa fecha EXACTA, así que:

  * `CAEResponse` y `ReconcileResponse` ganan `fecha_comprobante`;
  * `FECAESolicitar`: la `CbteFch` de la respuesta de detalle; si ARCA no la
    trae (ausente o vacía), la que el adapter ENVIÓ (ARCA autorizó con esa);
    si la trae pero no se puede leer → None (nunca una fecha inventada) y el
    `Resultado='A'` sigue siendo una autorización;
  * `FECompConsultar`: SÓLO la `CbteFch` de `ResultGet` (el envío original
    pudo ser de otro día) — ausente o deforme → None;
  * el relay la pasa a `update_authorized`, que la manda como 5.º argumento de
    `rpc_fiscal_document_authorize`;
  * OQ-7 (firmada 2026-09-26): la fecha que se le PIDE a ARCA es la de
    Argentina (`America/Argentina/Mendoza`), no la del reloj UTC del servidor.

Design refs: D5, D11, "Notas de implementación del apply" del design.md.
"""
from __future__ import annotations

import datetime
import sys
import types
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

try:
    import fpdf  # noqa: F401
except ImportError:
    _fpdf_stub = types.ModuleType("fpdf")
    _fpdf_stub.FPDF = MagicMock  # type: ignore[attr-defined]
    sys.modules["fpdf"] = _fpdf_stub

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
DOC_ID = "dddddddd-dddd-dddd-dddd-dddddddddddd"

ns = types.SimpleNamespace

# 2026-09-26 02:30 UTC = 2026-09-25 23:30 en Argentina (UTC−3).
NOCHE_UTC = datetime.datetime(2026, 9, 26, 2, 30, tzinfo=datetime.timezone.utc)


# ── Helpers ───────────────────────────────────────────────────────────────────

def make_cae_request(**overrides):
    from backend.services.fiscal.fiscal_document_port import CAERequest

    base = dict(
        account_id=ACCOUNT_ID,
        fiscal_document_id=DOC_ID,
        comprobante_type="factura_c",
        punto_de_venta=3,
        number=501,
        total=32500.0,
        cuit_emisor="27213790337",
        ambiente="homologacion",
    )
    base.update(overrides)
    return CAERequest(**base)


def make_pending_doc(**overrides) -> dict:
    base = {
        "id": DOC_ID,
        "account_id": ACCOUNT_ID,
        "fiscal_profile_id": "pppppppp-pppp-pppp-pppp-pppppppppppp",
        "point_of_sale_id": "vvvvvvvv-vvvv-vvvv-vvvv-vvvvvvvvvvvv",
        "comprobante_type": "factura_c",
        "punto_de_venta": 3,
        "number": 501,
        "total": 32500.0,
        "status": "pending_cae",
        "attempts": 0,
        "cuit": "27213790337",
        "ambiente": "homologacion",
        "cae_submit_unconfirmed_at": None,
        "arca_requested_number": None,
        "cae_submit_started_at": None,
        "receptor_iva_condition": None,
    }
    base.update(overrides)
    return base


def make_repo() -> MagicMock:
    repo = MagicMock()
    repo.update_authorized = AsyncMock(return_value=True)
    repo.update_rejected = AsyncMock()
    repo.update_retry = AsyncMock()
    repo.freeze_unconfirmed = AsyncMock()
    repo.mark_submit_started = AsyncMock()
    repo.clear_submit_mark = AsyncMock(return_value=True)
    return repo


_SIN_CAMPO = object()


def _det_aprobado(cbte_fch: object = _SIN_CAMPO):
    """`FECAEDetResponse` aprobado con la forma real del WSDL.

    `SimpleNamespace` y no `MagicMock`: en un MagicMock `CbteFch` SIEMPRE
    existe, así que el caso "ARCA no la informa" no se podría escribir.
    """
    campos: dict = {
        "Resultado": "A",
        "CAE": "71234567890123",
        "CAEFchVto": "20261005",
        "CbteDesde": 501,
    }
    if cbte_fch is not _SIN_CAMPO:
        campos["CbteFch"] = cbte_fch
    return ns(**campos)


async def _request_cae(det, invoice=None):
    """Corre `request_cae` del adapter real con zeep mockeado.

    Devuelve (respuesta, det_request que salió en el FECAESolicitar).
    """
    from backend.services.fiscal.wsfe_adapter import WSFEAdapter

    adapter = WSFEAdapter(platform_provider=MagicMock())
    invoice = invoice or make_cae_request(fecha_comprobante=datetime.date(2026, 9, 25))
    enviado: dict = {}

    def _submit(**kwargs):
        enviado.update(kwargs["FeCAEReq"]["FeDetReq"]["FECAEDetRequest"][0])
        return ns(FeDetResp=ns(FECAEDetResponse=[det]))

    with (
        patch.object(WSFEAdapter, "_get_wsaa_token", AsyncMock(return_value=("tok", "sig"))),
        patch("zeep.Client") as mock_client_cls,
    ):
        mock_client = MagicMock()
        mock_client_cls.return_value = mock_client
        mock_client.service.FECompUltimoAutorizado.return_value = ns(CbteNro=500)
        mock_client.service.FECAESolicitar.side_effect = _submit
        response = await adapter.request_cae(invoice)

    return response, enviado


async def _reconcile(result_get):
    from backend.services.fiscal.wsfe_adapter import WSFEAdapter

    adapter = WSFEAdapter(platform_provider=MagicMock())
    with (
        patch.object(WSFEAdapter, "_get_wsaa_token", AsyncMock(return_value=("tok", "sig"))),
        patch("zeep.Client") as mock_client_cls,
    ):
        mock_client = MagicMock()
        mock_client_cls.return_value = mock_client
        mock_client.service.FECompConsultar.return_value = ns(ResultGet=result_get)
        return await adapter.reconcile_submitted(make_cae_request(), requested_number=501)


def _result_get(cbte_fch: object = _SIN_CAMPO):
    campos: dict = {
        "Resultado": "A",
        "CodAutorizacion": "71234567890123",
        "FchVto": "20261005",
        "CbteDesde": 501,
    }
    if cbte_fch is not _SIN_CAMPO:
        campos["CbteFch"] = cbte_fch
    return ns(**campos)


# ═══════════════════════════════════════════════════════════════════════════
# 2.1 / 2.3 — FECAESolicitar devuelve la fecha que ARCA confirmó
# ═══════════════════════════════════════════════════════════════════════════

class TestFechaEnFECAESolicitar:

    @pytest.mark.asyncio
    async def test_la_cbtefch_de_la_respuesta_se_devuelve(self):
        response, enviado = await _request_cae(_det_aprobado(cbte_fch="20260925"))

        assert response.is_approved is True
        assert response.fecha_comprobante == datetime.date(2026, 9, 25)
        assert enviado["CbteFch"] == "20260925"

    @pytest.mark.asyncio
    async def test_arca_es_la_fuente_de_verdad_de_la_fecha(self):
        """Triangulación: si ARCA devuelve otra fecha que la enviada, gana ARCA
        (mismo principio que el número en #580)."""
        response, enviado = await _request_cae(_det_aprobado(cbte_fch="20260924"))

        assert enviado["CbteFch"] == "20260925"
        assert response.fecha_comprobante == datetime.date(2026, 9, 24)

    @pytest.mark.asyncio
    async def test_sin_cbtefch_en_la_respuesta_vale_la_enviada(self):
        response, _ = await _request_cae(_det_aprobado())

        assert response.is_approved is True
        assert response.fecha_comprobante == datetime.date(2026, 9, 25)

    @pytest.mark.asyncio
    @pytest.mark.parametrize("vacia", ["", None, "   "])
    async def test_cbtefch_vacia_vale_la_enviada(self, vacia):
        response, _ = await _request_cae(_det_aprobado(cbte_fch=vacia))

        assert response.fecha_comprobante == datetime.date(2026, 9, 25)

    @pytest.mark.asyncio
    @pytest.mark.parametrize("deforme", ["25/09/2026", "2026-13-40", "hoy", 20260925.5])
    async def test_cbtefch_deforme_queda_none_y_no_rompe_la_autorizacion(self, deforme):
        """2.3: una fecha ilegible NUNCA convierte un `A` en error (el CAE es real
        y perderlo provocaría una segunda factura) ni se reemplaza por una
        inventada: queda None y el comprobante cae en el backfill (OQ-9)."""
        response, _ = await _request_cae(_det_aprobado(cbte_fch=deforme))

        assert response.is_approved is True
        assert response.cae == "71234567890123"
        assert response.number == 501
        assert response.fecha_comprobante is None

    @pytest.mark.asyncio
    async def test_cbtefch_numerica_entera_se_interpreta(self):
        """zeep puede entregar el campo como int si el WSDL lo tipa así."""
        response, _ = await _request_cae(_det_aprobado(cbte_fch=20260925))

        assert response.fecha_comprobante == datetime.date(2026, 9, 25)

    @pytest.mark.asyncio
    async def test_un_rechazo_no_trae_fecha(self):
        det = ns(
            Resultado="R",
            Observaciones=ns(Obs=[ns(Code=10016, Msg="numero")]),
            CbteFch="20260925",
        )
        response, _ = await _request_cae(det)

        assert response.is_approved is False
        assert response.fecha_comprobante is None


# ═══════════════════════════════════════════════════════════════════════════
# 2.1 / 2.3 — FECompConsultar: sólo la fecha de ResultGet
# ═══════════════════════════════════════════════════════════════════════════

class TestFechaEnReconciliacion:

    @pytest.mark.asyncio
    async def test_la_cbtefch_de_resultget_se_devuelve(self):
        rec = await _reconcile(_result_get(cbte_fch="20260925"))

        assert rec.outcome == "authorized"
        assert rec.fecha_comprobante == datetime.date(2026, 9, 25)

    @pytest.mark.asyncio
    async def test_sin_cbtefch_queda_none_nunca_hoy(self):
        """El envío original pudo ser de otro día: sin la fecha de ARCA no hay
        fecha, ni siquiera la de hoy."""
        rec = await _reconcile(_result_get())

        assert rec.outcome == "authorized"
        assert rec.fecha_comprobante is None

    @pytest.mark.asyncio
    async def test_cbtefch_deforme_no_descarta_el_cae(self):
        rec = await _reconcile(_result_get(cbte_fch="2026/09/25"))

        assert rec.outcome == "authorized"
        assert rec.cae == "71234567890123"
        assert rec.fecha_comprobante is None


# ═══════════════════════════════════════════════════════════════════════════
# 2.1 — El relay la pasa a update_authorized en los dos caminos
# ═══════════════════════════════════════════════════════════════════════════

class TestProcessorPropagaLaFecha:

    @pytest.mark.asyncio
    async def test_camino_normal(self):
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor
        from backend.services.fiscal.fiscal_document_port import CAEResponse
        from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter

        adapter = WSFEStubAdapter()
        adapter.request_cae = AsyncMock(return_value=CAEResponse(
            cae="71234567890123",
            cae_due_date=datetime.date(2026, 10, 5),
            is_approved=True,
            number=501,
            fecha_comprobante=datetime.date(2026, 9, 25),
        ))
        repo = make_repo()

        await CAERelayProcessor(adapter=adapter, repo=repo).process_document(make_pending_doc())

        repo.update_authorized.assert_awaited_once_with(
            doc_id=DOC_ID,
            cae="71234567890123",
            cae_due_date=datetime.date(2026, 10, 5),
            number=501,
            fecha_comprobante=datetime.date(2026, 9, 25),
        )

    @pytest.mark.asyncio
    async def test_camino_normal_sin_fecha_pasa_none(self):
        """Triangulación: una respuesta sin fecha legible autoriza igual."""
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor
        from backend.services.fiscal.fiscal_document_port import CAEResponse
        from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter

        adapter = WSFEStubAdapter()
        adapter.request_cae = AsyncMock(return_value=CAEResponse(
            cae="71234567890123",
            cae_due_date=datetime.date(2026, 10, 5),
            is_approved=True,
            number=501,
        ))
        repo = make_repo()

        await CAERelayProcessor(adapter=adapter, repo=repo).process_document(make_pending_doc())

        assert repo.update_authorized.await_args.kwargs["fecha_comprobante"] is None

    @pytest.mark.asyncio
    async def test_camino_de_reconciliacion(self):
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor
        from backend.services.fiscal.fiscal_document_port import ReconcileResponse

        adapter = MagicMock()
        adapter.request_cae = AsyncMock()
        adapter.reconcile_submitted = AsyncMock(return_value=ReconcileResponse(
            outcome="authorized",
            cae="71234567890123",
            cae_due_date=datetime.date(2026, 10, 5),
            number=501,
            fecha_comprobante=datetime.date(2026, 9, 25),
        ))
        repo = make_repo()
        doc = make_pending_doc(
            cae_submit_started_at=datetime.datetime.now(datetime.timezone.utc),
            arca_requested_number=501,
        )

        await CAERelayProcessor(adapter=adapter, repo=repo).process_document(doc)

        adapter.request_cae.assert_not_called()
        repo.update_authorized.assert_awaited_once_with(
            doc_id=DOC_ID,
            cae="71234567890123",
            cae_due_date=datetime.date(2026, 10, 5),
            number=501,
            fecha_comprobante=datetime.date(2026, 9, 25),
        )


# ═══════════════════════════════════════════════════════════════════════════
# 2.1 — El repositorio manda la fecha como 5.º argumento
# ═══════════════════════════════════════════════════════════════════════════

class TestRepositorioQuintoArgumento:

    @pytest.mark.asyncio
    async def test_update_authorized_manda_la_fecha(self):
        from backend.repositories.fiscal_document_repository import FiscalDocumentRepository

        conn = AsyncMock()
        conn.fetchval = AsyncMock(return_value=True)

        matched = await FiscalDocumentRepository(conn).update_authorized(
            doc_id=DOC_ID,
            cae="71234567890123",
            cae_due_date=datetime.date(2026, 10, 5),
            number=501,
            fecha_comprobante=datetime.date(2026, 9, 25),
        )

        assert matched is True
        query, *args = conn.fetchval.await_args.args
        assert "rpc_fiscal_document_authorize" in query
        assert "$5::date" in query
        assert args == [DOC_ID, "71234567890123", datetime.date(2026, 10, 5), 501,
                        datetime.date(2026, 9, 25)]

    @pytest.mark.asyncio
    async def test_sin_fecha_manda_null(self):
        from backend.repositories.fiscal_document_repository import FiscalDocumentRepository

        conn = AsyncMock()
        conn.fetchval = AsyncMock(return_value=True)

        await FiscalDocumentRepository(conn).update_authorized(
            doc_id=DOC_ID, cae="71234567890123", cae_due_date=datetime.date(2026, 10, 5),
        )

        _query, *args = conn.fetchval.await_args.args
        assert args == [DOC_ID, "71234567890123", datetime.date(2026, 10, 5), None, None]


# ═══════════════════════════════════════════════════════════════════════════
# 2.2 — El stub devuelve la fecha que recibió
# ═══════════════════════════════════════════════════════════════════════════

class TestStub:

    @pytest.mark.asyncio
    async def test_el_stub_devuelve_la_fecha_recibida(self):
        from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter

        response = await WSFEStubAdapter().request_cae(
            make_cae_request(fecha_comprobante=datetime.date(2026, 9, 25))
        )

        assert response.is_approved is True
        assert response.fecha_comprobante == datetime.date(2026, 9, 25)

    @pytest.mark.asyncio
    async def test_la_reconciliacion_del_stub_devuelve_la_misma_fecha(self):
        from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter

        stub = WSFEStubAdapter()
        invoice = make_cae_request(fecha_comprobante=datetime.date(2026, 9, 24))
        await stub.request_cae(invoice)

        rec = await stub.reconcile_submitted(invoice, requested_number=501)

        assert rec.outcome == "authorized"
        assert rec.fecha_comprobante == datetime.date(2026, 9, 24)


# ═══════════════════════════════════════════════════════════════════════════
# 2.4 — OQ-7: la fecha que se le pide a ARCA es la de Argentina
# ═══════════════════════════════════════════════════════════════════════════

class TestFechaArgentina:

    @pytest.mark.parametrize(
        ("instante_utc", "esperada"),
        [
            (NOCHE_UTC, datetime.date(2026, 9, 25)),
            (datetime.datetime(2026, 9, 26, 2, 59, 59, tzinfo=datetime.timezone.utc),
             datetime.date(2026, 9, 25)),
            (datetime.datetime(2026, 9, 26, 3, 0, 0, tzinfo=datetime.timezone.utc),
             datetime.date(2026, 9, 26)),
            (datetime.datetime(2026, 9, 25, 15, 35, tzinfo=datetime.timezone.utc),
             datetime.date(2026, 9, 25)),
        ],
    )
    def test_hoy_en_argentina(self, instante_utc, esperada):
        from backend.core.timezone import today_in_argentina

        assert today_in_argentina(instante_utc) == esperada

    def test_un_instante_sin_zona_se_rechaza(self):
        """Un datetime naive es ambiguo (¿UTC? ¿local?): no se adivina."""
        from backend.core.timezone import today_in_argentina

        with pytest.raises(ValueError):
            today_in_argentina(datetime.datetime(2026, 9, 26, 2, 30))

    def test_sin_base_de_zonas_cae_a_utc_menos_3(self):
        """Windows sin `tzdata`: la regla vigente de Argentina (UTC−3 fijo, sin
        horario de verano desde 2009) da el mismo resultado."""
        import zoneinfo

        from backend.core import timezone as tz

        with patch.object(tz.zoneinfo, "ZoneInfo", side_effect=zoneinfo.ZoneInfoNotFoundError("x")):
            assert tz.today_in_argentina(NOCHE_UTC) == datetime.date(2026, 9, 25)

    def test_la_zona_es_la_de_mendoza(self):
        from backend.core.timezone import ARGENTINA_TZ_NAME

        assert ARGENTINA_TZ_NAME == "America/Argentina/Mendoza"

    @pytest.mark.asyncio
    async def test_el_relay_pide_la_fecha_argentina_de_noche(self):
        """Escenario del delta: servidor en UTC, 02:30 UTC → CbteFch 20260925."""
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor
        from backend.services.fiscal.fiscal_document_port import CAEResponse
        from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter

        capturado: list = []

        async def _request(invoice):
            capturado.append(invoice)
            return CAEResponse(cae="71234567890123", cae_due_date=datetime.date(2026, 10, 5),
                               is_approved=True, number=501)

        adapter = WSFEStubAdapter()
        adapter.request_cae = _request

        with patch("backend.core.timezone._utcnow", return_value=NOCHE_UTC):
            await CAERelayProcessor(adapter=adapter, repo=make_repo()).process_document(
                make_pending_doc()
            )

        assert capturado[0].fecha_comprobante == datetime.date(2026, 9, 25)

    @pytest.mark.asyncio
    async def test_el_adapter_sin_fecha_usa_la_argentina(self):
        """Defensa en profundidad: un caller que no pase fecha tampoco depende
        del reloj UTC del servidor."""
        with patch("backend.core.timezone._utcnow", return_value=NOCHE_UTC):
            response, enviado = await _request_cae(_det_aprobado(), invoice=make_cae_request())

        assert enviado["CbteFch"] == "20260925"
        assert response.fecha_comprobante == datetime.date(2026, 9, 25)
