"""
metodos-pago-operaciones — PaymentMethodRepository TDD tests (task 4.1-4.2).

Tests cover PaymentMethodRepository methods via asyncpg mock. Espejo de
test_cost_center_repository.py. No real DB is touched — all SQL is verified
through call_args.
"""
from __future__ import annotations

from unittest.mock import AsyncMock

import pytest

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
PM_ID = "cccccccc-cccc-cccc-cccc-cccccccccccc"

PM_ROW_ACTIVE = {
    "id": PM_ID,
    "account_id": ACCOUNT_ID,
    "name": "Efectivo",
    "kind": "cash",
    "is_active": True,
    "sort_order": 1,
    "created_at": "2026-08-19T10:00:00+00:00",
}

PM_ROW_INACTIVE = {
    "id": "dddddddd-dddd-dddd-dddd-dddddddddddd",
    "account_id": ACCOUNT_ID,
    "name": "Cheque",
    "kind": "check",
    "is_active": False,
    "sort_order": 7,
    "created_at": "2026-08-01T08:00:00+00:00",
}


@pytest.fixture
def payment_method_repo():
    from backend.repositories.payment_method_repository import PaymentMethodRepository

    conn = AsyncMock()
    return PaymentMethodRepository(conn), conn


# ── 4.1 RED: list_by_account ──────────────────────────────────────────────────

class TestPaymentMethodRepositoryList:
    @pytest.mark.asyncio
    async def test_list_active_only_by_default(self, payment_method_repo):
        repo, conn = payment_method_repo
        conn.fetch = AsyncMock(return_value=[PM_ROW_ACTIVE])

        result = await repo.list_by_account(ACCOUNT_ID, active_only=True)

        assert len(result) == 1
        sql = conn.fetch.call_args[0][0].lower()
        assert "is_active" in sql
        assert "deleted_at is null" in sql
        assert result[0]["name"] == "Efectivo"

    @pytest.mark.asyncio
    async def test_list_all_when_active_only_false(self, payment_method_repo):
        repo, conn = payment_method_repo
        conn.fetch = AsyncMock(return_value=[PM_ROW_ACTIVE, PM_ROW_INACTIVE])

        result = await repo.list_by_account(ACCOUNT_ID, active_only=False)

        assert len(result) == 2
        assert ACCOUNT_ID in conn.fetch.call_args[0]

    @pytest.mark.asyncio
    async def test_list_orders_by_sort_order_then_name(self, payment_method_repo):
        """D1: el orden del selector de uso diario importa — ORDER BY sort_order."""
        repo, conn = payment_method_repo
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_by_account(ACCOUNT_ID, active_only=True)

        sql = conn.fetch.call_args[0][0]
        assert "ORDER BY sort_order" in sql

    @pytest.mark.asyncio
    async def test_list_empty_when_no_methods(self, payment_method_repo):
        repo, conn = payment_method_repo
        conn.fetch = AsyncMock(return_value=[])

        result = await repo.list_by_account(ACCOUNT_ID, active_only=True)

        assert result == []


# ── 4.1 RED: create ────────────────────────────────────────────────────────────

class TestPaymentMethodRepositoryCreate:
    @pytest.mark.asyncio
    async def test_create_returns_new_row(self, payment_method_repo):
        repo, conn = payment_method_repo
        conn.fetchrow = AsyncMock(return_value=PM_ROW_ACTIVE)

        result = await repo.create(ACCOUNT_ID, name="Efectivo", kind="cash")

        assert result is not None
        assert result["kind"] == "cash"
        sql = conn.fetchrow.call_args[0][0].upper()
        assert "INSERT" in sql
        assert "RETURNING" in sql

    @pytest.mark.asyncio
    async def test_create_passes_sort_order(self, payment_method_repo):
        repo, conn = payment_method_repo
        conn.fetchrow = AsyncMock(return_value=PM_ROW_ACTIVE)

        await repo.create(ACCOUNT_ID, name="Efectivo", kind="cash", sort_order=3)

        args = conn.fetchrow.call_args[0]
        assert 3 in args

    @pytest.mark.asyncio
    async def test_create_default_sort_order_is_zero(self, payment_method_repo):
        repo, conn = payment_method_repo
        conn.fetchrow = AsyncMock(return_value=PM_ROW_ACTIVE)

        await repo.create(ACCOUNT_ID, name="Efectivo", kind="cash")

        args = conn.fetchrow.call_args[0]
        assert 0 in args


# ── 4.1 RED: update ────────────────────────────────────────────────────────────

class TestPaymentMethodRepositoryUpdate:
    @pytest.mark.asyncio
    async def test_update_name_returns_row(self, payment_method_repo):
        repo, conn = payment_method_repo
        updated = {**PM_ROW_ACTIVE, "name": "Banco Nación"}
        conn.fetchrow = AsyncMock(return_value=updated)

        result = await repo.update(PM_ID, ACCOUNT_ID, name="Banco Nación", sort_order=None)

        assert result is not None
        sql = conn.fetchrow.call_args[0][0].upper()
        assert "UPDATE" in sql
        assert "RETURNING" in sql

    @pytest.mark.asyncio
    async def test_update_does_not_touch_kind(self, payment_method_repo):
        """D2: kind es inmutable — renombrar no cambia la semántica."""
        repo, conn = payment_method_repo
        conn.fetchrow = AsyncMock(return_value=PM_ROW_ACTIVE)

        await repo.update(PM_ID, ACCOUNT_ID, name="Banco Nación", sort_order=None)

        sql = conn.fetchrow.call_args[0][0]
        assert "kind = " not in sql

    @pytest.mark.asyncio
    async def test_update_not_found_returns_none(self, payment_method_repo):
        repo, conn = payment_method_repo
        conn.fetchrow = AsyncMock(return_value=None)

        result = await repo.update("nonexistent-id", ACCOUNT_ID, name="X", sort_order=None)

        assert result is None

    # ── pos-banco-movimientos (D7, task 8.1/8.6) ────────────────────────────

    @pytest.mark.asyncio
    async def test_update_without_bank_account_provided_omits_column(self, payment_method_repo):
        """bank_account_provided=False (default) — el UPDATE liso, sin tocar
        la columna bank_account_id (sigue en el RETURNING, que expone el
        estado vigente sea cual sea, pero no en el SET — nada la escribe)."""
        repo, conn = payment_method_repo
        conn.fetchrow = AsyncMock(return_value=PM_ROW_ACTIVE)

        await repo.update(PM_ID, ACCOUNT_ID, name="Efectivo", sort_order=None)

        sql = conn.fetchrow.call_args[0][0]
        assert "bank_account_id  =" not in sql and "bank_account_id =" not in sql

    @pytest.mark.asyncio
    async def test_update_with_bank_account_provided_sets_column(self, payment_method_repo):
        BANK_ACCOUNT_ID = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
        repo, conn = payment_method_repo
        conn.fetchrow = AsyncMock(return_value={**PM_ROW_ACTIVE, "bank_account_id": BANK_ACCOUNT_ID})

        await repo.update(
            PM_ID, ACCOUNT_ID, name="Transferencia", sort_order=None,
            bank_account_id=BANK_ACCOUNT_ID, bank_account_provided=True,
        )

        sql = conn.fetchrow.call_args[0][0]
        args = conn.fetchrow.call_args[0]
        assert "bank_account_id" in sql
        assert BANK_ACCOUNT_ID in args

    @pytest.mark.asyncio
    async def test_update_bank_account_provided_null_unassigns(self, payment_method_repo):
        """provided=True + bank_account_id=None → desasigna explícitamente
        (distinto de no informar el campo)."""
        repo, conn = payment_method_repo
        conn.fetchrow = AsyncMock(return_value={**PM_ROW_ACTIVE, "bank_account_id": None})

        await repo.update(
            PM_ID, ACCOUNT_ID, name="Transferencia", sort_order=None,
            bank_account_id=None, bank_account_provided=True,
        )

        sql = conn.fetchrow.call_args[0][0]
        args = conn.fetchrow.call_args[0]
        assert "bank_account_id" in sql
        assert None in args


class TestPaymentMethodRepositoryBankAccountValidation:
    @pytest.mark.asyncio
    async def test_get_bank_account_for_validation_scopes_active_not_deleted(self, payment_method_repo):
        repo, conn = payment_method_repo
        conn.fetchrow = AsyncMock(return_value={"id": "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"})

        result = await repo.get_bank_account_for_validation(
            "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee", ACCOUNT_ID
        )

        assert result is not None
        sql = conn.fetchrow.call_args[0][0].lower()
        assert "is_active = true" in sql
        assert "deleted_at is null" in sql

    @pytest.mark.asyncio
    async def test_get_bank_account_for_validation_not_found_returns_none(self, payment_method_repo):
        repo, conn = payment_method_repo
        conn.fetchrow = AsyncMock(return_value=None)

        result = await repo.get_bank_account_for_validation("nonexistent", ACCOUNT_ID)

        assert result is None


# ── 4.1 RED: deactivate ────────────────────────────────────────────────────────

class TestPaymentMethodRepositoryDeactivate:
    @pytest.mark.asyncio
    async def test_deactivate_sets_is_active_false(self, payment_method_repo):
        repo, conn = payment_method_repo
        deactivated = {**PM_ROW_ACTIVE, "is_active": False}
        conn.fetchrow = AsyncMock(return_value=deactivated)

        result = await repo.deactivate(PM_ID, ACCOUNT_ID)

        assert result is not None
        assert result["is_active"] is False
        sql = conn.fetchrow.call_args[0][0]
        assert "is_active = FALSE" in sql
        assert "DELETE FROM" not in sql.upper()

    @pytest.mark.asyncio
    async def test_deactivate_returns_none_if_not_found(self, payment_method_repo):
        repo, conn = payment_method_repo
        conn.fetchrow = AsyncMock(return_value=None)

        result = await repo.deactivate("nonexistent", ACCOUNT_ID)

        assert result is None


# ── 4.6 RED: get_report ────────────────────────────────────────────────────────

class TestPaymentMethodRepositoryReport:
    @pytest.mark.asyncio
    async def test_get_report_calls_rpc(self, payment_method_repo):
        repo, conn = payment_method_repo
        conn.fetch = AsyncMock(return_value=[])
        import datetime

        await repo.get_report(ACCOUNT_ID, datetime.date(2026, 8, 1), datetime.date(2026, 8, 19))

        sql = conn.fetch.call_args[0][0]
        assert "rpc_payment_method_report" in sql
        assert ACCOUNT_ID in conn.fetch.call_args[0]
