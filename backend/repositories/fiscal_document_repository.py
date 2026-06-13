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
