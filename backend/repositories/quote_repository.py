"""
C-29 v21-quote-salesorder — Quote repository.

Arquitectura 3 capas (D9): solo acceso a datos, sin lógica de negocio.
- CRUD directo para quotes/quote_items (D3: escritura directa del repo)
- accept_quote va por RPC SECURITY DEFINER (D3 excepción: atómica)
- JWT-passthrough vía BaseRepository
"""
from __future__ import annotations

import json
from decimal import Decimal
from typing import Any

import asyncpg

from backend.repositories.base import BaseRepository


def _jsonb(value: Any) -> dict:
    """asyncpg devuelve jsonb como str cuando no hay codec registrado."""
    return json.loads(value) if isinstance(value, str) else value


class QuoteRepository(BaseRepository):
    """Repository for quotes and quote_items — JWT-passthrough via base.py."""

    # ── Quotes ────────────────────────────────────────────────────────────────

    async def create_quote(
        self,
        account_id: str,
        branch_id: str | None,
        client_id: str | None,
        valid_until: Any,
        total: Decimal,
        items: list[dict],
        created_by: str,
    ) -> asyncpg.Record | None:
        """INSERT en quotes y sus quote_items. Devuelve la fila del quote."""
        row = await self.fetchrow(
            """
            INSERT INTO public.quotes
              (account_id, branch_id, client_id, valid_until, total, created_by)
            VALUES ($1::uuid, $2::uuid, $3::uuid, $4::date, $5::numeric, $6::uuid)
            RETURNING *
            """,
            account_id,
            branch_id,
            client_id,
            valid_until,
            total,
            created_by,
        )
        if row is None:
            return None

        quote_id = str(row["id"])

        # Insertar ítems
        for item in items:
            await self.execute(
                """
                INSERT INTO public.quote_items
                  (quote_id, account_id, product_id, unit_id, quantity, price, subtotal)
                VALUES
                  ($1::uuid, $2::uuid, $3::uuid, $4::uuid,
                   $5::numeric, $6::numeric, $7::numeric)
                """,
                quote_id,
                account_id,
                item.get("product_id"),
                item.get("unit_id"),
                item["quantity"],
                item["price"],
                item["subtotal"],
            )

        return row

    async def list_quotes(self, account_id: str) -> list[dict]:
        """Lista los quotes de una cuenta, ordenados por created_at DESC."""
        return await self.fetch(
            """
            SELECT * FROM public.quotes
            WHERE account_id = $1::uuid
            ORDER BY created_at DESC
            """,
            account_id,
        )

    async def get_quote(self, quote_id: str) -> asyncpg.Record | None:
        """Obtiene un quote por id."""
        return await self.fetchrow(
            "SELECT * FROM public.quotes WHERE id = $1::uuid",
            quote_id,
        )

    async def list_quote_items(self, quote_id: str) -> list[dict]:
        """Lista los ítems de un quote."""
        return await self.fetch(
            """
            SELECT * FROM public.quote_items
            WHERE quote_id = $1::uuid
            ORDER BY id
            """,
            quote_id,
        )

    async def transition_quote(self, quote_id: str, new_status: str) -> asyncpg.Record | None:
        """UPDATE del status del quote. Devuelve la fila actualizada."""
        return await self.fetchrow(
            """
            UPDATE public.quotes
            SET status = $2::text
            WHERE id = $1::uuid
            RETURNING *
            """,
            quote_id,
            new_status,
        )

    # ── accept (vía RPC SECURITY DEFINER) ────────────────────────────────────

    async def accept_quote(self, quote_id: str) -> dict:
        """
        Llama a rpc_accept_quote — transiciona el quote a 'accepted' y crea
        la SalesOrder con los mismos ítems en una transacción atómica.
        Devuelve: {sales_order_id, quote_id, status}.
        """
        row = await self.fetchrow(
            "SELECT public.rpc_accept_quote($1::uuid) AS result",
            quote_id,
        )
        if row is None:
            raise ValueError("rpc_accept_quote devolvió NULL")
        return _jsonb(row["result"])
