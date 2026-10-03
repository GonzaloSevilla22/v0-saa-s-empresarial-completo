"""
Repositorio del remito de venta (remitos-venta tanda A, D13).

Arquitectura 3 capas: sólo acceso a datos, sin lógica de negocio.

  - TODA escritura va por una RPC `SECURITY DEFINER` (`rpc_create_sale_delivery_note`,
    `rpc_update_delivery_note`, `rpc_cancel_delivery_note` y, desde la tanda B,
    `rpc_convert_delivery_note_to_sale`). NO hay
    `INSERT`/`UPDATE`/`DELETE` sobre `delivery_notes` ni `delivery_note_items`
    (desde la migración 20261069000001 no existen políticas de escritura y el rol
    de la aplicación ni siquiera tiene el privilegio) y, sobre todo, NINGUNO
    sobre `stock_movements` ni `branch_stock`: el remito mueve el ledger de stock
    únicamente desde sus RPCs, que toman el lock de los productos, normalizan la
    unidad y controlan el faltante en el mismo camino para cualquier escritor.
    Un test (`test_delivery_notes_module.py`) falla si un método vuelve a
    escribir esas tablas directo.
  - Las lecturas son `SELECT` con `account_id` EXPLÍCITO además de la RLS (regla
    dura desde el incidente de fuga multi-tenant #446: el pool corre con la RLS
    como red, nunca como único guard). La cuenta es la del header, no la que
    adivine una RPC: con varias cuentas, un remito de otra de TUS cuentas no se
    ve desde esta.
  - El emisor del PDF viene de `rpc_commercial_issuer` (mixin compartido con el
    presupuesto).
  - JWT-passthrough vía `BaseRepository`: la conexión ya trae los claims.
"""
from __future__ import annotations

import json
from decimal import Decimal

from backend.repositories.base import BaseRepository
from backend.repositories.commercial_document_support import (
    CommercialIssuerMixin,
    jsonb_value,
    like_pattern,
)

_DN_FROM = """
    FROM public.delivery_notes dn
    LEFT JOIN public.clients c
           ON c.id = dn.client_id AND c.account_id = dn.account_id
    LEFT JOIN public.suppliers s
           ON s.id = dn.supplier_id AND s.account_id = dn.account_id
    LEFT JOIN public.branches b
           ON b.id = dn.branch_id AND b.account_id = dn.account_id
"""


def _scope_filters(supplier_param: int) -> str:
    """Filtros del recorte del listado SIN el estado. Los comparten el listado (que
    le suma el estado) y el resumen de pendientes (que lo fija en `issued`): un
    único fragmento, para que no puedan divergir.

    El filtro de proveedor (remitos-compra) es el ÚLTIMO parámetro de cada
    consulta, así que el número que ocupa lo decide quien arma la consulta: `$8`
    en el listado (después del estado, `$7`) y `$7` en el resumen (que no tiene
    estado). Así los siete primeros argumentos del listado de venta conservan su
    posición. El texto busca por cliente, por proveedor y por el número del
    remito del proveedor, además del número interno.
    """
    return f"""
      dn.account_id = $1::uuid
      AND ($2::text IS NULL OR dn.direction = $2::text)
      AND ($3::uuid IS NULL OR dn.client_id = $3::uuid)
      AND ($4::uuid IS NULL OR dn.branch_id = $4::uuid)
      AND ($5::text IS NULL
           OR c.name ILIKE $5::text
           OR c.legal_name ILIKE $5::text
           OR s.name ILIKE $5::text
           OR dn.supplier_reference ILIKE $5::text
           OR ($6::bigint IS NOT NULL AND dn.number = $6::bigint))
      AND (${supplier_param}::uuid IS NULL OR dn.supplier_id = ${supplier_param}::uuid)
"""


# Líneas con precio 0: el remito de compra recibido sin precios, que todavía no
# se puede convertir en compra (el total subestima lo recibido).
_MISSING_PRICE_LINES = """
    SELECT 1 FROM public.delivery_note_items mi
     WHERE mi.delivery_note_id = dn.id AND mi.account_id = dn.account_id AND mi.price = 0
"""

_LIST_FILTERS = f"""
    WHERE {_scope_filters(8)}
      AND ($7::text IS NULL OR dn.status = $7::text)
"""

_LIST_PROJECTION = """
    dn.id, dn.direction, dn.branch_id, b.name AS branch_name,
    dn.client_id, c.name AS client_name, c.phone AS client_phone,
    dn.supplier_id, s.name AS supplier_name, s.phone AS supplier_phone, dn.supplier_reference,
    (SELECT count(*) FROM public.delivery_note_items mi
      WHERE mi.delivery_note_id = dn.id AND mi.account_id = dn.account_id AND mi.price = 0) AS missing_price_count,
    dn.status, dn.issued_on, dn.total, dn.number, dn.revision,
    (SELECT count(*) FROM public.delivery_note_items i
      WHERE i.delivery_note_id = dn.id AND i.account_id = dn.account_id) AS item_count,
    dn.created_at, dn.updated_at
"""

_SUMMARY_SQL = f"""
    SELECT count(*) AS pending_count,
           COALESCE(sum(dn.total), 0) AS pending_total,
           count(*) FILTER (WHERE EXISTS ({_MISSING_PRICE_LINES})) AS pending_missing_price_count
    {_DN_FROM}
    WHERE {_scope_filters(7)}
      AND dn.status = 'issued'
"""


class DeliveryNoteRepository(CommercialIssuerMixin, BaseRepository):
    """Remitos y sus líneas — escritura por RPC, lectura con tenencia."""

    # ── Escrituras (una RPC por operación) ───────────────────────────────────

    async def create_delivery_note(
        self,
        *,
        idempotency_key: str,
        client_id: str,
        branch_id: str,
        delivery_address: str | None,
        notes: str | None,
        items: list[dict],
    ) -> dict:
        """`rpc_create_sale_delivery_note`: emite el remito, lo numera, descuenta
        el stock de la sucursal y es idempotente por `idempotency_key`. La RPC
        resuelve la cuenta por el cliente. Devuelve el payload con `replayed`."""
        raw = await self._conn.fetchval(
            "SELECT public.rpc_create_sale_delivery_note("
            "$1::text, $2::uuid, $3::uuid, $4::text, $5::text, $6::jsonb)",
            idempotency_key,
            client_id,
            branch_id,
            delivery_address,
            notes,
            json.dumps(items, default=str),
        )
        return jsonb_value(raw)

    async def update_delivery_note(
        self,
        delivery_note_id: str,
        *,
        expected_revision: int,
        client_id: str,
        branch_id: str,
        delivery_address: str | None,
        notes: str | None,
        items: list[dict],
    ) -> dict:
        """`rpc_update_delivery_note`: reemplazo completo bajo `FOR UPDATE` con
        par espejo en el ledger sólo en los pares producto-sucursal que cambian.
        Rechaza una versión vieja (`delivery_note_changed`) y un remito convertido
        (`delivery_note_locked_converted`)."""
        raw = await self._conn.fetchval(
            "SELECT public.rpc_update_delivery_note("
            "$1::uuid, $2::integer, $3::uuid, $4::uuid, $5::text, $6::text, $7::jsonb)",
            delivery_note_id,
            expected_revision,
            client_id,
            branch_id,
            delivery_address,
            notes,
            json.dumps(items, default=str),
        )
        return jsonb_value(raw)

    async def create_purchase_delivery_note(
        self,
        *,
        idempotency_key: str,
        supplier_id: str,
        branch_id: str,
        supplier_reference: str | None,
        notes: str | None,
        items: list[dict],
    ) -> dict:
        """`rpc_create_purchase_delivery_note` (remitos-compra): emite el remito de
        compra, lo numera (RC), SUMA el stock de la sucursal de destino y es
        idempotente por `idempotency_key`. La RPC resuelve la cuenta por el
        proveedor. Devuelve el payload con `replayed`."""
        raw = await self._conn.fetchval(
            "SELECT public.rpc_create_purchase_delivery_note("
            "$1::text, $2::uuid, $3::uuid, $4::text, $5::text, $6::jsonb)",
            idempotency_key,
            supplier_id,
            branch_id,
            supplier_reference,
            notes,
            json.dumps(items, default=str),
        )
        return jsonb_value(raw)

    async def update_purchase_delivery_note(
        self,
        delivery_note_id: str,
        *,
        expected_revision: int,
        supplier_id: str,
        branch_id: str,
        supplier_reference: str | None,
        notes: str | None,
        items: list[dict],
    ) -> dict:
        """`rpc_update_purchase_delivery_note`: reemplazo completo bajo `FOR UPDATE`
        con par espejo en el ledger sólo en los pares producto-sucursal que cambian
        (las patas que suman primero). Rechaza una versión vieja
        (`delivery_note_changed`), un remito convertido y una baja por debajo de lo
        que ya salió del depósito (`delivery_note_stock_consumed`)."""
        raw = await self._conn.fetchval(
            "SELECT public.rpc_update_purchase_delivery_note("
            "$1::uuid, $2::integer, $3::uuid, $4::uuid, $5::text, $6::text, $7::jsonb)",
            delivery_note_id,
            expected_revision,
            supplier_id,
            branch_id,
            supplier_reference,
            notes,
            json.dumps(items, default=str),
        )
        return jsonb_value(raw)

    async def cancel_delivery_note(self, delivery_note_id: str, *, expected_revision: int, reason: str) -> dict:
        """`rpc_cancel_delivery_note` (los dos sentidos): anula con motivo y
        revierte lo que el remito movió: repone el stock en venta, lo resta en
        compra (y rechaza si la mercadería ya se consumió). Sólo admin/owner,
        decidido en la base."""
        raw = await self._conn.fetchval(
            "SELECT public.rpc_cancel_delivery_note($1::uuid, $2::integer, $3::text)",
            delivery_note_id,
            expected_revision,
            reason,
        )
        return jsonb_value(raw)

    async def convert_to_sale(
        self,
        delivery_note_id: str,
        *,
        idempotency_key: str,
        expected_revision: int,
        payment_method_id: str,
        cash_session_id: str | None,
        bank_account_id: str | None,
        canal: str | None,
    ) -> dict:
        """`rpc_convert_delivery_note_to_sale`: convierte el remito `issued` en una
        venta confirmada en UNA transacción (caja, cuenta corriente, banco,
        historial, eventos) sobre el núcleo del POS, SIN volver a mover stock (lo
        decide la base por el origen persistido de la orden, nunca un parámetro de
        acá). Bloquea primero el remito, valida estado y versión y revierte todo
        ante cualquier fallo. La sucursal es la del remito (no se elige). La
        tenencia del remito, la forma de pago, la cuenta bancaria y la caja las
        resuelve la RPC; acá sólo se transportan los ids."""
        raw = await self._conn.fetchval(
            "SELECT public.rpc_convert_delivery_note_to_sale("
            "$1::text, $2::uuid, $3::integer, $4::uuid, $5::uuid, $6::uuid, $7::text)",
            idempotency_key,
            delivery_note_id,
            expected_revision,
            payment_method_id,
            cash_session_id,
            bank_account_id,
            canal,
        )
        return jsonb_value(raw)

    # ── Lecturas (SELECT con account_id explícito) ────────────────────────────

    async def get_delivery_note(self, delivery_note_id: str, account_id: str) -> dict | None:
        """Remito con cliente, sucursal, líneas (con el símbolo de su unidad y si
        el producto se dio de baja) e historial. `None` si no existe O es de otra
        cuenta: el mismo resultado en los dos casos, para no revelar si el id
        existe en otro tenant."""
        header = await self._conn.fetchrow(
            f"""
            SELECT dn.*,
                   c.name AS client_name, c.phone AS client_phone, c.tax_id AS client_tax_id,
                   (c.deleted_at IS NOT NULL) AS client_deleted,
                   -- remitos-compra: la contraparte del sentido compra (el
                   -- proveedor, cruzado con la cuenta del remito) y cuántas
                   -- líneas siguen en precio 0.
                   s.name AS supplier_name, s.phone AS supplier_phone, s.tax_id AS supplier_tax_id,
                   (s.deleted_at IS NOT NULL) AS supplier_deleted,
                   (SELECT count(*) FROM public.delivery_note_items mi
                     WHERE mi.delivery_note_id = dn.id AND mi.account_id = dn.account_id
                       AND mi.price = 0) AS missing_price_count,
                   b.name AS branch_name,
                   -- remitos-venta tanda B: la orden VIVA nacida del remito (a lo
                   -- sumo una: índice único parcial). Mismo criterio que
                   -- `_delivery_note_payload`: la cuenta va en el cruce y una orden
                   -- cancelada (venta borrada) no cuenta.
                   (SELECT so.id
                      FROM public.sales_orders so
                     WHERE so.source_delivery_note_id = dn.id
                       AND so.account_id = dn.account_id
                       AND so.status <> 'canceled') AS converted_sales_order_id,
                   (SELECT so.sale_operation_id
                      FROM public.sales_orders so
                     WHERE so.source_delivery_note_id = dn.id
                       AND so.account_id = dn.account_id
                       AND so.status <> 'canceled') AS converted_operation_id
            {_DN_FROM}
            WHERE dn.id = $1::uuid AND dn.account_id = $2::uuid
            """,
            delivery_note_id,
            account_id,
        )
        if header is None:
            return None

        items = await self._conn.fetch(
            """
            SELECT i.*, u.symbol AS unit_symbol, (p.deleted_at IS NOT NULL) AS product_deleted
            FROM public.delivery_note_items i
            LEFT JOIN public.units_of_measure u ON u.id = i.unit_id
            LEFT JOIN public.products p ON p.id = i.product_id AND p.account_id = i.account_id
            WHERE i.delivery_note_id = $1::uuid AND i.account_id = $2::uuid
            ORDER BY i.line_no, i.id
            """,
            delivery_note_id,
            account_id,
        )
        history = await self._conn.fetch(
            """
            SELECT h.from_status, h.to_status, h.performed_by, h.reason, h.occurred_at
            FROM public.document_status_history h
            WHERE h.document_type = 'delivery_note_' || $3::text
              AND h.document_id = $1::uuid
              AND h.account_id = $2::uuid
            ORDER BY h.occurred_at, h.id
            """,
            delivery_note_id,
            account_id,
            header["direction"],
        )
        return {**dict(header), "items": [dict(i) for i in items], "history": [dict(h) for h in history]}

    async def get_direction(self, delivery_note_id: str, account_id: str) -> str | None:
        """Sentido guardado de un remito de la cuenta del caller (`sale` o
        `purchase`), o `None` si no existe O es de otra cuenta (el mismo resultado
        en los dos casos). Lectura mínima para distinguir, ANTES de llamar a la RPC
        de edición, un cuerpo de otro sentido (409) de un remito inexistente (404):
        después de un error de la RPC la transacción del request ya está
        abortada."""
        return await self._conn.fetchval(
            "SELECT direction FROM public.delivery_notes WHERE id = $1::uuid AND account_id = $2::uuid",
            delivery_note_id,
            account_id,
        )

    async def list_delivery_notes(
        self,
        account_id: str,
        *,
        page: int,
        page_size: int,
        direction: str | None,
        status: str | None,
        client_id: str | None,
        branch_id: str | None,
        text: str | None,
        number: int | None,
        supplier_id: str | None = None,
    ) -> tuple[list[dict], int]:
        """Listado paginado (`page` es 0-based). El COUNT usa EXACTAMENTE los
        mismos filtros y parámetros que la página: si divergen, `total` miente.

        `text` busca por nombre del cliente, del proveedor o número del remito del
        proveedor; `number` (que el service extrae del texto del buscador: "R-12",
        "RC-12", "12" o "00000012") por número de remito. Se cumple cualquiera.
        `supplier_id` (remitos-compra) restringe a los remitos de ese proveedor.
        """
        args = (account_id, direction, client_id, branch_id, like_pattern(text), number, status, supplier_id)
        total: int = await self._conn.fetchval(f"SELECT COUNT(*) {_DN_FROM} {_LIST_FILTERS}", *args) or 0
        rows = await self._conn.fetch(
            f"""
            SELECT {_LIST_PROJECTION}
            {_DN_FROM}
            {_LIST_FILTERS}
            ORDER BY dn.created_at DESC, dn.id
            LIMIT $9 OFFSET $10
            """,
            *args,
            page_size,
            page * page_size,
        )
        return [dict(r) for r in rows], total

    async def pending_summary(
        self,
        account_id: str,
        *,
        direction: str | None,
        client_id: str | None,
        branch_id: str | None,
        text: str | None,
        number: int | None,
        supplier_id: str | None = None,
    ) -> dict:
        """Cantidad y total de los remitos `issued` del recorte del listado
        (sentido, cliente, sucursal, proveedor y búsqueda), sin importar el estado
        pedido. En el sentido compra suma `pending_missing_price_count`: cuántos de
        esos pendientes tienen alguna línea con precio 0. En venta (o sin sentido)
        la respuesta conserva sus dos claves de siempre."""
        purchase = direction == "purchase"
        row = await self._conn.fetchrow(
            _SUMMARY_SQL, account_id, direction, client_id, branch_id, like_pattern(text), number, supplier_id
        )
        summary = {
            "pending_count": int(row["pending_count"]) if row is not None else 0,
            "pending_total": row["pending_total"] if row is not None else Decimal("0"),
        }
        if purchase:
            summary["pending_missing_price_count"] = (
                int(row["pending_missing_price_count"]) if row is not None else 0
            )
        return summary
