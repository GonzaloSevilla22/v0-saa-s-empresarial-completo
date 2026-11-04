"""
edicion-operaciones-con-dinero (tanda A, task 1.5) — las proyecciones de lectura de los tres
listados (`/sales`, `/purchases`, `/expenses`) calculan `has_account_charge`, `has_cash_movement`,
`has_bank_movement` e `is_delete_blocked` sobre la HUELLA NETA de la operación (función
`op_money_footprint`, D3), no con un `EXISTS` sobre el tipo de movimiento.

Por qué: con referencias estables una operación editada acumula en un libro el movimiento original, su
compensación y el movimiento nuevo. Un `EXISTS` sigue diciendo "tiene caja" aunque el neto sea cero, y el
diálogo de borrado ofrecería compensar un libro que ya está en cero (o bloquearía el borrado por una
sesión de caja inexistente).

Dos capas:
  - unitarias (CI): el SQL de cada repositorio consume la función de huella y no reintroduce el `EXISTS`
    en esos cuatro derivados;
  - integración (`-m integration`, Postgres local): las filas REALES que devuelven los tres repositorios
    para una operación de huella compensada y una de huella viva. Es la capa que detecta el bug: un mock
    de asyncpg no ejecuta el SQL.

`is_payment_locked` NO se toca en la tanda A (lo retira la tanda B, grupo 10): sigue siendo el OR de los
`EXISTS`, y los tests lo fijan para que nadie lo migre por accidente.
"""
from __future__ import annotations

import inspect
import json
import os
import re
import uuid

import asyncpg
import pytest

from backend.repositories import expense_repository, purchase_repository, sales_repository
from backend.repositories.expense_repository import ExpenseRepository
from backend.repositories.purchase_repository import PurchaseRepository
from backend.repositories.sales_repository import SalesRepository

DSN = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@127.0.0.1:54322/postgres")

_FLAGS = ("has_account_charge", "has_cash_movement", "has_bank_movement", "is_delete_blocked")


# ═════════════════════════ capa unitaria (CI) ═════════════════════════
def _expr_before(src: str, alias: str) -> str:
    """El texto de la expresión SQL que termina en `AS <alias>`: desde el cierre de la columna anterior
    (`,` al final de línea) hasta el alias, para incluir expresiones de varias líneas."""
    pattern = r"(?:^|,\n)((?:(?!,\n).)*?)\bAS\s+" + alias + r"\b"
    m = re.search(pattern, src, flags=re.S)
    assert m, f"no se encontró la columna {alias}"
    return re.sub(r"--[^\n]*", "", m.group(1))  # sin los comentarios SQL: sólo la expresión


@pytest.mark.parametrize(
    "module, flags",
    [
        (sales_repository, ("has_account_charge", "has_cash_movement", "has_bank_movement")),
        (purchase_repository, _FLAGS),
        (expense_repository, ("has_cash_movement", "has_bank_movement", "is_delete_blocked")),
    ],
)
def test_projection_consume_la_huella_neta(module, flags) -> None:
    src = inspect.getsource(module)
    assert "op_money_footprint_flags" in src, "la proyección debe consumir la función de huella neta"
    for flag in flags:
        expr = _expr_before(src, flag)
        assert "fp." in expr, f"{flag} debe salir de la huella neta (fp.), no de un EXISTS: {expr!r}"
        assert "EXISTS" not in expr.upper(), f"{flag} no puede reintroducir un EXISTS: {expr!r}"


def test_is_payment_locked_sigue_siendo_el_or_de_los_exists() -> None:
    """Fuera de alcance de la tanda A: se retira en la tanda B (grupo 10)."""
    for module in (sales_repository, purchase_repository, expense_repository):
        src = inspect.getsource(module)
        assert re.search(r"AS\s+is_payment_locked\b", src), f"{module.__name__} perdió is_payment_locked"
        expr = _expr_before(src, "is_payment_locked")
        assert "EXISTS" in expr.upper()


# ═════════════════════════ capa de integración ═════════════════════════
integration = pytest.mark.integration


async def _set_claims(conn: asyncpg.Connection, user_id: uuid.UUID) -> None:
    claims = json.dumps({"sub": str(user_id), "role": "authenticated"})
    await conn.execute("SELECT set_config('request.jwt.claims', $1, true)", claims)
    await conn.execute("SELECT set_config('request.jwt.claim.sub', $1, true)", str(user_id))


@pytest.fixture
async def seeded():
    """Fixture dentro de UNA transacción que se revierte: no deja residuo (nada que limpiar)."""
    try:
        conn = await asyncpg.connect(DSN)
    except (OSError, asyncpg.PostgresError) as exc:  # pragma: no cover - depende del entorno
        pytest.skip(f"Postgres local no disponible ({exc}); levantá `supabase start`")
    tr = conn.transaction()
    await tr.start()
    try:
        user = uuid.uuid4()
        await conn.execute(
            """
            INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
            VALUES ($1, 'authenticated', 'authenticated', $2, now(), now(), jsonb_build_object('name', 'Proyeccion Huella'))
            """,
            user, f"op-proj-{user}@test.local",
        )
        acc = await conn.fetchval("SELECT account_id FROM public.account_members WHERE user_id = $1 LIMIT 1", user)
        branch = await conn.fetchval("SELECT id FROM public.branches WHERE account_id = $1 LIMIT 1", acc)
        cb1 = await conn.fetchval("SELECT id FROM public.cashboxes WHERE branch_id = $1 LIMIT 1", branch)
        cb2 = await conn.fetchval("INSERT INTO public.cashboxes (branch_id, name) VALUES ($1, 'caja 2') RETURNING id", branch)
        product = await conn.fetchval(
            "INSERT INTO public.products (user_id, account_id, name, price, cost, sku) VALUES ($1, $2, 'p', 100, 50, 'OPP-1') RETURNING id",
            user, acc,
        )
        client = await conn.fetchval("INSERT INTO public.clients (user_id, account_id, name, status) VALUES ($1, $2, 'c', 'active') RETURNING id", user, acc)
        supplier = await conn.fetchval("INSERT INTO public.suppliers (account_id, name) VALUES ($1, 's') RETURNING id", acc)
        bank = await conn.fetchval("INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance) VALUES ($1, 'b', 'ARS', 0) RETURNING id", acc)
        await _set_claims(conn, user)
        s_open = await conn.fetchval("INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by) VALUES ($1, 'open', 0, $2) RETURNING id", cb1, user)
        s_old = await conn.fetchval("INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by) VALUES ($1, 'open', 0, $2) RETURNING id", cb2, user)
        ca = await conn.fetchval("SELECT public.c30_get_or_create_customer_account($1, $2)", acc, client)
        sa = await conn.fetchval("SELECT public.c30_get_or_create_supplier_account($1, $2)", acc, supplier)

        ids: dict[str, uuid.UUID] = {"user": user, "acc": acc}

        async def sale(tag: str, charge: int, reversal: int, cash: int, cash_rev: int) -> None:
            op = uuid.uuid4()
            ids[tag] = op
            await conn.execute(
                "INSERT INTO public.sales (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, branch_id) "
                "VALUES ($1, $2, $3, $4, 100, 1, 100, 'ARS', CURRENT_DATE, $5, $6)", user, acc, client, product, op, branch)
            await conn.execute("SELECT public.c30_register_customer_account_movement($1, $2, 'sale', $3)", ca, charge, op)
            if reversal:
                await conn.execute("SELECT public.c30_register_customer_account_movement($1, $2, 'credit_note', $3)", ca, -reversal, op)
            await conn.execute("SELECT public.c28_register_cash_movement($1, $2, 'sale', $3)", s_open, cash, op)
            if cash_rev:
                await conn.execute("SELECT public.c28_register_cash_movement($1, $2, 'sale_reversal', $3)", s_open, -cash_rev, op)

        await sale("sale_netzero", 1000, 1000, 1000, 1000)
        await sale("sale_live", 500, 0, 500, 0)
        for tag in ("sale_netzero", "sale_live"):
            op = ids[tag]
            amount = 1000 if tag == "sale_netzero" else 500
            await conn.execute("SELECT public._register_bank_movement($1, $2, 'transfer_in', 'sale', $3, CURRENT_DATE, $4, 'x')", bank, amount, op, branch)
            if tag == "sale_netzero":
                await conn.execute("SELECT public._register_bank_movement($1, $2, 'transfer_out', 'sale', $3, CURRENT_DATE, $4, 'x')", bank, -amount, op, branch)

        async def purchase(tag: str, compensated: bool) -> None:
            op = uuid.uuid4()
            ids[tag] = op
            await conn.execute(
                "INSERT INTO public.purchases (user_id, account_id, product_id, amount, quantity, total, description, date, operation_id, branch_id, supplier_id) "
                "VALUES ($1, $2, $3, 700, 1, 700, 'p', CURRENT_DATE, $4, $5, $6)", user, acc, product, op, branch, supplier)
            await conn.execute("SELECT public.c30_register_supplier_account_movement($1, 700, 'purchase', $2)", sa, op)
            await conn.execute("SELECT public.c28_register_cash_movement($1, -700, 'purchase_payment', $2)", s_old, op)
            await conn.execute("SELECT public._register_bank_movement($1, -700, 'transfer_out', 'purchase', $2, CURRENT_DATE, $3, 'x')", bank, op, branch)
            if compensated:
                await conn.execute("SELECT public.c30_register_supplier_account_movement($1, -700, 'debit_note', $2)", sa, op)
                await conn.execute("SELECT public.c28_register_cash_movement($1, 700, 'purchase_payment_reversal', $2)", s_old, op)
                await conn.execute("SELECT public._register_bank_movement($1, 700, 'transfer_in', 'purchase', $2, CURRENT_DATE, $3, 'x')", bank, op, branch)

        await purchase("purchase_netzero", True)
        await purchase("purchase_live", False)

        async def expense(tag: str, compensated: bool) -> None:
            e = await conn.fetchval(
                "INSERT INTO public.expenses (user_id, account_id, category, amount, date, description, branch_id) "
                "VALUES ($1, $2, 'otros', 300, now(), 'g', $3) RETURNING id", user, acc, branch)
            ids[tag] = e
            await conn.execute("SELECT public.c28_register_cash_movement($1, -300, 'expense', $2)", s_old, e)
            await conn.execute("SELECT public._register_bank_movement($1, -300, 'transfer_out', 'expense', $2, CURRENT_DATE, $3, 'x')", bank, e, branch)
            if compensated:
                await conn.execute("SELECT public.c28_register_cash_movement($1, 300, 'expense_reversal', $2)", s_old, e)
                await conn.execute("SELECT public._register_bank_movement($1, 300, 'transfer_in', 'expense', $2, CURRENT_DATE, $3, 'x')", bank, e, branch)

        await expense("expense_netzero", True)
        await expense("expense_live", False)

        # La caja 2 queda SIN sesión abierta: la "vieja" se cierra después de cargarle todo.
        await conn.execute(
            "UPDATE public.cash_sessions SET status = 'closed', closed_by = $2, closed_at = now(), closing_balance = 0, "
            "counted_balance = 0, expected_balance = 0, difference = 0 WHERE id = $1", s_old, user)
        yield conn, ids, acc
    finally:
        await tr.rollback()
        await conn.close()


def _by_op(rows, op) -> dict:
    found = [dict(r) for r in rows if str(r["operation_id"]) == str(op)]
    assert found, "la operación no apareció en el listado"
    return found[0]


@integration
async def test_ventas_huella_compensada_no_reporta_dinero(seeded) -> None:
    conn, ids, acc = seeded
    rows, _ = await SalesRepository(conn).list_paginated_by_operation(str(acc), 0, 100)
    z = _by_op(rows, ids["sale_netzero"])
    assert (z["has_account_charge"], z["has_cash_movement"], z["has_bank_movement"]) == (False, False, False), (
        "una venta con la huella compensada en los tres libros no tiene dinero registrado")
    live = _by_op(rows, ids["sale_live"])
    assert (live["has_account_charge"], live["has_cash_movement"], live["has_bank_movement"]) == (True, True, True)
    # is_payment_locked NO se toca (grupo 10): sigue viendo cualquier movimiento, aunque el neto sea cero.
    assert z["is_payment_locked"] is True


@integration
async def test_compras_huella_compensada_no_reporta_dinero(seeded) -> None:
    conn, ids, acc = seeded
    rows, _ = await PurchaseRepository(conn).list_paginated_by_operation(str(acc), 0, 100)
    z = _by_op(rows, ids["purchase_netzero"])
    assert (z["has_account_charge"], z["has_cash_movement"], z["has_bank_movement"], z["is_delete_blocked"]) == (
        False, False, False, False), "huella compensada: ni dinero registrado ni borrado bloqueado por una caja cerrada"
    live = _by_op(rows, ids["purchase_live"])
    assert (live["has_account_charge"], live["has_cash_movement"], live["has_bank_movement"]) == (True, True, True)
    assert live["is_delete_blocked"] is True, "con huella viva de caja y la caja SIN sesión abierta el borrado está bloqueado"
    assert z["is_payment_locked"] is True


@integration
async def test_gastos_huella_compensada_no_reporta_dinero(seeded) -> None:
    conn, ids, acc = seeded
    items, _ = await ExpenseRepository(conn).list_paginated(str(acc), page=0, page_size=100)
    by_id = {str(i["id"]): i for i in items}
    z = by_id[str(ids["expense_netzero"])]
    assert (z["has_cash_movement"], z["has_bank_movement"], z["is_delete_blocked"]) == (False, False, False)
    live = by_id[str(ids["expense_live"])]
    assert (live["has_cash_movement"], live["has_bank_movement"], live["is_delete_blocked"]) == (True, True, True)
    one = await ExpenseRepository(conn).get_by_id(str(ids["expense_netzero"]), str(acc))
    assert one is not None and one["has_cash_movement"] is False
    assert z["is_payment_locked"] is True
