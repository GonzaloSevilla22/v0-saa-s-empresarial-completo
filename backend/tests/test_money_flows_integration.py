"""v31-money-integration-tests (task 1.4, D5) — los tres flujos de dinero de H-34 que ningún
test ejercitaba contra Postgres a través de su repositorio real.

Marcado `integration`: corre en el tier de integración de `KPI_Validation.yml`
(`pytest -m "integration and not arca"` contra el stack de `supabase start`). En local, con el
stack levantado: `python -m pytest backend/tests/test_money_flows_integration.py -m integration`.

* Arqueo de caja — `CashSessionRepository`: abre, registra efectivo, cierra con faltante; la base
  calcula `expected_balance` / `difference`; un segundo cierre se rechaza.
* Conciliación bancaria — `BankReconciliationRepository`: importa, abre sesión, matchea, deshace
  (la línea vuelve a estar disponible) y cierra.
* Partida doble — `SalesRepository` + `OutboxRepository.run_dispatch`: un asiento balanceado por
  venta y un segundo despacho que no lo duplica.

Cada test usa una cuenta sintética propia (aislamiento por cuenta, sin conteos globales) y asierta
residuo cero al terminar.
"""
from __future__ import annotations

import contextlib
import json
import uuid
from decimal import Decimal

import asyncpg
import pytest

from backend.repositories.bank_account_repository import BankAccountRepository
from backend.repositories.bank_reconciliation_repository import BankReconciliationRepository
from backend.repositories.cash_session_repository import CashSessionRepository
from backend.repositories.outbox_repository import OutboxRepository
from backend.repositories.sales_repository import SalesRepository
from backend.tests.integration_db import cleanup_account, connect, seed_account, set_claims

pytestmark = pytest.mark.integration


@contextlib.asynccontextmanager
async def _as(conn: asyncpg.Connection, user_id: object):
    """Una 'request': transacción + claims (`auth.uid()` para las RPCs `SECURITY DEFINER`)."""
    async with conn.transaction():
        await set_claims(conn, user_id)
        yield


async def _cleanup(conn: asyncpg.Connection, user_id: object, account_id: object) -> None:
    # cashboxes / cash_sessions / cash_movements no llevan account_id propio: cuelgan de la sucursal.
    branches = "SELECT id FROM public.branches WHERE account_id = $1"
    await cleanup_account(
        conn,
        user_id,
        account_id,
        before=(
            (
                f"DELETE FROM public.cash_movements WHERE session_id IN (SELECT cs.id FROM public.cash_sessions cs "
                f"JOIN public.cashboxes cb ON cb.id = cs.cashbox_id WHERE cb.branch_id IN ({branches}))",
                (account_id,),
            ),
            (
                f"DELETE FROM public.cash_sessions WHERE cashbox_id IN (SELECT id FROM public.cashboxes "
                f"WHERE branch_id IN ({branches}))",
                (account_id,),
            ),
            (f"DELETE FROM public.cashboxes WHERE branch_id IN ({branches})", (account_id,)),
        ),
    )


async def _assert_no_residue(conn: asyncpg.Connection, user_id: object, account_id: object, branch_ids: list) -> None:
    assert await conn.fetchval("SELECT count(*) FROM auth.users WHERE id = $1", user_id) == 0
    assert await conn.fetchval("SELECT count(*) FROM public.accounts WHERE id = $1", account_id) == 0
    for table in ("journal_entries", "events", "bank_accounts", "bank_movements", "bank_statement_lines",
                  "reconciliation_sessions", "reconciliation_matches", "sales", "branches"):
        assert await conn.fetchval(f"SELECT count(*) FROM public.{table} WHERE account_id = $1", account_id) == 0, table
    assert await conn.fetchval("SELECT count(*) FROM public.cashboxes WHERE branch_id = ANY($1::uuid[])", branch_ids) == 0
    assert await conn.fetchval(
        "SELECT count(*) FROM public.cash_sessions WHERE cashbox_id IN "
        "(SELECT id FROM public.cashboxes WHERE branch_id = ANY($1::uuid[]))",
        branch_ids,
    ) == 0


async def _branch_ids(conn: asyncpg.Connection, account_id: object) -> list:
    return [r["id"] for r in await conn.fetch("SELECT id FROM public.branches WHERE account_id = $1", account_id)]


async def test_cash_session_arqueo_with_shortfall_and_second_close_rejected():
    conn = await connect()
    user_id, account_id = await seed_account(conn, "arqueo")
    branch_ids = await _branch_ids(conn, account_id)
    try:
        cashbox_id = await conn.fetchval(
            "SELECT cb.id FROM public.cashboxes cb JOIN public.branches b ON b.id = cb.branch_id "
            "WHERE b.account_id = $1 ORDER BY cb.created_at LIMIT 1",
            account_id,
        )
        assert cashbox_id is not None, "SETUP: la cuenta nueva debe nacer con una caja"
        repo = CashSessionRepository(conn)

        async with _as(conn, user_id):
            opened = await repo.open_session(str(cashbox_id), 1000)
        assert opened["status"] == "open"
        session_id = str(opened["session_id"])

        async with _as(conn, user_id):
            await repo.register_movement(session_id, 500, "sale", None)
            await repo.register_movement(session_id, -200, "withdrawal", None, "retiro de prueba")

        # esperado = 1000 + 500 - 200 = 1300; se cuentan 1250 -> faltante de 50.
        async with _as(conn, user_id):
            closed = await repo.close_session(session_id, 1250)
        assert closed["status"] == "closed"
        assert Decimal(str(closed["expected_balance"])) == Decimal("1300")
        assert Decimal(str(closed["counted_balance"])) == Decimal("1250")
        assert Decimal(str(closed["difference"])) == Decimal("-50")

        stored = await conn.fetchrow(
            "SELECT status, expected_balance, counted_balance, difference FROM public.cash_sessions WHERE id = $1",
            uuid.UUID(session_id),
        )
        assert stored["status"] == "closed"
        assert (stored["expected_balance"], stored["counted_balance"], stored["difference"]) == (
            Decimal("1300"), Decimal("1250"), Decimal("-50"),
        )

        # El cierre queda en el historial con la diferencia como motivo (señal antifraude).
        reason = await conn.fetchval(
            "SELECT reason FROM public.document_status_history WHERE account_id = $1 "
            "AND document_type = 'cash_session' AND to_status = 'closed' AND document_id = $2",
            account_id, uuid.UUID(session_id),
        )
        assert reason is not None and "diferencia de arqueo" in reason

        # Segundo cierre de la misma sesión: la base lo rechaza.
        with pytest.raises(asyncpg.PostgresError) as info:
            async with _as(conn, user_id):
                await repo.close_session(session_id, 1300)
        assert "session_not_open" in str(info.value)
        assert info.value.sqlstate == "P0409"
    finally:
        await _cleanup(conn, user_id, account_id)
        await _assert_no_residue(conn, user_id, account_id, branch_ids)
        await conn.close()


async def test_bank_reconciliation_undo_match_releases_the_line():
    conn = await connect()
    user_id, account_id = await seed_account(conn, "conciliacion")
    branch_ids = await _branch_ids(conn, account_id)
    try:
        today = await conn.fetchval("SELECT public.reporting_local_today()")
        accounts = BankAccountRepository(conn)
        recon = BankReconciliationRepository(conn)

        async with _as(conn, user_id):
            bank = await accounts.create(
                name="__integ_banco__", bank_name=None, cbu=None, alias=None,
                currency="ARS", opening_balance=Decimal("0"), opening_date=None,
            )
        assert bank is not None
        bank_id = str(bank["id"])

        # Libro mayor: un ingreso de 1000. Extracto: esa línea de 1000 y otra de 300 sin movimiento.
        async with _as(conn, user_id):
            movement = await recon.register_manual_movement(
                f"integ-bm-{uuid.uuid4()}", bank_id, Decimal("1000"), "transfer_in", today, "ingreso de prueba"
            )
        movement_id = str(movement["movement_id"])
        assert movement["replayed"] is False

        lines = [
            {"line_no": 1, "value_date": today.isoformat(), "description": "ingreso 1000", "amount": 1000, "balance": None},
            {"line_no": 2, "value_date": today.isoformat(), "description": "comision 300", "amount": 300, "balance": None},
        ]
        async with _as(conn, user_id):
            imported = await recon.import_statement(
                f"integ-imp-{uuid.uuid4()}", bank_id, "extracto.csv", f"hash-{uuid.uuid4()}", json.dumps(lines)
            )
        assert imported["line_count"] == 2 and imported["replayed"] is False

        async with _as(conn, user_id):
            session = await recon.open_session(bank_id, today, today, Decimal("1300"))
        assert session["status"] == "open"
        session_id = str(session["session_id"])

        acct = str(account_id)
        pending = await recon.pending_lines(bank_id, acct, today, today)
        assert [(p["line_no"], p["amount"]) for p in pending] == [(1, Decimal("1000")), (2, Decimal("300"))]
        line1 = str(next(p["id"] for p in pending if p["line_no"] == 1))

        async with _as(conn, user_id):
            match = await recon.create_match(session_id, [line1], [movement_id])
        assert match["line_count"] == 1 and match["movement_count"] == 1
        assert Decimal(str(match["amount"])) == Decimal("1000")
        match_group = str(match["match_group"])

        assert await conn.fetchval(
            "SELECT reconciliation_status FROM public.bank_movements WHERE id = $1", uuid.UUID(movement_id)
        ) == "matched"
        assert [p["line_no"] for p in await recon.pending_lines(bank_id, acct, today, today)] == [2]
        assert [m["match_group"] for m in await recon.list_matches(session_id, acct)] == [uuid.UUID(match_group)]

        # Deshacer exige motivo, libera la línea y el movimiento.
        with pytest.raises(asyncpg.PostgresError) as info:
            async with _as(conn, user_id):
                await recon.undo_match(match_group, "")
        assert "motivo_requerido" in str(info.value)

        async with _as(conn, user_id):
            undone = await recon.undo_match(match_group, "match equivocado")
        assert undone["status"] == "undone" and undone["undone_rows"] >= 1
        assert await conn.fetchval(
            "SELECT reconciliation_status FROM public.bank_movements WHERE id = $1", uuid.UUID(movement_id)
        ) == "unreconciled"
        assert sorted(p["line_no"] for p in await recon.pending_lines(bank_id, acct, today, today)) == [1, 2]
        assert await recon.list_matches(session_id, acct) == []

        # La línea liberada se puede volver a conciliar (no quedó bloqueada por el match deshecho).
        async with _as(conn, user_id):
            rematch = await recon.create_match(session_id, [line1], [movement_id])
        assert rematch["match_group"] != match["match_group"]

        # Cierre: el extracto declara 1300 y el libro tiene 1000 -> diferencia de 300 exige motivo.
        with pytest.raises(asyncpg.PostgresError) as info:
            async with _as(conn, user_id):
                await recon.close_session(session_id, None)
        assert "motivo_requerido" in str(info.value)
        async with _as(conn, user_id):
            closed = await recon.close_session(session_id, "comision pendiente de contabilizar")
        assert closed["status"] == "closed"
        assert Decimal(str(closed["difference"])) == Decimal("300")
        assert Decimal(str(closed["ledger_closing_balance"])) == Decimal("1000")

        # CLOSED es terminal.
        with pytest.raises(asyncpg.PostgresError) as info:
            async with _as(conn, user_id):
                await recon.close_session(session_id, "otra vez")
        assert "session_closed" in str(info.value)
    finally:
        await _cleanup(conn, user_id, account_id)
        await _assert_no_residue(conn, user_id, account_id, branch_ids)
        await conn.close()


async def test_cash_sale_posts_one_balanced_idempotent_journal_entry_via_outbox():
    conn = await connect()
    user_id, account_id = await seed_account(conn, "asiento")
    branch_ids = await _branch_ids(conn, account_id)
    try:
        branch_id = branch_ids[0]
        pm_cash = await conn.fetchval(
            "SELECT id FROM public.payment_methods WHERE account_id = $1 AND kind = 'cash' AND deleted_at IS NULL LIMIT 1",
            account_id,
        )
        assert pm_cash is not None, "SETUP: handle_new_user debe sembrar las formas de pago"
        product_id = await conn.fetchval(
            "INSERT INTO public.products (user_id, account_id, name, price, cost, sku) "
            "VALUES ($1, $2, '__integ_asiento__', 15000, 6000, $3) RETURNING id",
            user_id, account_id, f"INTEG-{uuid.uuid4().hex[:8]}",
        )
        await conn.execute(
            "INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity) VALUES ($1, $2, $3, 50)",
            account_id, branch_id, product_id,
        )

        sales = SalesRepository(conn)
        async with _as(conn, user_id):
            created = await sales.create_operation(
                str(user_id), str(account_id),
                [{"product_id": str(product_id), "amount": 15000, "quantity": 1, "unit_id": None}],
                f"integ-asiento-{uuid.uuid4()}",
                payment_method_id=str(pm_cash),
                branch_id=str(branch_id),
            )
        assert created is not None
        op_id = created["operation_id"]

        # El productor dejó UN evento pendiente para ESTA venta (sin mirar conteos de otras cuentas).
        event_id = await conn.fetchval(
            "SELECT id FROM public.events WHERE account_id = $1 AND event_type = 'SaleOperationCreated' "
            "AND aggregate_id = $2 AND processed_at IS NULL",
            account_id, op_id,
        )
        assert event_id is not None

        outbox = OutboxRepository(conn)
        assert await outbox.run_dispatch(1000) >= 1

        async def _entries() -> list[asyncpg.Record]:
            return await conn.fetch(
                "SELECT id, status, reversal_of FROM public.journal_entries "
                "WHERE account_id = $1 AND source_doc_type = 'SaleOperation' AND source_doc_ref = $2",
                account_id, op_id,
            )

        entries = await _entries()
        assert len(entries) == 1
        entry = entries[0]
        assert entry["status"] == "posted" and entry["reversal_of"] is None
        assert await conn.fetchval("SELECT processed_at IS NOT NULL FROM public.events WHERE id = $1", event_id)

        totals = await conn.fetchrow(
            "SELECT COALESCE(SUM(amount) FILTER (WHERE side = 'debit'), 0) AS debe, "
            "COALESCE(SUM(amount) FILTER (WHERE side = 'credit'), 0) AS haber, count(*) AS n "
            "FROM public.journal_lines WHERE entry_id = $1",
            entry["id"],
        )
        assert totals["n"] >= 2
        assert totals["debe"] == totals["haber"] == Decimal("15000")
        # Venta en efectivo: el debe va a Caja.
        assert await conn.fetchval(
            "SELECT account_code FROM public.journal_lines WHERE entry_id = $1 AND side = 'debit' ORDER BY line_no LIMIT 1",
            entry["id"],
        ) == "1100"

        # Idempotencia: otra corrida del despachador no agrega asientos para este evento.
        await outbox.run_dispatch(1000)
        again = await _entries()
        assert [e["id"] for e in again] == [entry["id"]]
        assert await conn.fetchval(
            "SELECT count(*) FROM public.journal_lines WHERE entry_id = $1", entry["id"]
        ) == totals["n"]
    finally:
        await _cleanup(conn, user_id, account_id)
        await _assert_no_residue(conn, user_id, account_id, branch_ids)
        await conn.close()

