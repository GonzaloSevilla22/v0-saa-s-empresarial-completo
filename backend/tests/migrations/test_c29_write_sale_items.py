"""
c29-write-sale-items — Migration tests.

Estrategia (igual que test_events_reconcile): sin Docker/DB real en CI, se
verifican las PROPIEDADES del archivo de migración por parsing:
  - el core _c29_confirm_order_core inserta en sale_items dentro del bloque con
    producto (entre el INSERT de sales y el de stock_movements),
  - el backfill es idempotente (NOT EXISTS) y solo toca product_id NOT NULL,
  - no hay DDL destructivo (DROP), preserva el REVOKE del helper.

Spec ref: sale-line-items §"Invariante — toda venta con producto tiene su fila
en sale_items, sin importar la ruta".
"""
from __future__ import annotations

import re
from pathlib import Path

MIGRATION_FILE = (
    Path(__file__).parents[3]
    / "supabase"
    / "migrations"
    / "20260721000001_c29_write_sale_items.sql"
)


def _sql() -> str:
    assert MIGRATION_FILE.exists(), f"falta la migración: {MIGRATION_FILE}"
    return MIGRATION_FILE.read_text(encoding="utf-8")


def test_migration_file_exists():
    assert MIGRATION_FILE.exists()


def test_recrea_el_core_con_create_or_replace():
    sql = _sql()
    assert re.search(
        r"create\s+or\s+replace\s+function\s+public\._c29_confirm_order_core",
        sql,
        re.IGNORECASE,
    )


def test_core_inserta_en_sale_items():
    sql = _sql()
    assert re.search(
        r"insert\s+into\s+public\.sale_items", sql, re.IGNORECASE
    ), "el core debe insertar en sale_items"


def test_sale_items_se_inserta_entre_sales_y_stock_movements():
    """El ítem se escribe en la misma transacción del header, en el bloque de
    producto: después del INSERT de sales y antes del de stock_movements."""
    sql = _sql().lower()
    pos_sales = sql.find("insert into public.sales")
    pos_items = sql.find("insert into public.sale_items")
    pos_mov = sql.find("insert into public.stock_movements")
    assert -1 < pos_sales < pos_items < pos_mov, (
        "orden esperado: sales → sale_items → stock_movements"
    )


def test_sale_items_usa_variant_id_null():
    sql = _sql()
    bloque = sql[sql.lower().find("insert into public.sale_items"):]
    bloque = bloque[: bloque.find(";") + 1]
    assert "null" in bloque.lower(), "variant_id debe ir NULL (paridad con v2)"
    for col in ("sale_id", "product_id", "account_id", "quantity", "price", "subtotal"):
        assert col in bloque.lower(), f"falta columna {col} en el INSERT de sale_items"


def test_backfill_es_idempotente_not_exists():
    sql = _sql().lower()
    backfill = sql[sql.rfind("insert into public.sale_items"):]
    assert "not exists" in backfill, "el backfill debe usar NOT EXISTS (idempotente)"
    assert "product_id is not null" in backfill, (
        "el backfill solo cubre ventas con producto"
    )


def test_no_ddl_destructivo():
    sql = _sql().lower()
    assert "drop function" not in sql
    assert "drop column" not in sql
    assert "drop table" not in sql


def test_preserva_revoke_del_helper():
    sql = _sql().lower()
    assert "revoke all on function public._c29_confirm_order_core" in sql
