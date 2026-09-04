"""
estadisticas-ventas E1 — repository del read-model de estadísticas de ventas
(task 3.2). Sólo lectura sobre las RPCs SECURITY DEFINER rpc_sales_evolution y
rpc_product_ranking (migración 20261024000001).

Invariantes:
- Ningún predicado de negocio vive acá: la población de líneas, los bordes
  RN-D5, la resta de NC, la agrupación de variantes, el margen y el clamp de
  plan viven UNA sola vez en la base (D1/D2/D7/D8). Este módulo sólo liga
  parámetros y arma el envelope.
- Todo parámetro viaja LIGADO ($n); nada del usuario se interpola en el SQL.
  El orden del ranking y el bucket de la evolución son parámetros de la RPC,
  acotados por Literal en el router y por diccionario en el service.
- La paginación del ranking se resuelve en la RPC sobre el conjunto completo
  (ROW_NUMBER + LIMIT/OFFSET); total_count viaja por fila. Una página vacía
  más allá del final sondea la primera fila para no perder el total.
"""
from __future__ import annotations

import datetime

from backend.repositories.base import BaseRepository


def window_from_row(row: dict) -> dict:
    """D8: la ventana efectivamente aplicada, tal como la declara la RPC en
    cada fila (window_start / window_end / history_days / window_clamped)."""
    return {
        "start":        row["window_start"],
        "end":          row["window_end"],
        "history_days": int(row["history_days"]),
        "clamped":      bool(row["window_clamped"]),
    }


class StatisticsRepository(BaseRepository):
    _EVOLUTION_SQL = (
        "SELECT * FROM public.rpc_sales_evolution("
        "$1::uuid, $2::date, $3::date, $4::text, $5::uuid, $6::text)"
    )
    _RANKING_SQL = (
        "SELECT * FROM public.rpc_product_ranking("
        "$1::uuid, $2::date, $3::date, $4::text, $5::boolean, $6::uuid, $7::text, "
        "$8::integer, $9::integer)"
    )
    # E2 (migración 20261025000001)
    _BREAKDOWN_SQL = (
        "SELECT * FROM public.rpc_sales_breakdown("
        "$1::uuid, $2::date, $3::date, $4::text, $5::uuid, $6::text)"
    )
    _TOP_CLIENTS_SQL = (
        "SELECT * FROM public.rpc_sales_top_clients("
        "$1::uuid, $2::date, $3::date, $4::uuid, $5::integer)"
    )
    # E3 (migración 20261026000001)
    _PRODUCT_DETAIL_SQL = (
        "SELECT * FROM public.rpc_product_sales_evolution("
        "$1::uuid, $2::uuid, $3::date, $4::date, $5::text, $6::uuid, $7::text)"
    )

    async def fetch_sales_evolution(
        self,
        account_id: str,
        *,
        start: datetime.date,
        end: datetime.date,
        bucket: str,
        branch_id: str | None = None,
        canal: str | None = None,
    ) -> list[dict]:
        """Filas crudas de rpc_sales_evolution: period ∈ {bucket, current,
        previous}. La composición por período la hace el service."""
        return await self.fetch(
            self._EVOLUTION_SQL, account_id, start, end, bucket, branch_id, canal
        )

    async def fetch_product_ranking_page(
        self,
        account_id: str,
        *,
        start: datetime.date,
        end: datetime.date,
        order_by: str,
        group_variants: bool,
        page: int,
        size: int,
        branch_id: str | None = None,
        canal: str | None = None,
    ) -> dict:
        """Página del ranking como envelope estándar {items,total,page,pages}
        + window (D8). `page` es 0-based; limit/offset se resuelven en la RPC."""
        rows = await self.fetch(
            self._RANKING_SQL,
            account_id, start, end, order_by, group_variants, branch_id, canal,
            size, page * size,
        )
        meta_row = rows[0] if rows else None
        if meta_row is None and page > 0:
            # Página fuera de rango: el total y la ventana no viajan sin filas.
            # Una sonda de 1 fila (offset 0) los recupera sin re-agregar nada.
            probe = await self.fetch(
                self._RANKING_SQL,
                account_id, start, end, order_by, group_variants, branch_id, canal,
                1, 0,
            )
            meta_row = probe[0] if probe else None

        total = int(meta_row["total_count"]) if meta_row else 0
        pages = -(-total // size) if total > 0 else 0  # ceil sin math.ceil
        return {
            "items":  rows,
            "total":  total,
            "page":   page,
            "pages":  pages,
            "window": window_from_row(meta_row) if meta_row else None,
        }

    # ── E2 ──────────────────────────────────────────────────────────────────

    async def fetch_sales_breakdown(
        self,
        account_id: str,
        *,
        start: datetime.date,
        end: datetime.date,
        dimension: str,
        branch_id: str | None = None,
        canal: str | None = None,
    ) -> list[dict]:
        """Filas crudas de rpc_sales_breakdown para una dimensión (canal /
        branch / weekday / hour / category). El tramo "Sin …" viaja con
        bucket_key NULL; día y hora vienen completos (7 / 24 filas)."""
        return await self.fetch(
            self._BREAKDOWN_SQL, account_id, start, end, dimension, branch_id, canal
        )

    async def fetch_top_clients(
        self,
        account_id: str,
        *,
        start: datetime.date,
        end: datetime.date,
        branch_id: str | None = None,
        limit: int = 10,
    ) -> list[dict]:
        """Filas crudas de rpc_sales_top_clients: row_kind ∈ {client,
        unassigned}. La composición por clase de fila la hace el service."""
        return await self.fetch(
            self._TOP_CLIENTS_SQL, account_id, start, end, branch_id, limit
        )

    # ── E3 ──────────────────────────────────────────────────────────────────

    async def fetch_product_sales_evolution(
        self,
        account_id: str,
        product_id: str,
        *,
        start: datetime.date,
        end: datetime.date,
        bucket: str,
        branch_id: str | None = None,
        canal: str | None = None,
    ) -> list[dict]:
        """Filas crudas de rpc_product_sales_evolution: row_kind ∈ {total,
        bucket, member}. La tenencia del producto la resuelve la RPC (P0404
        ajeno o inexistente); la composición por clase de fila la hace el
        service."""
        return await self.fetch(
            self._PRODUCT_DETAIL_SQL,
            account_id, product_id, start, end, bucket, branch_id, canal,
        )
