from __future__ import annotations

import json
from datetime import date

import asyncpg

from backend.repositories.base import BaseRepository


def _jsonb(value) -> dict:
    """asyncpg devuelve jsonb como str cuando no hay codec registrado."""
    return json.loads(value) if isinstance(value, str) else value


class CashSessionRepository(BaseRepository):
    """Repository for cash_sessions and cash_movements — JWT-passthrough via base.py."""

    # ── CashSession ──────────────────────────────────────────────────────────

    async def open_session(self, cashbox_id: str, opening_balance: float) -> dict:
        row = await self.fetchrow(
            "SELECT public.rpc_open_cash_session($1::uuid, $2::numeric) AS result",
            cashbox_id,
            opening_balance,
        )
        return _jsonb(row["result"])

    async def close_session(
        self,
        session_id: str,
        counted_balance: float,
        idempotency_key: str | None = None,
    ) -> dict:
        """v3-api-standards §4: registra idempotencia en la misma transacción
        de cierre (RPC actualizado — 3er parámetro opcional, DEFAULT NULL en
        SQL, no rompe llamadas existentes sin clave)."""
        row = await self.fetchrow(
            "SELECT public.rpc_close_cash_session($1::uuid, $2::numeric, $3::text) AS result",
            session_id,
            counted_balance,
            idempotency_key,
        )
        return _jsonb(row["result"])

    # banco-caja-historial-ajustes (D5): adjustments_total es un snapshot
    # persistido AL CIERRE (rpc_close_cash_session) — para una sesión todavía
    # 'open' esa columna vive en su DEFAULT 0 (no NULL, así que no se puede
    # distinguir "sin calcular" de "genuinamente cero" leyendo la columna
    # sola). Se calcula al vuelo con una subquery SOLO para status='open';
    # 'closed' usa directamente el valor materializado por el cierre.
    _SESSION_COLUMNS = """
        cs.id, cs.cashbox_id, cs.status, cs.opening_balance, cs.closing_balance,
        cs.counted_balance, cs.expected_balance, cs.difference,
        cs.opened_by, cs.closed_by, cs.opened_at, cs.closed_at,
        CASE WHEN cs.status = 'open'
          THEN COALESCE(
            (SELECT SUM(cm.amount) FROM public.cash_movements cm
             WHERE cm.session_id = cs.id AND cm.movement_type = 'adjustment'),
            0
          )
          ELSE cs.adjustments_total
        END AS adjustments_total
    """

    async def current_session(self, cashbox_id: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            f"""
            SELECT {self._SESSION_COLUMNS}
            FROM public.cash_sessions cs
            WHERE cs.cashbox_id = $1 AND cs.status = 'open'
            LIMIT 1
            """,
            cashbox_id,
        )

    async def list_sessions(self, cashbox_id: str) -> list[dict]:
        return await self.fetch(
            f"""
            SELECT {self._SESSION_COLUMNS}
            FROM public.cash_sessions cs
            WHERE cs.cashbox_id = $1
            ORDER BY cs.opened_at DESC
            """,
            cashbox_id,
        )

    # ── CashMovement ─────────────────────────────────────────────────────────

    async def register_movement(
        self,
        session_id: str,
        amount: float,
        movement_type: str,
        reference_id: str | None,
        description: str | None = None,
    ) -> dict:
        """banco-caja-historial-ajustes: description es el 5to parámetro
        trailing (DEFAULT NULL en SQL) — los llamadores existentes (hot path
        de venta) no se tocan; el ajuste lo pasa explícito (task 6.2, mismo
        endpoint, sin camino paralelo)."""
        row = await self.fetchrow(
            """
            SELECT public.rpc_register_cash_movement(
              $1::uuid, $2::numeric, $3::text, $4::uuid, $5::text
            ) AS result
            """,
            session_id,
            amount,
            movement_type,
            reference_id,
            description,
        )
        return _jsonb(row["result"])

    async def list_movements(self, session_id: str) -> list[dict]:
        return await self.fetch(
            """
            SELECT * FROM public.cash_movements
            WHERE session_id = $1
            ORDER BY created_at ASC
            """,
            session_id,
        )

    # ── Historial por cashbox — D2 (todas las sesiones, no solo la abierta) ────

    async def list_movements_by_cashbox_page(
        self,
        cashbox_id: str,
        *,
        page: int,
        size: int,
        types: list[str] | None = None,
        q: str | None = None,
        date_from: date | None = None,
        date_to: date | None = None,
    ) -> dict:
        """GET /cashboxes/{id}/movements (D2 del design): cash_movements ⋈
        cash_sessions por cashbox_id, orden created_at DESC, con filtros de
        tipo/texto/fecha en SQL (corrige el atajo del molde de Stock — acá el
        buscador va al servidor, task 7.3). RLS de cash_movements ya cubre el
        aislamiento por cuenta vía la cadena de FKs (JWT-passthrough)."""
        where = ["cs.cashbox_id = $1"]
        params: list = [cashbox_id]

        if types:
            params.append(types)
            where.append(f"cm.movement_type = ANY(${len(params)}::text[])")
        if q:
            params.append(f"%{q}%")
            where.append(f"cm.description ILIKE ${len(params)}")
        if date_from:
            params.append(date_from)
            where.append(f"cm.created_at::date >= ${len(params)}")
        if date_to:
            params.append(date_to)
            where.append(f"cm.created_at::date <= ${len(params)}")

        where_sql = " AND ".join(where)

        # v3-api-standards §2 — helper centralizado (BaseRepository.paginate):
        # una sola definición de COUNT+LIMIT/OFFSET+envelope, reutilizada por
        # todos los listados paginados del backend (journal_entries, etc.).
        select_sql = f"""
            SELECT
              cm.id, cm.session_id, cm.amount, cm.movement_type, cm.reference_id,
              cm.balance_after, cm.created_by, cm.created_at, cm.description,
              cs.opened_at AS session_opened_at, cs.status AS session_status
            FROM public.cash_movements cm
            JOIN public.cash_sessions cs ON cs.id = cm.session_id
            WHERE {where_sql}
            ORDER BY cm.created_at DESC
        """
        count_sql = f"""
            SELECT COUNT(*)
            FROM public.cash_movements cm
            JOIN public.cash_sessions cs ON cs.id = cm.session_id
            WHERE {where_sql}
        """
        return await self.paginate(select_sql, count_sql, *params, page=page, size=size)
