from __future__ import annotations

import datetime
import json
from decimal import Decimal
from typing import TYPE_CHECKING

import asyncpg

from backend.repositories.base import BaseRepository

if TYPE_CHECKING:
    from backend.repositories.outbox_repository import OutboxRepository


class PurchaseRepository(BaseRepository):
    async def list_by_org(self, account_id: str) -> list[dict]:
        return await self.fetch(
            "SELECT * FROM purchases WHERE account_id = $1 ORDER BY date DESC",
            account_id,
        )

    async def list_paginated_by_operation(
        self,
        account_id: str,
        page: int,
        page_size: int,
        date_from: datetime.date | None = None,
        date_to: datetime.date | None = None,
        cost_center_id: str | None = None,
        payment_method_id: str | None = None,
    ) -> tuple[list[asyncpg.Record], int]:
        """Página de compras agrupada por operación.

        cost-center-surface: `cost_center_id` es un filtro OPCIONAL. El centro
        de costo es un atributo de la OPERACIÓN (todas sus líneas comparten el
        mismo valor), así que el predicado va dentro de la CTE `op_page` y del
        COUNT — nunca en el join externo, que devolvería operaciones parciales
        y descuadraría el `total` de la paginación.

        metodos-pago-operaciones: `payment_method_id` es un filtro OPCIONAL,
        mismo criterio (atributo de la operación, predicado dentro de la CTE).
        """
        total: int = await self._conn.fetchval(
            """
            SELECT COUNT(DISTINCT COALESCE(operation_id::text, id::text))
            FROM purchases
            WHERE account_id = $1::uuid
              AND ($2::date IS NULL OR date >= $2::date)
              AND ($3::date IS NULL OR date <= $3::date)
              AND ($4::uuid IS NULL OR cost_center_id = $4::uuid)
              AND ($5::uuid IS NULL OR payment_method_id = $5::uuid)
            """,
            account_id, date_from, date_to, cost_center_id, payment_method_id,
        ) or 0

        rows: list[asyncpg.Record] = await self._conn.fetch(
            """
            WITH op_page AS (
              SELECT COALESCE(operation_id::text, id::text) AS op_key
              FROM purchases
              WHERE account_id = $1::uuid
                AND ($2::date IS NULL OR date >= $2::date)
                AND ($3::date IS NULL OR date <= $3::date)
                AND ($4::uuid IS NULL OR cost_center_id = $4::uuid)
                AND ($5::uuid IS NULL OR payment_method_id = $5::uuid)
              GROUP BY COALESCE(operation_id::text, id::text)
              ORDER BY MAX(date) DESC
              LIMIT $6 OFFSET $7
            )
            SELECT p.id, p.date, p.operation_id, p.description,
                   COALESCE(pi2.product_id, p.product_id) AS product_id,
                   COALESCE(pi2.quantity,   p.quantity)   AS quantity,
                   COALESCE(pi2.price,      p.amount)     AS amount,
                   COALESCE(pi2.subtotal,   p.total)      AS total,
                   pr.name AS product_name,
                   -- edicion-preserva-contexto (D11): expuestos para
                   -- prefillear el form de edición (espejo de SalesRepository).
                   p.branch_id,
                   COALESCE(pi2.unit_id, p.unit_id) AS unit_id,
                   p.cost_center_id,
                   cc.name AS cost_center_name,
                   p.payment_method_id,
                   pm.name AS payment_method_name,
                   pm.kind AS payment_method_kind,
                   -- compras-proveedor-cuenta-corriente (task 9.3): badge del
                   -- listado + prefill del selector de edición, mismo patrón
                   -- de relación opcional con suppliers que cost_center_name y
                   -- payment_method_name. Ojo: el gate check_backend_table_refs
                   -- escanea el texto SQL incluidos los comentarios "--": no
                   -- nombrar la keyword de union seguida de una palabra acá.
                   p.supplier_id,
                   sup.name AS supplier_name,
                   -- pagos-cableados-restantes (D6, task 9.3): MISMO
                   -- predicado que el guard P0423 de
                   -- rpc_atomic_update_purchase_operation. Sin la doble
                   -- convención de reference_id de la venta (no hay un
                   -- concepto análogo a sales_orders para compras): siempre
                   -- p.operation_id.
                   -- pos-banco-movimientos (D8): segundo término —
                   -- bank_movements, mismo predicado que el EXISTS de
                   -- rpc_atomic_update_purchase_operation (source_doc_type='purchase').
                   -- delete-guard-ledgers (task 9.2): expuestos también por
                   -- separado para que el diálogo de borrado enumere qué
                   -- libro compensaría.
                   -- caja-compras-cobranzas (D9): tercer término —
                   -- has_cash_movement, mismo predicado que el tercer EXISTS
                   -- del guard P0423 de rpc_atomic_update_purchase_operation
                   -- (movement_type='purchase_payment'). is_delete_blocked es
                   -- el MISMO EXISTS que precede al P0426 de
                   -- rpc_delete_purchase_operation: hay movimiento de caja Y
                   -- no hay sesión abierta en esa caja.
                   EXISTS (
                     SELECT 1 FROM supplier_account_movements sam
                     WHERE sam.reference_id = p.operation_id
                   ) AS has_account_charge,
                   EXISTS (
                     SELECT 1 FROM bank_movements bm
                     WHERE bm.source_doc_type = 'purchase' AND bm.source_doc_ref = p.operation_id
                   ) AS has_bank_movement,
                   EXISTS (
                     SELECT 1 FROM cash_movements cm
                     WHERE cm.movement_type = 'purchase_payment' AND cm.reference_id = p.operation_id
                   ) AS has_cash_movement,
                   -- Mismo molde que _EXPENSE_PROJECTION.is_delete_blocked
                   -- (backend/repositories/expense_repository.py): hay
                   -- movimiento de caja de esta compra Y no hay sesión
                   -- abierta en ESA MISMA caja donde compensar.
                   EXISTS (
                     SELECT 1
                     FROM cash_movements cm
                     JOIN cash_sessions cs ON cs.id = cm.session_id
                     WHERE cm.reference_id = p.operation_id AND cm.movement_type = 'purchase_payment'
                       AND NOT EXISTS (
                         SELECT 1 FROM cash_sessions os
                         WHERE os.cashbox_id = cs.cashbox_id AND os.status = 'open'
                       )
                   ) AS is_delete_blocked,
                   (
                     EXISTS (
                       SELECT 1 FROM supplier_account_movements sam
                       WHERE sam.reference_id = p.operation_id
                     )
                     OR EXISTS (
                       SELECT 1 FROM bank_movements bm
                       WHERE bm.source_doc_type = 'purchase' AND bm.source_doc_ref = p.operation_id
                     )
                     OR EXISTS (
                       SELECT 1 FROM cash_movements cm
                       WHERE cm.movement_type = 'purchase_payment' AND cm.reference_id = p.operation_id
                     )
                   ) AS is_payment_locked
            FROM purchases p
            JOIN op_page ON COALESCE(p.operation_id::text, p.id::text) = op_page.op_key
            LEFT JOIN purchase_items pi2 ON pi2.purchase_id = p.id AND pi2.product_id IS NOT NULL
            LEFT JOIN products pr ON COALESCE(pi2.product_id, p.product_id) = pr.id
            LEFT JOIN cost_centers cc ON cc.id = p.cost_center_id
            LEFT JOIN payment_methods pm ON pm.id = p.payment_method_id
            LEFT JOIN suppliers sup ON sup.id = p.supplier_id
            WHERE p.account_id = $1::uuid
            ORDER BY p.date DESC, p.id
            """,
            account_id, date_from, date_to, cost_center_id, payment_method_id, page_size, page * page_size,
        )
        return rows, total

    async def get_operation(self, operation_id: str, account_id: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            "SELECT * FROM purchases WHERE operation_id = $1 AND account_id = $2 LIMIT 1",
            operation_id,
            account_id,
        )

    async def get_idempotency(self, account_id: str, idempotency_key: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            """
            SELECT operation_id, operation_kind FROM operation_idempotency
            WHERE account_id = $1 AND idempotency_key = $2
            """,
            account_id,
            idempotency_key,
        )

    async def delete_by_id(self, purchase_id: str, account_id: str) -> bool:
        # delete-guard-ledgers: caller fino de rpc_delete_purchase_operation
        # (SECURITY DEFINER) — la secuencia anterior vive ahora ENTERA dentro
        # de la RPC, junto con la compensación de cuenta corriente de
        # proveedor (P0425) y banco. account_id no se pasa — la RPC resuelve
        # la cuenta del auth.uid() bajo el pool JWT-passthrough.
        row = await self._conn.fetchrow(
            "SELECT public.rpc_delete_purchase_operation(p_purchase_id => $1::uuid, p_reason => $2::text) AS result",
            purchase_id,
            "Compra eliminada",
        )
        return bool(row["result"]) if row is not None else False

    async def delete_by_operation(self, operation_id: str, account_id: str) -> bool:
        # delete-guard-ledgers: caller fino — mismo molde que delete_by_id,
        # vía p_operation_id (cubre TODAS las filas de la operación en una
        # sola llamada).
        row = await self._conn.fetchrow(
            "SELECT public.rpc_delete_purchase_operation(p_operation_id => $1::uuid, p_reason => $2::text) AS result",
            operation_id,
            "Compra eliminada (operación)",
        )
        return bool(row["result"]) if row is not None else False

    async def update_operation(
        self,
        purchase_ids: list[str],
        date: datetime.date,
        description: str | None,
        items: list[dict],
        payment_method_id: str | None = None,
        payment_method_provided: bool = False,
        branch_id: str | None = None,
        branch_provided: bool = False,
        supplier_id: str | None = None,
        supplier_provided: bool = False,
        cost_center_id: str | None = None,
        cost_center_provided: bool = False,
    ) -> None:
        # rpc_atomic_update_purchase_operation hace REVERSE de los ítems viejos +
        # APPLY de los nuevos en una sola transacción (stock sobre branch_stock,
        # C-21 hotfix). RLS/auth.uid() scope vía JWT-passthrough de la conexión.
        # metodos-pago-operaciones (D5): mismo patrón que SalesRepository.update_operation.
        # edicion-preserva-contexto (F1 §D3): branch_provided, mismo contrato tri-estado.
        # compras-proveedor-cuenta-corriente (D7, task 9.3, OQ-5 opción A):
        # supplier_id/supplier_provided + cost_center_id/cost_center_provided
        # TRAILING, después de branch_id/branch_provided (firma 8 -> 12 args
        # en supabase/migrations/20261009000001, ver p_supplier_id => $9 /
        # p_supplier_provided => $10 / p_cost_center_id => $11 /
        # p_cost_center_provided => $12).
        def _default(obj):
            if isinstance(obj, Decimal):
                return str(obj)
            raise TypeError(f"Not serializable: {type(obj)}")

        await self._conn.execute(
            """
            SELECT rpc_atomic_update_purchase_operation(
                $1::text[]::uuid[], $2::date, $3::text, $4::jsonb,
                p_payment_method_id => $5, p_payment_method_provided => $6,
                p_branch_id => $7, p_branch_provided => $8,
                p_supplier_id => $9, p_supplier_provided => $10,
                p_cost_center_id => $11, p_cost_center_provided => $12
            )
            """,
            purchase_ids,
            date,
            description,
            json.dumps(items, default=_default),
            payment_method_id,
            payment_method_provided,
            branch_id,
            branch_provided,
            supplier_id,
            supplier_provided,
            cost_center_id,
            cost_center_provided,
        )

    async def create_operation(
        self,
        user_id: str,
        account_id: str,
        items: list[dict],
        idempotency_key: str,
        date: datetime.date | None = None,
        description: str | None = None,
        branch_id: str | None = None,
        cost_center_id: str | None = None,
        payment_method_id: str | None = None,
        bank_account_id: str | None = None,
        supplier_id: str | None = None,
        cash_session_id: str | None = None,
    ) -> dict | None:
        # caja-compras-cobranzas (D3): branch_id propagated as the RPC's 5th
        # argument — antes se pasaba NULL literal acá (bug medido: 0 de 507
        # compras con branch_id). Es el ancla de la condición 2 del opt-in de
        # caja (D2): sin sucursal persistida, "sucursal efectiva de la
        # compra" nunca coincide con la de ninguna caja real.
        # cost-center-dimension: cost_center_id propagated to all rows via the RPC
        # metodos-pago-operaciones: payment_method_id propagated the same way
        # pos-banco-movimientos: bank_account_id propagated the same way (D2)
        # compras-proveedor-cuenta-corriente (D4): supplier_id propagated the
        # same way (9th arg in rpc_create_purchase_operation).
        # caja-compras-cobranzas (D2): cash_session_id propagated as the RPC's
        # 10th (trailing) argument — NULL = no-op, la compra no toca caja.
        existing = await self.get_idempotency(account_id, idempotency_key)
        if existing is not None:
            return dict(existing)

        def _default(obj):
            if isinstance(obj, Decimal):
                return str(obj)
            raise TypeError(f"Not serializable: {type(obj)}")

        clean_items = [
            {k: v for k, v in item.items() if k != "description"}
            for item in items
        ]

        row = await self._conn.fetchrow(
            """
            SELECT
                (rpc_create_purchase_operation($1, $2, $3, $4::jsonb, $5::uuid, $6::uuid, $7::uuid, $8::uuid, $9::uuid, $10::uuid)->>'operation_id')::uuid
                    AS operation_id,
                'purchase'::text AS operation_kind
            """,
            idempotency_key,
            date or datetime.date.today(),
            description,
            json.dumps(clean_items, default=_default),
            branch_id,
            cost_center_id,
            payment_method_id,
            bank_account_id,
            supplier_id,
            cash_session_id,
        )
        return dict(row) if row else None

    async def create_operation_with_event(
        self,
        outbox_repo: "OutboxRepository",
        user_id: str,
        account_id: str,
        items: list[dict],
        idempotency_key: str,
        date: datetime.date | None = None,
        description: str | None = None,
        branch_id: str | None = None,
        cost_center_id: str | None = None,
        payment_method_id: str | None = None,
        bank_account_id: str | None = None,
        supplier_id: str | None = None,
        cash_session_id: str | None = None,
    ) -> dict | None:
        """C-25 producer: create purchase + emit PurchaseCreated in the SAME transaction.

        Per DEC-20: the event INSERT is in the same transaction as the mutation.
        If the mutation fails, the event row rolls back with it (no orphaned event).
        On idempotency hit (existing operation), no new event is emitted.
        """
        existing = await self.get_idempotency(account_id, idempotency_key)
        if existing is not None:
            # Idempotency replay — return existing, do NOT emit a duplicate event
            return dict(existing)

        def _default(obj):
            if isinstance(obj, Decimal):
                return str(obj)
            raise TypeError(f"Not serializable: {type(obj)}")

        clean_items = [
            {k: v for k, v in item.items() if k != "description"}
            for item in items
        ]

        # Run mutation + event INSERT in the same transaction (DEC-20)
        # caja-compras-cobranzas (D3): branch_id propagated — mismo fix que
        # create_operation, las DOS ramas tenían el mismo NULL hardcodeado.
        # cost-center-dimension: cost_center_id propagated to all rows via the RPC
        # metodos-pago-operaciones: payment_method_id propagated the same way
        # compras-proveedor-cuenta-corriente: supplier_id propagated the same way
        # caja-compras-cobranzas (D2): cash_session_id propagated, trailing.
        async with self._conn.transaction():
            row = await self._conn.fetchrow(
                """
                SELECT
                    (rpc_create_purchase_operation($1, $2, $3, $4::jsonb, $5::uuid, $6::uuid, $7::uuid, $8::uuid, $9::uuid, $10::uuid)->>'operation_id')::uuid
                        AS operation_id,
                    'purchase'::text AS operation_kind
                """,
                idempotency_key,
                date or datetime.date.today(),
                description,
                json.dumps(clean_items, default=_default),
                branch_id,
                cost_center_id,
                payment_method_id,
                bank_account_id,
                supplier_id,
                cash_session_id,
            )

            if row is None:
                return None

            operation_id = str(row["operation_id"])

            # C-25 DEC-20: emit PurchaseCreated in the same transaction
            await outbox_repo.emit_event(
                account_id=account_id,
                event_type="PurchaseCreated",
                aggregate_type="Purchase",
                aggregate_id=operation_id,
                payload={
                    "account_id": account_id,
                    "operation_id": operation_id,
                    "item_count": len(clean_items),
                },
            )

        return dict(row)
