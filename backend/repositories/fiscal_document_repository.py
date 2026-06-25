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
    ) -> None:
        """Transiciona el comprobante a authorized con el CAE obtenido."""
        await self.execute(
            """
            UPDATE public.fiscal_documents
            SET status       = 'authorized',
                cae          = $2,
                cae_due_date = $3
            WHERE id = $1 AND status = 'pending_cae'
            """,
            doc_id,
            cae,
            cae_due_date,
        )

    async def update_rejected(self, doc_id: str, last_error: str) -> None:
        """Transiciona el comprobante a rejected con el detalle del error."""
        await self.execute(
            """
            UPDATE public.fiscal_documents
            SET status     = 'rejected',
                last_error = $2
            WHERE id = $1 AND status = 'pending_cae'
            """,
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
        # Por eso usamos UPDATE ... FROM fiscal_profiles ... RETURNING fp.cuit, fp.ambiente.
        row = await self.fetchrow(
            """
            UPDATE public.fiscal_documents fd
            SET next_attempt_at = now() + interval '5 minutes'
            FROM public.fiscal_profiles fp
            WHERE fd.id = $1
              AND fp.id = fd.fiscal_profile_id
              AND fd.status = 'pending_cae'
              AND (fd.next_attempt_at IS NULL OR fd.next_attempt_at <= now())
              AND fd.attempts < $2
            RETURNING
              fd.id, fd.account_id, fd.fiscal_profile_id, fd.point_of_sale_id,
              fd.comprobante_type, fd.punto_de_venta, fd.number, fd.total,
              fd.status, fd.cae, fd.cae_due_date, fd.attempts, fd.next_attempt_at,
              fd.last_error,
              fp.cuit, fp.ambiente
            """,
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
        """Incrementa el contador de intentos y reprograma el próximo intento (backoff)."""
        await self.execute(
            """
            UPDATE public.fiscal_documents
            SET attempts       = $2,
                next_attempt_at = $3,
                last_error      = $4
            WHERE id = $1 AND status = 'pending_cae'
            """,
            doc_id,
            attempts,
            next_attempt_at,
            last_error,
        )
