"""
Repository para bank-reconciliation C3.

Mutaciones vía SELECT rpc_...(args) → SECURITY DEFINER RPCs (la transaccionalidad
y los guards viven en la DB). Lecturas vía SELECT directo (RLS SELECT aplica por
JWT-passthrough de base.py).

La conciliación opera SOLO sobre bank_movements vs bank_statement_lines —
ninguna query de este repo toca el journal.
"""
from __future__ import annotations

import json
from datetime import date
from decimal import Decimal

import asyncpg

from backend.repositories.base import BaseRepository

# D4: ventana de fecha para sugerencias 1:1 (días)
SUGGESTION_DATE_WINDOW_DAYS = 3


def _jsonb(value) -> dict:
    """asyncpg devuelve jsonb como str cuando no hay codec registrado."""
    return json.loads(value) if isinstance(value, str) else value


class BankReconciliationRepository(BaseRepository):
    """Repository de conciliación bancaria — JWT-passthrough via base.py."""

    # ── Mutaciones (RPCs SECURITY DEFINER) ────────────────────────────────────

    async def import_statement(
        self,
        idempotency_key: str,
        bank_account_id: str,
        file_name: str,
        file_hash: str,
        lines_json: str,
    ) -> dict:
        """Invoca rpc_import_bank_statement con las líneas normalizadas (jsonb)."""
        row = await self.fetchrow(
            "SELECT public.rpc_import_bank_statement("
            "$1::text, $2::uuid, $3::text, $4::text, $5::jsonb) AS result",
            idempotency_key,
            bank_account_id,
            file_name,
            file_hash,
            lines_json,
        )
        return _jsonb(row["result"])

    async def open_session(
        self,
        bank_account_id: str,
        period_from: date,
        period_to: date,
        statement_closing_balance: Decimal,
    ) -> dict:
        row = await self.fetchrow(
            "SELECT public.rpc_open_reconciliation_session("
            "$1::uuid, $2::date, $3::date, $4::numeric) AS result",
            bank_account_id,
            period_from,
            period_to,
            statement_closing_balance,
        )
        return _jsonb(row["result"])

    async def close_session(self, session_id: str, close_reason: str | None) -> dict:
        row = await self.fetchrow(
            "SELECT public.rpc_close_reconciliation_session($1::uuid, $2::text) AS result",
            session_id,
            close_reason,
        )
        return _jsonb(row["result"])

    async def create_match(
        self,
        session_id: str,
        statement_line_ids: list[str],
        bank_movement_ids: list[str],
    ) -> dict:
        row = await self.fetchrow(
            "SELECT public.rpc_create_reconciliation_match("
            "$1::uuid, $2::uuid[], $3::uuid[]) AS result",
            session_id,
            statement_line_ids,
            bank_movement_ids,
        )
        return _jsonb(row["result"])

    async def undo_match(self, match_group: str, undo_reason: str) -> dict:
        row = await self.fetchrow(
            "SELECT public.rpc_undo_reconciliation_match($1::uuid, $2::text) AS result",
            match_group,
            undo_reason,
        )
        return _jsonb(row["result"])

    async def register_manual_movement(
        self,
        idempotency_key: str,
        bank_account_id: str,
        amount: Decimal,
        movement_type: str,
        value_date: date | None,
        description: str | None,
    ) -> dict:
        """Invoca rpc_register_bank_movement (carga manual — 'solo anotar' V1)."""
        row = await self.fetchrow(
            "SELECT public.rpc_register_bank_movement("
            "$1::text, $2::uuid, $3::numeric, $4::text, $5::date, NULL::uuid, $6::text) AS result",
            idempotency_key,
            bank_account_id,
            amount,
            movement_type,
            value_date,
            description,
        )
        return _jsonb(row["result"])

    # ── Lecturas ────────────────────────────────────────────────────────────
    #
    # fix/tenancy-bank-accounts-leak (2026-08-22): `account_id` es OBLIGATORIO
    # en TODOS los métodos de este bloque — "RLS SELECT aplica" (comentario
    # original de la clase) no alcanza mientras TENANCY_TX_SCOPE_ENABLED
    # siga apagada (el pool corre como owner de las tablas). Las cuatro
    # tablas leídas acá (bank_statement_imports, bank_statement_lines,
    # reconciliation_sessions, reconciliation_matches) denormalizan
    # account_id directo (mismo patrón C1/D6 documentado en la migración),
    # así que el fix es un filtro directo, sin JOIN.

    async def list_imports(self, bank_account_id: str, account_id: str) -> list[dict]:
        return await self.fetch(
            """
            SELECT id, bank_account_id, file_name, period_from, period_to,
                   line_count, created_at
            FROM public.bank_statement_imports
            WHERE bank_account_id = $1::uuid AND account_id = $2::uuid
            ORDER BY created_at DESC
            """,
            bank_account_id,
            account_id,
        )

    async def list_import_lines(self, import_id: str, account_id: str) -> list[dict]:
        """Líneas del import con estado derivado vía EXISTS sobre matches activos (D5)."""
        return await self.fetch(
            """
            SELECT l.id, l.line_no, l.value_date, l.description, l.amount, l.balance,
                   EXISTS (
                     SELECT 1 FROM public.reconciliation_matches m
                     WHERE m.statement_line_id = l.id AND m.status = 'active'
                   ) AS matched
            FROM public.bank_statement_lines l
            WHERE l.import_id = $1::uuid AND l.account_id = $2::uuid
            ORDER BY l.line_no
            """,
            import_id,
            account_id,
        )

    async def get_session(self, session_id: str, account_id: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            """
            SELECT id, bank_account_id, status, period_from, period_to,
                   statement_closing_balance, ledger_closing_balance, difference,
                   close_reason, opened_at, closed_at
            FROM public.reconciliation_sessions
            WHERE id = $1::uuid AND account_id = $2::uuid
            """,
            session_id,
            account_id,
        )

    async def list_sessions(self, bank_account_id: str, account_id: str) -> list[dict]:
        return await self.fetch(
            """
            SELECT id, bank_account_id, status, period_from, period_to,
                   statement_closing_balance, ledger_closing_balance, difference,
                   close_reason, opened_at, closed_at
            FROM public.reconciliation_sessions
            WHERE bank_account_id = $1::uuid AND account_id = $2::uuid
            ORDER BY opened_at DESC
            """,
            bank_account_id,
            account_id,
        )

    async def pending_lines(
        self, bank_account_id: str, account_id: str, period_from: date, period_to: date
    ) -> list[dict]:
        """Líneas de extracto del período sin match activo."""
        return await self.fetch(
            """
            SELECT l.id, l.line_no, l.value_date, l.description, l.amount, l.balance,
                   false AS matched
            FROM public.bank_statement_lines l
            WHERE l.bank_account_id = $1::uuid
              AND l.account_id = $2::uuid
              AND l.value_date BETWEEN $3::date AND $4::date
              AND NOT EXISTS (
                SELECT 1 FROM public.reconciliation_matches m
                WHERE m.statement_line_id = l.id AND m.status = 'active'
              )
            ORDER BY l.value_date, l.line_no
            """,
            bank_account_id,
            account_id,
            period_from,
            period_to,
        )

    async def pending_movements(
        self, bank_account_id: str, account_id: str, period_to: date
    ) -> list[dict]:
        """Movimientos del ledger sin conciliar hasta el corte (RN-D5: por value_date)."""
        return await self.fetch(
            """
            SELECT bm.id, bm.amount, bm.movement_type, bm.value_date, bm.description,
                   bm.balance_after, bm.reconciliation_status
            FROM public.bank_movements bm
            WHERE bm.bank_account_id = $1::uuid
              AND bm.account_id = $2::uuid
              AND bm.reconciliation_status = 'unreconciled'
              AND COALESCE(bm.value_date, bm.created_at::date) <= $3::date
            ORDER BY COALESCE(bm.value_date, bm.created_at::date), bm.created_at
            """,
            bank_account_id,
            account_id,
            period_to,
        )

    async def list_matches(self, session_id: str, account_id: str) -> list[dict]:
        """Grupos de match ACTIVOS de la sesión (para la lista de conciliados + undo)."""
        return await self.fetch(
            """
            SELECT m.match_group,
                   MIN(m.matched_at) AS matched_at,
                   COUNT(*) FILTER (WHERE m.statement_line_id IS NOT NULL)  AS line_count,
                   COUNT(*) FILTER (WHERE m.bank_movement_id IS NOT NULL)   AS movement_count,
                   COALESCE(SUM(l.amount), 0)                               AS amount
            FROM public.reconciliation_matches m
            LEFT JOIN public.bank_statement_lines l ON l.id = m.statement_line_id
            WHERE m.session_id = $1::uuid
              AND m.account_id = $2::uuid
              AND m.status = 'active'
            GROUP BY m.match_group
            ORDER BY MIN(m.matched_at) DESC
            """,
            session_id,
            account_id,
        )

    async def suggestions(
        self, bank_account_id: str, account_id: str, period_from: date, period_to: date
    ) -> list[dict]:
        """Sugerencias 1:1 (D4): monto exacto + value_date ±N días, ambos sin match activo.

        Solo propone — nunca confirma. Confirmar pasa por create_match (un solo
        camino de escritura).
        """
        return await self.fetch(
            f"""
            SELECT l.id            AS statement_line_id,
                   bm.id           AS bank_movement_id,
                   l.amount        AS amount,
                   l.value_date    AS line_value_date,
                   bm.value_date   AS movement_value_date,
                   l.description   AS line_description,
                   bm.description  AS movement_description
            FROM public.bank_statement_lines l
            JOIN public.bank_movements bm
              ON bm.bank_account_id = l.bank_account_id
             AND l.amount = bm.amount
             AND ABS(l.value_date - COALESCE(bm.value_date, bm.created_at::date))
                 <= {SUGGESTION_DATE_WINDOW_DAYS}
            WHERE l.bank_account_id = $1::uuid
              AND l.account_id = $2::uuid
              AND l.value_date BETWEEN $3::date AND $4::date
              AND bm.reconciliation_status = 'unreconciled'
              AND NOT EXISTS (
                SELECT 1 FROM public.reconciliation_matches m
                WHERE m.statement_line_id = l.id AND m.status = 'active'
              )
            ORDER BY l.value_date, l.line_no
            """,
            bank_account_id,
            account_id,
            period_from,
            period_to,
        )
