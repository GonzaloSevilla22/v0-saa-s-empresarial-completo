"""
Repository para C-30 — SupplierAccount / PaymentMade / SupplierCharge.

Espejo exacto de CustomerAccountRepository para el dominio de proveedores.
JWT-passthrough via base.py.
"""
from __future__ import annotations

import json

import asyncpg

from backend.repositories.base import BaseRepository


def _jsonb(value) -> dict:
    """asyncpg devuelve jsonb como str cuando no hay codec registrado."""
    return json.loads(value) if isinstance(value, str) else value


class SupplierAccountRepository(BaseRepository):
    """Repository para cuentas corrientes de proveedores — JWT-passthrough via base.py."""

    async def create_account(self, supplier_id: str) -> dict:
        """Invoca rpc_create_supplier_account(p_supplier_id) → crea/retorna la cuenta."""
        row = await self.fetchrow(
            "SELECT public.rpc_create_supplier_account($1::uuid) AS result",
            supplier_id,
        )
        return _jsonb(row["result"])

    async def get_account(self, account_id: str, supplier_id: str) -> asyncpg.Record | None:
        """Lee la fila de supplier_accounts para (account_id, supplier_id)."""
        return await self.fetchrow(
            """
            SELECT *
            FROM public.supplier_accounts
            WHERE account_id  = $1::uuid
              AND supplier_id = $2::uuid
            """,
            account_id,
            supplier_id,
        )

    async def list_movements(
        self,
        supplier_account_id: str,
        account_id: str,
        limit: int = 50,
        offset: int = 0,
    ) -> list[dict]:
        """Lista supplier_account_movements paginados por (supplier_account_id, created_at).

        Usado por `get_account` (vista combinada saldo+historial) — mantiene
        su firma limit/offset. Para el endpoint dedicado de listado usar
        `list_movements_page` (v3-api-standards §2.8).

        fix/tenancy-bank-accounts-leak (2026-08-22): `account_id` obligatorio
        — antes solo filtraba por supplier_account_id (IDOR: un id de OTRO
        tenant devolvía sus movimientos). account_id está desnormalizado en
        la tabla (RLS), así que el filtro es directo, sin JOIN.

        caja-compras-cobranzas (OQ-1, task 8.5): payment_method resuelto por
        LEFT JOIN a payments_made (reference_id = payments_made.id, sólo
        pobla cuando movement_type='payment_made') — NULL para el resto de
        los tipos y para los pagos históricos, sin backfill.
        """
        return await self.fetch(
            """
            SELECT sam.*, pm.payment_method
            FROM public.supplier_account_movements sam
            LEFT JOIN public.payments_made pm
              ON pm.id = sam.reference_id AND sam.movement_type = 'payment_made'
            WHERE sam.supplier_account_id = $1::uuid AND sam.account_id = $2::uuid
            ORDER BY sam.created_at DESC
            LIMIT $3
            OFFSET $4
            """,
            supplier_account_id,
            account_id,
            limit,
            offset,
        )

    async def list_movements_page(
        self,
        supplier_account_id: str,
        *,
        account_id: str,
        page: int,
        size: int,
    ) -> dict:
        """v3-api-standards §2.8: envelope estándar {items,total,page,pages}
        para GET /supplier-accounts/{id}/movements (reemplaza limit/offset +
        lista plana).

        fix/tenancy-bank-accounts-leak: `account_id` obligatorio — mismo IDOR
        que list_movements (ver nota ahí). caja-compras-cobranzas (OQ-1):
        mismo LEFT JOIN a payments_made que list_movements.

        cobranzas-reverso (D12, task 9.3): espejo exacto de
        CustomerAccountRepository.list_movements_page — is_reversible/
        is_reversal_blocked con el mismo predicado que evalúa
        rpc_reverse_payment_made."""
        return await self.paginate(
            """
            SELECT sam.*, pmd.payment_method,
              (sam.movement_type = 'payment_made' AND EXISTS (
                SELECT 1 FROM public.payments_made pm2 WHERE pm2.id = sam.reference_id
              )) AS is_reversible,
              EXISTS (
                SELECT 1
                FROM public.cash_movements cm
                JOIN public.cash_sessions cs ON cs.id = cm.session_id
                WHERE cm.reference_id = sam.reference_id AND cm.movement_type = 'payment_made'
                  AND NOT EXISTS (
                    SELECT 1 FROM public.cash_sessions cs_open
                    WHERE cs_open.cashbox_id = cs.cashbox_id AND cs_open.status = 'open'
                  )
              ) AS is_reversal_blocked
            FROM public.supplier_account_movements sam
            LEFT JOIN public.payments_made pmd
              ON pmd.id = sam.reference_id AND sam.movement_type = 'payment_made'
            WHERE sam.supplier_account_id = $1::uuid AND sam.account_id = $2::uuid
            ORDER BY sam.created_at DESC
            """,
            """
            SELECT COUNT(*)
            FROM public.supplier_account_movements sam
            WHERE sam.supplier_account_id = $1::uuid AND sam.account_id = $2::uuid
            """,
            supplier_account_id,
            account_id,
            page=page,
            size=size,
        )

    async def reverse_payment_made(self, payment_id: str, reason: str | None) -> dict:
        """cobranzas-reverso (task 9.3): invoca rpc_reverse_payment_made.
        Espejo exacto de CustomerAccountRepository.reverse_payment_received."""
        row = await self.fetchrow(
            "SELECT public.rpc_reverse_payment_made($1::uuid, $2::text) AS result",
            payment_id,
            reason,
        )
        return _jsonb(row["result"])

    async def register_payment_made(
        self,
        idempotency_key: str,
        supplier_id: str,
        amount: float,
        reference_purchase_id: str | None = None,
        payment_method: str = "cash",
        bank_account_id: str | None = None,
        cash_session_id: str | None = None,
    ) -> dict:
        """Invoca rpc_register_payment_made → registra pago a la cuenta del proveedor.

        bank-payment-routing C2: payment_method/bank_account_id son params aditivos
        trailing (default cash/None) — retrocompatibles con la firma de C-30.
        caja-compras-cobranzas (D5): cash_session_id trailing — NULL = no-op,
        el pago no toca caja.
        """
        row = await self.fetchrow(
            """
            SELECT public.rpc_register_payment_made(
              $1::text, $2::uuid, $3::numeric, $4::uuid, $5::text, $6::uuid, $7::uuid
            ) AS result
            """,
            idempotency_key,
            supplier_id,
            amount,
            reference_purchase_id,
            payment_method,
            bank_account_id,
            cash_session_id,
        )
        return _jsonb(row["result"])

    async def register_supplier_charge(
        self,
        idempotency_key: str,
        supplier_id: str,
        amount: float,
        reference_id: str | None = None,
    ) -> dict:
        """Invoca rpc_register_supplier_charge → cargo manual en la cuenta del proveedor."""
        row = await self.fetchrow(
            """
            SELECT public.rpc_register_supplier_charge(
              $1::text, $2::uuid, $3::numeric, $4::uuid
            ) AS result
            """,
            idempotency_key,
            supplier_id,
            amount,
            reference_id,
        )
        return _jsonb(row["result"])
