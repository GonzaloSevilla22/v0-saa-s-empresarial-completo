from __future__ import annotations

import datetime
import json
from decimal import Decimal

import asyncpg

from backend.repositories.base import BaseRepository


class SalesRepository(BaseRepository):
    async def list_by_org(self, account_id: str) -> list[dict]:
        return await self.fetch(
            "SELECT * FROM sales WHERE account_id = $1 ORDER BY date DESC",
            account_id,
        )

    async def list_paginated_by_operation(
        self,
        account_id: str,
        page: int,
        page_size: int,
        date_from: datetime.date | None = None,
        date_to: datetime.date | None = None,
        payment_method_id: str | None = None,
    ) -> tuple[list[asyncpg.Record], int]:
        # metodos-pago-operaciones: `payment_method_id` es un filtro OPCIONAL,
        # atributo de la OPERACIÓN (todas sus líneas comparten el mismo valor)
        # — mismo patrón que cost_center_id en PurchaseRepository. El filtro
        # aplica sobre la IMPUTACIÓN EXPLÍCITA (s.payment_method_id), nunca
        # sobre la derivación de lectura del POS (D7 — ver abajo), porque
        # filtrar la CTE por la derivación forzaría el JOIN adentro de
        # op_page y descuadraría el `total` de la paginación.
        total: int = await self._conn.fetchval(
            """
            SELECT COUNT(DISTINCT COALESCE(operation_id::text, id::text))
            FROM sales
            WHERE account_id = $1::uuid
              AND ($2::date IS NULL OR date >= $2::date)
              AND ($3::date IS NULL OR date <= $3::date)
              AND ($4::uuid IS NULL OR payment_method_id = $4::uuid)
            """,
            account_id, date_from, date_to, payment_method_id,
        ) or 0

        rows: list[asyncpg.Record] = await self._conn.fetch(
            """
            WITH op_page AS (
              SELECT COALESCE(operation_id::text, id::text) AS op_key
              FROM sales
              WHERE account_id = $1::uuid
                AND ($2::date IS NULL OR date >= $2::date)
                AND ($3::date IS NULL OR date <= $3::date)
                AND ($4::uuid IS NULL OR payment_method_id = $4::uuid)
              GROUP BY COALESCE(operation_id::text, id::text)
              ORDER BY MAX(date) DESC
              LIMIT $5 OFFSET $6
            )
            SELECT s.id, s.date, s.client_id, s.operation_id, s.currency,
                   COALESCE(si.product_id, s.product_id) AS product_id,
                   COALESCE(si.quantity,   s.quantity)   AS quantity,
                   COALESCE(si.price,      s.amount)     AS amount,
                   COALESCE(si.subtotal,   s.total)      AS total,
                   pr.name AS product_name,
                   cl.name AS client_name,
                   -- edicion-preserva-contexto (D11): expuestos para
                   -- prefillear el form de edición. branch_id/canal son del
                   -- header (por operación); unit_id sigue a la línea igual
                   -- que quantity/amount (COALESCE con el header como
                   -- fallback legacy).
                   s.branch_id,
                   s.canal,
                   COALESCE(si.unit_id, s.unit_id) AS unit_id,
                   -- metodos-pago-operaciones (D7) + limpiezas-pagos-admin
                   -- (G1b, D3): la imputación explícita gana; si no hay, se
                   -- deriva DE LECTURA desde la orden del POS por identidad
                   -- (payment_method_id), ya no desde el kind: payment_
                   -- methods.kind no es único por cuenta, así que unir desde
                   -- ahí devolvía más de una fila y duplicaba la operación
                   -- en el listado (fan-out latente). Cero escritura —
                   -- sales/sales_orders no se tocan.
                   COALESCE(pm.id,   pos_pm.id)   AS payment_method_id,
                   COALESCE(pm.name, pos_pm.name) AS payment_method_name,
                   COALESCE(pm.kind, pos_pm.kind) AS payment_method_kind,
                   -- edicion-preserva-contexto (F2/D11): MISMO predicado que
                   -- el guard P0423 de rpc_atomic_update_sale_operation
                   -- (sales_orders.fiscal_document_id → fiscal_documents.
                   -- status IN pending_cae/authorized) — derivado de lectura,
                   -- reusando el acceso a sales_orders ya montado más arriba
                   -- para el payment_method del POS, NUNCA una columna denormalizada
                   -- (D5: segunda fuente de verdad = fuente de bugs
                   -- silenciosos). sale_operation_id tiene índice único
                   -- parcial → sin fan-out.
                   -- venta-editable-sin-cae (D2/D11): MISMO predicado que el
                   -- helper _fiscal_void_pending_for_sale_edit. El nombre
                   -- cambió (is_invoiced → is_fiscally_locked) porque con la
                   -- regla nueva "facturada" e "inmutable" dejaron de ser lo
                   -- mismo: una venta con comprobante pendiente NO enviado
                   -- está facturada y SÍ es editable. `is_invoiced=false` para
                   -- ese caso habría sido una mentira, y `true` otra.
                   COALESCE(
                     fd.status = 'authorized'
                     OR (fd.status = 'pending_cae'
                         AND (fd.cae_submit_started_at IS NOT NULL
                           OR fd.cae_submit_unconfirmed_at IS NOT NULL)),
                     false
                   )                                        AS is_fiscally_locked,
                   -- Evidencia CRUDA del comprobante, para que la UI pueda
                   -- nombrar la causa real y mostrar el badge: el motivo del
                   -- lápiz deshabilitado ("ya se envió a ARCA" vs. "autorizado
                   -- por ARCA" vs. "congelado") y el label 0003-00000005 del
                   -- aviso de anulación salen de acá, no de una adivinanza.
                   fd.id                                    AS fiscal_document_id,
                   fd.status                                AS fiscal_document_status,
                   fd.punto_de_venta                        AS fiscal_punto_de_venta,
                   fd.number                                AS fiscal_number,
                   (fd.cae_submit_started_at IS NOT NULL)   AS fiscal_submitted_to_arca,
                   -- `fiscal_frozen` replica EXACTAMENTE la condición de
                   -- backend/routers/fiscal.py (`is_frozen`: la marca Y
                   -- status='pending_cae'), por el mismo motivo que explica su
                   -- comentario: un congelado resuelto a mano deja de estar
                   -- congelado aunque la marca no se limpie nunca.
                   (fd.cae_submit_unconfirmed_at IS NOT NULL
                      AND fd.status = 'pending_cae')        AS fiscal_frozen,
                   -- "si edito o borro esta venta, su comprobante se ANULA":
                   -- pendiente sin marca alguna. Lo consume la confirmación
                   -- explícita de la UI.
                   (fd.id IS NOT NULL AND fd.status = 'pending_cae'
                      AND fd.cae_submit_started_at IS NULL
                      AND fd.cae_submit_unconfirmed_at IS NULL) AS fiscal_pending_voidable,
                   -- pagos-cableados-restantes (D6): MISMO predicado que el
                   -- guard P0423 de rpc_atomic_update_sale_operation — cubre
                   -- las DOS convenciones de reference_id que la migración
                   -- deja conviviendo: operation_id (formulario, vía el
                   -- helper _pay_register_party_charge / opt-in de caja) y
                   -- sales_orders.id (POS, _c29_confirm_order_core). Derivado
                   -- de lectura, reusando el `so` ya montado para
                   -- payment_method/is_fiscally_locked — nunca una columna
                   -- denormalizada (misma regla D5 de arriba). El nombre
                   -- is_invoiced que menciona este comentario pasó a
                   -- is_fiscally_locked en venta-editable-sin-cae.
                   -- pos-banco-movimientos (D8): tercer término — bank_movements,
                   -- mismo predicado que el tercer EXISTS de
                   -- rpc_atomic_update_sale_operation (source_doc_type='sale').
                   -- delete-guard-ledgers (task 9.2): los tres EXISTS se
                   -- exponen TAMBIÉN por separado (has_account_charge/
                   -- has_cash_movement/has_bank_movement) para que el diálogo
                   -- de borrado enumere específicamente qué libro compensaría
                   -- — is_payment_locked (el OR de los tres) se preserva tal
                   -- cual para no romper el badge de lock de edición existente.
                   (
                     EXISTS (SELECT 1 FROM customer_account_movements cam WHERE cam.reference_id = s.operation_id)
                     OR (so.id IS NOT NULL AND EXISTS (SELECT 1 FROM customer_account_movements cam WHERE cam.reference_id = so.id))
                   ) AS has_account_charge,
                   (
                     EXISTS (SELECT 1 FROM cash_movements cm WHERE cm.reference_id = s.operation_id)
                     OR (so.id IS NOT NULL AND EXISTS (SELECT 1 FROM cash_movements cm WHERE cm.reference_id = so.id))
                   ) AS has_cash_movement,
                   (
                     EXISTS (SELECT 1 FROM bank_movements bm WHERE bm.source_doc_type = 'sale' AND bm.source_doc_ref = s.operation_id)
                     OR (so.id IS NOT NULL AND EXISTS (SELECT 1 FROM bank_movements bm WHERE bm.source_doc_type = 'sale' AND bm.source_doc_ref = so.id))
                   ) AS has_bank_movement,
                   (
                     EXISTS (SELECT 1 FROM customer_account_movements cam WHERE cam.reference_id = s.operation_id)
                     OR (so.id IS NOT NULL AND EXISTS (SELECT 1 FROM customer_account_movements cam WHERE cam.reference_id = so.id))
                     OR EXISTS (SELECT 1 FROM cash_movements cm WHERE cm.reference_id = s.operation_id)
                     OR (so.id IS NOT NULL AND EXISTS (SELECT 1 FROM cash_movements cm WHERE cm.reference_id = so.id))
                     OR EXISTS (SELECT 1 FROM bank_movements bm WHERE bm.source_doc_type = 'sale' AND bm.source_doc_ref = s.operation_id)
                     OR (so.id IS NOT NULL AND EXISTS (SELECT 1 FROM bank_movements bm WHERE bm.source_doc_type = 'sale' AND bm.source_doc_ref = so.id))
                   ) AS is_payment_locked
            FROM sales s
            JOIN op_page ON COALESCE(s.operation_id::text, s.id::text) = op_page.op_key
            LEFT JOIN sale_items si ON si.sale_id = s.id AND si.product_id IS NOT NULL
            LEFT JOIN products pr ON COALESCE(si.product_id, s.product_id) = pr.id
            LEFT JOIN clients cl ON s.client_id = cl.id
            LEFT JOIN payment_methods pm ON pm.id = s.payment_method_id
            LEFT JOIN sales_orders so ON so.sale_operation_id = s.operation_id
            LEFT JOIN payment_methods pos_pm
                   ON pos_pm.id          = so.payment_method_id
                  AND pos_pm.deleted_at IS NULL
            LEFT JOIN fiscal_documents fd ON fd.id = so.fiscal_document_id
            WHERE s.account_id = $1::uuid
            ORDER BY s.date DESC, s.id
            """,
            account_id, date_from, date_to, payment_method_id, page_size, page * page_size,
        )
        return rows, total

    async def get_operation(self, operation_id: str, account_id: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            "SELECT * FROM sales WHERE operation_id = $1 AND account_id = $2 LIMIT 1",
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

    async def delete_by_id(self, sale_id: str, account_id: str) -> bool:
        # delete-guard-ledgers: caller fino de rpc_delete_sale_operation
        # (SECURITY DEFINER) — la secuencia anterior (SELECT header → reversa
        # de stock → DELETE → limpieza de idempotencia) vive ahora ENTERA
        # dentro de la RPC, junto con el guard fiscal (P0423) y la
        # compensación de los cuatro libros (cuenta corriente P0425, caja
        # P0426, banco espejo, contable async vía evento). account_id no se
        # pasa a la RPC — resuelve la cuenta del auth.uid() bajo el pool
        # JWT-passthrough, igual que update_operation.
        row = await self._conn.fetchrow(
            "SELECT public.rpc_delete_sale_operation(p_sale_id => $1::uuid, p_reason => $2::text) AS result",
            sale_id,
            "Venta eliminada",
        )
        return bool(row["result"]) if row is not None else False

    async def delete_by_operation(self, operation_id: str, account_id: str) -> bool:
        # delete-guard-ledgers: caller fino — mismo molde que delete_by_id,
        # vía p_operation_id (cubre TODAS las filas de la operación en una
        # sola llamada, en vez de iterar rpc_reverse_stock_movement por fila).
        row = await self._conn.fetchrow(
            "SELECT public.rpc_delete_sale_operation(p_operation_id => $1::uuid, p_reason => $2::text) AS result",
            operation_id,
            "Venta eliminada (operación)",
        )
        return bool(row["result"]) if row is not None else False

    async def update_operation(
        self,
        sale_ids: list[str],
        client_id: str | None,
        date: datetime.date,
        currency: str,
        items: list[dict],
        payment_method_id: str | None = None,
        payment_method_provided: bool = False,
        branch_id: str | None = None,
        branch_provided: bool = False,
        canal: str | None = None,
        canal_provided: bool = False,
    ) -> dict[str, object]:
        # rpc_atomic_update_sale_operation hace REVERSE de los ítems viejos +
        # APPLY de los nuevos en una sola transacción (stock sobre branch_stock,
        # C-21 hotfix). RLS/auth.uid() scope vía JWT-passthrough de la conexión.
        # metodos-pago-operaciones (D5): payment_method_provided distingue
        # "ausente" (preserva el vigente, COALESCE en el RPC) de "informado
        # explícito" (incluido NULL = desimputar) — por parámetro nombrado,
        # como ya se hace con p_canal en la creación.
        # edicion-preserva-contexto (F1 §D3): branch_provided/canal_provided
        # son el MISMO contrato tri-estado, parámetros nombrados nuevos.
        # venta-editable-sin-cae: pasa de `execute` (que DESCARTABA el
        # resultado) a `fetchval`. La RPC devuelve jsonb con `operation_id`,
        # `items` y —lo nuevo— `voided_fiscal_document`: el descriptor del
        # comprobante que la edición anuló, o null. Sin esto el toast de éxito
        # tendría que adivinar si hubo anulación, y una carrera perdida
        # mostraría un "anulado" falso.
        # asyncpg entrega jsonb como `str` (el pool no configura set_type_codec)
        # — mismo patrón de decodificación que `promote_to_order`, más abajo en
        # este mismo archivo.
        def _default(obj):
            if isinstance(obj, Decimal):
                return str(obj)
            raise TypeError(f"Not serializable: {type(obj)}")

        result = await self._conn.fetchval(
            """
            SELECT rpc_atomic_update_sale_operation(
                $1::text[]::uuid[], $2::text::uuid, $3::date, $4::text, $5::jsonb,
                p_payment_method_id => $6, p_payment_method_provided => $7,
                p_branch_id => $8, p_branch_provided => $9,
                p_canal => $10, p_canal_provided => $11
            )
            """,
            sale_ids,
            client_id,
            date,
            currency,
            json.dumps(items, default=_default),
            payment_method_id,
            payment_method_provided,
            branch_id,
            branch_provided,
            canal,
            canal_provided,
        )
        if result is None:
            # La RPC siempre devuelve jsonb; un NULL acá es un contrato roto,
            # no un caso de negocio. Mismo criterio que promote_to_order.
            raise ValueError("rpc_atomic_update_sale_operation devolvió NULL inesperado")
        decoded = json.loads(result) if isinstance(result, str) else result
        return dict(decoded)

    async def promote_to_order(self, operation_id: str) -> dict:
        """
        facturar-venta-manual (D1-D5):
        Invoca rpc_promote_legacy_sale_to_order para materializar una SalesOrder
        confirmada a partir de una venta legacy. Side-effect-free.
        Idempotente: segunda llamada devuelve replayed=true.

        Propaga excepciones asyncpg sin swallowing — el mapeo P→HTTP está en el service.
        """
        import json as _json

        row = await self.fetchrow(
            "SELECT public.rpc_promote_legacy_sale_to_order($1::uuid) AS result",
            operation_id,
        )
        if row is None:
            raise ValueError("rpc_promote_legacy_sale_to_order devolvió NULL inesperado")
        result = row["result"]
        return _json.loads(result) if isinstance(result, str) else result

    async def create_operation(
        self,
        user_id: str,
        account_id: str,
        items: list[dict],
        idempotency_key: str,
        date: datetime.date | None = None,
        client_id: str | None = None,
        currency: str = "ARS",
        canal: str | None = None,
        payment_method_id: str | None = None,
        cash_session_id: str | None = None,
        bank_account_id: str | None = None,
        due_date: datetime.date | None = None,
    ) -> dict | None:
        existing = await self.get_idempotency(account_id, idempotency_key)
        if existing is not None:
            return dict(existing)

        def _default(obj):
            if isinstance(obj, Decimal):
                return str(obj)
            raise TypeError(f"Not serializable: {type(obj)}")

        row = await self._conn.fetchrow(
            """
            SELECT
                (rpc_create_sale_operation(
                    $1, $2::text::uuid, $3, $4, $5::jsonb,
                    p_canal => $6, p_payment_method_id => $7, p_cash_session_id => $8,
                    p_bank_account_id => $9, p_due_date => $10
                )->>'operation_id')::uuid
                    AS operation_id,
                'sale'::text AS operation_kind
            """,
            idempotency_key,
            client_id,
            date or datetime.date.today(),
            currency,
            json.dumps(items, default=_default),
            canal,
            payment_method_id,
            cash_session_id,
            bank_account_id,
            due_date,
        )
        return dict(row) if row else None
