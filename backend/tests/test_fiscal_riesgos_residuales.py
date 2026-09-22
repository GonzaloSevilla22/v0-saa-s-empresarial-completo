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


# ═══════════════════════════════════════════════════════════════════════════
# G4 — Reconciliación contra ARCA (FECompConsultar) en el adapter real
# ═══════════════════════════════════════════════════════════════════════════

def _consultar_response(
    *,
    resultado: str | None = "A",
    cod_autorizacion: str | None = "86250464989491",
    fch_vto: object = "20261231",
    cbte_desde: object = 51,
    errors: list[tuple[int, str]] | None = None,
    sin_result_get: bool = False,
    con_cae_en_vez_de_cod_autorizacion: bool = False,
):
    """Respuesta de `FECompConsultar` con la forma real del WSDL de WSFEv1.

    `types.SimpleNamespace` y no `MagicMock` a propósito: con un MagicMock
    CUALQUIER atributo existe y es truthy, así que el candado de
    `CodAutorizacion` vs `CAE` (4.7) no podría escribirse — sería verde con el
    código equivocado.
    """
    ns = types.SimpleNamespace
    kwargs: dict = {}

    if errors is not None:
        kwargs["Errors"] = ns(Err=[ns(Code=c, Msg=m) for c, m in errors])

    if not sin_result_get:
        det: dict = {"CbteDesde": cbte_desde, "FchVto": fch_vto}
        if resultado is not None:
            det["Resultado"] = resultado
        if cod_autorizacion is not None:
            if con_cae_en_vez_de_cod_autorizacion:
                det["CAE"] = cod_autorizacion
            else:
                det["CodAutorizacion"] = cod_autorizacion
        kwargs["ResultGet"] = ns(**det)

    return ns(**kwargs)


def _ultimo_response(*, cbte_nro: object = 50, errors: list[tuple[int, str]] | None = None,
                     sin_cbte_nro: bool = False):
    """Respuesta de `FECompUltimoAutorizado` con la forma real del WSDL.

    `types.SimpleNamespace` y NO `MagicMock`, por la misma razón que
    `_consultar_response`: en un MagicMock cualquier atributo existe, así que
    `Errors` sería siempre truthy y `CbteNro` nunca podría faltar — el BLOCKER
    del segundo red team (el cross-check del 602 creyéndole a un `0` fabricado)
    es invisible para un mock así.
    """
    ns = types.SimpleNamespace
    kwargs: dict = {}
    if not sin_cbte_nro:
        kwargs["CbteNro"] = cbte_nro
    if errors is not None:
        kwargs["Errors"] = ns(Err=[ns(Code=c, Msg=m) for c, m in errors])
    return ns(**kwargs)


async def _reconcile(respuesta=None, *, exc=None, ultimo=None, ultimo_resp=None,
                     requested_number: int = 51):
    """Corre `reconcile_submitted` con `FECompConsultar` mockeado.

    `ultimo` es el número que devuelve `FECompUltimoAutorizado` (el cross-check
    del 602). `None` = esa llamada falla. `ultimo_resp` inyecta una respuesta
    CRUDA (para las formas degradadas: sin `CbteNro`, con `Errors`, etc.).
    """
    from backend.services.fiscal.wsfe_adapter import WSFEAdapter

    adapter = WSFEAdapter(platform_provider=MagicMock())
    invoice = make_cae_request()

    with (
        patch.object(WSFEAdapter, "_get_wsaa_token", AsyncMock(return_value=("tok", "sig"))),
        patch("zeep.Client") as mock_client_cls,
    ):
        mock_client = MagicMock()
        mock_client_cls.return_value = mock_client
        if exc is not None:
            mock_client.service.FECompConsultar.side_effect = exc
        else:
            mock_client.service.FECompConsultar.return_value = respuesta
        if ultimo_resp is not None:
            mock_client.service.FECompUltimoAutorizado.return_value = ultimo_resp
        elif ultimo is None:
            mock_client.service.FECompUltimoAutorizado.side_effect = RuntimeError("cross-check caído")
        else:
            mock_client.service.FECompUltimoAutorizado.return_value = _ultimo_response(cbte_nro=ultimo)
        return await adapter.reconcile_submitted(invoice, requested_number=requested_number)


class TestReconciliacionContraArca:
    """4.1-4.10: la consulta es la ÚNICA fuente que puede desbloquear un
    documento marcado. Todo lo que no sea una respuesta interpretable es
    `unknown` — nunca `not_found` por defecto, porque `not_found` es la única
    salida que habilita re-emitir.
    """

    @pytest.mark.asyncio
    async def test_el_port_sin_implementar_no_emite(self):
        """4.1: la implementación por defecto del port es FAIL-CLOSED.

        Un adapter futuro que no implemente `reconcile_submitted` hace que el
        documento reintente la consulta y termine congelado — NUNCA que se
        emita a ciegas. Por eso NO es @abstractmethod: si lo fuera, cada fake
        tendría que implementarla y un adapter incompleto explotaría en runtime.
        """
        from backend.services.fiscal.fiscal_document_port import (
            CAEResponse,
            FiscalDocumentPort,
        )

        class AdapterIncompleto(FiscalDocumentPort):
            async def request_cae(self, invoice_data):
                return CAEResponse(cae=None, cae_due_date=None, is_approved=False)

        rec = await AdapterIncompleto().reconcile_submitted(make_cae_request(), requested_number=51)

        assert rec.outcome == "unknown"
        assert rec.cae is None

    @pytest.mark.asyncio
    async def test_comprobante_aprobado_en_arca(self):
        """4.2 GREEN: Resultado='A' + CodAutorizacion → authorized con ese CAE."""
        rec = await _reconcile(_consultar_response(), ultimo=51)

        assert rec.outcome == "authorized"
        assert rec.cae == "86250464989491"
        assert rec.cae_due_date == datetime.date(2026, 12, 31)
        assert rec.number == 51

    @pytest.mark.asyncio
    async def test_602_no_existe_con_cross_check(self):
        """4.3 TRIANGULACIÓN: 602 + `ultimo < n` → not_found, con el cross-check.

        El 602 solo NO alcanza: también aparece cuando el PtoVta/CbteTipo de la
        consulta no matchea. Tomarlo como "no existe" y re-emitir sería la forma
        elegante de volver a la doble factura.
        """
        rec = await _reconcile(
            _consultar_response(errors=[(602, "No existen datos en nuestros registros")],
                                sin_result_get=True),
            ultimo=50,
        )

        assert rec.outcome == "not_found"
        assert rec.ultimo_autorizado == 50

    @pytest.mark.asyncio
    async def test_602_sin_cross_check_es_unknown(self):
        """4.4 TRIANGULACIÓN: si `FECompUltimoAutorizado` falla, el 602 no se
        puede creer y la respuesta es `unknown`.

        Fail-closed: sin el cross-check no hay nada demostrado.
        """
        rec = await _reconcile(
            _consultar_response(errors=[(602, "No existen datos")], sin_result_get=True),
            ultimo=None,
        )

        assert rec.outcome == "unknown"
        assert rec.ultimo_autorizado is None

    @pytest.mark.asyncio
    async def test_otro_codigo_de_error_es_unknown(self):
        """4.5 TRIANGULACIÓN: cualquier código que no sea 602 → unknown."""
        rec = await _reconcile(
            _consultar_response(errors=[(600, "Token invalido")], sin_result_get=True),
            ultimo=51,
        )

        assert rec.outcome == "unknown"
        assert rec.error_code == "600"

    @pytest.mark.parametrize(
        "exc",
        [
            pytest.param(Exception("Read timed out"), id="timeout"),
            pytest.param(RuntimeError("TransportError 502"), id="transport"),
            pytest.param(ValueError("Document is empty"), id="xml-ilegible"),
        ],
    )
    @pytest.mark.asyncio
    async def test_la_consulta_que_falla_es_unknown(self, exc):
        """4.6 TRIANGULACIÓN: si la consulta no se puede hacer, no se sabe nada.

        La marca se conserva y NO se emite: el documento reintenta la CONSULTA
        con el backoff de siempre y, al agotar intentos, termina congelado.
        """
        rec = await _reconcile(exc=exc, ultimo=51)

        assert rec.outcome == "unknown"
        assert rec.error_code == "RECONCILE_CALL_FAILED"

    @pytest.mark.asyncio
    async def test_el_cae_viene_en_cod_autorizacion_no_en_cae(self):
        """4.7 TRIANGULACIÓN — candado contra copiar el parseo de FECAESolicitar.

        En `FECompConsultar` el CAE se llama `CodAutorizacion`. Una respuesta
        que sólo trae `CAE` NO se puede interpretar: `unknown`, nunca
        "autorizado sin CAE".
        """
        rec = await _reconcile(
            _consultar_response(con_cae_en_vez_de_cod_autorizacion=True), ultimo=51,
        )

        assert rec.outcome == "unknown"
        assert rec.error_code == "RECONCILE_SIN_CAE"

    @pytest.mark.asyncio
    async def test_fecha_de_vencimiento_deforme_no_descarta_el_cae(self):
        """4.8 TRIANGULACIÓN: un `FchVto` imparseable degrada el vencimiento a
        None — el CAE REAL nunca se descarta.

        Mismo hallazgo que B2-2 de #577 encontró en `CAEFchVto`: ahí un strptime
        deforme hacía perder un CAE real y reintentar.
        """
        rec = await _reconcile(_consultar_response(fch_vto="31/12/2026"), ultimo=51)

        assert rec.outcome == "authorized"
        assert rec.cae == "86250464989491"
        assert rec.cae_due_date is None

    @pytest.mark.asyncio
    async def test_resultado_rechazado(self):
        """4.9 TRIANGULACIÓN: `Resultado='R'` → rejected (que el processor trata
        como unknown: un FECAESolicitar rechazado no consume el número, así que
        un comprobante "existente pero rechazado" no se sabe interpretar).
        """
        rec = await _reconcile(_consultar_response(resultado="R"), ultimo=51)

        assert rec.outcome == "rejected"

    @pytest.mark.asyncio
    async def test_sin_result_get_ni_errores_es_unknown(self):
        """4.10 TRIANGULACIÓN: una respuesta vacía no dice nada."""
        rec = await _reconcile(_consultar_response(sin_result_get=True), ultimo=51)

        assert rec.outcome == "unknown"
        assert rec.error_code == "RECONCILE_SIN_RESULTGET"

    @pytest.mark.asyncio
    async def test_errors_ilegible_es_unknown(self):
        """4.11 TRIANGULACIÓN: si el nodo Errors no se puede leer, tampoco se
        sabe nada — y en particular NO se puede descartar que haya un 602.

        Caer al camino de `ResultGet` con un `Errors` ilegible sería interpretar
        una respuesta que no se entendió.
        """
        ns = types.SimpleNamespace
        # Err presente pero con un Code que no es un entero: el int() explota.
        respuesta = ns(Errors=ns(Err=[ns(Code="no-es-un-numero", Msg="?")]))

        rec = await _reconcile(respuesta, ultimo=51)

        assert rec.outcome == "unknown"
        assert rec.error_code == "RECONCILE_ERRORS_ILEGIBLES"

    @pytest.mark.asyncio
    async def test_result_get_sin_resultado_es_unknown(self):
        """4.12 TRIANGULACIÓN: `ResultGet` sin `Resultado` es imparseable, NO un
        rechazo.

        Tratarlo como `rejected` sería inventar una respuesta de ARCA. Como
        `rejected` y `unknown` terminan igual en el processor, la diferencia es
        de honestidad del error_code — que es lo que va a leer el humano que
        resuelva el comprobante congelado.
        """
        rec = await _reconcile(_consultar_response(resultado=None), ultimo=51)

        assert rec.outcome == "unknown"
        assert rec.error_code == "RECONCILE_SIN_RESULTADO"

    @pytest.mark.asyncio
    async def test_cbte_desde_ilegible_cae_al_numero_pedido(self):
        """4.13 TRIANGULACIÓN: un `CbteDesde` imparseable NO descarta el CAE.

        Se degrada al número que se le pidió a ARCA (que es el que está en la
        marca), igual que el camino normal de `FECAESolicitar` degrada a
        `ultimo+1`. Descartar un CAE real por no poder leer un número sería el
        mismo error que B2-2.
        """
        rec = await _reconcile(_consultar_response(cbte_desde="cuarenta"), ultimo=51,
                               requested_number=51)

        assert rec.outcome == "authorized"
        assert rec.cae == "86250464989491"
        assert rec.number == 51


# ═══════════════════════════════════════════════════════════════════════════
# G5 — La decisión de dominio: con marca, NUNCA se pide un CAE nuevo
# ═══════════════════════════════════════════════════════════════════════════

def _adapter_que_reconcilia(**rec_kwargs):
    """Adapter mock cuya `reconcile_submitted` devuelve lo que se le indique."""
    from backend.services.fiscal.fiscal_document_port import ReconcileResponse

    adapter = MagicMock()
    adapter.request_cae = AsyncMock()
    adapter.reconcile_submitted = AsyncMock(return_value=ReconcileResponse(**rec_kwargs))
    return adapter


def _marcado(**overrides) -> dict:
    base = dict(
        cae_submit_started_at=datetime.datetime.now(datetime.timezone.utc),
        arca_requested_number=51,
    )
    base.update(overrides)
    return make_pending_doc(**base)


class TestProcessorReconciliaEnVezDeEmitir:
    """5.1-5.11: la aserción que importa es `request_cae.assert_not_called()`.

    No se assertea sólo el estado final del documento: un `if/else` que "casi
    siempre" cae del lado bueno pasaría igual. Lo que se fija es que la rama de
    reconciliación es un `return` temprano y que en NINGUNA de sus salidas se
    pide un CAE nuevo.
    """

    @pytest.mark.asyncio
    async def test_marcado_y_aprobado_en_arca_se_autoriza_sin_pedir_cae(self):
        """5.1 GREEN: el documento se autoriza con el CAE que ARCA ya tenía."""
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor

        repo = make_repo()
        adapter = _adapter_que_reconcilia(
            outcome="authorized", cae="86250464989491",
            cae_due_date=datetime.date(2026, 12, 31), number=51,
        )
        processor = CAERelayProcessor(adapter=adapter, repo=repo)

        await processor.process_document(_marcado())

        adapter.request_cae.assert_not_called()
        repo.update_authorized.assert_awaited_once_with(
            doc_id=DOC_ID, cae="86250464989491",
            cae_due_date=datetime.date(2026, 12, 31), number=51,
        )
        repo.clear_submit_mark.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_602_con_cross_check_limpia_la_marca_y_no_emite_en_ese_tick(self):
        """5.2 TRIANGULACIÓN: ARCA demuestra que no existe → se limpia la marca.

        Y NO se emite en ESE tick: el documento vuelve al reposo con attempts+1
        y next_attempt_at=now(), y se re-emite UNA vez en el siguiente.
        """
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor

        repo = make_repo()
        adapter = _adapter_que_reconcilia(outcome="not_found", ultimo_autorizado=50, error_code="602")
        processor = CAERelayProcessor(adapter=adapter, repo=repo)

        await processor.process_document(_marcado())

        adapter.request_cae.assert_not_called()
        repo.clear_submit_mark.assert_awaited_once()
        assert repo.clear_submit_mark.await_args.kwargs["doc_id"] == DOC_ID
        repo.update_authorized.assert_not_awaited()
        repo.freeze_unconfirmed.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_602_contradicho_no_limpia_nada(self):
        """5.3 TRIANGULACIÓN: ARCA dice "no existe" un número que su propio
        último autorizado ya alcanzó → se contradice, y no se le cree.
        """
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor

        repo = make_repo()
        adapter = _adapter_que_reconcilia(outcome="not_found", ultimo_autorizado=51, error_code="602")
        processor = CAERelayProcessor(adapter=adapter, repo=repo)

        await processor.process_document(_marcado())

        adapter.request_cae.assert_not_called()
        repo.clear_submit_mark.assert_not_awaited()
        repo.update_retry.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_602_sin_cross_check_no_limpia_nada(self):
        """5.4 TRIANGULACIÓN: sin `ultimo_autorizado` no hay cross-check, así que
        el 602 no alcanza para limpiar la marca.

        Segunda capa del mismo guard: el adapter ya devuelve `unknown` cuando la
        consulta del último autorizado falla, pero el processor NO delega en eso
        — un adapter futuro que devuelva `not_found` sin cross-check tampoco
        puede provocar una re-emisión.
        """
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor

        repo = make_repo()
        adapter = _adapter_que_reconcilia(outcome="not_found", ultimo_autorizado=None, error_code="602")
        processor = CAERelayProcessor(adapter=adapter, repo=repo)

        await processor.process_document(_marcado())

        adapter.request_cae.assert_not_called()
        repo.clear_submit_mark.assert_not_awaited()
        repo.update_retry.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_unknown_reintenta_la_consulta_con_la_marca_intacta(self):
        """5.5 TRIANGULACIÓN: no se sabe nada → retry, y la marca se conserva.

        Conservar la marca es lo que impide emitir en el próximo tick.
        """
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor

        repo = make_repo()
        adapter = _adapter_que_reconcilia(outcome="unknown", error_code="RECONCILE_CALL_FAILED")
        processor = CAERelayProcessor(adapter=adapter, repo=repo)

        await processor.process_document(_marcado(attempts=2))

        adapter.request_cae.assert_not_called()
        repo.clear_submit_mark.assert_not_awaited()
        repo.update_retry.assert_awaited_once()
        assert repo.update_retry.await_args.kwargs["attempts"] == 3

    @pytest.mark.asyncio
    async def test_al_agotar_intentos_se_congela_nunca_se_rechaza(self):
        """5.6 TRIANGULACIÓN: `rejected` es terminal y el documento PUEDE tener
        un CAE real en ARCA. Al agotar intentos se CONGELA.

        El camino normal de error sí rechaza al llegar al tope (comportamiento
        de siempre, intacto); el de reconciliación no puede.
        """
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor

        repo = make_repo()
        adapter = _adapter_que_reconcilia(outcome="unknown", error_code="RECONCILE_CALL_FAILED")
        processor = CAERelayProcessor(adapter=adapter, repo=repo, max_attempts=10)

        await processor.process_document(_marcado(attempts=9))

        adapter.request_cae.assert_not_called()
        repo.update_rejected.assert_not_awaited()
        repo.freeze_unconfirmed.assert_awaited_once()
        assert repo.freeze_unconfirmed.await_args.kwargs["arca_requested_number"] == 51

    @pytest.mark.asyncio
    async def test_rejected_se_trata_como_unknown(self):
        """5.7 TRIANGULACIÓN: un comprobante "existente pero rechazado" no se
        puede interpretar. Rechazar el documento sería terminal y podría estar
        tapando un CAE real.
        """
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor

        repo = make_repo()
        adapter = _adapter_que_reconcilia(outcome="rejected", error_code="RESULTADO_R")
        processor = CAERelayProcessor(adapter=adapter, repo=repo)

        await processor.process_document(_marcado())

        adapter.request_cae.assert_not_called()
        repo.update_rejected.assert_not_awaited()
        repo.clear_submit_mark.assert_not_awaited()
        repo.update_retry.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_marca_sin_numero_congela(self):
        """5.8 TRIANGULACIÓN: una marca sin número es imposible por construcción
        (la RPC rechaza el NULL con P0437). Si igual aparece, fail-closed: se
        congela, nunca se emite.
        """
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor

        repo = make_repo()
        adapter = _adapter_que_reconcilia(outcome="authorized", cae="x")
        processor = CAERelayProcessor(adapter=adapter, repo=repo)

        await processor.process_document(_marcado(arca_requested_number=None))

        adapter.request_cae.assert_not_called()
        adapter.reconcile_submitted.assert_not_called()
        repo.freeze_unconfirmed.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_produccion_con_adapter_no_real_no_reconcilia_tampoco(self):
        """5.9 TRIANGULACIÓN: el guard de ambiente de G2 (#577) cubre las DOS
        ramas, porque se evalúa primero.

        Un stub reconciliando un documento de producción devolvería `not_found`
        y limpiaría una marca REAL — o sea, provocaría exactamente la segunda
        factura que este change impide.
        """
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor

        repo = make_repo()
        adapter = _adapter_que_reconcilia(outcome="not_found", ultimo_autorizado=50)
        processor = CAERelayProcessor(adapter=adapter, repo=repo)

        await processor.process_document(_marcado(ambiente="produccion"))

        adapter.request_cae.assert_not_called()
        adapter.reconcile_submitted.assert_not_called()
        repo.clear_submit_mark.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_sin_marca_el_camino_feliz_no_consulta_nada(self):
        """5.10 TRIANGULACIÓN: el documento en REPOSO va por el camino de
        siempre y NO agrega una llamada SOAP.

        Es la contrapositiva de la invariante: sin marca no hubo envío, así que
        es seguro emitir sin preguntarle nada a ARCA.
        """
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor
        from backend.services.fiscal.fiscal_document_port import CAEResponse

        repo = make_repo()
        adapter = _adapter_que_reconcilia(outcome="not_found", ultimo_autorizado=50)
        adapter.request_cae = AsyncMock(return_value=CAEResponse(
            cae="123", cae_due_date=datetime.date(2026, 12, 31), is_approved=True, number=7,
        ))
        processor = CAERelayProcessor(adapter=adapter, repo=repo)

        await processor.process_document(make_pending_doc())

        adapter.reconcile_submitted.assert_not_called()
        adapter.request_cae.assert_awaited_once()
        repo.update_authorized.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_si_la_persistencia_del_reconciliado_falla_se_congela(self):
        """5.11 TRIANGULACIÓN: mismo guard M-1 que el camino normal.

        ARCA ya confirmó el CAE y está en memoria; si la escritura local falla,
        el documento se CONGELA con el CAE en el detalle — no vuelve a pedir
        nada.
        """
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor

        repo = make_repo()
        repo.update_authorized = AsyncMock(side_effect=RuntimeError("statement timeout"))
        adapter = _adapter_que_reconcilia(
            outcome="authorized", cae="86250464989491",
            cae_due_date=datetime.date(2026, 12, 31), number=51,
        )
        processor = CAERelayProcessor(adapter=adapter, repo=repo)

        await processor.process_document(_marcado())

        adapter.request_cae.assert_not_called()
        repo.freeze_unconfirmed.assert_awaited_once()
        assert "86250464989491" in repo.freeze_unconfirmed.await_args.kwargs["detail"]


# ═══════════════════════════════════════════════════════════════════════════
# G6 — El stub sabe simular los tres caminos de la reconciliación
# ═══════════════════════════════════════════════════════════════════════════

class TestStubReconcilia:
    """6.1-6.4: sin esto, ni el humo local ni las sondas de punta a punta
    podrían ejercitar la reconciliación.
    """

    @pytest.mark.asyncio
    async def test_el_stub_nace_sin_memoria(self):
        """6.1: un stub nuevo no conoce ningún envío — que es exactamente lo
        que pasa cuando el proceso del relay muere y arranca otro.
        """
        from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter

        rec = await WSFEStubAdapter().reconcile_submitted(make_cae_request(), requested_number=51)

        assert rec.outcome == "not_found"
        assert rec.ultimo_autorizado == 50, "el cross-check del 602 tiene que PASAR por defecto"

    @pytest.mark.asyncio
    async def test_el_registro_inyectado_sobrevive_al_proceso(self):
        """6.2: con un registro inyectado, "ARCA sí lo tiene aunque nosotros
        morimos" — y el CAE que devuelve la reconciliación es EL MISMO que
        habría devuelto `request_cae`.

        Que sea el mismo es lo que permite assertear identidad en la sonda de
        punta a punta, y no sólo "hay algo".
        """
        from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter

        registro: dict[str, int] = {}
        stub = WSFEStubAdapter(submitted_registry=registro)
        invoice = make_cae_request(number=51)

        emitido = await stub.request_cae(invoice)

        otro_proceso = WSFEStubAdapter(submitted_registry=registro)
        rec = await otro_proceso.reconcile_submitted(invoice, requested_number=51)

        assert rec.outcome == "authorized"
        assert rec.cae == emitido.cae
        assert rec.number == 51

    @pytest.mark.asyncio
    async def test_el_stub_puede_simular_una_consulta_fallida(self):
        """6.3: `reconcile_failure=True` → unknown, para ejercitar el camino en
        que la consulta no se puede hacer.
        """
        from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter

        rec = await WSFEStubAdapter(reconcile_failure=True).reconcile_submitted(
            make_cae_request(), requested_number=51,
        )

        assert rec.outcome == "unknown"

    @pytest.mark.asyncio
    async def test_el_stub_sigue_negandose_en_produccion(self):
        """6.4 TRIANGULACIÓN: G2 de #577 intacto — el stub no reconcilia un
        documento de producción, ni siquiera para "sólo consultar".

        Devolvería `not_found` y el processor limpiaría una marca real.
        """
        from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter

        rec = await WSFEStubAdapter().reconcile_submitted(
            make_cae_request(ambiente="produccion"), requested_number=51,
        )

        assert rec.outcome == "unknown"
        assert rec.error_code == "STUB_FORBIDDEN_IN_PRODUCTION"


# ═══════════════════════════════════════════════════════════════════════════
# G7 — El cross-check del 602 no puede apoyarse en un número FABRICADO
#
# BLOCKER 1 del SEGUNDO red team (2026-09-22). `_ultimo_autorizado` cerraba con
#
#     return int(ultimo_cbte) if ultimo_cbte is not None else 0
#
# En `_call_wsfe` ese `0` era inocuo (se pide el comprobante 1 y ARCA valida con
# 10016). En `reconcile_submitted` es una AFIRMACIÓN: "ARCA no autorizó nada en
# este PV". Como el número pedido siempre es ≥ 1, un `0` fabricado hacía PASAR
# el cross-check SIEMPRE → `not_found` → el processor limpia la marca → el tick
# siguiente pide `ultimo+1` y emite una SEGUNDA factura real.
#
# Y `Errors` —que es JUSTO como WSFEv1 reporta un token vencido o un PV
# inexistente, devolviendo la respuesta "bien" con `CbteNro=0`— no se miraba.
#
# La regla que fija este grupo: el `0` sólo vale cuando ARCA lo AFIRMA sin
# errores. Todo lo demás levanta, y levantar cae en los caminos que ya son
# fail-closed (unknown en la reconciliación, retry antes de marcar en la
# emisión).
# ═══════════════════════════════════════════════════════════════════════════

def _llamar_ultimo_autorizado(respuesta):
    from backend.services.fiscal.wsfe_adapter import WSFEAdapter

    client = MagicMock()
    client.service.FECompUltimoAutorizado.return_value = respuesta
    return WSFEAdapter._ultimo_autorizado(client, {"Token": "t"}, 3, 11)


# Las tres formas hostiles que el red team reprodujo contra ARCA degradada.
_ULTIMO_DEGRADADO = [
    pytest.param(
        dict(sin_cbte_nro=True, errors=[(600, "Token invalido")]),
        id="sin-CbteNro-con-Errors-600",
    ),
    pytest.param(
        dict(cbte_nro=None, errors=[(600, "Token invalido")]),
        id="CbteNro-None-con-Errors",
    ),
    pytest.param(
        dict(cbte_nro=0, errors=[(602, "No existen datos")]),
        id="CbteNro-0-con-Errors-602",
    ),
    pytest.param(dict(sin_cbte_nro=True), id="sin-CbteNro-sin-Errors"),
    pytest.param(dict(cbte_nro=""), id="CbteNro-vacio"),
    pytest.param(dict(cbte_nro="no-es-un-numero"), id="CbteNro-no-numerico"),
]


class TestUltimoAutorizadoNoFabricaUnCero:
    """7.1-7.4: `_ultimo_autorizado` afirma o levanta. Nunca inventa."""

    @pytest.mark.parametrize("forma", _ULTIMO_DEGRADADO)
    def test_una_respuesta_ilegible_levanta(self, forma):
        """7.1 RED: ninguna de las formas degradadas puede devolver un número.

        Antes las seis devolvían `0` — y `0 < requested` siempre, así que el
        cross-check del 602 las daba por buenas.
        """
        from backend.services.fiscal.wsfe_adapter import WSFEUltimoAutorizadoIlegibleError

        with pytest.raises(WSFEUltimoAutorizadoIlegibleError):
            _llamar_ultimo_autorizado(_ultimo_response(**forma))

    def test_el_cero_afirmado_por_arca_sigue_siendo_valido(self):
        """7.2 CONTROL POSITIVO: un PV sin ningún comprobante autorizado
        devuelve `CbteNro=0` SIN errores, y eso es una afirmación legítima.

        Sin este caso el fix sería "levantar siempre que venga 0", que rompería
        la primera factura de cada punto de venta.
        """
        assert _llamar_ultimo_autorizado(_ultimo_response(cbte_nro=0)) == 0

    def test_un_numero_normal_se_devuelve_igual(self):
        """7.3 TRIANGULACIÓN: el camino feliz no cambia."""
        assert _llamar_ultimo_autorizado(_ultimo_response(cbte_nro=50)) == 50

    def test_un_numero_como_texto_se_interpreta(self):
        """7.4 TRIANGULACIÓN: zeep puede entregar el escalar como str.

        Levantar acá sería congelar de más por una cuestión de tipo.
        """
        assert _llamar_ultimo_autorizado(_ultimo_response(cbte_nro="50")) == 50


class TestElCrossCheckDegradadoNoHabilitaReEmitir:
    """7.5-7.7: la consecuencia en la reconciliación y en el processor."""

    @pytest.mark.asyncio
    @pytest.mark.parametrize("forma", _ULTIMO_DEGRADADO)
    async def test_602_con_cross_check_degradado_es_unknown(self, forma):
        """7.5 RED: 602 + cross-check ilegible NO es `not_found`.

        `not_found` es la ÚNICA salida que habilita re-emitir. Antes las seis
        formas la producían.
        """
        rec = await _reconcile(
            _consultar_response(errors=[(602, "No existen datos")], sin_result_get=True),
            ultimo_resp=_ultimo_response(**forma),
        )

        assert rec.outcome == "unknown"
        assert rec.error_code == "RECONCILE_602_SIN_CROSSCHECK"
        assert rec.ultimo_autorizado is None

    @pytest.mark.asyncio
    async def test_el_processor_no_limpia_la_marca_con_el_cross_check_degradado(self):
        """7.6 RED: la consecuencia medida por el red team.

        Con la marca limpiada, el próximo tick pide `ultimo+1` y emite la
        segunda factura. Acá la marca tiene que sobrevivir y el documento
        reintentar la CONSULTA.
        """
        from backend.services.fiscal.cae_relay_processor import CAERelayProcessor
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        repo = make_repo()
        adapter = WSFEAdapter(platform_provider=MagicMock())
        adapter.request_cae = AsyncMock()

        with (
            patch.object(WSFEAdapter, "_get_wsaa_token", AsyncMock(return_value=("tok", "sig"))),
            patch("zeep.Client") as mock_client_cls,
        ):
            mock_client = MagicMock()
            mock_client_cls.return_value = mock_client
            mock_client.service.FECompConsultar.return_value = _consultar_response(
                errors=[(602, "No existen datos")], sin_result_get=True,
            )
            # ARCA degradada: responde "bien" pero sin número legible.
            mock_client.service.FECompUltimoAutorizado.return_value = _ultimo_response(
                sin_cbte_nro=True, errors=[(600, "Token invalido")],
            )

            await CAERelayProcessor(adapter, repo).process_document(
                make_pending_doc(
                    cae_submit_started_at=datetime.datetime.now(datetime.timezone.utc),
                    arca_requested_number=7,
                ),
            )

        repo.clear_submit_mark.assert_not_awaited()
        adapter.request_cae.assert_not_called()
        repo.update_retry.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_un_ultimo_autorizado_ilegible_no_marca_ni_envia(self):
        """7.7 TRIANGULACIÓN: en la EMISIÓN, la misma respuesta degradada aborta
        antes de marcar nada.

        El `0` fabricado hacía pedir el comprobante 1 sobre un PV que ya tiene
        comprobantes. Ahora levanta ANTES del hook: no hay marca, no sale un
        byte, y es un retry normal (`WSFE_ERROR`).
        """
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        hook = AsyncMock()
        adapter = WSFEAdapter(platform_provider=MagicMock())

        with (
            patch.object(WSFEAdapter, "_get_wsaa_token", AsyncMock(return_value=("tok", "sig"))),
            patch("zeep.Client") as mock_client_cls,
        ):
            mock_client = MagicMock()
            mock_client_cls.return_value = mock_client
            mock_client.service.FECompUltimoAutorizado.return_value = _ultimo_response(
                cbte_nro=0, errors=[(600, "Token invalido")],
            )

            resp = await adapter.request_cae(make_cae_request(on_submit_start=hook))

            mock_client.service.FECAESolicitar.assert_not_called()

        hook.assert_not_awaited()
        assert resp.is_approved is False
        assert resp.submitted is False
        assert resp.error_code == "WSFE_ERROR"
