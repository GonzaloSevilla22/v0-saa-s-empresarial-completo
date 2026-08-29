"""
Repository de `expenses`.

gastos-forma-pago (D4, DEC-24): el alta, la edición y el borrado pasan a **una
sola llamada** a su RPC `SECURITY DEFINER` (`rpc_create_expense` /
`rpc_update_expense` / `rpc_delete_expense`). El repositorio ya NO compone SQL
de escritura ni orquesta pasos de negocio: dos libros (caja y banco) en una
transacción no se hacen con `INSERT` sueltos desde asyncpg, y el `DELETE FROM
expenses` crudo que había antes borraba sin compensar los libros — el mismo
estado que motivó `delete-guard-ledgers` (204 operaciones backfilleadas).

Las RPCs devuelven `jsonb`; tras cada una se re-SELECT-a la fila para armar el
shape completo de `ExpenseOut` (precedente: `BankAccountRepository.create` con
`rpc_create_bank_account`).

Tenencia: las RPCs resuelven la cuenta desde la SESIÓN (`current_account_ids()`)
y nunca por parámetro (lección del hotfix #454). Las LECTURAS de este archivo sí
filtran explícitamente por `account_id` — RLS es la red, no el guard único
(regla dura tras la fuga multi-tenant del PR #446).
"""
from __future__ import annotations

import datetime
import json
import uuid
from decimal import Decimal

from backend.repositories.base import BaseRepository


def _jsonb(value):
    """asyncpg entrega jsonb como str cuando no hay type codec registrado.

    Mismo helper canónico que el resto de los repositories del proyecto.
    """
    return json.loads(value) if isinstance(value, str) else value


def _uid(value) -> str | None:
    """Normaliza uuid → str: es lo que asyncpg recibe en el transporte real
    para un parámetro declarado `uuid` en una llamada posicional."""
    if value is None:
        return None
    return str(value) if isinstance(value, uuid.UUID) else value


# ── Proyección única de lectura ───────────────────────────────────────────────
# D11/D18: los cuatro derivados se calculan acá con los MISMOS predicados que
# evalúan los guards del servidor, para que el listado deshabilite el control
# con el motivo visible antes de que el usuario llegue al 409:
#
#   has_cash_movement / has_bank_movement → los dos EXISTS de los guards P0423
#     de rpc_update_expense (cash_movements.reference_id = <gasto>;
#     bank_movements.source_doc_type='expense' AND source_doc_ref = <gasto>).
#   is_payment_locked → el OR de los dos, exactamente como bloquea la edición.
#   is_delete_blocked → el único bloqueo propio del borrado: hay movimientos de
#     caja del gasto y NO hay sesión abierta en ESA caja donde compensar — el
#     mismo par de predicados que rpc_delete_expense evalúa antes del P0426.
#
# Se define UNA sola vez y la usan get_by_id, list_paginated y el re-SELECT de
# las mutaciones: una segunda definición del predicado es una segunda fuente de
# verdad, que es lo que la spec prohíbe explícitamente.
_EXPENSE_PROJECTION = """
    e.id, e.user_id, e.account_id, e.category, e.amount, e.description,
    e.date, e.created_at, e.cost_center_id, e.branch_id, e.payment_method_id,
    pm.name AS payment_method_name,
    pm.kind AS payment_method_kind,
    EXISTS (
      SELECT 1 FROM public.cash_movements cm
      WHERE cm.reference_id = e.id
    ) AS has_cash_movement,
    EXISTS (
      SELECT 1 FROM public.bank_movements bm
      WHERE bm.source_doc_type = 'expense' AND bm.source_doc_ref = e.id
    ) AS has_bank_movement,
    (
      EXISTS (
        SELECT 1 FROM public.cash_movements cm
        WHERE cm.reference_id = e.id
      )
      OR EXISTS (
        SELECT 1 FROM public.bank_movements bm
        WHERE bm.source_doc_type = 'expense' AND bm.source_doc_ref = e.id
      )
    ) AS is_payment_locked,
    EXISTS (
      SELECT 1
      FROM public.cash_movements cm
      JOIN public.cash_sessions cs ON cs.id = cm.session_id
      WHERE cm.reference_id = e.id AND cm.movement_type = 'expense'
        AND NOT EXISTS (
          SELECT 1 FROM public.cash_sessions os
          WHERE os.cashbox_id = cs.cashbox_id AND os.status = 'open'
        )
    ) AS is_delete_blocked
"""

# El LEFT JOIN del nombre NO filtra is_active ni deleted_at a propósito (D18):
# una forma de pago dada de baja tiene que seguir nombrándose en los gastos que
# ya la usaron. Mismo criterio que el join `pm` de SalesRepository.
_EXPENSE_FROM = """
    FROM public.expenses e
    LEFT JOIN public.payment_methods pm ON pm.id = e.payment_method_id
"""


class ExpenseRepository(BaseRepository):
    # ── Lecturas ──────────────────────────────────────────────────────────────

    async def list_paginated(
        self,
        account_id: str,
        *,
        page: int,
        page_size: int,
        date_from: datetime.date | None = None,
        date_to: datetime.date | None = None,
        search: str | None = None,
        cost_center_id: str | None = None,
        payment_method_id: str | None = None,
    ) -> tuple[list[dict], int]:
        """D18 — listado paginado con filtros server-side, espejo de
        `SalesRepository.list_paginated_by_operation`. `page` es 0-based.

        El COUNT usa EXACTAMENTE los mismos filtros y los mismos parámetros
        posicionales que el SELECT: si divergen, `total` miente y la
        paginación del cliente se desalinea.
        """
        filters = """
            WHERE e.account_id = $1::uuid
              AND ($2::date IS NULL OR e.date >= $2::date)
              AND ($3::date IS NULL OR e.date < ($3::date + 1))
              AND ($4::text IS NULL OR e.category ILIKE $4 OR e.description ILIKE $4)
              AND ($5::uuid IS NULL OR e.cost_center_id = $5::uuid)
              AND ($6::uuid IS NULL OR e.payment_method_id = $6::uuid)
        """
        args = (
            account_id,
            date_from,
            date_to,
            f"%{search}%" if search else None,
            _uid(cost_center_id),
            _uid(payment_method_id),
        )

        total: int = await self._conn.fetchval(
            f"SELECT COUNT(*) {_EXPENSE_FROM} {filters}", *args
        ) or 0

        rows = await self._conn.fetch(
            f"""
            SELECT {_EXPENSE_PROJECTION}
            {_EXPENSE_FROM}
            {filters}
            ORDER BY e.date DESC, e.created_at DESC, e.id
            LIMIT $7 OFFSET $8
            """,
            *args,
            page_size,
            page * page_size,
        )
        return [dict(r) for r in rows], total

    async def get_by_id(self, expense_id: str, account_id: str) -> dict | None:
        record = await self._conn.fetchrow(
            f"""
            SELECT {_EXPENSE_PROJECTION}
            {_EXPENSE_FROM}
            WHERE e.id = $1::uuid AND e.account_id = $2::uuid
            """,
            _uid(expense_id),
            _uid(account_id),
        )
        return dict(record) if record is not None else None

    # ── Escrituras: una llamada por operación (D4) ────────────────────────────

    async def create(
        self,
        account_id: str,
        *,
        category: str,
        amount: Decimal,
        date: datetime.date,
        description: str | None = None,
        branch_id: str | None = None,
        cost_center_id: str | None = None,
        payment_method_id: str | None = None,
        cash_session_id: str | None = None,
        bank_account_id: str | None = None,
    ) -> dict | None:
        """`rpc_create_expense` — alta + impacto en caja y banco, atómico.

        El orden posicional replica la firma SQL exacta; `account_id` NO viaja
        como parámetro (la RPC lo resuelve desde la sesión) pero sí se usa para
        el re-SELECT con filtro explícito de tenencia.
        """
        rpc_row = await self._conn.fetchrow(
            "SELECT public.rpc_create_expense($1, $2, $3, $4, $5, $6, $7, $8, $9) AS result",
            category,
            amount,
            date,
            description,
            _uid(branch_id),
            _uid(cost_center_id),
            _uid(payment_method_id),
            _uid(cash_session_id),
            _uid(bank_account_id),
        )
        if rpc_row is None:
            return None
        result = _jsonb(rpc_row["result"]) or {}
        return await self.get_by_id(result["expense_id"], account_id)

    async def update(
        self,
        expense_id: str,
        account_id: str,
        *,
        category: str | None,
        amount: Decimal | None,
        date: datetime.date | None,
        description: str | None,
        payment_method_id: str | None,
        payment_method_provided: bool,
        branch_id: str | None,
        branch_provided: bool,
        cost_center_id: str | None,
        cost_center_provided: bool,
    ) -> dict | None:
        """`rpc_update_expense` — edición con guards de inmutabilidad (P0423) y
        contrato tri-estado. Los `*_provided` son el "la clave vino en el JSON":
        sin ellos, un `null` explícito sería indistinguible de una ausencia.
        """
        rpc_row = await self._conn.fetchrow(
            "SELECT public.rpc_update_expense("
            "$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) AS result",
            _uid(expense_id),
            category,
            amount,
            date,
            description,
            _uid(payment_method_id),
            payment_method_provided,
            _uid(branch_id),
            branch_provided,
            _uid(cost_center_id),
            cost_center_provided,
        )
        if rpc_row is None:
            return None
        return await self.get_by_id(expense_id, account_id)

    async def delete(self, expense_id: str, account_id: str) -> dict:
        """`rpc_delete_expense` — compensa caja (`expense_reversal`) y banco
        (movimiento espejo) ANTES de borrar. Devuelve el jsonb de la RPC:
        `{expense_id, deleted, cash_reversal_id, bank_reversals}`.

        Una sola llamada: no hay pre-chequeo de existencia acá, porque la RPC
        localiza el gasto por `id + cuenta de la sesión` y ya responde P0404.
        """
        rpc_row = await self._conn.fetchrow(
            "SELECT public.rpc_delete_expense($1) AS result",
            _uid(expense_id),
        )
        return _jsonb(rpc_row["result"]) if rpc_row is not None else {}
