"""
edicion-operaciones-con-dinero (tanda A, tasks 2.1-2.2) — emparejamiento de la reversión de un cargo en el
aging FIFO de Python (`_account_aging_sql.build_aging_cte`, la ÚNICA definición con cuatro consumidores:
`CustomerAccountRepository` y `SupplierAccountRepository` × `list_movements` / `list_movements_page`).

La regla (D9) es la misma que aplica el SQL de los cinco lugares de base de datos (gate
`supabase/tests/test_aging_reversal_pairing.sql`): el crédito de una reversión de cargo —`credit_note` del cliente,
`debit_note` del proveedor— cancela PRIMERO los cargos de su misma referencia y de la misma cuenta corriente, en
el orden de la línea de flotación de esos cargos; sólo el remanente va al pozo general.

Dos capas:
  - unitarias (CI): el SQL generado nombra el tipo de reversión de cada lado y empareja por referencia;
  - integración (`-m integration`, Postgres local): el CTE EJECUTADO reparte igual que la función SQL
    `_customer_open_items` / `_supplier_open_items` sobre el mismo ledger (spec `receivables-aging`).
"""
from __future__ import annotations

import datetime
import json
import os
import re
import uuid
from decimal import Decimal

import asyncpg
import pytest

from backend.repositories._account_aging_sql import build_aging_cte

DSN = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@127.0.0.1:54322/postgres")

CUSTOMER = dict(account_column="customer_account_id", movements_table="customer_account_movements",
                charge_type="sale", reversal_type="credit_note", outer_alias="cam")
SUPPLIER = dict(account_column="supplier_account_id", movements_table="supplier_account_movements",
                charge_type="purchase", reversal_type="debit_note", outer_alias="sam")


@pytest.mark.parametrize("side, reversal", [(CUSTOMER, "credit_note"), (SUPPLIER, "debit_note")])
def test_el_cte_empareja_la_reversion_por_referencia(side, reversal) -> None:
    cte, derivatives = build_aging_cte(**side)
    flat = re.sub(r"\s+", " ", cte)
    assert f"m.movement_type = '{reversal}'" in flat, "el CTE debe conocer el tipo de reversión de ese lado"
    assert "PARTITION BY m.reference_id" in flat, "los cargos se acumulan dentro de su referencia"
    assert "WITH pool AS" in cte and "open_items AS" in cte
    assert "open_amount" in derivatives


def test_el_tipo_de_reversion_es_obligatorio() -> None:
    """Una definición que se puede llamar sin decir cuál es la reversión volvería al comportamiento viejo."""
    with pytest.raises(TypeError):
        build_aging_cte(account_column="customer_account_id", movements_table="customer_account_movements",
                        charge_type="sale", outer_alias="cam")  # type: ignore[call-arg]


# ═════════════════════════ integración ═════════════════════════
@pytest.fixture
async def ledger():
    """Ledger sintético dentro de UNA transacción revertida: sin residuo."""
    try:
        conn = await asyncpg.connect(DSN)
    except (OSError, asyncpg.PostgresError) as exc:  # pragma: no cover
        pytest.skip(f"Postgres local no disponible ({exc}); levantá `supabase start`")
    tr = conn.transaction()
    await tr.start()
    try:
        user = uuid.uuid4()
        await conn.execute(
            "INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data) "
            "VALUES ($1, 'authenticated', 'authenticated', $2, now(), now(), jsonb_build_object('name', 'Aging Py'))",
            user, f"aging-py-{user}@test.local")
        acc = await conn.fetchval("SELECT account_id FROM public.account_members WHERE user_id = $1 LIMIT 1", user)
        await conn.execute("SELECT set_config('request.jwt.claims', $1, true)", json.dumps({"sub": str(user), "role": "authenticated"}))
        client = await conn.fetchval(
            "INSERT INTO public.clients (user_id, account_id, name, status) VALUES ($1, $2, 'c', 'active') RETURNING id", user, acc)
        supplier = await conn.fetchval("INSERT INTO public.suppliers (account_id, name) VALUES ($1, 's') RETURNING id", acc)
        ca = await conn.fetchval("SELECT public.c30_get_or_create_customer_account($1, $2)", acc, client)
        sa = await conn.fetchval("SELECT public.c30_get_or_create_supplier_account($1, $2)", acc, supplier)
        today = await conn.fetchval("SELECT public.reporting_local_today()")
        ref_a, ref_b, ref_r = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()

        async def seed(fn: str, party: uuid.UUID, charge: str, rev: str, table: str, col: str) -> None:
            q = f"SELECT public.{fn}($1, $2, $3, $4, $5)"
            await conn.fetchval(q, party, 500, charge, ref_a, today - datetime.timedelta(days=5))
            await conn.fetchval(q, party, 1000, charge, ref_b, today + datetime.timedelta(days=10))
            await conn.fetchval(q, party, 1200, charge, ref_b, today + datetime.timedelta(days=10))
            await conn.fetchval(q, party, -1000, rev, ref_b, None)
            # cadena de ediciones sobre otra referencia
            await conn.fetchval(q, party, 700, charge, ref_r, today + datetime.timedelta(days=10))
            await conn.fetchval(q, party, 800, charge, ref_r, today + datetime.timedelta(days=10))
            await conn.fetchval(q, party, -700, rev, ref_r, None)
            # crédito sin cargo de su referencia (huérfana) y otra sin referencia: van al pozo
            await conn.fetchval(q, party, -100, rev, uuid.uuid4(), None)
            await conn.fetchval(q, party, -50, rev, None, None)
            for i, (amt, typ) in enumerate([(500, charge), (1000, charge), (1200, charge), (-1000, rev),
                                            (700, charge), (800, charge), (-700, rev), (-100, rev), (-50, rev)]):
                await conn.execute(
                    f"UPDATE public.{table} SET created_at = now() - make_interval(hours => $2) "
                    f"WHERE id = (SELECT id FROM public.{table} WHERE {col} = $1 AND amount = $3 AND movement_type = $4 "
                    f"ORDER BY created_at DESC LIMIT 1)", party, 100 - i, Decimal(amt), typ)

        await seed("c30_register_customer_account_movement", ca, "sale", "credit_note", "customer_account_movements", "customer_account_id")
        await seed("c30_register_supplier_account_movement", sa, "purchase", "debit_note", "supplier_account_movements", "supplier_account_id")
        yield conn, acc, ca, sa
    finally:
        await tr.rollback()
        await conn.close()


async def _py_open(conn, side: dict, party: uuid.UUID, acc: uuid.UUID) -> dict:
    cte, _ = build_aging_cte(**side)
    rows = await conn.fetch(
        cte + f" SELECT oi.id, oi.open_amount FROM open_items oi", party, acc)
    return {r["id"]: r["open_amount"] for r in rows}


@pytest.mark.integration
async def test_cte_de_python_reparte_igual_que_la_funcion_sql(ledger) -> None:
    conn, acc, ca, sa = ledger
    for side, fn, party in ((CUSTOMER, "_customer_open_items", ca), (SUPPLIER, "_supplier_open_items", sa)):
        py = await _py_open(conn, side, party, acc)
        sql_rows = await conn.fetch(f"SELECT id, open_amount FROM public.{fn}($1, $2)", acc, party)
        sql = {r["id"]: r["open_amount"] for r in sql_rows}
        assert py == sql, f"{fn}: el CTE de Python y la función SQL repartieron distinto"


@pytest.mark.integration
async def test_reparto_y_cierre_del_cte_de_python(ledger) -> None:
    conn, acc, ca, sa = ledger
    for side, party, table, col in ((CUSTOMER, ca, "customer_account_movements", "customer_account_id"),
                                    (SUPPLIER, sa, "supplier_account_movements", "supplier_account_id")):
        py = await _py_open(conn, side, party, acc)
        amounts = {r["id"]: r for r in await conn.fetch(
            f"SELECT id, amount, reference_id FROM public.{table} WHERE {col} = $1 AND amount > 0", party)}
        opens = sorted(float(v) for v in py.values())
        # A (500, ajeno) pierde 150 contra el pozo (la nota huérfana de 100 y la nota sin referencia de 50);
        # B1 (1000) y R1 (700) quedan en 0 por SU reversión; B2 (1200) y R2 (800) abiertos.
        assert opens == [0.0, 0.0, 350.0, 800.0, 1200.0], opens
        saldo = await conn.fetchval(f"SELECT COALESCE(SUM(amount), 0) FROM public.{table} WHERE {col} = $1", party)
        assert sum(py.values()) == saldo, "invariante de cierre: lo abierto suma el saldo"
        assert len(amounts) == len(py)
