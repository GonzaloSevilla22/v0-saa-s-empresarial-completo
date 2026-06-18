"""
C-27 v21-fiscal-profile — CAERelayProcessor: relay idempotente de comprobantes pending_cae.

Implementa el proceso de background (OQ-1=A, D5/D6):
  - Lee un comprobante pending_cae
  - Llama al adapter (stub o real) para obtener el CAE
  - Actualiza el estado: authorized, retry con backoff, o rejected
  - Idempotente: documentos ya authorized/rejected no se modifican

Patrón: reusa la filosofía de operation_idempotency del proyecto.
El relay se dispara vía pg_cron cada minuto + fire-and-forget al emitir (D6, OQ-1=A).

Design refs: D5 (máquina de estados), D6 (OQ-1=A relay), PA-22
"""
from __future__ import annotations

import datetime
import logging

from backend.services.fiscal.fiscal_document_port import CAERequest, FiscalDocumentPort

logger = logging.getLogger(__name__)

# Backoff por intento (en minutos): 1, 2, 5, 15, 60, 60, 60, ...
_BACKOFF_MINUTES = [1, 2, 5, 15, 60]
DEFAULT_MAX_ATTEMPTS = 10


class CAERelayProcessor:
    """Procesa comprobantes pending_cae y los transiciona a authorized/rejected.

    El processor es stateless: recibe un doc dict y un adapter; el repository
    persiste el resultado. Diseñado para ser invocado desde:
      - El endpoint POST /fiscal/documents/process-pending (fire-and-forget)
      - El pg_cron job relay-process-pending-cae (dispatcher cada minuto)

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
        cae_request = CAERequest(
            account_id=doc["account_id"],
            fiscal_document_id=doc["id"],
            comprobante_type=doc["comprobante_type"],
            punto_de_venta=doc["punto_de_venta"],
            number=doc["number"],
            total=float(doc.get("total", 0)),
            cuit_emisor=doc.get("cuit", ""),
            ambiente=doc.get("ambiente", "homologacion"),
        )

        # Llamar al adapter (stub o real)
        response = await self._adapter.request_cae(cae_request)

        if response.is_approved:
            # Éxito → authorized
            await self._repo.update_authorized(
                doc_id=doc["id"],
                cae=response.cae,
                cae_due_date=response.cae_due_date,
            )
            logger.info("CAERelayProcessor: doc %s autorizado con CAE %s", doc["id"], response.cae)

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
        (another trigger holds the lease), this method is a no-op. Only the caller
        that successfully claims the lease proceeds to request_cae.

        Safe to call concurrently from:
          - fire-and-forget BackgroundTask (immediately after emit)
          - pg_cron batch via process_all_pending_documents
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
