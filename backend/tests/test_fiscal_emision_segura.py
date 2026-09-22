"""
fiscal-emision-segura (governance CRÍTICO) — candados de los tres hallazgos.

Contexto (por qué existe este archivo):
  El disparo inmediato de `POST /fiscal/documents/emit*` instanciaba el
  **stub** del adapter (`WSFEStubAdapter`), que devuelve `is_approved=True` con
  un CAE inventado. Lo único que lo desarmaba era un `AttributeError` de tipo
  (`uuid.UUID` no tiene `.encode()`). Si ese camino corriera, un CAE ficticio
  quedaría escrito en un comprobante de PRODUCCIÓN y el documento pasaría a
  `authorized`, que es estado terminal: el cron nunca lo volvería a mirar.

Grupos:
  G1 — se retiran los caminos de emisión que no se pueden defender:
       el disparo inmediato y `POST /fiscal/documents/process-pending`
       (4.º camino, con adapter REAL y sin `claim_pending`).
  G2 — defensa en profundidad: el stub se niega en `produccion` y el processor
       no llama a un adapter que no sea el real para un doc de producción.
       Ninguno de los dos delega en el otro ("un guard que delega no es guard").
  G3 — el número que ARCA autoriza se PERSISTE (hoy se descarta).
  G4 — un envío a ARCA no confirmado CONGELA el documento en vez de
       reintentarse a ciegas pidiendo un número nuevo (doble factura real).
  G5 — consumidor final (DocTipo 99) en el pago de suscripción.

El único camino de emisión que queda es el cron
(`POST /fiscal/documents/process-pending-cron`).
"""
from __future__ import annotations

import datetime
import json
import sys
import types
import uuid
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Stub fpdf BEFORE any import of backend.main (dep faltante pre-existente).
# Mismo patrón que test_c27_cae_relay_trigger.py / test_c28_cash_session.py.
# ---------------------------------------------------------------------------
try:
    import fpdf  # noqa: F401
except ImportError:
    _fpdf_stub = types.ModuleType("fpdf")
    _fpdf_stub.FPDF = MagicMock  # type: ignore[attr-defined]
    sys.modules["fpdf"] = _fpdf_stub

from backend.tests.conftest import TEST_ACCOUNT_ID, make_token  # noqa: E402

ACCOUNT_ID = str(TEST_ACCOUNT_ID)
DOC_ID = "dddddddd-dddd-dddd-dddd-dddddddddddd"


# ── Helpers ───────────────────────────────────────────────────────────────────

def make_pending_doc(**overrides) -> dict:
    """Doc `pending_cae` con la forma que devuelve rpc_fiscal_document_claim_pending."""
    base = {
        "id": DOC_ID,
        "account_id": ACCOUNT_ID,
        "fiscal_profile_id": "pppppppp-pppp-pppp-pppp-pppppppppppp",
        "point_of_sale_id": "vvvvvvvv-vvvv-vvvv-vvvv-vvvvvvvvvvvv",
        "comprobante_type": "factura_c",
        "punto_de_venta": 3,
        "number": 7,
        "total": 1500.0,
        "status": "pending_cae",
        "cae": None,
        "cae_due_date": None,
        "attempts": 0,
        "next_attempt_at": None,
        "last_error": None,
        "cuit": "20123456789",
        "ambiente": "homologacion",
        "cae_submit_unconfirmed_at": None,
        "arca_requested_number": None,
    }
    base.update(overrides)
    return base


def make_repo() -> MagicMock:
    repo = MagicMock()
    repo.update_authorized = AsyncMock()
    repo.update_rejected = AsyncMock()
    repo.update_retry = AsyncMock()
    repo.freeze_unconfirmed = AsyncMock()
    return repo


# ═══════════════════════════════════════════════════════════════════════════
# G1 — No queda ningún camino de emisión fuera del cron
# ═══════════════════════════════════════════════════════════════════════════

class TestNoHayDisparoInmediato:
    """1.1-1.3: ni `emit` ni `emit-subscription-payment` programan trabajo de
    fondo, y el 4.º camino de emisión (`process-pending`) ya no existe."""

    @pytest.mark.asyncio
    async def test_emit_no_programa_background_task(self, async_client, mock_pool):
        """POST /fiscal/documents/emit NO programa ninguna BackgroundTask.

        Falla antes de G1: routers/fiscal.py:279 hacía
        `background_tasks.add_task(process_doc_by_id_background, doc_id)`.
        """
        pool, conn = mock_pool
        emit_result = {
            "id": DOC_ID,
            "fiscal_document_id": DOC_ID,
            "status": "pending_cae",
            "comprobante_type": "factura_b",
            "number": 1,
        }
        conn.fetchrow = AsyncMock(return_value={"result": json.dumps(emit_result)})
        owner_token = make_token({"role": "user"})

        with (
            patch("backend.core.database.pool", pool),
            patch("starlette.background.BackgroundTasks.add_task") as add_task,
        ):
            resp = await async_client.post(
                "/fiscal/documents/emit",
                json={"comprobante_type": "factura_b", "total": 1500.0},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200, resp.text
        add_task.assert_not_called()

    @pytest.mark.asyncio
    async def test_emit_subscription_no_programa_background_task(self, async_client, mock_pool):
        """POST /fiscal/documents/emit-subscription-payment tampoco programa nada.

        Falla antes de G1: routers/fiscal.py:307.
        """
        pool, conn = mock_pool
        rpc_result = {
            "fiscal_document_id": DOC_ID,
            "status": "pending_cae",
            "comprobante_type": "factura_c",
            "number": 2,
            "total": 12000.0,
        }
        conn.fetchrow = AsyncMock(
            side_effect=[None, {"result": json.dumps(rpc_result)}]
        )
        conn.fetchval = AsyncMock(return_value="admin")
        admin_token = make_token({"role": "admin"})

        with (
            patch("backend.core.database.pool", pool),
            patch("starlette.background.BackgroundTasks.add_task") as add_task,
        ):
            resp = await async_client.post(
                "/fiscal/documents/emit-subscription-payment",
                json={
                    "receipt_id": "receipt-001",
                    "receptor_doc_tipo": 80,
                    "receptor_doc_nro": "20422662457",
                },
                headers={"Authorization": f"Bearer {admin_token}"},
            )

        assert resp.status_code == 201, resp.text
        add_task.assert_not_called()

    @pytest.mark.asyncio
    async def test_process_pending_endpoint_no_existe(self, async_client, mock_pool):
        """POST /fiscal/documents/process-pending → 404.

        Era el 4.º camino de emisión: construía el adapter REAL
        (build_cae_adapter_from_settings) y NO llamaba claim_pending. Sin caller
        en el frontend, pero expuesto a cualquier JWT válido.
        """
        pool, _conn = mock_pool
        token = make_token({"role": "user"})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/fiscal/documents/process-pending",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 404, (
            f"El endpoint sigue existiendo (status {resp.status_code}): {resp.text}"
        )

    def test_no_queda_sujeto_del_disparo_inmediato(self):
        """El helper del disparo inmediato y el del 4.º camino ya no existen.

        Candado estructural: sin esto, alguien podría dejar la función viva
        (y con el stub adentro) aunque ningún endpoint la llame hoy.
        """
        from backend.services.fiscal import fiscal_profile_service as svc

        assert not hasattr(svc, "process_doc_by_id_background"), (
            "process_doc_by_id_background sigue vivo: es el que instanciaba "
            "WSFEStubAdapter() a mano y podía escribir un CAE falso."
        )
        assert not hasattr(svc, "process_pending_documents"), (
            "process_pending_documents sigue vivo: emitía sin claim_pending."
        )

    def test_el_cron_sigue_siendo_el_camino_de_emision(self):
        """1.5 TRIANGULACIÓN: el batch cross-account del cron sigue intacto."""
        from backend.services.fiscal import fiscal_profile_service as svc

        assert hasattr(svc, "process_all_pending_documents"), (
            "process_all_pending_documents es el ÚNICO camino de emisión que "
            "debe quedar — no se toca."
        )


# ═══════════════════════════════════════════════════════════════════════════
# G2 — El stub no puede escribir un CAE en producción (defensa en profundidad)
# ═══════════════════════════════════════════════════════════════════════════

def make_cae_request(**overrides):
    from backend.services.fiscal.fiscal_document_port import CAERequest

    base = dict(
        account_id=ACCOUNT_ID,
        fiscal_document_id=DOC_ID,
        comprobante_type="factura_c",
        punto_de_venta=3,
        number=7,
        total=12000.0,
        cuit_emisor="20422662457",
        ambiente="homologacion",
    )
    base.update(overrides)
    return CAERequest(**base)


class TestStubNuncaEnProduccion:
    """2.1-2.4: dos capas independientes, ninguna delegando en la otra.

    El stub cubre cualquier CALLER futuro; el guard del processor cubre
    cualquier ADAPTER futuro (allow-list del real, no deny-list del stub).
    """

    @pytest.mark.asyncio
    async def test_stub_rechaza_produccion(self):
        """2.1 RED: el stub NUNCA devuelve un CAE para un doc de producción."""
        from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter

        resp = await WSFEStubAdapter().request_cae(make_cae_request(ambiente="produccion"))

        assert resp.is_approved is False
        assert resp.error_code == "STUB_FORBIDDEN_IN_PRODUCTION"
        assert resp.cae is None
        assert resp.cae_due_date is None

    @pytest.mark.asyncio
    async def test_stub_sigue_funcionando_en_homologacion(self):
        """2.2 TRIANGULACIÓN: en homologación el stub sigue dando su CAE de 14 dígitos."""
        from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter

        resp = await WSFEStubAdapter().request_cae(make_cae_request(ambiente="homologacion"))

        assert resp.is_approved is True
        assert resp.cae is not None
        assert len(resp.cae) == 14 and resp.cae.isdigit()
        assert resp.error_code is None

    @pytest.mark.asyncio
    async def test_processor_no_llama_stub_para_doc_de_produccion(self):
        """2.3 RED: el processor no llama a un adapter que no sea el real si el
        documento es de producción — ni siquiera para preguntarle."""
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor
        from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter

        repo = make_repo()
        stub = WSFEStubAdapter()
        spy = MagicMock(wraps=stub.request_cae)
        processor = CAERelayProcessor(adapter=stub, repo=repo)

        with patch.object(WSFEStubAdapter, "request_cae", spy):
            await processor.process_document(make_pending_doc(ambiente="produccion"))

        spy.assert_not_called()
        repo.update_authorized.assert_not_called()
        repo.update_rejected.assert_not_called()
        repo.update_retry.assert_awaited_once()
        last_error = repo.update_retry.await_args.kwargs["last_error"]
        assert "produccion" in last_error
        assert "STUB_FORBIDDEN_IN_PRODUCTION" in last_error
        assert "WSFEStubAdapter" in last_error

    @pytest.mark.asyncio
    async def test_processor_si_autoriza_produccion_con_el_adapter_real(self):
        """2.4 TRIANGULACIÓN: el guard discrimina por TIPO de adapter, no bloquea
        producción en general. Con el adapter real, un doc de producción se autoriza."""
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor
        from backend.services.fiscal.fiscal_document_port import CAEResponse
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        real = MagicMock(spec=WSFEAdapter)
        real.request_cae = AsyncMock(
            return_value=CAEResponse(
                cae="86250464989491",
                cae_due_date=datetime.date(2026, 12, 31),
                is_approved=True,
            )
        )
        repo = make_repo()
        processor = CAERelayProcessor(adapter=real, repo=repo)

        await processor.process_document(make_pending_doc(ambiente="produccion"))

        real.request_cae.assert_awaited_once()
        repo.update_authorized.assert_awaited_once()
        repo.update_retry.assert_not_called()

    def test_la_factory_documenta_que_su_gate_no_es_el_ambiente(self):
        """2.5: el gate de la factory es "¿hay cert de plataforma?", NO "¿este
        documento es de producción?". Sin este recordatorio, alguien puede leer
        la factory como si ya cubriera el ambiente — y no lo hace: sin cert de
        plataforma, un doc de PRODUCCIÓN recibe el stub."""
        from backend.services.fiscal import adapter_factory

        doc = adapter_factory.build_cae_adapter.__doc__ or ""
        assert "ambiente" in doc.lower(), (
            "El docstring de build_cae_adapter debe decir explícitamente que su "
            "gate NO mira el ambiente del documento."
        )


# ═══════════════════════════════════════════════════════════════════════════
# G3 — El número que ARCA autorizó se persiste
# ═══════════════════════════════════════════════════════════════════════════

class TestNumeroAutoritativo:
    """3.4-3.5: el número confirmado por ARCA llega desde el adapter hasta la RPC.

    R6 del plan: el desfasaje no es hipotético. Prod tiene dos fiscal_profiles con
    el MISMO CUIT y el mismo PV activo; ARCA numera por (CUIT, PtoVta, CbteTipo) y
    `document_sequences` por point_of_sale_id, que es distinto en cada perfil. La
    primera factura_c del segundo perfil reservará el 1 mientras ARCA está en 2.
    """

    @pytest.mark.asyncio
    async def test_processor_pasa_el_numero_a_update_authorized(self):
        """3.4 RED: el processor propaga response.number a update_authorized."""
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor
        from backend.services.fiscal.fiscal_document_port import CAEResponse
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        real = MagicMock(spec=WSFEAdapter)
        real.request_cae = AsyncMock(
            return_value=CAEResponse(
                cae="86250464989491",
                cae_due_date=datetime.date(2026, 12, 31),
                is_approved=True,
                number=51,
            )
        )
        repo = make_repo()
        processor = CAERelayProcessor(adapter=real, repo=repo)

        await processor.process_document(make_pending_doc(number=42))

        kwargs = repo.update_authorized.await_args.kwargs
        assert kwargs["number"] == 51, (
            "El processor debe pasar el número que ARCA confirmó, no el local."
        )

    @pytest.mark.asyncio
    async def test_update_authorized_llama_la_rpc_con_4_args(self):
        """3.5 RED: el repo llama rpc_fiscal_document_authorize con 4 parámetros."""
        from backend.repositories.fiscal_document_repository import FiscalDocumentRepository

        conn = AsyncMock()
        conn.execute = AsyncMock(return_value="SELECT 1")
        repo = FiscalDocumentRepository(conn)

        await repo.update_authorized(
            doc_id=DOC_ID,
            cae="86250464989491",
            cae_due_date=datetime.date(2026, 12, 31),
            number=51,
        )

        conn.execute.assert_awaited_once()
        args = conn.execute.await_args.args
        query = args[0]
        assert "rpc_fiscal_document_authorize" in query
        assert "$4" in query, f"La query debe pasar 4 parámetros; got: {query}"
        assert args[1:] == (DOC_ID, "86250464989491", datetime.date(2026, 12, 31), 51)

    @pytest.mark.asyncio
    async def test_update_authorized_acepta_number_ausente(self):
        """3.5 TRIANGULACIÓN: `number` es opcional — un caller que no lo pase manda
        NULL, y la RPC (p_number DEFAULT NULL) se comporta como antes.

        Esto es lo que sostiene la ventana de despliegue: el merge aplica la
        migración antes de que Render termine de desplegar el backend nuevo.
        """
        from backend.repositories.fiscal_document_repository import FiscalDocumentRepository

        conn = AsyncMock()
        conn.execute = AsyncMock(return_value="SELECT 1")
        repo = FiscalDocumentRepository(conn)

        await repo.update_authorized(
            doc_id=DOC_ID, cae="86250464989491", cae_due_date=datetime.date(2026, 12, 31)
        )

        assert conn.execute.await_args.args[4] is None


# ═══════════════════════════════════════════════════════════════════════════
# G4 — Un envío no confirmado congela el documento (nunca se reintenta a ciegas)
# ═══════════════════════════════════════════════════════════════════════════

def _make_invoice_for_adapter(local_number: int = 42):
    return make_cae_request(
        number=local_number,
        comprobante_type="factura_c",
        punto_de_venta=3,
        ambiente="homologacion",
    )


class TestSubmitNoConfirmado:
    """4.1-4.6: el escenario catastrófico del dominio.

    Si el `FECAESolicitar` SALE y su resultado nunca se confirma (timeout de red,
    respuesta inesperada), ARCA puede haber autorizado la factura. Reintentar
    pide `FECompUltimoAutorizado+1` —que ya avanzó— y emite una SEGUNDA factura
    real por el camino feliz del backoff, sin ninguna excepción visible. El
    documento se CONGELA.
    """

    @pytest.mark.asyncio
    async def test_timeout_en_fecaesolicitar_marca_submitted(self):
        """4.1 RED: timeout DESPUÉS de mandar el pedido → CAE_SUBMIT_UNCONFIRMED."""
        import requests
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        adapter = WSFEAdapter(platform_provider=MagicMock())
        invoice = _make_invoice_for_adapter(local_number=42)

        with (
            patch.object(WSFEAdapter, "_get_wsaa_token", AsyncMock(return_value=("tok", "sig"))),
            patch("zeep.Client") as mock_client_cls,
        ):
            mock_client = MagicMock()
            mock_client_cls.return_value = mock_client
            mock_client.service.FECompUltimoAutorizado.return_value = MagicMock(CbteNro=50)
            mock_client.service.FECAESolicitar.side_effect = requests.exceptions.ReadTimeout(
                "HTTPSConnectionPool(host=wswhomo.afip.gob.ar, port=443): Read timed out."
            )

            resp = await adapter.request_cae(invoice)

        assert resp.is_approved is False
        assert resp.error_code == "CAE_SUBMIT_UNCONFIRMED"
        assert resp.submitted is True
        assert resp.number == 51, (
            "El número PEDIDO tiene que viajar en la respuesta: es el único dato "
            "con el que un humano puede consultar en ARCA si la factura existe."
        )

    @pytest.mark.asyncio
    async def test_fallo_antes_de_submit_no_marca_submitted(self):
        """4.2 TRIANGULACIÓN: el fallo ocurre ANTES del pedido → error normal.

        Este test es el que le da sentido al guard: sin él, cualquier fallo de
        red previo al FECAESolicitar congelaría documentos que nunca pidieron CAE.
        """
        import requests
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        adapter = WSFEAdapter(platform_provider=MagicMock())
        invoice = _make_invoice_for_adapter(local_number=42)

        with (
            patch.object(WSFEAdapter, "_get_wsaa_token", AsyncMock(return_value=("tok", "sig"))),
            patch("zeep.Client") as mock_client_cls,
        ):
            mock_client = MagicMock()
            mock_client_cls.return_value = mock_client
            mock_client.service.FECompUltimoAutorizado.side_effect = (
                requests.exceptions.ReadTimeout("Read timed out.")
            )

            resp = await adapter.request_cae(invoice)

        assert resp.is_approved is False
        assert resp.error_code == "WSFE_ERROR"
        assert resp.submitted is False
        mock_client.service.FECAESolicitar.assert_not_called()

    @pytest.mark.asyncio
    async def test_respuesta_imparseable_marca_submitted(self):
        """4.2b TRIANGULACIÓN: una respuesta que no se puede parsear TAMBIÉN es un
        envío no confirmado — es el caso que el segundo estudio describió mal
        (creía que abortaba el batch) y que en realidad terminaba en un
        `update_retry` normal, o sea en una segunda factura real."""
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        adapter = WSFEAdapter(platform_provider=MagicMock())
        invoice = _make_invoice_for_adapter(local_number=42)

        # Respuesta sin FeDetResp → AttributeError al parsear
        garbage = MagicMock(spec=[])

        with (
            patch.object(WSFEAdapter, "_get_wsaa_token", AsyncMock(return_value=("tok", "sig"))),
            patch("zeep.Client") as mock_client_cls,
        ):
            mock_client = MagicMock()
            mock_client_cls.return_value = mock_client
            mock_client.service.FECompUltimoAutorizado.return_value = MagicMock(CbteNro=50)
            mock_client.service.FECAESolicitar.return_value = garbage

            resp = await adapter.request_cae(invoice)

        assert resp.is_approved is False
        assert resp.error_code == "CAE_SUBMIT_UNCONFIRMED"
        assert resp.submitted is True
        assert resp.number == 51

    @pytest.mark.asyncio
    async def test_error_de_delegacion_en_el_submit_no_congela(self):
        """4.2c TRIANGULACIÓN (refinamiento sobre el plan): un rechazo de ARCA por
        delegación no autorizada es una NO-emisión CONFIRMADA (ARCA rechazó la
        autenticación, no procesó el comprobante). Sigue siendo reintentable y
        NO congela — si congelara, cada cuenta que todavía no autorizó a
        Aliadata en ARCA acumularía documentos que requieren trabajo manual."""
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        adapter = WSFEAdapter(platform_provider=MagicMock())
        invoice = _make_invoice_for_adapter(local_number=42)

        with (
            patch.object(WSFEAdapter, "_get_wsaa_token", AsyncMock(return_value=("tok", "sig"))),
            patch("zeep.Client") as mock_client_cls,
        ):
            mock_client = MagicMock()
            mock_client_cls.return_value = mock_client
            mock_client.service.FECompUltimoAutorizado.return_value = MagicMock(CbteNro=50)
            mock_client.service.FECAESolicitar.side_effect = RuntimeError(
                "El representante no está autorizado a actuar en nombre del CUIT"
            )

            resp = await adapter.request_cae(invoice)

        assert resp.is_approved is False
        assert resp.error_code == "DELEGATION_NOT_AUTHORIZED"
        assert resp.submitted is False

    @pytest.mark.asyncio
    async def test_processor_congela_en_vez_de_reintentar(self):
        """4.3 RED: con submitted=True el relay congela, no reintenta ni rechaza."""
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor
        from backend.services.fiscal.fiscal_document_port import CAEResponse
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        real = MagicMock(spec=WSFEAdapter)
        real.request_cae = AsyncMock(
            return_value=CAEResponse(
                cae=None,
                cae_due_date=None,
                is_approved=False,
                error_code="CAE_SUBMIT_UNCONFIRMED",
                error_detail="Read timed out.",
                number=51,
                submitted=True,
            )
        )
        repo = make_repo()
        processor = CAERelayProcessor(adapter=real, repo=repo)

        await processor.process_document(make_pending_doc(number=42))

        repo.freeze_unconfirmed.assert_awaited_once()
        kwargs = repo.freeze_unconfirmed.await_args.kwargs
        assert kwargs["doc_id"] == DOC_ID
        assert kwargs["arca_requested_number"] == 51
        assert "CAE_SUBMIT_UNCONFIRMED" in kwargs["detail"]
        repo.update_retry.assert_not_called()
        repo.update_rejected.assert_not_called()
        repo.update_authorized.assert_not_called()

    @pytest.mark.asyncio
    async def test_fallo_normal_sigue_con_backoff(self):
        """4.4 TRIANGULACIÓN: submitted=False → el backoff de siempre (no regresión)."""
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor
        from backend.services.fiscal.fiscal_document_port import CAEResponse
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        real = MagicMock(spec=WSFEAdapter)
        real.request_cae = AsyncMock(
            return_value=CAEResponse(
                cae=None, cae_due_date=None, is_approved=False,
                error_code="WSFE_ERROR", error_detail="connection refused",
            )
        )
        repo = make_repo()
        processor = CAERelayProcessor(adapter=real, repo=repo)

        await processor.process_document(make_pending_doc())

        repo.update_retry.assert_awaited_once()
        repo.freeze_unconfirmed.assert_not_called()

    def test_zeep_transport_tiene_operation_timeout(self):
        """4.5 RED: la llamada SOAP tiene cota temporal.

        Es lo que le devuelve al lease de 5 minutos su propiedad de exclusión
        mutua: con `operation_timeout=None` (el default de zeep) el POST puede
        colgarse indefinidamente, la sección crítica queda sin cota y el candado
        con cota fija, así que el cron re-reclama el documento con el
        FECAESolicitar anterior todavía en vuelo. Dos facturas reales.
        """
        from backend.services.fiscal import wsfe_adapter as mod

        captured: dict = {}

        class _FakeTransport:
            def __init__(self, **kwargs):
                captured.update(kwargs)

        with (
            patch("zeep.Transport", _FakeTransport),
            patch("zeep.Client", MagicMock()),
        ):
            mod._build_zeep_client("https://example.invalid/wsfev1?WSDL")

        timeout = captured.get("operation_timeout")
        assert timeout is not None, (
            "El Transport de zeep debe llevar operation_timeout — sin él, el POST "
            "de la operación va a requests SIN timeout."
        )
        assert 0 < timeout <= 120, f"operation_timeout fuera de rango razonable: {timeout}"
        assert timeout < 5 * 60, (
            "operation_timeout debe ser MUY menor al lease de 5 minutos de claim_pending."
        )

    @pytest.mark.asyncio
    async def test_freeze_unconfirmed_llama_la_rpc(self):
        """4.6 RED (repo): freeze_unconfirmed encamina por la RPC nueva."""
        from backend.repositories.fiscal_document_repository import FiscalDocumentRepository

        conn = AsyncMock()
        conn.execute = AsyncMock(return_value="SELECT 1")
        repo = FiscalDocumentRepository(conn)

        await repo.freeze_unconfirmed(
            doc_id=DOC_ID, arca_requested_number=51, detail="[CAE_SUBMIT_UNCONFIRMED] x"
        )

        conn.execute.assert_awaited_once()
        args = conn.execute.await_args.args
        assert "rpc_fiscal_document_freeze_unconfirmed" in args[0]
        assert args[1:] == (DOC_ID, 51, "[CAE_SUBMIT_UNCONFIRMED] x")


# ═══════════════════════════════════════════════════════════════════════════
# G5 — Consumidor final (DocTipo 99) en el pago de suscripción (H3)
# ═══════════════════════════════════════════════════════════════════════════

class TestConsumidorFinalSuscripcion:
    """5.1-5.3: el bloqueo era sólo Pydantic + UI.

    `rpc_emit_subscription_payment_cae` ya acepta `p_receptor_doc_tipo DEFAULT 99`
    y hace `NULLIF(p_receptor_doc_tipo, 99)`, y el adapter ya resuelve un receptor
    sin identificar como DocTipo=99 / DocNro=0. Sin migración.
    """

    def test_schema_acepta_receptor_ausente(self):
        """5.1 RED: el schema valida sin receptor y deja los dos campos en None."""
        from backend.schemas.fiscal import EmitSubscriptionPaymentRequest

        req = EmitSubscriptionPaymentRequest(receipt_id="receipt-001")

        assert req.receptor_doc_tipo is None
        assert req.receptor_doc_nro is None

    def test_schema_acepta_receptor_identificado(self):
        """5.2 TRIANGULACIÓN: el camino identificado no cambia."""
        from backend.schemas.fiscal import EmitSubscriptionPaymentRequest

        req = EmitSubscriptionPaymentRequest(
            receipt_id="receipt-001", receptor_doc_tipo=80, receptor_doc_nro="20422662457"
        )

        assert req.receptor_doc_tipo == 80
        assert req.receptor_doc_nro == "20422662457"

    def test_schema_rechaza_tipo_sin_numero(self):
        """5.2 TRIANGULACIÓN: relajar el schema no puede abrir la puerta a un
        DocTipo=80 con DocNro vacío — ante ARCA es un comprobante inconsistente."""
        import pydantic

        from backend.schemas.fiscal import EmitSubscriptionPaymentRequest

        with pytest.raises(pydantic.ValidationError):
            EmitSubscriptionPaymentRequest(receipt_id="receipt-001", receptor_doc_tipo=80)

    def test_schema_rechaza_numero_sin_tipo(self):
        """5.2 TRIANGULACIÓN (simétrico)."""
        import pydantic

        from backend.schemas.fiscal import EmitSubscriptionPaymentRequest

        with pytest.raises(pydantic.ValidationError):
            EmitSubscriptionPaymentRequest(
                receipt_id="receipt-001", receptor_doc_nro="20422662457"
            )

    def test_schema_rechaza_numero_vacio_con_tipo(self):
        """5.2 TRIANGULACIÓN: un string vacío no alcanza para identificar."""
        import pydantic

        from backend.schemas.fiscal import EmitSubscriptionPaymentRequest

        with pytest.raises(pydantic.ValidationError):
            EmitSubscriptionPaymentRequest(
                receipt_id="receipt-001", receptor_doc_tipo=96, receptor_doc_nro="   "
            )

    @pytest.mark.asyncio
    async def test_service_pasa_none_a_la_rpc(self):
        """5.3 RED: con receptor ausente, la RPC recibe None en los dos parámetros.

        `NULLIF(NULL, 99)` ya es NULL, así que el documento queda con
        receptor_doc_tipo NULL y el adapter manda DocTipo=99 / DocNro=0.
        """
        from backend.schemas.fiscal import EmitSubscriptionPaymentRequest
        from backend.services.fiscal import fiscal_profile_service as svc

        conn = AsyncMock()
        conn.fetchrow = AsyncMock(
            side_effect=[
                None,  # idempotency check
                {"result": json.dumps({"fiscal_document_id": DOC_ID, "status": "pending_cae"})},
            ]
        )

        with patch.object(svc, "require_platform_admin", AsyncMock(return_value=None)):
            await svc.emit_subscription_payment_cae(
                conn,
                {"user_id": "u", "role": "admin"},
                EmitSubscriptionPaymentRequest(receipt_id="receipt-001"),
            )

        rpc_args = conn.fetchrow.await_args_list[1].args
        assert "rpc_emit_subscription_payment_cae" in rpc_args[0]
        # (query, receipt_id, point_of_sale_id, receptor_doc_tipo, receptor_doc_nro)
        assert rpc_args[3] is None, "p_receptor_doc_tipo debe viajar NULL"
        assert rpc_args[4] is None, "p_receptor_doc_nro debe viajar NULL"


# ═══════════════════════════════════════════════════════════════════════════
# G7 — Superficie visible del número (regla PO: backend sin puerta = incompleto)
# ═══════════════════════════════════════════════════════════════════════════

class TestByReceiptDevuelveElComprobante:
    """7.1: sin esto, G3 corrige un dato que nadie ve.

    `GET /fiscal/documents/by-receipt/{id}` es lo que consume /admin/pagos para
    mostrar el estado del comprobante de un pago de suscripción. Traía el CAE
    pero NO el punto de venta ni el número, que es justamente lo que identifica
    al comprobante ante ARCA ("Factura C 0003-00000002").
    """

    @pytest.mark.asyncio
    async def test_by_receipt_devuelve_punto_de_venta_y_numero(self):
        from httpx import ASGITransport, AsyncClient

        from backend.core.auth import get_current_user
        from backend.core.database import get_db_conn
        from backend.main import app

        doc_id = uuid.UUID("cccc3333-3333-3333-3333-333333333333")
        conn = AsyncMock()
        conn.fetchval = AsyncMock(return_value="admin")  # guard de platform admin
        conn.fetchrow = AsyncMock(
            return_value={
                "id": doc_id,
                "status": "authorized",
                "cae": "86250464989491",
                "cae_due_date": datetime.date(2026, 12, 31),
                "comprobante_type": "factura_c",
                "total": 12000.0,
                "subscription_payment_id": "receipt-001",
                "punto_de_venta": 3,
                "number": 2,
            }
        )

        def fake_admin():
            return {"user_id": str(uuid.uuid4()), "role": "admin", "plan": "pro"}

        async def fake_conn():
            yield conn

        app.dependency_overrides[get_current_user] = fake_admin
        app.dependency_overrides[get_db_conn] = fake_conn
        try:
            async with AsyncClient(
                transport=ASGITransport(app=app), base_url="http://test"
            ) as client:
                resp = await client.get("/fiscal/documents/by-receipt/receipt-001")
        finally:
            app.dependency_overrides.pop(get_current_user, None)
            app.dependency_overrides.pop(get_db_conn, None)

        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["punto_de_venta"] == 3
        assert body["number"] == 2
        # La query tiene que TRAER las dos columnas (si no, el dict no las tiene
        # y el endpoint devolvería null aunque el comprobante las tenga).
        query = conn.fetchrow.await_args.args[0]
        assert "punto_de_venta" in query
        assert "number" in query
