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
            ),
            op_fp AS (
              -- edicion-operaciones-con-dinero (tanda B, D15): el ESTADO de la huella NETA de cada operación de la página, UNA
              -- vez por operación: los cuatro indicadores y los datos vigentes que el formulario de edición precarga. UNA sola
              -- definición (función op_money_footprint_state), la misma base que usan el borrado y la edición.
              SELECT op_page.op_key, fp.has_account_charge, fp.has_cash_movement, fp.has_bank_movement, fp.is_delete_blocked,
                     fp.charge_due_date, fp.charge_party_id, fp.cash_cashbox_id, fp.cash_open_session_id, fp.bank_account_id
              FROM op_page
              LEFT JOIN LATERAL public.op_money_footprint_state(
                $1::uuid, 'purchase', ARRAY[op_page.op_key::uuid]
              ) fp ON TRUE
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
                   -- multiusuario-operativo tanda B (D9, OQ-4 b): el AUTOR de la operación, para que la
                   -- interfaz oculte "Editar"/"Eliminar" sobre lo ajeno cuando el rol no es dueño ni
                   -- administrador. Es sólo informativo: la autoridad es la RPC (P0403).
                   p.user_id AS created_by,
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
                   -- remitos-compra (tanda B, D11/D13): el remito de compra que originó
                   -- la compra, derivado de purchases.source_delivery_note_id (sin
                   -- columnas denormalizadas), con la cuenta y el sentido en el cruce.
                   -- source_delivery_note_branch_active usa el MISMO predicado que
                   -- rpc_delete_purchase_operation (sucursal del remito activa y no
                   -- cerrada, con la cuenta en el cruce): el listado deshabilita
                   -- "Eliminar" con su motivo ANTES de llegar al P0422. Y el motivo por
                   -- el que la operación NO se edita: una compra nacida de un remito es
                   -- inmutable (P0423 delivery_note_purchase_locked) porque editarla
                   -- restaría stock que el remito sigue aportando; es el mismo token del
                   -- RAISE para que la UI explique antes del error.
                   p.source_delivery_note_id               AS source_delivery_note_id,
                   sdn.number                              AS source_delivery_note_number,
                   (sdb.is_active = TRUE AND sdb.status IS DISTINCT FROM 'closed')
                                                           AS source_delivery_note_branch_active,
                   CASE WHEN p.source_delivery_note_id IS NOT NULL THEN 'delivery_note_purchase_locked' END
                                                           AS edit_locked_reason,
                   -- edicion-operaciones-con-dinero (tanda B, D15): los cuatro indicadores y los datos vigentes de la huella NETA
                   -- (CTE op_fp de arriba). is_delete_blocked: hay neto de caja de esta compra Y no hay sesión abierta en ESA MISMA
                   -- caja donde compensar (el mismo par de condiciones que precede al P0426 del borrado). `is_payment_locked` SE
                   -- RETIRÓ: la edición ya no se bloquea por dinero.
                   COALESCE(fp.has_account_charge, FALSE) AS has_account_charge,
                   COALESCE(fp.has_bank_movement,  FALSE) AS has_bank_movement,
                   COALESCE(fp.has_cash_movement,  FALSE) AS has_cash_movement,
                   COALESCE(fp.is_delete_blocked,  FALSE) AS is_delete_blocked,
                   fp.charge_due_date,
                   fp.charge_party_id,
                   fp.cash_cashbox_id,
                   fp.cash_open_session_id,
                   fp.bank_account_id
            FROM purchases p
            JOIN op_page ON COALESCE(p.operation_id::text, p.id::text) = op_page.op_key
            LEFT JOIN op_fp fp ON fp.op_key = op_page.op_key
            LEFT JOIN purchase_items pi2 ON pi2.purchase_id = p.id AND pi2.product_id IS NOT NULL
            LEFT JOIN products pr ON COALESCE(pi2.product_id, p.product_id) = pr.id
            LEFT JOIN cost_centers cc ON cc.id = p.cost_center_id
            LEFT JOIN payment_methods pm ON pm.id = p.payment_method_id
            LEFT JOIN suppliers sup ON sup.id = p.supplier_id
            LEFT JOIN delivery_notes sdn ON sdn.id = p.source_delivery_note_id AND sdn.account_id = p.account_id AND sdn.direction = 'purchase'
            LEFT JOIN branches sdb ON sdb.id = sdn.branch_id AND sdb.account_id = sdn.account_id
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
        cash_session_id: str | None = None,
        cash_provided: bool = False,
        bank_account_id: str | None = None,
        bank_account_provided: bool = False,
        due_date: datetime.date | None = None,
        due_date_provided: bool = False,
        reason: str | None = None,
        dry_run: bool = False,
    ) -> dict[str, object]:
        # edicion-operaciones-con-dinero (tanda B, D13/D18): caja, banco y vencimiento con el MISMO contrato tri-estado
        # (valor + `*_provided`), y `dry_run` pide el PLAN sin escribir (la MISMA RPC). Antes la edición descartaba el
        # resultado (`execute`); ahora lo devuelve: `{operation_id, items, money}` en firme o `{dry_run, plan}` en seco.
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

        result = await self._conn.fetchval(
            """
            SELECT rpc_atomic_update_purchase_operation(
                $1::text[]::uuid[], $2::date, $3::text, $4::jsonb,
                p_payment_method_id => $5, p_payment_method_provided => $6,
                p_branch_id => $7, p_branch_provided => $8,
                p_supplier_id => $9, p_supplier_provided => $10,
                p_cost_center_id => $11, p_cost_center_provided => $12,
                p_cash_session_id => $13, p_cash_provided => $14,
                p_bank_account_id => $15, p_bank_account_provided => $16,
                p_due_date => $17, p_due_date_provided => $18,
                p_reason => $19, p_dry_run => $20
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
            cash_session_id,
            cash_provided,
            bank_account_id,
            bank_account_provided,
            due_date,
            due_date_provided,
            reason,
            dry_run,
        )
        if result is None:
            raise ValueError("rpc_atomic_update_purchase_operation devolvió NULL inesperado")
        decoded = json.loads(result) if isinstance(result, str) else result
        return dict(decoded)

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
