from __future__ import annotations

import datetime

import asyncpg

from backend.core.client_activity import (
    FRECUENTE_MIN_OPS,
    FRECUENTE_WINDOW_DAYS,
    INACTIVO_MIN_DAYS,
)
from backend.repositories.base import BaseRepository


class ClientRepository(BaseRepository):
    """v3-soft-delete-policy: las lecturas excluyen filas borradas (RN-B1) y
    el borrado es soft vía BaseRepository.soft_delete("clients", ...) (RN-B2).

    clientes-frecuentes-historial (design.md §4): `_OP_KEY_EXPR` y
    `_LINE_AMOUNT_EXPR` son la única definición de "qué es una operación de
    compra" y "cuánto vale una línea" — se reutilizan sin duplicar en
    `list_activity_page`, `get_activity_for` y `list_purchases_page`.
    """

    # Agrupa las filas de `sales` de una misma operación. Coincide con el
    # patrón ya usado por SalesRepository.list_paginated_by_operation — el
    # COALESCE es obligatorio porque hay filas con cliente sin operation_id.
    _OP_KEY_EXPR = "COALESCE(s.operation_id::text, s.id::text)"

    # RN-D / reporting-invariants: `sales.amount` es el precio UNITARIO;
    # `sales.total` (o `sale_items.subtotal`, fuente de verdad desde C-20) es
    # el subtotal de línea. Sumar `amount` a secas subvalúa toda línea con
    # quantity > 1 — es la regresión del 17,53% que encontró
    # v3-reporting-invariants.
    _LINE_AMOUNT_EXPR = "COALESCE(si.subtotal, s.total, s.amount)"

    # Whitelist de orden — nunca se interpola texto de usuario en ORDER BY.
    # Pydantic ya restringe `sort` a este mismo conjunto en el schema del
    # router (client-activity §"El frontend no replica umbrales" / defensa
    # en profundidad), pero el repository no confía ciegamente en eso.
    _SORT_COLUMNS: dict[str, str] = {
        "name": "name",
        "last_purchase": "last_purchase_date",
        "total_spent": "total_spent",
        "purchase_count": "purchase_count",
    }

    async def list_by_org(self, account_id: str) -> list[dict]:
        return await self.fetch(
            "SELECT * FROM clients WHERE account_id = $1"
            + self.not_deleted_clause()
            + " ORDER BY name ASC",
            account_id,
        )

    async def get_by_id(self, client_id: str, account_id: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            "SELECT * FROM clients WHERE id = $1 AND account_id = $2"
            + self.not_deleted_clause(),
            client_id,
            account_id,
        )

    async def count_by_org(self, account_id: str) -> int:
        # billing-pro-trial (D5/D7): borrados no cuentan para el límite —
        # borrar libera cupo, mismo patrón que ProductRepository.count_by_org.
        row = await self.fetchrow(
            "SELECT COUNT(*) AS total FROM clients WHERE account_id = $1"
            + self.not_deleted_clause(),
            account_id,
        )
        return int(row["total"]) if row else 0

    async def create(self, user_id: str, account_id: str, data: dict) -> asyncpg.Record | None:
        return await self.fetchrow(
            """
            INSERT INTO clients (user_id, account_id, name, email, phone, tax_id, iva_condition, legal_name)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
            RETURNING *
            """,
            user_id,
            account_id,
            data["name"],
            data.get("email"),
            data.get("phone"),
            data.get("tax_id"),
            data.get("iva_condition"),
            data.get("legal_name"),
        )

    async def update(self, client_id: str, account_id: str, data: dict) -> asyncpg.Record | None:
        fields = {k: v for k, v in data.items() if v is not None}
        if not fields:
            return await self.get_by_id(client_id, account_id)
        set_clauses = ", ".join(f"{k} = ${i + 3}" for i, k in enumerate(fields))
        values = list(fields.values())
        return await self.fetchrow(
            f"UPDATE clients SET {set_clauses} WHERE id = $1 AND account_id = $2"
            + self.not_deleted_clause()
            + " RETURNING *",
            client_id,
            account_id,
            *values,
        )

    # ── clientes-frecuentes-historial — agregados de actividad (design.md §4) ──

    async def get_reference_today(self) -> datetime.date:
        """Día de referencia en día calendario argentino — client-activity
        §"Días y ventanas en día calendario argentino": SHALL obtenerse de
        `reporting_local_today()`, nunca de `now()`/huso del servidor."""
        return await self._conn.fetchval("SELECT public.reporting_local_today()")

    def _activity_lateral_sql(self) -> str:
        """LATERAL de agregados por cliente: una compra = una operación de
        `sales` (`_OP_KEY_EXPR`), su día en calendario argentino y su monto
        canónico (`_LINE_AMOUNT_EXPR`). $1 = día de referencia
        (`reporting_local_today()`, ya resuelto por el caller), $2 = tamaño de
        la ventana de frecuencia — posiciones fijas compartidas por todo
        query que use este fragmento (client-activity §"Días y ventanas en
        día calendario argentino")."""
        return f"""
            LEFT JOIN LATERAL (
                SELECT
                    COUNT(*) AS ops_total,
                    COUNT(*) FILTER (WHERE ops.op_day >= $1::date - ($2::int - 1)) AS ops_window,
                    MAX(ops.op_day) AS last_op_day,
                    SUM(ops.op_total) AS total_spent
                FROM (
                    SELECT
                        {self._OP_KEY_EXPR} AS op_key,
                        MAX((s.date AT TIME ZONE 'America/Argentina/Mendoza')::date) AS op_day,
                        SUM({self._LINE_AMOUNT_EXPR}) AS op_total
                    FROM sales s
                    LEFT JOIN sale_items si ON si.sale_id = s.id
                    WHERE s.account_id = c.account_id AND s.client_id = c.id
                    GROUP BY {self._OP_KEY_EXPR}
                ) ops
            ) agg ON TRUE
        """

    def _classified_activity_cte(self, where_clients_sql: str) -> str:
        """SQL compartido de agregados + clasificación por cliente. `$1` =
        día de referencia, `$2` = ventana de frecuencia, `$3` =
        FRECUENTE_MIN_OPS, `$4` = INACTIVO_MIN_DAYS (todos parámetros, nunca
        interpolados — client-activity §"Umbrales canónicos"). `where_clients_sql`
        es el predicado sobre `clients` con sus propios placeholders ya
        numerados por el caller (arrancan en $5).

        Reutilizado tal cual por `list_activity_page` (paginado) y
        `get_activity_for` (un cliente) — una sola definición de los
        agregados para lista y detalle (client-purchase-history §"Resumen
        acumulado")."""
        return f"""
            WITH client_agg AS (
                SELECT
                    c.id, c.account_id, c.user_id, c.name, c.email, c.phone,
                    c.tax_id, c.iva_condition, c.legal_name, c.created_at,
                    COALESCE(agg.ops_total, 0)::int AS purchase_count,
                    COALESCE(agg.ops_window, 0)::int AS purchase_count_90d,
                    COALESCE(agg.total_spent, 0)::numeric AS total_spent,
                    agg.last_op_day AS last_purchase_date,
                    CASE WHEN agg.last_op_day IS NULL THEN NULL
                         ELSE ($1::date - agg.last_op_day) END AS days_since_last_purchase
                FROM clients c
                {self._activity_lateral_sql()}
                WHERE {where_clients_sql}
            ),
            classified_activity AS (
                SELECT *,
                    CASE
                        WHEN purchase_count = 0 OR days_since_last_purchase IS NULL THEN 'sin_compras'
                        WHEN days_since_last_purchase >= $4::int THEN 'inactivo'
                        WHEN purchase_count_90d >= $3::int THEN 'frecuente'
                        ELSE 'activo'
                    END AS activity_status
                FROM client_agg
            )
        """

    async def list_activity_page(
        self,
        account_id: str,
        *,
        today: datetime.date,
        page: int,
        size: int,
        search: str | None = None,
        activity_status: str | None = None,
        sort: str = "name",
        sort_dir: str = "asc",
        window_days: int = FRECUENTE_WINDOW_DAYS,
        frecuente_min_ops: int = FRECUENTE_MIN_OPS,
        inactivo_min_days: int = INACTIVO_MIN_DAYS,
    ) -> dict:
        """Página de clientes con sus agregados de actividad — una sola
        consulta por página (design.md §4), sin N+1."""
        where_clients = (
            f"c.account_id = $5::uuid{self.not_deleted_clause('c')} "
            "AND ($6::text IS NULL OR c.name ILIKE '%' || $6 || '%' OR c.email ILIKE '%' || $6 || '%')"
        )
        cte = self._classified_activity_cte(where_clients)

        sort_column = self._SORT_COLUMNS.get(sort, "name")
        direction = "DESC" if sort_dir == "desc" else "ASC"
        nulls = " NULLS LAST" if sort_column == "last_purchase_date" else ""
        order_clause = f"ORDER BY {sort_column} {direction}{nulls}, id ASC"

        select_sql = (
            f"{cte} SELECT * FROM classified_activity "
            "WHERE ($7::text IS NULL OR activity_status = $7) "
            f"{order_clause}"
        )
        count_sql = (
            f"{cte} SELECT COUNT(*) FROM classified_activity "
            "WHERE ($7::text IS NULL OR activity_status = $7)"
        )

        return await self.paginate(
            select_sql,
            count_sql,
            today,
            window_days,
            frecuente_min_ops,
            inactivo_min_days,
            account_id,
            search,
            activity_status,
            page=page,
            size=size,
        )

    async def get_activity_for(
        self,
        client_id: str,
        account_id: str,
        *,
        today: datetime.date,
        window_days: int = FRECUENTE_WINDOW_DAYS,
        frecuente_min_ops: int = FRECUENTE_MIN_OPS,
        inactivo_min_days: int = INACTIVO_MIN_DAYS,
    ) -> asyncpg.Record | None:
        """Resumen de actividad de un único cliente — reutiliza la misma SQL
        de agregados que `list_activity_page`, filtrada a `client_id`
        (client-purchase-history §"Resumen acumulado")."""
        where_clients = (
            f"c.account_id = $5::uuid AND c.id = $6::uuid{self.not_deleted_clause('c')}"
        )
        cte = self._classified_activity_cte(where_clients)
        query = f"{cte} SELECT * FROM classified_activity LIMIT 1"
        return await self.fetchrow(
            query, today, window_days, frecuente_min_ops, inactivo_min_days, account_id, client_id
        )

    async def list_purchases_page(
        self,
        client_id: str,
        account_id: str,
        *,
        page: int,
        size: int,
    ) -> dict:
        """Historial de compras de un cliente — una fila por operación de
        venta, ordenado por fecha descendente (client-purchase-history
        §"Historial de compras del cliente")."""
        base_sql = f"""
            WITH lines AS (
                SELECT
                    s.id,
                    {self._OP_KEY_EXPR} AS op_key,
                    s.date,
                    {self._LINE_AMOUNT_EXPR} AS line_amount
                FROM sales s
                LEFT JOIN sale_items si ON si.sale_id = s.id
                WHERE s.account_id = $1::uuid AND s.client_id = $2::uuid
            ),
            ops AS (
                SELECT
                    op_key AS operation_id,
                    MAX(date) AS operation_date,
                    COUNT(*) AS item_count,
                    SUM(line_amount) AS total
                FROM lines
                GROUP BY op_key
            )
        """
        select_sql = f"{base_sql} SELECT * FROM ops ORDER BY operation_date DESC, operation_id"
        count_sql = f"{base_sql} SELECT COUNT(*) FROM ops"

        return await self.paginate(
            select_sql, count_sql, account_id, client_id, page=page, size=size
        )
