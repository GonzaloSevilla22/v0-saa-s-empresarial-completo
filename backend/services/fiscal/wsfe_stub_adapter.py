"""
C-27 v21-fiscal-profile — WSFEStubAdapter: implementación ficticia del port WSFE.

Retorna un CAE determinístico basado en el fiscal_document_id.
Sin I/O, sin red, sin SOAP. Usada en todos los tests de la suite y en dev.

Design ref: D4 — stub inyectable por DI.
"""
from __future__ import annotations

import datetime
import hashlib


from backend.services.fiscal.fiscal_document_port import (
    CAERequest,
    CAEResponse,
    FiscalDocumentPort,
    ReconcileResponse,
)


class WSFEStubAdapter(FiscalDocumentPort):
    """Stub del adaptador WSFE.

    Devuelve un CAE ficticio pero determinístico (mismo fiscal_document_id → mismo CAE).
    No toca la red. Usado en:
      - tests (unit y de endpoint)
      - entorno de desarrollo local
      - relay processor cuando el adaptador real no está configurado
    """

    _CAE_LENGTH = 14  # AFIP CAE real tiene 14 dígitos

    # fiscal-emision-segura (G2, 2026-09-22): capa 1 del guard de ambiente.
    _PRODUCTION_REFUSAL_CODE = "STUB_FORBIDDEN_IN_PRODUCTION"

    def __init__(
        self,
        submitted_registry: dict[str, int] | None = None,
        reconcile_failure: bool = False,
    ) -> None:
        """fiscal-riesgos-residuales (R1): el stub aprende a reconciliar.

        Args:
            submitted_registry: "qué llegó a ARCA". Por defecto es de la
                INSTANCIA — un proceso nuevo nace sin memoria, que es
                exactamente lo que pasa cuando el relay muere y arranca otro.
                Un test o una sonda que quiera simular "ARCA SÍ lo tiene aunque
                nosotros morimos" inyecta un dict que sobrevive al proceso.
            reconcile_failure: la consulta falla (`unknown`), para ejercitar el
                camino en que no se puede demostrar nada.
        """
        self._submitted: dict[str, int] = (
            submitted_registry if submitted_registry is not None else {}
        )
        self._reconcile_failure = reconcile_failure

    async def request_cae(self, invoice_data: CAERequest) -> CAEResponse:
        """Retorna un CAEResponse ficticio determinístico.

        El CAE se deriva del fiscal_document_id vía SHA-256 (los primeros 14 dígitos).
        La fecha de vencimiento es 10 días a partir de hoy (convención del stub).

        fiscal-emision-segura (G2): si el comprobante es de ambiente
        `produccion`, el stub se NIEGA — nunca devuelve un CAE. Un CAE ficticio
        en un comprobante real es el error que el dominio no puede cometer, y
        `authorized` es estado terminal: nadie lo corrige después. Esta capa
        cubre cualquier CALLER futuro que construya el stub a mano (como hacía
        el disparo inmediato que G1 retiró) y NO delega en el guard del
        processor — la capa 2 cubre cualquier ADAPTER futuro, y ninguna de las
        dos se apoya en la otra.
        """
        if invoice_data.ambiente == "produccion":
            return CAEResponse(
                cae=None,
                cae_due_date=None,
                is_approved=False,
                error_code=self._PRODUCTION_REFUSAL_CODE,
                error_detail=(
                    "El stub del adapter WSFE se niega a responder por un comprobante "
                    "de ambiente 'produccion': devolvería un CAE inventado y el "
                    "documento quedaría 'authorized' (estado terminal) sin existir en "
                    "ARCA. Configurá el certificado de plataforma "
                    "(AFIP_PLATFORM_CERT/KEY/CUIT) para que el relay use el adapter real."
                ),
            )

        # fiscal-riesgos-residuales (R1): el stub también marca. Si no lo
        # hiciera, el camino local/dev (el único que corre en el humo y en las
        # sondas de punta a punta) no ejercitaría la invariante "un envío nunca
        # sale sin marca commiteada" y la prueba no probaría nada. El stub no
        # habla con ARCA, así que el número que marca es el local.
        if invoice_data.on_submit_start is not None:
            await invoice_data.on_submit_start(invoice_data.number)

        # R1: queda registrado que "llegó a ARCA", para que la reconciliación
        # pueda devolver el MISMO CAE que habría devuelto esta llamada.
        self._submitted[invoice_data.fiscal_document_id] = invoice_data.number

        fake_cae = self._derive_cae(invoice_data.fiscal_document_id)
        due_date = datetime.date.today() + datetime.timedelta(days=10)

        return CAEResponse(
            cae=fake_cae,
            cae_due_date=due_date,
            is_approved=True,
            error_code=None,
            error_detail=None,
            # G3: el stub nunca diverge del número local (no habla con ARCA, así
            # que no tiene otro número que informar).
            number=invoice_data.number,
        )

    async def reconcile_submitted(
        self,
        invoice_data: CAERequest,
        requested_number: int,
    ) -> ReconcileResponse:
        """Simula FECompConsultar — fiscal-riesgos-residuales (R1).

        El CAE que devuelve es EL MISMO que habría devuelto `request_cae` (se
        deriva del mismo fiscal_document_id), así que una sonda puede assertear
        identidad y no sólo "hay algo".
        """
        # G2 (#577), capa 1: el stub tampoco reconcilia en producción. Diría
        # "no existe" sobre un comprobante REAL y el relay limpiaría una marca
        # real — o sea, provocaría la segunda factura que R1 impide.
        if invoice_data.ambiente == "produccion":
            return ReconcileResponse(
                outcome="unknown",
                error_code=self._PRODUCTION_REFUSAL_CODE,
                error_detail=(
                    "El stub del adapter WSFE se niega a reconciliar un comprobante de "
                    "ambiente 'produccion': su respuesta ficticia podría borrar la marca "
                    "de un envío real y provocar una segunda factura."
                ),
            )

        if self._reconcile_failure:
            return ReconcileResponse(
                outcome="unknown",
                error_code="STUB_RECONCILE_FAILURE",
                error_detail="El stub está configurado para simular una consulta fallida.",
            )

        if invoice_data.fiscal_document_id in self._submitted:
            return ReconcileResponse(
                outcome="authorized",
                cae=self._derive_cae(invoice_data.fiscal_document_id),
                cae_due_date=datetime.date.today() + datetime.timedelta(days=10),
                number=self._submitted[invoice_data.fiscal_document_id],
            )

        # ARCA no lo tiene. `ultimo_autorizado = requested_number - 1` hace que
        # el cross-check del 602 PASE por defecto (el caso normal del stub);
        # para ejercitar el 602 contradicho se inyecta otra respuesta.
        return ReconcileResponse(
            outcome="not_found",
            ultimo_autorizado=requested_number - 1,
            error_code="602",
            error_detail="(stub) ARCA: no existen datos en nuestros registros",
        )

    @staticmethod
    def _derive_cae(document_id: str) -> str:
        """Deriva un CAE ficticio de 14 dígitos determinístico a partir del document_id."""
        digest = hashlib.sha256(document_id.encode()).hexdigest()
        # Extraer 14 dígitos numéricos del digest (tomando los primeros chars hex y convirtiendo)
        numeric = "".join(c for c in digest if c.isdigit())
        # Si hay menos de 14 dígitos numéricos, rellenar con dígitos del hash int
        if len(numeric) < WSFEStubAdapter._CAE_LENGTH:
            hash_int = int(digest, 16)
            numeric = str(hash_int)
        return numeric[: WSFEStubAdapter._CAE_LENGTH]
