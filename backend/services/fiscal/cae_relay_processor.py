"""
C-27 v21-fiscal-profile — CAERelayProcessor: relay idempotente de comprobantes pending_cae.

Implementa el proceso de background (OQ-1=A, D5/D6):
  - Lee un comprobante pending_cae
  - Llama al adapter (stub o real) para obtener el CAE
  - Actualiza el estado: authorized, retry con backoff, o rejected
  - Idempotente: documentos ya authorized/rejected no se modifican

Patrón: reusa la filosofía de operation_idempotency del proyecto.
El relay se dispara vía pg_cron cada minuto. fiscal-emision-segura (G1,
2026-09-22) retiró el disparo inmediato al emitir (instanciaba el STUB a mano y
podía escribir un CAE inventado en un comprobante de producción, con
`authorized` como estado terminal): el cron es el ÚNICO camino de emisión.

Design refs: D5 (máquina de estados), D6 (OQ-1=A relay), PA-22
"""
from __future__ import annotations

import datetime
import logging

from backend.services.fiscal.fiscal_document_port import CAERequest, CAEResponse, FiscalDocumentPort
from backend.services.fiscal.wsfe_adapter import WSFEAdapter

logger = logging.getLogger(__name__)

# Backoff por intento (en minutos): 1, 2, 5, 15, 60, 60, 60, ...
_BACKOFF_MINUTES = [1, 2, 5, 15, 60]
DEFAULT_MAX_ATTEMPTS = 10


class CAERelayProcessor:
    """Procesa comprobantes pending_cae y los transiciona a authorized/rejected.

    El processor es stateless: recibe un doc dict y un adapter; el repository
    persiste el resultado. Único invocador en producción (G1):
      - El pg_cron job relay-process-pending-cae (dispatcher cada minuto), vía
        POST /fiscal/documents/process-pending-cron → process_all_pending_documents.

    Idempotencia: si el doc ya está en authorized o rejected, no hace nada.
    """

    def __init__(
        self,
        adapter: FiscalDocumentPort,
        repo,
        max_attempts: int = DEFAULT_MAX_ATTEMPTS,
    ) -> None:
        self._adapter = adapter
        self._repo = repo
        self._max_attempts = max_attempts

    async def process_document(self, doc: dict) -> None:
        """Procesa un documento fiscal:

        - Idempotente: documentos ya authorized/rejected → no op.
        - pending_cae + adapter retorna CAE válido → authorized.
        - pending_cae + adapter retorna error transitorio (attempts < max) → retry con backoff.
        - pending_cae + attempts >= max_attempts → rejected.
        """
        status = doc.get("status", "")

        # Idempotencia: ya en estado terminal → no op
        if status in ("authorized", "rejected"):
            return

        if status != "pending_cae":
            logger.warning("CAERelayProcessor: doc %s en estado inesperado '%s'", doc["id"], status)
            return

        current_attempts = doc.get("attempts", 0)

        # Construir request de dominio (sin SOAP)
        # fiscal-receptor-iva-relay (D1): propagar la identificación del receptor y el
        # desglose de IVA persistidos en el doc, para que el adapter arme DocTipo/DocNro
        # y el array AlicIva reales. Campos NULL → None (comportamiento actual: DocTipo=99).
        cae_request = CAERequest(
            account_id=doc["account_id"],
            fiscal_document_id=doc["id"],
            comprobante_type=doc["comprobante_type"],
            punto_de_venta=doc["punto_de_venta"],
            number=doc["number"],
            total=float(doc.get("total", 0)),
            cuit_emisor=doc.get("cuit", ""),
            ambiente=doc.get("ambiente", "homologacion"),
            cuit_receptor=doc.get("cuit_receptor"),
            receptor_iva_condition=doc.get("receptor_iva_condition"),
            receptor_doc_tipo=doc.get("receptor_doc_tipo"),
            receptor_doc_nro=doc.get("receptor_doc_nro"),
            neto=float(doc["neto"]) if doc.get("neto") is not None else None,
            iva_amount=float(doc["iva_amount"]) if doc.get("iva_amount") is not None else None,
            iva_alicuota_id=doc.get("iva_alicuota_id"),
        )

        # ── fiscal-emision-segura (G2): capa 2 del guard de ambiente ──────────
        # Punto de paso canónico del relay. Si el documento es de PRODUCCIÓN, el
        # adapter tiene que ser el real: cualquier otro devolvería un CAE que no
        # existe en ARCA, y `authorized` es terminal (nadie lo corrige después).
        # Es una ALLOW-LIST del adapter real, no una deny-list del stub: así
        # cubre también cualquier adapter futuro (un fake de demo, un mock que se
        # filtre a un camino de producción). No delega en el guard del stub —
        # ni siquiera le pregunta: un guard que delega no es guard.
        if doc.get("ambiente") == "produccion" and not isinstance(self._adapter, WSFEAdapter):
            response = CAEResponse(
                cae=None,
                cae_due_date=None,
                is_approved=False,
                error_code="STUB_FORBIDDEN_IN_PRODUCTION",
                error_detail=(
                    f"guard del relay: el comprobante es de ambiente 'produccion' y el "
                    f"adapter inyectado no es el real ({type(self._adapter).__name__}). "
                    "No se llamó al adapter. Configurá el certificado de plataforma "
                    "(AFIP_PLATFORM_CERT/KEY/CUIT) para emitir en producción."
                ),
            )
            logger.critical(
                "CAERelayProcessor: doc %s de PRODUCCIÓN con adapter %s — no se pidió CAE",
                doc["id"], type(self._adapter).__name__,
            )
        else:
            # Llamar al adapter (stub o real)
            response = await self._adapter.request_cae(cae_request)

        if response.is_approved:
            # Éxito → authorized
            await self._repo.update_authorized(
                doc_id=doc["id"],
                cae=response.cae,
                cae_due_date=response.cae_due_date,
                # G3: el número que ARCA confirmó. La RPC lo adopta si difiere
                # del local y deja el desfasaje en document_status_history.
                number=response.number,
            )
            logger.info("CAERelayProcessor: doc %s autorizado con CAE %s", doc["id"], response.cae)

        elif getattr(response, "submitted", False):
            # ── fiscal-emision-segura (G4) ────────────────────────────────────
            # El FECAESolicitar SALIÓ y su resultado nunca se confirmó: ARCA
            # PUEDE haber autorizado el comprobante. Reintentar pediría
            # `FECompUltimoAutorizado+1` (que ya avanzó) y emitiría una SEGUNDA
            # factura real, por el camino feliz del backoff y sin ninguna
            # excepción visible. Se CONGELA: el documento sigue pending_cae pero
            # claim_pending deja de reclamarlo. Resolución manual.
            await self._repo.freeze_unconfirmed(
                doc_id=doc["id"],
                arca_requested_number=response.number,
                detail=f"[{response.error_code}] {response.error_detail}",
            )
            logger.critical(
                "CAERelayProcessor: doc %s CONGELADO — envío no confirmado "
                "(numero pedido a ARCA: %s). Requiere verificación manual en ARCA.",
                doc["id"], response.number,
            )

        else:
            # Error: ¿intentar de nuevo o rechazar?
            new_attempts = current_attempts + 1
            error_message = f"[{response.error_code}] {response.error_detail}"
            if new_attempts >= self._max_attempts:
                # Rechazar definitivamente (ya en el límite de intentos)
                await self._repo.update_rejected(
                    doc_id=doc["id"],
                    last_error=error_message,
                )
                logger.warning(
                    "CAERelayProcessor: doc %s RECHAZADO (attempts=%d): %s",
                    doc["id"], new_attempts, response.error_detail,
                )
            else:
                # Retry con backoff exponencial
                next_at = self._next_attempt_at(new_attempts)
                await self._repo.update_retry(
                    doc_id=doc["id"],
                    attempts=new_attempts,
                    next_attempt_at=next_at,
                    last_error=f"[{response.error_code}] {response.error_detail}",
                )
                logger.info(
                    "CAERelayProcessor: doc %s retry %d a las %s",
                    doc["id"], new_attempts, next_at.isoformat(),
                )

    async def process_document_by_id(self, doc_id: str) -> None:
        """Attempt to claim and process a single document by id.

        Anti-double-CAE guard: calls claim_pending first. If claim returns None
        (another trigger holds the lease, or the doc is FROZEN by an unconfirmed
        submit — G4), this method is a no-op. Only the caller that successfully
        claims the lease proceeds to request_cae.

        fiscal-emision-segura (G1): sin caller en producción desde que se retiró
        el disparo inmediato. Se conserva porque es la forma canónica de
        "procesar UN doc respetando el lease" y sus tests son el candado del
        guard de claim; cualquier camino futuro por-documento debe pasar por acá
        (nunca llamar process_document sin haber reclamado el lease antes).
        """
        doc = await self._repo.claim_pending(doc_id)
        if doc is None:
            logger.debug(
                "CAERelayProcessor.process_document_by_id: doc %s already claimed — skipping",
                doc_id,
            )
            return
        await self.process_document(doc)

    @staticmethod
    def _next_attempt_at(attempts: int) -> datetime.datetime:
        """Calcula el próximo intento con backoff (minutos según _BACKOFF_MINUTES).

        attempts=1 → +1 min, attempts=2 → +2 min, attempts=3 → +5 min, etc.
        """
        idx = min(attempts - 1, len(_BACKOFF_MINUTES) - 1)
        delay_minutes = _BACKOFF_MINUTES[idx]
        return datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=delay_minutes)
