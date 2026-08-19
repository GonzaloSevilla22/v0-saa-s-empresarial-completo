"""
metodos-pago-operaciones — PaymentMethodService TDD tests (task 4.1-4.2).

Espejo de test_cost_center_service.py: gatea create/update/deactivate contra
require_account_role (TENANT: owner/admin); list es abierto a cualquier
miembro. Repository is mocked — no DB interaction on the happy path (claim
presente).
"""
from __future__ import annotations

from unittest.mock import AsyncMock

import pytest
from fastapi import HTTPException

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
PM_ID = "cccccccc-cccc-cccc-cccc-cccccccccccc"

PM_ROW = {
    "id": PM_ID,
    "account_id": ACCOUNT_ID,
    "name": "Efectivo",
    "kind": "cash",
    "is_active": True,
    "sort_order": 1,
    "created_at": "2026-08-19T10:00:00+00:00",
}


def _make_auth(account_role: str | None) -> dict:
    return {
        "user_id": "11111111-1111-1111-1111-111111111111",
        "role": "user",
        "account_role": account_role,
        "plan": "pro",
    }


def _make_conn(fallback_role: object = "__unset__") -> AsyncMock:
    conn = AsyncMock()
    if fallback_role != "__unset__":
        conn.fetchval = AsyncMock(return_value=fallback_role)
    return conn


_SENTINEL = object()


def _make_repo(
    *,
    list_result=_SENTINEL,
    create_result=_SENTINEL,
    update_result=_SENTINEL,
    deactivate_result=_SENTINEL,
    report_result=_SENTINEL,
):
    repo = AsyncMock()
    repo.list_by_account = AsyncMock(return_value=[PM_ROW] if list_result is _SENTINEL else list_result)
    repo.create = AsyncMock(return_value=PM_ROW if create_result is _SENTINEL else create_result)
    repo.update = AsyncMock(return_value=PM_ROW if update_result is _SENTINEL else update_result)
    repo.deactivate = AsyncMock(
        return_value={**PM_ROW, "is_active": False} if deactivate_result is _SENTINEL else deactivate_result
    )
    repo.get_report = AsyncMock(return_value=[] if report_result is _SENTINEL else report_result)
    return repo


# ── 4.1 RED: list is permitted to any member ──────────────────────────────────

class TestPaymentMethodServiceList:
    @pytest.mark.asyncio
    async def test_list_permitted_for_member(self):
        from backend.services.payment_methods import list_payment_methods

        repo = _make_repo()
        auth = _make_auth("member")

        result = await list_payment_methods(repo, auth, ACCOUNT_ID, active_only=True)

        assert isinstance(result, list)
        repo.list_by_account.assert_awaited_once_with(ACCOUNT_ID, active_only=True)


# ── 4.1 RED: create requires account_role owner/admin ───────────────────────

class TestPaymentMethodServiceCreate:
    @pytest.mark.asyncio
    async def test_create_member_raises_403(self):
        from backend.services.payment_methods import create_payment_method

        repo = _make_repo()
        auth = _make_auth("member")

        with pytest.raises(HTTPException) as exc_info:
            await create_payment_method(
                repo, auth, ACCOUNT_ID, name="Mercado Pago", kind="wallet", sort_order=0, conn=_make_conn()
            )

        assert exc_info.value.status_code == 403

    @pytest.mark.asyncio
    async def test_create_owner_ok(self):
        from backend.services.payment_methods import create_payment_method

        repo = _make_repo(create_result=PM_ROW)
        auth = _make_auth("owner")

        result = await create_payment_method(
            repo, auth, ACCOUNT_ID, name="Efectivo", kind="cash", sort_order=1, conn=_make_conn()
        )

        assert result["kind"] == "cash"
        repo.create.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_create_admin_ok(self):
        from backend.services.payment_methods import create_payment_method

        repo = _make_repo(create_result=PM_ROW)
        auth = _make_auth("admin")

        result = await create_payment_method(
            repo, auth, ACCOUNT_ID, name="Efectivo", kind="cash", sort_order=0, conn=_make_conn()
        )

        assert result is not None

    @pytest.mark.asyncio
    async def test_create_normalizes_name_trim(self):
        from backend.services.payment_methods import create_payment_method

        repo = _make_repo(create_result={**PM_ROW, "name": "Efectivo"})
        auth = _make_auth("owner")

        await create_payment_method(
            repo, auth, ACCOUNT_ID, name="  Efectivo  ", kind="cash", sort_order=0, conn=_make_conn()
        )

        call_kwargs = repo.create.call_args
        name_arg = call_kwargs[1].get("name") or call_kwargs[0][1]
        assert name_arg == "Efectivo"

    @pytest.mark.asyncio
    async def test_create_invalid_kind_raises_422(self):
        """RED: kind fuera del vocabulario cerrado (D2) — defensa en profundidad,
        el CHECK de la DB también lo rechaza."""
        from backend.services.payment_methods import create_payment_method

        repo = _make_repo()
        auth = _make_auth("owner")

        with pytest.raises(HTTPException) as exc_info:
            await create_payment_method(
                repo, auth, ACCOUNT_ID, name="Cripto", kind="crypto", sort_order=0, conn=_make_conn()
            )

        assert exc_info.value.status_code == 422
        repo.create.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_create_claim_present_never_touches_conn(self):
        from backend.services.payment_methods import create_payment_method

        repo = _make_repo(create_result=PM_ROW)
        auth = _make_auth("owner")
        conn = _make_conn()

        await create_payment_method(
            repo, auth, ACCOUNT_ID, name="Efectivo", kind="cash", sort_order=0, conn=conn
        )

        conn.fetchval.assert_not_awaited()


# ── 4.1 RED: update requires account_role owner/admin ───────────────────────

class TestPaymentMethodServiceUpdate:
    @pytest.mark.asyncio
    async def test_update_member_raises_403(self):
        from backend.services.payment_methods import update_payment_method

        repo = _make_repo()
        auth = _make_auth("member")

        with pytest.raises(HTTPException) as exc_info:
            await update_payment_method(
                repo, auth, ACCOUNT_ID, PM_ID, name="X", sort_order=None, conn=_make_conn()
            )

        assert exc_info.value.status_code == 403

    @pytest.mark.asyncio
    async def test_update_owner_ok(self):
        from backend.services.payment_methods import update_payment_method

        repo = _make_repo(update_result={**PM_ROW, "name": "Banco Nación"})
        auth = _make_auth("owner")

        result = await update_payment_method(
            repo, auth, ACCOUNT_ID, PM_ID, name="Banco Nación", sort_order=None, conn=_make_conn()
        )

        assert result["name"] == "Banco Nación"

    @pytest.mark.asyncio
    async def test_update_not_found_raises_404(self):
        from backend.services.payment_methods import update_payment_method

        repo = _make_repo(update_result=None)
        auth = _make_auth("owner")

        with pytest.raises(HTTPException) as exc_info:
            await update_payment_method(
                repo, auth, ACCOUNT_ID, "nonexistent", name="X", sort_order=None, conn=_make_conn()
            )

        assert exc_info.value.status_code == 404


# ── 4.1 RED: deactivate requires account_role owner/admin ───────────────────

class TestPaymentMethodServiceDeactivate:
    @pytest.mark.asyncio
    async def test_deactivate_member_raises_403(self):
        from backend.services.payment_methods import deactivate_payment_method

        repo = _make_repo()
        auth = _make_auth("member")

        with pytest.raises(HTTPException) as exc_info:
            await deactivate_payment_method(repo, auth, ACCOUNT_ID, PM_ID, conn=_make_conn())

        assert exc_info.value.status_code == 403

    @pytest.mark.asyncio
    async def test_deactivate_owner_ok(self):
        from backend.services.payment_methods import deactivate_payment_method

        repo = _make_repo(deactivate_result={**PM_ROW, "is_active": False})
        auth = _make_auth("owner")

        result = await deactivate_payment_method(repo, auth, ACCOUNT_ID, PM_ID, conn=_make_conn())

        assert result["is_active"] is False

    @pytest.mark.asyncio
    async def test_deactivate_not_found_raises_404(self):
        from backend.services.payment_methods import deactivate_payment_method

        repo = _make_repo(deactivate_result=None)
        auth = _make_auth("admin")

        with pytest.raises(HTTPException) as exc_info:
            await deactivate_payment_method(repo, auth, ACCOUNT_ID, "nonexistent", conn=_make_conn())

        assert exc_info.value.status_code == 404


# ── 4.6 RED: report is permitted to any member (no plan gate, D10) ─────────

class TestPaymentMethodServiceReport:
    @pytest.mark.asyncio
    async def test_report_permitted_for_member(self):
        from backend.services.payment_methods import get_payment_method_report
        import datetime

        repo = _make_repo(report_result=[{"payment_method_id": None, "total_sold": 100}])
        auth = _make_auth("member")

        result = await get_payment_method_report(
            repo, auth, ACCOUNT_ID, datetime.date(2026, 8, 1), datetime.date(2026, 8, 19)
        )

        assert isinstance(result, list)
        repo.get_report.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_report_invalid_range_raises_422(self):
        from backend.services.payment_methods import get_payment_method_report
        import datetime

        repo = _make_repo()
        auth = _make_auth("member")

        with pytest.raises(HTTPException) as exc_info:
            await get_payment_method_report(
                repo, auth, ACCOUNT_ID, datetime.date(2026, 8, 19), datetime.date(2026, 8, 1)
            )

        assert exc_info.value.status_code == 422
        repo.get_report.assert_not_awaited()


# ── 4.3 TRIANGULATE ──────────────────────────────────────────────────────────

class TestPaymentMethodServiceTriangulate:
    @pytest.mark.asyncio
    async def test_member_list_ok_but_member_create_forbidden(self):
        from backend.services.payment_methods import create_payment_method, list_payment_methods

        repo = _make_repo()
        member = _make_auth("member")

        result = await list_payment_methods(repo, member, ACCOUNT_ID, active_only=True)
        assert isinstance(result, list)

        with pytest.raises(HTTPException) as exc_info:
            await create_payment_method(
                repo, member, ACCOUNT_ID, name="Test", kind="other", sort_order=0, conn=_make_conn()
            )
        assert exc_info.value.status_code == 403

    @pytest.mark.asyncio
    async def test_admin_deactivate_sets_is_active_false(self):
        from backend.services.payment_methods import deactivate_payment_method

        repo = _make_repo(deactivate_result={**PM_ROW, "is_active": False})
        auth = _make_auth("admin")

        result = await deactivate_payment_method(repo, auth, ACCOUNT_ID, PM_ID, conn=_make_conn())

        assert result["is_active"] is False
        repo.deactivate.assert_awaited_once_with(PM_ID, ACCOUNT_ID)

    @pytest.mark.asyncio
    async def test_create_claim_absent_falls_back_to_db_owner_succeeds(self):
        from backend.services.payment_methods import create_payment_method

        repo = _make_repo(create_result=PM_ROW)
        auth = _make_auth(None)
        conn = _make_conn(fallback_role="owner")

        result = await create_payment_method(
            repo, auth, ACCOUNT_ID, name="Efectivo", kind="cash", sort_order=0, conn=conn
        )

        assert result["kind"] == "cash"
        conn.fetchval.assert_awaited_once()
