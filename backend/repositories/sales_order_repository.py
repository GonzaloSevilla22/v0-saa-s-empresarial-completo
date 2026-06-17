"""
C-29 v21-quote-salesorder — SalesOrder repository.

Arquitectura 3 capas (D9): solo acceso a datos.
- confirm y quick_sale van exclusivamente por RPCs SECURITY DEFINER (D1, D2)
- list/get vía SELECT directo (RLS garantiza tenencia)
- JWT-passthrough vía BaseRepository
"""
from __future__ import annotations

import json
from typing import Any

import asyncpg

from backend.repositories.base import BaseRepository


def _jsonb(value: Any) -> dict:
    """asyncpg devuelve jsonb como str cuando no hay codec registrado."""
    return json.loads(value) if isinstance(value, str) else value


class SalesOrderRepository(BaseRepository):
    """Repository for sales_orders and sales_order_items."""

    # ── RPCs (hot path) ───────────────────────────────────────────────────────

    async def confirm(
        self,
        idempotency_key: str,
        sales_order_id: str,
        payment_method: str,
        cash_session_id: str | None,
        comprobante_type: str | None,
        point_of_sale_id: str | None,
        branch_id: str | None,
        canal: str | None,
    ) -> dict:
        """
        Llama a rpc_confirm_sales_order — hot path transaccional:
        stock + caja + fiscal + outbox en un commit atómico.
        Idempotente por idempotency_key (DEC-06).
        """
        row = await self.fetchrow(
            """
            SELECT public.rpc_confirm_sales_order(
              $1::text,   -- p_idempotency_key
              $2::uuid,   -- p_sales_order_id
              $3::text,   -- p_payment_method
              $4::uuid,   -- p_cash_session_id
              $5::text,   -- p_comprobante_type
              $6::uuid,   -- p_point_of_sale_id
              $7::uuid,   -- p_branch_id
              $8::text    -- p_canal
            ) AS result
            """,
            idempotency_key,
            sales_order_id,
            payment_method,
            cash_session_id,
            comprobante_type,
            point_of_sale_id,
            branch_id,
            canal,
        )
        if row is None:
            raise ValueError("rpc_confirm_sales_order devolvió NULL")
        return _jsonb(row["result"])

    async def quick_sale(
        self,
        idempotency_key: str,
        client_id: str | None,
        items: list[dict],
        payment_method: str,
        cash_session_id: str | None,
        comprobante_type: str | None,
        point_of_sale_id: str | None,
        branch_id: str | None,
        canal: str | None,
    ) -> dict:
        """
        Llama a rpc_quick_sale — crea + confirma una SalesOrder en un paso (POS).
        Idempotente por idempotency_key (DEC-06).
        """
        items_json = json.dumps(items)
        row = await self.fetchrow(
            """
            SELECT public.rpc_quick_sale(
              $1::text,   -- p_idempotency_key
              $2::uuid,   -- p_client_id
              $3::jsonb,  -- p_items
              $4::text,   -- p_payment_method
              $5::uuid,   -- p_cash_session_id
              $6::text,   -- p_comprobante_type
              $7::uuid,   -- p_point_of_sale_id
              $8::uuid,   -- p_branch_id
              $9::text    -- p_canal
            ) AS result
            """,
            idempotency_key,
            client_id,
            items_json,
            payment_method,
            cash_session_id,
            comprobante_type,
            point_of_sale_id,
            branch_id,
            canal,
        )
        if row is None:
            raise ValueError("rpc_quick_sale devolvió NULL")
        return _jsonb(row["result"])

    # ── Lecturas ──────────────────────────────────────────────────────────────

    async def list_orders(self, account_id: str) -> list[dict]:
        """Lista las órdenes de venta de una cuenta."""
        return await self.fetch(
            """
            SELECT * FROM public.sales_orders
            WHERE account_id = $1::uuid
            ORDER BY created_at DESC
            """,
            account_id,
        )

    async def get_order(self, sales_order_id: str) -> asyncpg.Record | None:
        """Obtiene una orden de venta por id."""
        return await self.fetchrow(
            "SELECT * FROM public.sales_orders WHERE id = $1::uuid",
            sales_order_id,
        )

    async def list_order_items(self, sales_order_id: str) -> list[dict]:
        """Lista los ítems de una orden de venta."""
        return await self.fetch(
            """
            SELECT * FROM public.sales_order_items
            WHERE sales_order_id = $1::uuid
            ORDER BY id
            """,
            sales_order_id,
        )
