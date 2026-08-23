"""
Repository para bank_accounts — lectura (C2) y alta (bank-account-crud).

JWT-passthrough (invariant de BaseRepository) mantiene la RLS activa. La
creación invoca la RPC SECURITY DEFINER ya existente `rpc_create_bank_account`
(bank-account-ledger C1, migración 20260804000002) — sin INSERT directo, sin
service_role. Tras la RPC se hace un re-SELECT por id para devolver el shape
completo de BankAccountOut (D2 del design: consistencia con lo persistido).
"""
from __future__ import annotations

import json
from datetime import date
from decimal import Decimal

from backend.repositories.base import BaseRepository


def _jsonb(value):
    """asyncpg entrega jsonb como str cuando no hay type codec registrado.

    Mismo helper canónico que usan los demás repositories del proyecto
    (cash_session, sales_order, customer_account, etc.).
    """
    return json.loads(value) if isinstance(value, str) else value


class BankAccountRepository(BaseRepository):
    """Repository de bank_accounts — JWT-passthrough via base.py."""

    async def list_active(self, account_id: str) -> list[dict]:
        """Lista las bank_accounts activas de LA CUENTA DEL CALLER.

        fix/tenancy-bank-accounts-leak (2026-08-22): filtro EXPLÍCITO por
        account_id — el pool corre la sesión como owner de las tablas
        mientras TENANCY_TX_SCOPE_ENABLED sigue apagada, así que RLS NO
        aplica sola; sin este WHERE, la query devolvía TODAS las cuentas
        bancarias de TODOS los tenants (fuga multi-tenant confirmada en prod).

        v3-soft-delete-policy (D1): is_active = baja lógica reversible;
        deleted_at IS NULL excluye además las borradas (RN-B1). El borrado
        real es soft_delete("bank_accounts", ...) del BaseRepository.
        """
        return await self.fetch(
            """
            SELECT id, account_id, name, bank_name, cbu, alias, currency, account_kind, is_active
            FROM public.bank_accounts
            WHERE account_id = $1
              AND is_active = true
              AND deleted_at IS NULL
            ORDER BY name
            """,
            account_id,
        )

    async def get_by_id_for_account(
        self, bank_account_id: str, account_id: str
    ) -> dict | None:
        """fix/tenancy-bank-accounts-leak: helper de PERTENENCIA — a
        diferencia de `_get_by_id` (uso interno inmediatamente después de un
        INSERT propio), este método se usa para verificar que un
        bank_account_id que llega por path param realmente pertenece a la
        cuenta del caller ANTES de listar sus movimientos (IDOR guard)."""
        record = await self.fetchrow(
            """
            SELECT id, account_id, name, bank_name, cbu, alias, currency, account_kind, is_active
            FROM public.bank_accounts
            WHERE id = $1 AND account_id = $2
            """,
            bank_account_id,
            account_id,
        )
        return dict(record) if record is not None else None

    async def create(
        self,
        *,
        name: str,
        bank_name: str | None,
        cbu: str | None,
        alias: str | None,
        currency: str,
        opening_balance: Decimal,
        opening_date: date | None,
        account_kind: str = "bank",
    ) -> dict | None:
        """Invoca rpc_create_bank_account (SECURITY DEFINER) y re-SELECT-a la fila creada.

        La RPC devuelve un jsonb con bank_account_id/account_id/name/currency/
        opening_balance/account_kind/is_active (no incluye bank_name/cbu/alias).
        Se re-SELECT-a por id para armar el shape completo de BankAccountOut,
        consistente con lo que quedó persistido.

        cuentas-billetera-tipo: account_kind es el 8º parámetro posicional,
        AL FINAL — preserva el orden de los 7 originales (D4 del design.md).
        """
        rpc_row = await self.fetchrow(
            "SELECT rpc_create_bank_account($1, $2, $3, $4, $5, $6, $7, $8) AS result",
            name,
            bank_name,
            cbu,
            alias,
            currency,
            opening_balance,
            opening_date,
            account_kind,
        )
        if rpc_row is None:
            return None
        result = _jsonb(rpc_row["result"])
        bank_account_id = result["bank_account_id"] if isinstance(result, dict) else result
        return await self._get_by_id(bank_account_id)

    # ── Historial de movimientos — D3 (ledger-movement-history) ────────────────

    async def list_movements_page(
        self,
        bank_account_id: str,
        *,
        account_id: str,
        page: int,
        size: int,
        types: list[str] | None = None,
        status: str | None = None,
        q: str | None = None,
        date_from: date | None = None,
        date_to: date | None = None,
    ) -> dict:
        """GET /bank-accounts/{id}/movements (D3): todos los bank_movements de
        la cuenta, orden value_date DESC, created_at DESC para desempatar
        movimientos del mismo día.

        fix/tenancy-bank-accounts-leak (2026-08-22): `account_id` es
        OBLIGATORIO — antes solo filtraba por bm.bank_account_id, así que un
        bank_account_id de OTRO tenant (adivinado o filtrado de otra
        respuesta) devolvía sus movimientos igual (IDOR). El JOIN contra
        bank_accounts.account_id es defensa en profundidad DESPUÉS de que el
        service ya verificó pertenencia con get_by_id_for_account (404 si no
        es suya) — RLS sola no alcanza mientras TENANCY_TX_SCOPE_ENABLED
        siga apagada."""
        where = ["bm.bank_account_id = $1", "ba.account_id = $2"]
        params: list = [bank_account_id, account_id]

        if types:
            params.append(types)
            where.append(f"bm.movement_type = ANY(${len(params)}::text[])")
        if status:
            params.append(status)
            where.append(f"bm.reconciliation_status = ${len(params)}")
        if q:
            params.append(f"%{q}%")
            where.append(f"bm.description ILIKE ${len(params)}")
        if date_from:
            params.append(date_from)
            where.append(f"bm.value_date >= ${len(params)}")
        if date_to:
            params.append(date_to)
            where.append(f"bm.value_date <= ${len(params)}")

        where_sql = " AND ".join(where)

        select_sql = f"""
            SELECT
              bm.id, bm.bank_account_id, bm.amount, bm.balance_after,
              bm.movement_type, bm.value_date, bm.description, bm.created_at,
              bm.reconciliation_status
            FROM public.bank_movements bm
            JOIN public.bank_accounts ba ON ba.id = bm.bank_account_id
            WHERE {where_sql}
            ORDER BY bm.value_date DESC, bm.created_at DESC
        """
        count_sql = f"""
            SELECT COUNT(*)
            FROM public.bank_movements bm
            JOIN public.bank_accounts ba ON ba.id = bm.bank_account_id
            WHERE {where_sql}
        """
        return await self.paginate(select_sql, count_sql, *params, page=page, size=size)

    async def _get_by_id(self, bank_account_id) -> dict | None:
        record = await self.fetchrow(
            """
            SELECT id, account_id, name, bank_name, cbu, alias, currency, account_kind, is_active
            FROM public.bank_accounts
            WHERE id = $1
            """,
            bank_account_id,
        )
        return dict(record) if record is not None else None
