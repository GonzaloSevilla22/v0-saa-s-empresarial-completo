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

    # cobranzas-vencimientos (task 7.5): espejo exacto del diccionario de
    # tramos de CustomerAccountRepository — traducción por diccionario a
    # predicado, jamás interpolación del input.
    _PAYABLES_BUCKET_FILTERS: dict[str, str] = {
        "overdue": "overdue_total > 0",
        "current": "amount_current > 0",
        "overdue_1_30": "amount_overdue_1_30 > 0",
        "overdue_31_60": "amount_overdue_31_60 > 0",
        "overdue_60_plus": "amount_overdue_60_plus > 0",
        "no_due_date": "amount_no_due_date > 0",
    }

    _PAYABLES_SORT_COLUMNS: dict[str, str] = {
        "balance": "balance",
        "days_since_last_charge": "days_since_last_charge",
        "days_since_last_payment": "days_since_last_payment",
        "supplier_name": "supplier_name",
    }

    # cobranzas-vencimientos (D4/D7): espejo del bloque FIFO de
    # CustomerAccountRepository — cargo = 'purchase' + adjustment positivo.
    _MOVEMENT_OPEN_ITEMS_CTE = """
            WITH pool AS (
              SELECT COALESCE(SUM(-m.amount), 0) AS credit
              FROM public.supplier_account_movements m
              WHERE m.supplier_account_id = $1::uuid AND m.account_id = $2::uuid
                AND NOT (m.movement_type = 'purchase' OR (m.movement_type = 'adjustment' AND m.amount > 0))
            ),
            open_items AS (
              SELECT m.id,
                     LEAST(m.amount, GREATEST(0::numeric,
                       SUM(m.amount) OVER (
                         ORDER BY COALESCE(m.due_date, (m.created_at AT TIME ZONE 'America/Argentina/Mendoza')::date),
                                  m.created_at, m.id
                       ) - (SELECT credit FROM pool)
                     )) AS open_amount
              FROM public.supplier_account_movements m
              WHERE m.supplier_account_id = $1::uuid AND m.account_id = $2::uuid
                AND (m.movement_type = 'purchase' OR (m.movement_type = 'adjustment' AND m.amount > 0))
            )
    """

    _MOVEMENT_DUE_DERIVATIVES = """
              oi.open_amount,
              CASE WHEN oi.id IS NOT NULL AND sam.due_date IS NOT NULL
                   THEN (sam.due_date < public.reporting_local_today() AND oi.open_amount > 0)
                   END AS is_overdue,
              CASE WHEN oi.id IS NOT NULL AND sam.due_date IS NOT NULL
                        AND sam.due_date < public.reporting_local_today() AND oi.open_amount > 0
                   THEN (public.reporting_local_today() - sam.due_date)
                   END AS days_overdue
    """

    async def list_payables_page(
        self,
        account_id: str,
        *,
        page: int,
        size: int,
        sort: str = "balance",
        sort_dir: str = "desc",
        bucket: str | None = None,
    ) -> dict:
        """cobranzas-vencimientos (task 7.5): listado paginado de acreedores —
        molde exacto de list_receivables_page sobre rpc_payables_report. El
        predicado de "quién es acreedor" vive UNA sola vez en el RPC; el
        guard de membresía es su P0401."""
        sort_column = self._PAYABLES_SORT_COLUMNS.get(sort, "balance")
        direction = "ASC" if sort_dir == "asc" else "DESC"
        nulls = (
            " NULLS LAST"
            if sort_column in ("days_since_last_charge", "days_since_last_payment")
            else ""
        )
        bucket_predicate = self._PAYABLES_BUCKET_FILTERS.get(bucket or "")
        where = f"WHERE {bucket_predicate}" if bucket_predicate else ""
        return await self.paginate(
            f"""
            SELECT *
            FROM public.rpc_payables_report($1::uuid)
            {where}
            ORDER BY {sort_column} {direction}{nulls}, supplier_id ASC
            """,
            f"""
            SELECT COUNT(*)
            FROM public.rpc_payables_report($1::uuid)
            {where}
            """,
            account_id,
            page=page,
            size=size,
        )

    async def get_payables_summary(self, account_id: str) -> dict:
        """cobranzas-vencimientos (task 7.5): total por pagar + vencido +
        cantidad de acreedores, agregado sobre el MISMO RPC del listado."""
        row = await self.fetchrow(
            """
            SELECT COALESCE(SUM(balance), 0)       AS total_payable,
                   COALESCE(SUM(overdue_total), 0) AS overdue_total,
                   COUNT(*)::int                   AS creditor_count
            FROM public.rpc_payables_report($1::uuid)
            """,
            account_id,
        )
        return dict(row)

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

        cobranzas-reverso (D12, task 13.2): espejo exacto del hallazgo de
        CustomerAccountRepository.list_movements — es la query que alimenta
        GET /proveedores/{id}/cuenta (SupplierAccountHistory en la pantalla
        real), no list_movements_page.
        """
        return await self.fetch(
            f"""
            {self._MOVEMENT_OPEN_ITEMS_CTE}
            SELECT sam.*, pmethod.name AS payment_method,
              {self._MOVEMENT_DUE_DERIVATIVES},
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
              ) AS is_reversal_blocked,
              EXISTS (
                SELECT 1 FROM public.cash_movements cm2
                WHERE cm2.reference_id = sam.reference_id AND cm2.movement_type = 'payment_made'
              ) AS has_cash_movement,
              EXISTS (
                SELECT 1 FROM public.bank_movements bm
                WHERE bm.source_doc_type = 'payment_made' AND bm.source_doc_ref = sam.reference_id
              ) AS has_bank_movement
            FROM public.supplier_account_movements sam
            LEFT JOIN open_items oi ON oi.id = sam.id
            LEFT JOIN public.payments_made pm
              ON pm.id = sam.reference_id AND sam.movement_type = 'payment_made'
            LEFT JOIN public.payment_methods pmethod
              ON pmethod.id = pm.payment_method_id
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
        is_reversal_blocked/has_cash_movement/has_bank_movement con el mismo
        predicado que evalúa rpc_reverse_payment_made."""
        return await self.paginate(
            f"""
            {self._MOVEMENT_OPEN_ITEMS_CTE}
            SELECT sam.*, pmethod.name AS payment_method,
              {self._MOVEMENT_DUE_DERIVATIVES},
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
              ) AS is_reversal_blocked,
              EXISTS (
                SELECT 1 FROM public.cash_movements cm2
                WHERE cm2.reference_id = sam.reference_id AND cm2.movement_type = 'payment_made'
              ) AS has_cash_movement,
              EXISTS (
                SELECT 1 FROM public.bank_movements bm
                WHERE bm.source_doc_type = 'payment_made' AND bm.source_doc_ref = sam.reference_id
              ) AS has_bank_movement
            FROM public.supplier_account_movements sam
            LEFT JOIN open_items oi ON oi.id = sam.id
            LEFT JOIN public.payments_made pmd
              ON pmd.id = sam.reference_id AND sam.movement_type = 'payment_made'
            LEFT JOIN public.payment_methods pmethod
              ON pmethod.id = pmd.payment_method_id
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
        payment_method_id: str | None = None,
        bank_account_id: str | None = None,
        cash_session_id: str | None = None,
    ) -> dict:
        """Invoca rpc_register_payment_made → registra pago a la cuenta del proveedor.

        cobranzas-catalogo-pagos (D1): espejo exacto de
        CustomerAccountRepository.register_payment_received — payment_method
        (text) → payment_method_id (uuid) en la MISMA posición.
        caja-compras-cobranzas (D5): cash_session_id trailing — NULL = no-op,
        el pago no toca caja.
        """
        row = await self.fetchrow(
            """
            SELECT public.rpc_register_payment_made(
              $1::text, $2::uuid, $3::numeric, $4::uuid, $5::uuid, $6::uuid, $7::uuid
            ) AS result
            """,
            idempotency_key,
            supplier_id,
            amount,
            reference_purchase_id,
            payment_method_id,
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
