"""
fiscal-riesgos-residuales (governance CRÍTICO) — los dos riesgos que dejó
abiertos fiscal-emision-segura (#577).

R1 — `fiscal-marca-previa-al-envio`. Hasta este change la marca de "algo salió
para ARCA" (`cae_submit_unconfirmed_at` / `arca_requested_number`) se escribía
DESPUÉS del intento, desde el proceso que lo hizo. Si ese proceso muere (OOM,
SIGKILL, redeploy de Render) o la base se cae entre el `FECAESolicitar` y el
`freeze`/`authorize`, NO queda marca: a los 5 minutos vence el lease, el
próximo tick reclama el documento, pide `FECompUltimoAutorizado+1` (que ya
avanzó) y emite una SEGUNDA factura real. Medido en local por el red team de
#577: con la base caída, 2 llamadas a `request_cae`.

La invariante que este archivo fija:

    Un FECAESolicitar NUNCA sale sin una marca commiteada para ese documento
    con ese número; y un documento con marca NUNCA vuelve a pedir un CAE
    nuevo — se RECONCILIA contra ARCA (FECompConsultar).

Grupos:
  G3 — el hook `on_submit_start` corre ANTES del `FECAESolicitar`, y si no
       puede escribir la marca el envío NO sale (fail-closed).
  G4 — `reconcile_submitted` en el adapter real: sólo `Resultado='A'` con
       `CodAutorizacion` es "autorizado"; todo lo demás es `unknown` salvo el
       602, que además exige el cross-check contra `FECompUltimoAutorizado`.
  G5 — la decisión de dominio en el processor: con marca, `request_cae` NUNCA
       se llama.

R2 (`fiscal-documents-insert-solo-pending`) vive en SQL: bloques (17)/(18) de
supabase/tests/test_fiscal_cae_numero_autoritativo.sql.
"""
from __future__ import annotations

import datetime
import sys
import types
import uuid
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Stub fpdf BEFORE any import de backend.main (dep faltante pre-existente).
# Mismo patrón que test_fiscal_emision_segura.py.
# ---------------------------------------------------------------------------
try:
    import fpdf  # noqa: F401
except ImportError:
    _fpdf_stub = types.ModuleType("fpdf")
    _fpdf_stub.FPDF = MagicMock  # type: ignore[attr-defined]
    sys.modules["fpdf"] = _fpdf_stub

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
DOC_ID = "dddddddd-dddd-dddd-dddd-dddddddddddd"


# ── Helpers ───────────────────────────────────────────────────────────────────

def make_cae_request(**overrides):
    from backend.services.fiscal.fiscal_document_port import CAERequest

    base = dict(
        account_id=ACCOUNT_ID,
        fiscal_document_id=DOC_ID,
        comprobante_type="factura_c",
        punto_de_venta=3,
        number=42,
        total=12000.0,
        cuit_emisor="20422662457",
        ambiente="homologacion",
    )
    base.update(overrides)
    return CAERequest(**base)


def make_pending_doc(**overrides) -> dict:
    """Doc con la forma que devuelve rpc_fiscal_document_claim_pending.

    Incluye `cae_submit_started_at` (columna nueva de R1): la fila que el relay
    recibe viene de esa RPC, y sin la columna el processor no puede distinguir
    un documento en reposo de uno con un envío en curso.
    """
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


def _approved_response(cae: str = "86250464989491", vto: str = "20261231", cbte_desde: int = 51):
    """Respuesta aprobada de `FECAESolicitar`, con la forma que devuelve zeep."""
    det = MagicMock()
    det.Resultado = "A"
    det.CAE = cae
    det.CAEFchVto = vto
    det.CbteDesde = cbte_desde
    result = MagicMock()
    result.FeDetResp.FECAEDetResponse = [det]
    return result


# ═══════════════════════════════════════════════════════════════════════════
# G3 — La marca se escribe ANTES del FECAESolicitar
# ═══════════════════════════════════════════════════════════════════════════

class TestMarcaPreviaAlEnvio:
    """3.1-3.5: la invariante estructural de R1.

    No es "el código llama al hook en algún momento": es que el hook corre
    FUERA del `try` del submit e inmediatamente ANTES, así que si no puede
    escribir la marca la excepción sale antes de que zeep toque la red.
    """

    @pytest.mark.asyncio
    async def test_la_marca_se_escribe_antes_del_fecaesolicitar(self):
        """3.1 GREEN: orden real de las dos llamadas, y el número marcado es
        el que se le va a pedir a ARCA (ultimo+1), no el local.

        RED antes del fix: `CAERequest` no tenía `on_submit_start` y el adapter
        no lo llamaba — el orden no existía.
        """
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        orden: list[tuple[str, int | None]] = []

        async def _hook(cbte_numero: int) -> None:
            orden.append(("mark", cbte_numero))

        adapter = WSFEAdapter(platform_provider=MagicMock())
        invoice = make_cae_request(number=42, on_submit_start=_hook)

        with (
            patch.object(WSFEAdapter, "_get_wsaa_token", AsyncMock(return_value=("tok", "sig"))),
            patch("zeep.Client") as mock_client_cls,
        ):
            mock_client = MagicMock()
            mock_client_cls.return_value = mock_client
            mock_client.service.FECompUltimoAutorizado.return_value = MagicMock(CbteNro=50)

            def _submit(**_kwargs):
                orden.append(("submit", None))
                return _approved_response(cbte_desde=51)

            mock_client.service.FECAESolicitar.side_effect = _submit
            response = await adapter.request_cae(invoice)

        assert response.is_approved is True
        assert orden == [("mark", 51), ("submit", None)], (
            "La marca tiene que COMMITEARSE antes del FECAESolicitar y con el número "
            f"autoritativo de ARCA (ultimo+1 = 51), no con el local (42). Orden real: {orden}"
        )

    @pytest.mark.asyncio
    async def test_si_la_marca_falla_el_fecaesolicitar_no_sale(self):
        """3.2 TRIANGULACIÓN — el caso "la base está caída".

        Si el hook levanta, el pedido NO sale y el documento queda REINTENTABLE
        (`submitted=False`): no salió un byte, así que congelarlo sería congelar
        de más y alimentar la starvation que M-2/M-3 de #577 costó cerrar.
        """
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        async def _hook_que_falla(_cbte_numero: int) -> None:
            raise RuntimeError("connection was closed in the middle of operation")

        adapter = WSFEAdapter(platform_provider=MagicMock())
        invoice = make_cae_request(on_submit_start=_hook_que_falla)

        with (
            patch.object(WSFEAdapter, "_get_wsaa_token", AsyncMock(return_value=("tok", "sig"))),
            patch("zeep.Client") as mock_client_cls,
        ):
            mock_client = MagicMock()
            mock_client_cls.return_value = mock_client
            mock_client.service.FECompUltimoAutorizado.return_value = MagicMock(CbteNro=50)
            mock_client.service.FECAESolicitar.return_value = _approved_response()
            response = await adapter.request_cae(invoice)

        mock_client.service.FECAESolicitar.assert_not_called()
        assert response.is_approved is False
        assert response.submitted is False, (
            "No salió ningún pedido: el documento tiene que quedar reintentable, "
            "no congelado."
        )

    @pytest.mark.asyncio
    async def test_sin_hook_el_comportamiento_es_el_de_siempre(self):
        """3.3 TRIANGULACIÓN: `on_submit_start=None` (default) no cambia nada.

        Sostiene la ventana de despliegue y a cualquier caller que arme un
        CAERequest sin hook (tests de C-27, el adapter real llamado a mano).
        """
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        adapter = WSFEAdapter(platform_provider=MagicMock())
        invoice = make_cae_request()

        assert invoice.on_submit_start is None

        with (
            patch.object(WSFEAdapter, "_get_wsaa_token", AsyncMock(return_value=("tok", "sig"))),
            patch("zeep.Client") as mock_client_cls,
        ):
            mock_client = MagicMock()
            mock_client_cls.return_value = mock_client
            mock_client.service.FECompUltimoAutorizado.return_value = MagicMock(CbteNro=50)
            mock_client.service.FECAESolicitar.return_value = _approved_response()
            response = await adapter.request_cae(invoice)

        assert response.is_approved is True
        assert response.cae == "86250464989491"

    @pytest.mark.asyncio
    async def test_un_fallo_antes_del_numero_no_marca_nada(self):
        """3.4 TRIANGULACIÓN: si `FECompUltimoAutorizado` falla no hay número
        que marcar, así que el hook NO corre.

        Marcar acá dejaría el documento con una marca sin número real y la
        reconciliación consultaría en ARCA un comprobante que nunca se pidió.
        """
        import requests

        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        llamadas: list[int] = []

        async def _hook(cbte_numero: int) -> None:
            llamadas.append(cbte_numero)

        adapter = WSFEAdapter(platform_provider=MagicMock())
        invoice = make_cae_request(on_submit_start=_hook)

        with (
            patch.object(WSFEAdapter, "_get_wsaa_token", AsyncMock(return_value=("tok", "sig"))),
            patch("zeep.Client") as mock_client_cls,
        ):
            mock_client = MagicMock()
            mock_client_cls.return_value = mock_client
            mock_client.service.FECompUltimoAutorizado.side_effect = requests.exceptions.ReadTimeout(
                "Read timed out"
            )
            response = await adapter.request_cae(invoice)

        assert llamadas == [], "No hay número: no se marca nada."
        mock_client.service.FECAESolicitar.assert_not_called()
        assert response.is_approved is False
        assert response.submitted is False

    @pytest.mark.asyncio
    async def test_una_validacion_que_falla_no_marca_nada(self):
        """3.5 TRIANGULACIÓN: una validación de datos que levanta ANTES del
        envío (Factura A/B sin desglose de IVA) tampoco marca.

        El hook está DESPUÉS de todas las validaciones que pueden levantar, a
        propósito: no se marca un envío que nunca iba a salir.
        """
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        llamadas: list[int] = []

        async def _hook(cbte_numero: int) -> None:
            llamadas.append(cbte_numero)

        adapter = WSFEAdapter(platform_provider=MagicMock())
        invoice = make_cae_request(
            comprobante_type="factura_b",  # tipo con IVA discriminado
            neto=None,
            iva_amount=None,
            on_submit_start=_hook,
        )

        with (
            patch.object(WSFEAdapter, "_get_wsaa_token", AsyncMock(return_value=("tok", "sig"))),
            patch("zeep.Client") as mock_client_cls,
        ):
            mock_client = MagicMock()
            mock_client_cls.return_value = mock_client
            mock_client.service.FECompUltimoAutorizado.return_value = MagicMock(CbteNro=50)
            response = await adapter.request_cae(invoice)

        assert llamadas == []
        mock_client.service.FECAESolicitar.assert_not_called()
        assert response.is_approved is False
        assert "IVA_BREAKDOWN_REQUIRED" in (response.error_detail or "")


class TestRepositorioDeLaMarca:
    """3.6-3.9: el repo encamina por las RPCs nuevas, con los casts explícitos."""

    @pytest.mark.asyncio
    async def test_mark_submit_started_llama_la_rpc(self):
        """3.6: `mark_submit_started` va por rpc_fiscal_document_mark_submit_started."""
        from backend.repositories.fiscal_document_repository import FiscalDocumentRepository

        conn = AsyncMock()
        repo = FiscalDocumentRepository(conn)

        await repo.mark_submit_started(doc_id=DOC_ID, arca_requested_number=51)

        conn.execute.assert_awaited_once()
        args = conn.execute.await_args.args
        assert "rpc_fiscal_document_mark_submit_started" in args[0]
        assert "$1::uuid" in args[0] and "$2::bigint" in args[0]
        assert args[1:] == (DOC_ID, 51)

    @pytest.mark.asyncio
    async def test_mark_submit_started_propaga_el_error(self):
        """3.7 TRIANGULACIÓN: si la RPC levanta (P0437), el repo NO lo traga.

        Es lo que convierte al hook en fail-closed: el `raise` tiene que llegar
        hasta `_call_wsfe` para abortar el envío.
        """
        import asyncpg

        from backend.repositories.fiscal_document_repository import FiscalDocumentRepository

        conn = AsyncMock()
        conn.execute = AsyncMock(
            side_effect=asyncpg.exceptions.RaiseError("MARK_SUBMIT_STARTED_MARCA_VIVA")
        )
        repo = FiscalDocumentRepository(conn)

        with pytest.raises(asyncpg.exceptions.RaiseError):
            await repo.mark_submit_started(doc_id=DOC_ID, arca_requested_number=51)

    @pytest.mark.asyncio
    async def test_clear_submit_mark_devuelve_el_boolean(self):
        """3.8: `clear_submit_mark` recupera el boolean de la RPC (fetchval).

        `False` significa "no había marca que limpiar, o el documento está
        congelado" — el caller lo necesita para no dar por resuelto algo que no
        pasó.
        """
        from backend.repositories.fiscal_document_repository import FiscalDocumentRepository

        conn = AsyncMock()
        conn.fetchval = AsyncMock(return_value=True)
        repo = FiscalDocumentRepository(conn)

        cleared = await repo.clear_submit_mark(doc_id=DOC_ID, detail="ARCA_602")

        assert cleared is True
        args = conn.fetchval.await_args.args
        assert "rpc_fiscal_document_clear_submit_mark" in args[0]
        assert args[1:] == (DOC_ID, "ARCA_602")

    @pytest.mark.asyncio
    async def test_clear_submit_mark_false_cuando_no_limpio_nada(self):
        """3.9 TRIANGULACIÓN: `False` viaja tal cual (congelado / sin marca)."""
        from backend.repositories.fiscal_document_repository import FiscalDocumentRepository

        conn = AsyncMock()
        conn.fetchval = AsyncMock(return_value=False)
        repo = FiscalDocumentRepository(conn)

        assert await repo.clear_submit_mark(doc_id=DOC_ID, detail="x") is False


class TestProcessorInyectaElHook:
    """3.10-3.11: el relay es quien conecta la marca con el documento."""

    @pytest.mark.asyncio
    async def test_el_processor_inyecta_un_hook_que_marca_el_documento(self):
        """3.10: el `CAERequest` que llega al adapter trae el hook, y el hook
        escribe la marca del documento que se está procesando.

        Se assertea EJECUTANDO el hook (no su mera presencia): un hook que no
        llame al repo sería indistinguible de no tenerlo.
        """
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor
        from backend.services.fiscal.fiscal_document_port import CAEResponse

        repo = make_repo()
        adapter = MagicMock()
        capturado: dict = {}

        async def _request_cae(invoice_data):
            capturado["invoice"] = invoice_data
            return CAEResponse(
                cae="123", cae_due_date=datetime.date(2026, 12, 31),
                is_approved=True, number=51,
            )

        adapter.request_cae = AsyncMock(side_effect=_request_cae)

        processor = CAERelayProcessor(adapter=adapter, repo=repo)
        await processor.process_document(make_pending_doc())

        hook = capturado["invoice"].on_submit_start
        assert hook is not None, "El relay tiene que inyectar el hook de la marca previa"

        await hook(51)
        repo.mark_submit_started.assert_awaited_once_with(
            doc_id=DOC_ID, arca_requested_number=51,
        )

    @pytest.mark.asyncio
    async def test_el_guard_de_produccion_sigue_sin_llamar_al_adapter(self):
        """3.11 TRIANGULACIÓN: G2 de #577 intacto — con un adapter que no es el
        real y un documento de PRODUCCIÓN no se llama al adapter, así que
        tampoco se marca nada.
        """
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor

        repo = make_repo()
        adapter = MagicMock()
        adapter.request_cae = AsyncMock()

        processor = CAERelayProcessor(adapter=adapter, repo=repo)
        await processor.process_document(make_pending_doc(ambiente="produccion"))

        adapter.request_cae.assert_not_called()
        repo.mark_submit_started.assert_not_awaited()
