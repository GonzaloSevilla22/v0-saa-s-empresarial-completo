"""
estadisticas-ventas E1 — schemas Pydantic v2 del read-model de estadísticas
de ventas (task 3.5). Ningún payload ni respuesta viaja sin schema.

Los importes son Decimal (asyncpg → numeric) y se serializan como string,
igual que el resto de los reportes; el frontend los normaliza en
lib/sales-statistics.ts. Un margen ausente viaja como null — NUNCA como 0
(D11: un grupo sin costo resoluble no tiene margen, no un margen de cero).

`response_model` filtra la salida: las columnas de la RPC que no están acá
(total_count, window_*) no llegan al cliente; si una columna nueva del
read-model tiene que viajar, hay que declararla en este archivo.
"""
from __future__ import annotations

import datetime
import uuid
from decimal import Decimal
from typing import Literal

from pydantic import BaseModel

EvolutionBucket = Literal["day", "week", "month"]
RankingOrder = Literal["units", "revenue", "margin"]


class StatisticsWindowOut(BaseModel):
    """D8: ventana efectivamente aplicada por el read-model tras el clamp de
    historial del plan. `clamped=True` es lo que la superficie explica al
    usuario ("tu plan permite N días") en vez de mostrar un gráfico más
    corto sin causa aparente."""

    start:        datetime.date
    end:          datetime.date
    history_days: int
    clamped:      bool


class SalesEvolutionPointOut(BaseModel):
    """Un intervalo (día / semana ISO / mes) de la ventana aplicada. Los
    intervalos sin ventas viajan en cero, no se omiten."""

    bucket_start:    datetime.date
    bucket_end:      datetime.date
    revenue:         Decimal
    credit_notes:    Decimal
    net_revenue:     Decimal
    units:           Decimal
    operations:      int
    service_revenue: Decimal


class SalesPeriodTotalsOut(BaseModel):
    """Totales de un período completo — el actual (ventana aplicada) o el
    inmediatamente anterior de igual longitud. `service_revenue` es el importe
    de las líneas de servicio (product_id NULL): SÍ facturación, NO ranking
    (D6) — la superficie del ranking lo declara al pie."""

    start:           datetime.date
    end:             datetime.date
    revenue:         Decimal
    credit_notes:    Decimal
    net_revenue:     Decimal
    units:           Decimal
    operations:      int
    service_revenue: Decimal


class SalesEvolutionOut(BaseModel):
    bucket:   EvolutionBucket
    window:   StatisticsWindowOut
    points:   list[SalesEvolutionPointOut]
    current:  SalesPeriodTotalsOut
    previous: SalesPeriodTotalsOut


class ProductRankingRowOut(BaseModel):
    """Fila del ranking. `is_group` + `variant_count` distinguen un producto
    simple de un padre que agrupa variantes; `parent_id`/`parent_name` dan
    contexto a la variante en la vista sin agrupar. `cost_coverage_pct` es la
    proporción de líneas del grupo con costo congelado (D11)."""

    rank:              int
    product_id:        uuid.UUID
    product_name:      str
    sku:               str | None = None
    category:          str | None = None
    parent_id:         uuid.UUID | None = None
    parent_name:       str | None = None
    is_group:          bool
    variant_count:     int
    units:             Decimal
    revenue:           Decimal
    operations:        int
    total_cost:        Decimal | None = None
    gross_margin:      Decimal | None = None
    gross_margin_pct:  Decimal | None = None
    cost_coverage_pct: Decimal
    last_sale_date:    datetime.date | None = None


class ProductRankingPageOut(BaseModel):
    """Envelope estándar de paginación (api-standards §2) + la ventana
    aplicada. `window` es None sólo cuando el conjunto está vacío (el
    read-model no devuelve filas de las que leerla); la superficie toma la
    ventana de la evolución, que siempre la informa."""

    items:  list[ProductRankingRowOut]
    total:  int
    page:   int
    pages:  int
    window: StatisticsWindowOut | None = None


# ── E2 — desgloses por dimensión y top clientes (rpc_sales_breakdown /
#         rpc_sales_top_clients, migración 20261025000001) ────────────────────

BreakdownDimension = Literal["canal", "branch", "weekday", "hour", "category"]


class SalesBreakdownRowOut(BaseModel):
    """Un tramo del desglose. `key` es el valor crudo de la dimensión (canal,
    uuid de sucursal / categoría, isodow 1..7, hora 0..23) y viaja como null
    para el tramo "Sin canal" / "Sin sucursal" / "Sin categoría" — que NUNCA
    se omite (en producción es la mayoría del dinero). `label` es el rótulo
    resuelto por el read-model (nombre del catálogo, día en castellano,
    "HH:00")."""

    key:        str | None = None
    label:      str
    sort_order: int
    revenue:    Decimal
    units:      Decimal
    operations: int


class SalesBreakdownOut(BaseModel):
    """`window` es None sólo cuando la dimensión no devolvió filas (canal /
    sucursal / categoría sin ventas); día y hora viajan siempre completos."""

    dimension: BreakdownDimension
    window:    StatisticsWindowOut | None = None
    rows:      list[SalesBreakdownRowOut]


class TopClientRowOut(BaseModel):
    """Fila del top. `client_id` es null cuando la venta referencia un cliente
    que no pertenece a la cuenta: rankea por su importe con el nombre
    "Cliente no disponible", sin exponer datos ajenos."""

    rank:           int
    client_id:      uuid.UUID | None = None
    client_name:    str
    revenue:        Decimal
    units:          Decimal
    operations:     int
    last_sale_date: datetime.date | None = None


class UnassignedSalesOut(BaseModel):
    """OQ-2: las ventas sin cliente NO compiten en el ranking; su importe viaja
    aparte para que la superficie lo declare."""

    revenue:        Decimal
    units:          Decimal
    operations:     int
    last_sale_date: datetime.date | None = None


class TopClientsOut(BaseModel):
    window:        StatisticsWindowOut
    items:         list[TopClientRowOut]
    unassigned:    UnassignedSalesOut
    total_clients: int


# ── E3 — detalle por producto (rpc_product_sales_evolution, migración
#         20261026000001) ─────────────────────────────────────────────────────

class ProductSalesHeaderOut(BaseModel):
    """Cabecera del producto pedido. `is_group` + `variant_count` distinguen
    un producto simple de un padre que agrupa variantes CON ventas en el
    período (misma regla que el ranking); `parent_id`/`parent_name` dan
    contexto a una variante pedida directamente."""

    product_id:    uuid.UUID
    product_name:  str
    sku:           str | None = None
    category:      str | None = None
    parent_id:     uuid.UUID | None = None
    parent_name:   str | None = None
    is_group:      bool
    variant_count: int


class ProductSalesMetricsOut(BaseModel):
    """Métricas de un agregado del detalle (total / intervalo / miembro). Un
    margen ausente viaja como null — NUNCA como 0 (D11): un agregado sin
    líneas no tiene costo ni margen. `cost_coverage_pct` es null por la misma
    razón (no hay líneas sobre las que medir cobertura)."""

    units:             Decimal
    revenue:           Decimal
    operations:        int
    total_cost:        Decimal | None = None
    gross_margin:      Decimal | None = None
    gross_margin_pct:  Decimal | None = None
    cost_coverage_pct: Decimal | None = None
    last_sale_date:    datetime.date | None = None


class ProductSalesPointOut(ProductSalesMetricsOut):
    """Un intervalo (día / semana ISO / mes) de la ventana aplicada; los
    intervalos sin ventas viajan en cero, no se omiten."""

    bucket_start: datetime.date
    bucket_end:   datetime.date


class ProductSalesMemberOut(ProductSalesMetricsOut):
    """Un producto del grupo con ventas en el período (una variante, o el
    padre si vendió directo), con su puesto por importe dentro del grupo."""

    rank:         int
    product_id:   uuid.UUID
    product_name: str
    sku:          str | None = None


class ProductSalesDetailOut(BaseModel):
    product: ProductSalesHeaderOut
    bucket:  EvolutionBucket
    window:  StatisticsWindowOut
    totals:  ProductSalesMetricsOut
    points:  list[ProductSalesPointOut]
    members: list[ProductSalesMemberOut]
