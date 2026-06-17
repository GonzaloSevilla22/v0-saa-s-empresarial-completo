from __future__ import annotations

import json

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

    async def close_session(self, session_id: str, counted_balance: float) -> dict:
        row = await self.fetchrow(
            "SELECT public.rpc_close_cash_session($1::uuid, $2::numeric) AS result",
            session_id,
            counted_balance,
        )
        return _jsonb(row["result"])

    async def current_session(self, cashbox_id: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            """
            SELECT * FROM public.cash_sessions
            WHERE cashbox_id = $1 AND status = 'open'
            LIMIT 1
            """,
            cashbox_id,
        )

    async def list_sessions(self, cashbox_id: str) -> list[dict]:
        return await self.fetch(
            """
            SELECT * FROM public.cash_sessions
            WHERE cashbox_id = $1
            ORDER BY opened_at DESC
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
    ) -> dict:
        row = await self.fetchrow(
            """
            SELECT public.rpc_register_cash_movement(
              $1::uuid, $2::numeric, $3::text, $4::uuid
            ) AS result
            """,
            session_id,
            amount,
            movement_type,
            reference_id,
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
