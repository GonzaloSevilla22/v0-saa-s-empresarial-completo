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
            # fiscal-riesgos-residuales (R1): el hook que persiste la marca del
            # envío ANTES de que el FECAESolicitar salga.
            on_submit_start=self._make_submit_hook(doc["id"]),
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
        elif doc.get("cae_submit_started_at") is not None:
            # ── fiscal-riesgos-residuales (R1) ────────────────────────────────
            # El documento tiene un envío MARCADO: alguien ya le pidió a ARCA el
            # número `arca_requested_number` y no sabemos cómo terminó (el
            # proceso murió, o la base se cayó antes de persistir). Pedirle un
            # CAE nuevo pediría `FECompUltimoAutorizado+1` —que ya avanzó— y
            # emitiría una SEGUNDA factura real. La única salida es preguntarle
            # a ARCA.
            #
            # Es un `return` temprano y no un `if/else`: en NINGUNA de las
            # salidas de esta rama se llama a `request_cae`. El guard de
            # ambiente de arriba se evalúa PRIMERO y cubre las dos ramas — un
            # stub reconciliando un documento de producción devolvería
            # "no existe" y borraría una marca real.
            await self._reconcile_marked_document(doc, cae_request)
            return
        else:
            # Llamar al adapter (stub o real)
            response = await self._adapter.request_cae(cae_request)

        if response.is_approved:
            # ── fiscal-emision-segura (M-1, red team 2026-09-22) ──────────────
            # ARCA YA aprobó y el CAE está en memoria (`response.cae`), pero
            # persistirlo puede fallar (lock, timeout de statement, corte de
            # conexión). Sin este guard el documento queda pending_cae y el
            # PRÓXIMO tick lo reclama como si nunca hubiera pedido nada: pide
            # `FECompUltimoAutorizado+1` (que YA avanzó) y emite una SEGUNDA
            # factura real. Se CONGELA con el CAE real en el detail para que
            # la resolución manual no dependa de re-consultar ARCA a ciegas.
            try:
                matched = await self._repo.update_authorized(
                    doc_id=doc["id"],
                    cae=response.cae,
                    cae_due_date=response.cae_due_date,
                    # G3: el número que ARCA confirmó. La RPC lo adopta si difiere
                    # del local y deja el desfasaje en document_status_history.
                    number=response.number,
                )
            except Exception as exc:
                logger.critical(
                    "CAERelayProcessor: doc %s — ARCA APROBÓ (CAE %s, vto %s, "
                    "numero %s) pero la persistencia de update_authorized FALLÓ: "
                    "%s. CONGELANDO para no pedir un CAE nuevo en el próximo tick.",
                    doc["id"], response.cae, response.cae_due_date, response.number, exc,
                )
                await self._repo.freeze_unconfirmed(
                    doc_id=doc["id"],
                    arca_requested_number=response.number,
                    detail=(
                        f"PERSIST_FAILED_AFTER_ARCA_APPROVAL: ARCA aprobó con CAE "
                        f"{response.cae} (vto {response.cae_due_date}) pero la "
                        f"escritura local falló: {exc}"
                    ),
                )
                return

            # (m-3 minor) `matched=False` sin excepción NO es un error: pasa en
            # la idempotencia (otro relay ya lo transicionó) y en la colisión
            # irresoluble (7b de la migración), donde la RPC persiste el CAE
            # pero CONGELA en vez de autorizar. No hay que loguearlo como
            # autorizado en ninguno de los dos casos.
            if matched:
                logger.info(
                    "CAERelayProcessor: doc %s autorizado con CAE %s", doc["id"], response.cae,
                )
            else:
                logger.warning(
                    "CAERelayProcessor: doc %s — ARCA aprobó (CAE %s) pero "
                    "rpc_fiscal_document_authorize devolvió false (idempotencia, o "
                    "colisión irresoluble que la propia RPC ya congeló). Revisar "
                    "document_status_history / last_error del documento.",
                    doc["id"], response.cae,
                )

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

    async def _reconcile_marked_document(self, doc: dict, cae_request: CAERequest) -> None:
        """Resuelve un documento con la marca de envío puesta — R1.

        Invariante de esta función: NUNCA llama a `request_cae`. El documento
        sale de acá autorizado (con el CAE que ARCA ya tenía), devuelto al
        reposo (sólo si ARCA DEMOSTRÓ que el comprobante no existe), reintentado
        o congelado. Nunca con una segunda factura.
        """
        doc_id = doc["id"]
        requested = doc.get("arca_requested_number")

        if requested is None:
            # Imposible por construcción: rpc_fiscal_document_mark_submit_started
            # rechaza el NULL con P0437. Si aparece igual, fail-closed.
            logger.critical(
                "CAERelayProcessor: doc %s tiene marca de envío SIN número pedido. "
                "CONGELANDO: no se puede consultar en ARCA ni emitir a ciegas.",
                doc_id,
            )
            await self._repo.freeze_unconfirmed(
                doc_id=doc_id,
                arca_requested_number=None,
                detail=(
                    "MARCA_SIN_NUMERO: el comprobante tiene cae_submit_started_at pero "
                    "arca_requested_number es NULL. Verificar en ARCA a mano."
                ),
            )
            return

        rec = await self._adapter.reconcile_submitted(
            cae_request, requested_number=requested,
        )
        outcome = getattr(rec, "outcome", "unknown")

        if outcome == "authorized":
            # Mismo guard M-1 que el camino normal: ARCA ya confirmó y el CAE
            # está en memoria; si la persistencia falla, se congela con el CAE
            # en el detalle en vez de volver a pedir nada.
            try:
                await self._repo.update_authorized(
                    doc_id=doc_id,
                    cae=rec.cae,
                    cae_due_date=rec.cae_due_date,
                    number=rec.number or requested,
                )
            except Exception as exc:
                logger.critical(
                    "CAERelayProcessor: doc %s — la RECONCILIACIÓN encontró el CAE %s "
                    "(vto %s) en ARCA pero la persistencia falló: %s. CONGELANDO.",
                    doc_id, rec.cae, rec.cae_due_date, exc,
                )
                await self._repo.freeze_unconfirmed(
                    doc_id=doc_id,
                    arca_requested_number=requested,
                    detail=(
                        f"PERSIST_FAILED_AFTER_ARCA_RECONCILE: ARCA tiene el comprobante "
                        f"con CAE {rec.cae} (vto {rec.cae_due_date}) pero la escritura "
                        f"local falló: {exc}"
                    ),
                )
                return

            logger.critical(
                "CAERelayProcessor: doc %s RECONCILIADO — el comprobante %s ya existía "
                "en ARCA con CAE %s. Se adoptó ese CAE en vez de pedir uno nuevo "
                "(que habría sido una segunda factura real).",
                doc_id, requested, rec.cae,
            )
            return

        if outcome == "not_found":
            ultimo = getattr(rec, "ultimo_autorizado", None)
            # El 602 solo no alcanza. Sin cross-check no hay nada demostrado, y
            # si el último autorizado de ARCA ya alcanzó el número pedido, ARCA
            # se está contradiciendo. Segunda capa del mismo guard que el
            # adapter ya aplica: no delega en él.
            if ultimo is None or ultimo >= requested:
                await self._retry_or_freeze_reconcile(
                    doc,
                    requested,
                    detail=(
                        f"[RECONCILE_602_NO_VERIFICABLE] ARCA dijo que el comprobante "
                        f"{requested} no existe, pero el cross-check no lo confirma "
                        f"(ultimo_autorizado={ultimo}). NO se re-emite."
                    ),
                )
                return

            await self._repo.clear_submit_mark(
                doc_id=doc_id,
                detail=(
                    f"[ARCA_602] El comprobante {requested} no existe en ARCA "
                    f"(ultimo autorizado {ultimo}): el envío nunca llegó. Se limpia la "
                    "marca y se vuelve a emitir UNA vez."
                ),
            )
            logger.warning(
                "CAERelayProcessor: doc %s — ARCA no tiene el comprobante %s "
                "(ultimo=%s). Marca limpiada: se re-emite en el próximo tick.",
                doc_id, requested, ultimo,
            )
            return

        # "rejected" y "unknown" son lo mismo acá: no se puede demostrar qué
        # pasó con el envío, así que no se emite y no se limpia nada. `rejected`
        # NO rechaza el documento — un FECAESolicitar rechazado no consume el
        # número, y `rejected` es terminal: podría estar tapando un CAE real.
        await self._retry_or_freeze_reconcile(
            doc,
            requested,
            detail=f"[{rec.error_code}] {rec.error_detail}",
        )

    async def _retry_or_freeze_reconcile(
        self, doc: dict, requested: int | None, detail: str,
    ) -> None:
        """Salida no resolutiva de la reconciliación: reintentar o congelar.

        NUNCA rechaza. El camino normal de error sí rechaza al llegar al tope de
        intentos (comportamiento de siempre, intacto), pero acá el documento
        puede tener un CAE real en ARCA y `rejected` es terminal.
        """
        new_attempts = doc.get("attempts", 0) + 1

        if new_attempts >= self._max_attempts:
            logger.critical(
                "CAERelayProcessor: doc %s CONGELADO — la reconciliación agotó los "
                "intentos sin poder demostrar qué pasó con el comprobante %s. "
                "Requiere verificación manual en ARCA. Último detalle: %s",
                doc["id"], requested, detail,
            )
            await self._repo.freeze_unconfirmed(
                doc_id=doc["id"],
                arca_requested_number=requested,
                detail=detail,
            )
            return

        next_at = self._next_attempt_at(new_attempts)
        await self._repo.update_retry(
            doc_id=doc["id"],
            attempts=new_attempts,
            next_attempt_at=next_at,
            last_error=detail,
        )
        logger.info(
            "CAERelayProcessor: doc %s — reconciliación sin resolver, reintento %d a "
            "las %s (la marca se conserva: no se emite nada)",
            doc["id"], new_attempts, next_at.isoformat(),
        )

    def _make_submit_hook(self, doc_id: str):
        """Hook que el adapter awaitea justo antes del FECAESolicitar (R1).

        Persiste, en su propia transacción (el relay corre en autocommit sobre
        `get_service_conn`), el número que se le va a pedir a ARCA. Si la
        escritura falla, la excepción sale del hook y el envío NO se despacha:
        fail-closed por construcción, no por disciplina del caller.
        """
        async def _hook(cbte_numero: int) -> None:
            await self._repo.mark_submit_started(
                doc_id=doc_id,
                arca_requested_number=cbte_numero,
            )

        return _hook

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
