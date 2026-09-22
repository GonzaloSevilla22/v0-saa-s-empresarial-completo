"""
C-27 v21-fiscal-profile — FiscalDocumentRepository.

Acceso a datos de fiscal_documents vía JWT-passthrough (lecturas/emisión).
El relay del CAE (update_authorized, update_rejected, update_retry) usa service_role
en prod (D7 — única excepción). En tests, el repo está mockeado.

Design ref: D5 (máquina de estados), D6 (relay idempotente)
"""
from __future__ import annotations

import datetime

from backend.repositories.base import BaseRepository


class FiscalDocumentRepository(BaseRepository):
    """Repository para fiscal_documents."""

    async def list_pending(self, limit: int = 50) -> list[dict]:
        """Lista comprobantes pending_cae listos para procesar (next_attempt_at <= now o NULL)."""
        return await self.fetch(
            """
            SELECT
              fd.*,
              fp.cuit,
              fp.ambiente
            FROM public.fiscal_documents fd
            JOIN public.fiscal_profiles fp ON fp.id = fd.fiscal_profile_id
            WHERE fd.status = 'pending_cae'
              AND (fd.next_attempt_at IS NULL OR fd.next_attempt_at <= now())
              AND fd.attempts < 10
            ORDER BY fd.next_attempt_at NULLS FIRST, fd.created_at ASC
            LIMIT $1
            """,
            limit,
        )

    async def get_by_id(self, doc_id: str, account_id: str) -> dict | None:
        row = await self.fetchrow(
            "SELECT * FROM public.fiscal_documents WHERE id = $1 AND account_id = $2",
            doc_id,
            account_id,
        )
        return dict(row) if row else None

    async def update_authorized(
        self,
        doc_id: str,
        cae: str,
        cae_due_date: datetime.date,
        number: int | None = None,
    ) -> bool:
        """Transiciona el comprobante a authorized con el CAE obtenido.

        v31-tenancy-pool-rls (colisión #1, sign-off PO 2026-08-01):
        fiscal_documents no tiene policy de UPDATE — encaminado por
        rpc_fiscal_document_authorize (SECURITY DEFINER), que hace el UPDATE
        y, si matcheó (doc seguía pending_cae), registra el historial
        (rpc_record_fiscal_transition) en el mismo statement SQL. Si el
        UPDATE no matcheó (otro relay ya lo transicionó — lease de
        claim_pending), no se registra historial — mismo contrato que antes.

        fiscal-emision-segura (G3): `number` es el número que ARCA CONFIRMÓ. La
        RPC lo adopta si difiere del local (ARCA es la fuente de verdad),
        resincroniza `document_sequences` SOLO hacia adelante y deja el desfasaje
        en `document_status_history.reason`. `None` (o un caller viejo con 3
        argumentos, que el DEFAULT NULL de la RPC sigue aceptando durante la
        ventana de despliegue) = "no informado", y la RPC se comporta como antes.

        (m-3 minor, red team 2026-09-22): retorna el boolean de la RPC. `False`
        NO es un error — pasa en el camino de idempotencia (el doc ya no
        estaba pending_cae) y en la colisión irresoluble (7b de la migración):
        el CAE se persiste igual pero el documento queda CONGELADO, no
        autorizado. El caller lo usa para no loguear "autorizado" cuando en
        realidad no lo está.
        """
        return await self._conn.fetchval(
            "SELECT public.rpc_fiscal_document_authorize($1::uuid, $2, $3, $4::bigint)",
            doc_id,
            cae,
            cae_due_date,
            number,
        )

    async def freeze_unconfirmed(
        self,
        doc_id: str,
        arca_requested_number: int | None,
        detail: str,
    ) -> None:
        """CONGELA un comprobante cuyo FECAESolicitar salió y nunca se confirmó.

        fiscal-emision-segura (G4). El status NO cambia (sigue pending_cae: no
        sabemos si ARCA autorizó); lo que cambia es que
        `rpc_fiscal_document_claim_pending` deja de reclamarlo, por un predicado
        estructural y no por el contador de intentos. Evita el peor error del
        dominio: reintentar pidiendo `FECompUltimoAutorizado+1` y emitir una
        SEGUNDA factura real para el mismo documento.

        Resolución manual: consultar `arca_requested_number` en ARCA.
        """
        await self.execute(
            "SELECT public.rpc_fiscal_document_freeze_unconfirmed($1::uuid, $2::bigint, $3)",
            doc_id,
            arca_requested_number,
            detail,
        )

    async def mark_submit_started(self, doc_id: str, arca_requested_number: int) -> None:
        """Marca el envío ANTES de que salga — fiscal-riesgos-residuales (R1).

        La llama el hook `on_submit_start` que el relay inyecta en el
        `CAERequest`, justo antes del `FECAESolicitar`. El relay corre sobre
        `get_service_conn`, que NO abre transacción explícita: cada statement
        es autocommit, así que la marca queda commiteada aunque el proceso
        muera un instante después. Eso es exactamente lo que el fix necesita.

        NO traga la excepción: si `rpc_fiscal_document_mark_submit_started`
        levanta (P0437 — documento inexistente, ya no pending_cae, o con una
        marca viva), el `raise` tiene que llegar hasta `_call_wsfe` para
        ABORTAR el envío. Un booleano que alguien pueda ignorar no serviría.
        """
        await self.execute(
            "SELECT public.rpc_fiscal_document_mark_submit_started($1::uuid, $2::bigint)",
            doc_id,
            arca_requested_number,
        )

    async def clear_submit_mark(self, doc_id: str, detail: str) -> bool:
        """Borra la marca de envío — fiscal-riesgos-residuales (R1).

        SÓLO cuando ARCA demostró que el comprobante no existe (FECompConsultar
        602 + FECompUltimoAutorizado < el número pedido). La RPC incrementa
        `attempts`, así que el ciclo marca → 602 → limpieza → marca queda
        acotado por el mismo tope que el resto del relay.

        `False` = no había marca que limpiar, o el documento está CONGELADO (la
        RPC no desmarca congelados ni aunque se la llame por error).
        """
        return await self._conn.fetchval(
            "SELECT public.rpc_fiscal_document_clear_submit_mark($1::uuid, $2)",
            doc_id,
            detail,
        )

    async def update_rejected(self, doc_id: str, last_error: str) -> None:
        """Transiciona el comprobante a rejected con el detalle del error.

        v31-tenancy-pool-rls (colisión #1): encaminado por
        rpc_fiscal_document_reject (SECURITY DEFINER) — UPDATE + historial
        (RN-A1, con last_error como reason) en el mismo statement SQL.
        """
        await self.execute(
            "SELECT public.rpc_fiscal_document_reject($1::uuid, $2)",
            doc_id,
            last_error,
        )

    async def claim_pending(self, doc_id: str, max_attempts: int = 10) -> dict | None:
        """Atomic optimistic claim: sets next_attempt_at +5min lease on the doc.

        Returns the row dict if THIS caller claimed it (i.e. the UPDATE matched and
        returned the row via RETURNING *), or None if another concurrent trigger already
        holds the lease (0 rows returned).

        The 5-minute lease prevents a second trigger from re-claiming the same doc while
        the SOAP call is in flight. When the processor finishes (update_authorized /
        update_retry / update_rejected) the lease is superseded by the terminal/retry state.

        This is the anti-double-CAE guard (D6, OQ-1=A):
          - Fire-and-forget on emit: claims immediately after INSERT
          - pg_cron backstop: claims at each cron tick for any unclaimed/expired docs
          - Two concurrent callers for the same doc_id → exactly one gets the row
        """
        # IMPORTANTE: el RETURNING DEBE incluir cuit + ambiente del fiscal_profile.
        # El CAERelayProcessor arma CAERequest con doc["ambiente"] (default
        # "homologacion" si falta) y doc["cuit"] (Auth.Cuit). Sin el JOIN, todo doc
        # de PRODUCCIÓN se relayaba contra el endpoint de HOMOLOGACIÓN con el cert
        # de prod -> AFIP: "Certificado no emitido por AC de confianza".
        #
        # v31-tenancy-pool-rls (colisión #1): el UPDATE...FROM fiscal_profiles...
        # RETURNING de arriba ahora vive en rpc_fiscal_document_claim_pending
        # (SECURITY DEFINER) — mismo WHERE, mismo RETURNING, mismo contrato
        # (SETOF vacío == "ya reclamado por otro caller").
        row = await self.fetchrow(
            "SELECT * FROM public.rpc_fiscal_document_claim_pending($1::uuid, $2::int)",
            doc_id,
            max_attempts,
        )
        if row is None:
            return None
        return dict(row)

    async def list_pending_all(self, limit: int = 50) -> list[dict]:
        """Lists pending_cae docs from ALL accounts (cross-account, no RLS).

        Intended for service-role connections only (pg_cron / machine endpoint).
        Orders by next_attempt_at NULLS FIRST, created_at ASC so oldest/unclaimed docs
        are processed first.

        NOTE: FOR UPDATE SKIP LOCKED is NOT used here because the SOAP call (request_cae)
        is long-running and must not hold a DB lock across a network round-trip.
        The claim_pending optimistic lease is the concurrency guard instead.

        fiscal-emision-segura (M-2, red team 2026-09-22): excluye los
        documentos CONGELADOS (`cae_submit_unconfirmed_at`, G4). Un congelado
        tiene `next_attempt_at = NULL` PARA SIEMPRE — con la orden `NULLS
        FIRST`, si hay >= `limit` congelados el batch entero se llena de ellos
        (`claim_pending` los rechaza a todos porque tiene el mismo predicado)
        y el relay deja de procesar CUALQUIER documento fresco,
        indefinidamente. Mismo predicado que ya tiene
        `rpc_fiscal_document_claim_pending`.
        """
        return await self.fetch(
            """
            SELECT
              fd.*,
              fp.cuit,
              fp.ambiente
            FROM public.fiscal_documents fd
            JOIN public.fiscal_profiles fp ON fp.id = fd.fiscal_profile_id
            WHERE fd.status = 'pending_cae'
              AND (fd.next_attempt_at IS NULL OR fd.next_attempt_at <= now())
              AND fd.attempts < 10
              AND fd.cae_submit_unconfirmed_at IS NULL
            ORDER BY fd.next_attempt_at NULLS FIRST, fd.created_at ASC
            LIMIT $1
            """,
            limit,
        )

    async def update_retry(
        self,
        doc_id: str,
        attempts: int,
        next_attempt_at: datetime.datetime,
        last_error: str,
    ) -> None:
        """Incrementa el contador de intentos y reprograma el próximo intento (backoff).

        v31-tenancy-pool-rls (colisión #1): encaminado por
        rpc_fiscal_document_retry (SECURITY DEFINER) — mismo UPDATE, sin
        historial (pending_cae -> pending_cae no es una transición de estado).
        """
        await self.execute(
            "SELECT public.rpc_fiscal_document_retry($1::uuid, $2::int, $3, $4)",
            doc_id,
            attempts,
            next_attempt_at,
            last_error,
        )
