"""
journal-entry-outbox — JournalEntryRepository (Task 6.1)
asiento-contable-gastos (D10/D11, 2026-09-10) — suma filtros server-side por
rango de fechas, tipo/referencia de documento y estado.

Read-only repository for journal_entries + journal_lines.
JWT-passthrough: RLS SELECT policy on both tables enforces account scope.
No service_role. Writes are not exposed here (relay-only via SECURITY DEFINER).
"""
from __future__ import annotations

import datetime
import uuid

from backend.repositories.base import BaseRepository

# asiento-contable-gastos (D10): filtros opcionales, empujados al `WHERE` en
# SQL (nunca filtrados en Python) — mismo patrón que ExpenseRepository.
# `_FILTERS` es la ÚNICA definición del predicado: la usan _fetch_entries
# (compartido por list_by_account y list_by_account_page, D8 de
# cobranzas-reverso aplicado acá) y el COUNT(*) de list_by_account_page, que
# antes no tenía ningún filtro — sin esto, `total` mentiría en cuanto se
# filtrara la página.
# Corrección de findings (revisor, ronda 1, minor): `posted_at` es un
# INSTANTE (timestamptz) — comparado contra un `date` pelado, el corte se
# resuelve en la zona de la SESIÓN del pool (UTC), no en hora argentina.
# `AT TIME ZONE 'America/Argentina/Mendoza'` antes del `::date` alinea el
# filtro con la zona del negocio (mismo patrón ya usado en
# client_repository.py / _account_aging_sql.py) — un contra-asiento de
# edición/borrado hecho entre las 21:00 y las 24:00 ART (posted_at = now())
# ya no desaparece del filtro "hasta hoy".
_FILTERS = """
    AND ($2::date IS NULL OR (posted_at AT TIME ZONE 'America/Argentina/Mendoza')::date >= $2::date)
    AND ($3::date IS NULL OR (posted_at AT TIME ZONE 'America/Argentina/Mendoza')::date <= $3::date)
    AND ($4::text IS NULL OR source_doc_type = $4)
    AND ($5::uuid IS NULL OR source_doc_ref = $5::uuid)
    AND ($6::text IS NULL OR status = $6)
"""


class JournalEntryRepository(BaseRepository):
    """Read-only access to the double-entry accounting tables.

    Connection is JWT-passthrough (no service_role). The SELECT RLS policy on
    journal_entries and journal_lines (account_id IN current_account_ids()) is
    the DB-level access gate.

    Task 6.1: list_by_account returns entries with their lines, most-recent-first.
    """

    async def list_by_account(
        self,
        account_id: str,
        *,
        limit: int = 100,
        offset: int = 0,
        date_from: datetime.date | None = None,
        date_to: datetime.date | None = None,
        source_doc_type: str | None = None,
        source_doc_ref: str | None = None,
        status: str | None = None,
    ) -> list[dict]:
        """List journal entries with their lines for the account (most recent first).

        Returns entries with nested lines. RLS enforces account scope so the
        WHERE clause on account_id is defence-in-depth (not the only guard).

        Args:
            account_id: Tenant UUID (also enforced by RLS).
            limit: Page size (default 100).
            offset: Page offset for pagination.
            date_from/date_to: filtro opcional por `posted_at` (rango, D10).
            source_doc_type: filtro opcional por tipo de documento de origen.
            source_doc_ref: filtro opcional por el documento puntual —
                es el que hace posible el enlace "ver el asiento de este gasto".
            status: filtro opcional por 'posted'/'reversed'.
        """
        entries = await self._fetch_entries(
            account_id,
            limit=limit,
            offset=offset,
            date_from=date_from,
            date_to=date_to,
            source_doc_type=source_doc_type,
            source_doc_ref=source_doc_ref,
            status=status,
        )
        return await self._attach_lines(entries)

    async def list_by_account_page(
        self,
        account_id: str,
        *,
        page: int,
        size: int,
        date_from: datetime.date | None = None,
        date_to: datetime.date | None = None,
        source_doc_type: str | None = None,
        source_doc_ref: str | None = None,
        status: str | None = None,
    ) -> dict:
        """v3-api-standards §2.9: envelope estándar {items,total,page,pages}
        (reemplaza limit/offset + lista plana).

        asiento-contable-gastos (D10/8.8): el COUNT usa el MISMO predicado
        `_FILTERS` que `_fetch_entries` — antes no filtraba nada, y con
        filtros nuevos en el SELECT sin tocar el COUNT, `total` mentiría.
        """
        total: int = await self._conn.fetchval(
            f"""
            SELECT COUNT(*) FROM public.journal_entries
            WHERE account_id = $1::uuid
            {_FILTERS}
            """,
            account_id,
            date_from,
            date_to,
            source_doc_type,
            source_doc_ref,
            status,
        ) or 0

        offset = page * size
        entries = await self._fetch_entries(
            account_id,
            limit=size,
            offset=offset,
            date_from=date_from,
            date_to=date_to,
            source_doc_type=source_doc_type,
            source_doc_ref=source_doc_ref,
            status=status,
        )
        items = await self._attach_lines(entries)
        pages = -(-total // size) if total > 0 else 0

        return {"items": items, "total": total, "page": page, "pages": pages}

    async def _fetch_entries(
        self,
        account_id: str,
        *,
        limit: int,
        offset: int,
        date_from: datetime.date | None = None,
        date_to: datetime.date | None = None,
        source_doc_type: str | None = None,
        source_doc_ref: str | None = None,
        status: str | None = None,
    ) -> list[dict]:
        """Fetch entry headers (sin líneas).

        Compartido por list_by_account y list_by_account_page (D8 de
        cobranzas-reverso aplicado acá): una sola definición del filtro, para
        que no exista una consulta con filtros y otra sin ellos.
        """
        return await self.fetch(
            f"""
            SELECT
                id,
                account_id,
                posted_at,
                status,
                source_doc_type,
                source_doc_ref,
                reversal_of,
                created_at
            FROM public.journal_entries
            WHERE account_id = $1::uuid
            {_FILTERS}
            ORDER BY posted_at DESC, created_at DESC
            LIMIT $7 OFFSET $8
            """,
            account_id,
            date_from,
            date_to,
            source_doc_type,
            source_doc_ref,
            status,
            limit,
            offset,
        )

    async def _attach_lines(self, entries: list[dict]) -> list[dict]:
        """Batch-fetch journal_lines para las entries dadas y las agrupa por entry_id."""
        if not entries:
            return []

        entry_ids = [e["id"] for e in entries]
        lines = await self.fetch(
            """
            SELECT
                id,
                entry_id,
                account_code,
                side,
                amount,
                line_no,
                cost_center_id
            FROM public.journal_lines
            WHERE entry_id = ANY($1::uuid[])
            ORDER BY entry_id, line_no
            """,
            entry_ids,
        )

        lines_by_entry: dict[uuid.UUID, list[dict]] = {}
        for line in lines:
            eid = line["entry_id"]
            lines_by_entry.setdefault(eid, []).append(dict(line))

        result = []
        for entry in entries:
            entry_dict = dict(entry)
            entry_dict["lines"] = lines_by_entry.get(entry["id"], [])
            result.append(entry_dict)

        return result
