"""
cobranzas-vencimientos OQ-1 — TDD tests for the "edit a charge's due date"
feature: AccountChargeRepository, backend/services/account_charges.py, and
the two PATCH endpoints added to routers/customer_accounts.py and
routers/supplier_accounts.py.

Layers:
  - Repository: verifies the RPC name + positional args via conn.fetchrow mock.
  - Service: verifies require_account_role(conn, auth, ["owner", "admin"]) —
    same pattern as test_cost_center_service.py (D9 v31-authz-token-hook).
  - Router: verifies 200 (owner), 403 (member), 404 (PostgresError P0404
    propagated to the GLOBAL asyncpg_error_handler — account_charges.py has
    no local ERRCODE map, unlike customer_accounts.py/supplier_accounts.py).
"""
from __future__ import annotations

import json
from unittest.mock import AsyncMock, patch

import asyncpg
import pytest
from fastapi import HTTPException

from backend.tests.conftest import make_token

MOVEMENT_ID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
CLIENT_ID = "11111111-1111-1111-1111-111111111111"
SUPPLIER_ID = "22222222-2222-2222-2222-222222222222"

CUSTOMER_RPC_RESULT = {
    "movement_id": MOVEMENT_ID,
    "due_date": "2026-10-15",
    "previous_due_date": "2026-08-06",
}

SUPPLIER_RPC_RESULT = {
    "movement_id": MOVEMENT_ID,
    "due_date": "2026-10-20",
    "previous_due_date": "2026-08-11",
}


def _account_role_token(account_role: str) -> str:
    """v31-authz-token-hook D1: el rol de TENANT viaja en
    `app_metadata.account_role` — mismo criterio que test_cost_center_router.py."""
    return make_token({"app_metadata": {"account_role": account_role}})


# ═══════════════════════════════════════════════════════════════════════════
# Repository
# ═══════════════════════════════════════════════════════════════════════════

class TestAccountChargeRepository:
    @pytest.fixture
    def mock_conn(self):
        conn = AsyncMock()
        conn.fetchrow = AsyncMock(return_value=None)
        return conn

    @pytest.mark.asyncio
    async def test_update_customer_charge_due_date_calls_rpc(self, mock_conn):
        """RED: invoca rpc_update_customer_charge_due_date con los 3 args
        posicionales (movement_id, due_date, reason)."""
        from backend.repositories.account_charge_repository import AccountChargeRepository

        mock_conn.fetchrow.return_value = {"result": json.dumps(CUSTOMER_RPC_RESULT)}
        repo = AccountChargeRepository(mock_conn)

        result = await repo.update_customer_charge_due_date(
            MOVEMENT_ID, "2026-10-15", "corrección de carga"
        )

        call_args = mock_conn.fetchrow.call_args[0]
        assert "rpc_update_customer_charge_due_date" in call_args[0]
        assert call_args[1:] == (MOVEMENT_ID, "2026-10-15", "corrección de carga")
        assert result["movement_id"] == MOVEMENT_ID
        assert result["due_date"] == "2026-10-15"
        assert result["previous_due_date"] == "2026-08-06"

    @pytest.mark.asyncio
    async def test_update_customer_charge_due_date_null_clears(self, mock_conn):
        """due_date=None viaja como NULL — nunca se traduce a un error antes
        de llegar al RPC (D es responsabilidad de la DB, no del repo)."""
        from backend.repositories.account_charge_repository import AccountChargeRepository

        cleared = {**CUSTOMER_RPC_RESULT, "due_date": None}
        mock_conn.fetchrow.return_value = {"result": json.dumps(cleared)}
        repo = AccountChargeRepository(mock_conn)

        result = await repo.update_customer_charge_due_date(MOVEMENT_ID, None, None)

        call_args = mock_conn.fetchrow.call_args[0]
        assert call_args[2] is None
        assert result["due_date"] is None

    @pytest.mark.asyncio
    async def test_update_supplier_charge_due_date_calls_rpc(self, mock_conn):
        """RED: espejo exacto — invoca rpc_update_supplier_charge_due_date."""
        from backend.repositories.account_charge_repository import AccountChargeRepository

        mock_conn.fetchrow.return_value = {"result": json.dumps(SUPPLIER_RPC_RESULT)}
        repo = AccountChargeRepository(mock_conn)

        result = await repo.update_supplier_charge_due_date(
            MOVEMENT_ID, "2026-10-20", "ajuste proveedor"
        )

        call_args = mock_conn.fetchrow.call_args[0]
        assert "rpc_update_supplier_charge_due_date" in call_args[0]
        assert call_args[1:] == (MOVEMENT_ID, "2026-10-20", "ajuste proveedor")
        assert result["due_date"] == "2026-10-20"


# ═══════════════════════════════════════════════════════════════════════════
# Service — guard require_account_role(conn, auth, ["owner", "admin"])
# ═══════════════════════════════════════════════════════════════════════════

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


class TestAccountChargeServiceCustomer:
    @pytest.mark.asyncio
    async def test_member_raises_403(self):
        """RED: member (account_role) no puede cambiar el vencimiento."""
        from backend.services.account_charges import update_customer_charge_due_date

        repo = AsyncMock()
        auth = _make_auth("member")

        with pytest.raises(HTTPException) as exc_info:
            await update_customer_charge_due_date(
                repo, auth,
                movement_id=MOVEMENT_ID, due_date=None, reason=None,
                conn=_make_conn(),
            )

        assert exc_info.value.status_code == 403
        repo.update_customer_charge_due_date.assert_not_called()

    @pytest.mark.asyncio
    async def test_owner_ok(self):
        """GREEN: owner puede cambiar el vencimiento."""
        from backend.services.account_charges import update_customer_charge_due_date

        repo = AsyncMock()
        repo.update_customer_charge_due_date = AsyncMock(return_value=CUSTOMER_RPC_RESULT)
        auth = _make_auth("owner")

        result = await update_customer_charge_due_date(
            repo, auth,
            movement_id=MOVEMENT_ID, due_date="2026-10-15", reason="motivo",
            conn=_make_conn(),
        )

        assert result["movement_id"] == MOVEMENT_ID
        repo.update_customer_charge_due_date.assert_awaited_once_with(
            MOVEMENT_ID, "2026-10-15", "motivo"
        )

    @pytest.mark.asyncio
    async def test_admin_ok(self):
        """TRIANGULATE: admin (segundo rol permitido) también puede."""
        from backend.services.account_charges import update_customer_charge_due_date

        repo = AsyncMock()
        repo.update_customer_charge_due_date = AsyncMock(return_value=CUSTOMER_RPC_RESULT)
        auth = _make_auth("admin")

        result = await update_customer_charge_due_date(
            repo, auth,
            movement_id=MOVEMENT_ID, due_date="2026-10-15", reason=None,
            conn=_make_conn(),
        )

        assert result is not None

    @pytest.mark.asyncio
    async def test_claim_absent_falls_back_to_db_owner_succeeds(self):
        """TRIANGULATE (D6): claim account_role ausente (token viejo) +
        membresía owner resuelta en la DB → éxito igual."""
        from backend.services.account_charges import update_customer_charge_due_date

        repo = AsyncMock()
        repo.update_customer_charge_due_date = AsyncMock(return_value=CUSTOMER_RPC_RESULT)
        auth = _make_auth(None)
        conn = _make_conn(fallback_role=["owner"])

        result = await update_customer_charge_due_date(
            repo, auth,
            movement_id=MOVEMENT_ID, due_date=None, reason=None,
            conn=conn,
        )

        assert result is not None
        conn.fetchval.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_postgres_error_propagates_unwrapped(self):
        """El service NO envuelve asyncpg.PostgresError — se deja propagar
        para que el asyncpg_error_handler GLOBAL lo traduzca a RFC 7807
        (mismo criterio que cost_centers.py: no hay _pg_to_http local acá)."""
        from backend.services.account_charges import update_customer_charge_due_date

        err = asyncpg.PostgresError()
        err.sqlstate = "P0404"
        repo = AsyncMock()
        repo.update_customer_charge_due_date = AsyncMock(side_effect=err)
        auth = _make_auth("owner")

        with pytest.raises(asyncpg.PostgresError) as exc_info:
            await update_customer_charge_due_date(
                repo, auth,
                movement_id=MOVEMENT_ID, due_date=None, reason=None,
                conn=_make_conn(),
            )

        assert exc_info.value.sqlstate == "P0404"


class TestAccountChargeServiceSupplier:
    @pytest.mark.asyncio
    async def test_member_raises_403(self):
        """RED: espejo exacto del lado cliente."""
        from backend.services.account_charges import update_supplier_charge_due_date

        repo = AsyncMock()
        auth = _make_auth("member")

        with pytest.raises(HTTPException) as exc_info:
            await update_supplier_charge_due_date(
                repo, auth,
                movement_id=MOVEMENT_ID, due_date=None, reason=None,
                conn=_make_conn(),
            )

        assert exc_info.value.status_code == 403
        repo.update_supplier_charge_due_date.assert_not_called()

    @pytest.mark.asyncio
    async def test_owner_ok(self):
        """GREEN: owner puede cambiar el vencimiento de un cargo de proveedor."""
        from backend.services.account_charges import update_supplier_charge_due_date

        repo = AsyncMock()
        repo.update_supplier_charge_due_date = AsyncMock(return_value=SUPPLIER_RPC_RESULT)
        auth = _make_auth("owner")

        result = await update_supplier_charge_due_date(
            repo, auth,
            movement_id=MOVEMENT_ID, due_date="2026-10-20", reason="motivo",
            conn=_make_conn(),
        )

        assert result["due_date"] == "2026-10-20"
        repo.update_supplier_charge_due_date.assert_awaited_once_with(
            MOVEMENT_ID, "2026-10-20", "motivo"
        )


# ═══════════════════════════════════════════════════════════════════════════
# Router — PATCH .../movements/{movement_id}/due-date
# ═══════════════════════════════════════════════════════════════════════════

class TestCustomerChargeDueDateEndpoint:
    @pytest.mark.asyncio
    async def test_patch_owner_ok(self, async_client, mock_pool):
        """GREEN: owner → 200 con el jsonb de la RPC."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value={"result": json.dumps(CUSTOMER_RPC_RESULT)})
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/customer-accounts/{CLIENT_ID}/movements/{MOVEMENT_ID}/due-date",
                json={"due_date": "2026-10-15", "reason": "corrección"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        body = resp.json()
        assert body["movement_id"] == MOVEMENT_ID
        assert body["due_date"] == "2026-10-15"

    @pytest.mark.asyncio
    async def test_patch_member_returns_403(self, async_client, mock_pool):
        """RED: member (account_role) → 403, sin tocar la DB de negocio."""
        pool, conn = mock_pool
        member_token = _account_role_token("member")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/customer-accounts/{CLIENT_ID}/movements/{MOVEMENT_ID}/due-date",
                json={"due_date": "2026-10-15"},
                headers={"Authorization": f"Bearer {member_token}"},
            )

        assert resp.status_code == 403

    @pytest.mark.asyncio
    async def test_patch_not_found_returns_404(self, async_client, mock_pool):
        """El P0404 del RPC (cargo de otra cuenta / inexistente) llega al
        cliente como 404 vía el asyncpg_error_handler GLOBAL."""
        pool, conn = mock_pool
        err = asyncpg.PostgresError(f"charge_not_found: {MOVEMENT_ID}")
        err.sqlstate = "P0404"
        conn.fetchrow = AsyncMock(side_effect=err)
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/customer-accounts/{CLIENT_ID}/movements/{MOVEMENT_ID}/due-date",
                json={"due_date": "2026-10-15"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 404

    @pytest.mark.asyncio
    async def test_patch_charge_already_settled_returns_400(self, async_client, mock_pool):
        """El P0400 del RPC (cargo saldado / no-cargo) llega como 400."""
        pool, conn = mock_pool
        err = asyncpg.PostgresError("charge_fully_settled: el cargo no tiene saldo abierto")
        err.sqlstate = "P0400"
        conn.fetchrow = AsyncMock(side_effect=err)
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/customer-accounts/{CLIENT_ID}/movements/{MOVEMENT_ID}/due-date",
                json={"due_date": "2026-10-15"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 400

    @pytest.mark.asyncio
    async def test_patch_reason_over_200_chars_returns_422(self, async_client, mock_pool):
        """Pydantic (ChargeDueDateIn._reason_max_len) rechaza ANTES de tocar
        la DB — 422 sin llamar al RPC."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value={"result": json.dumps(CUSTOMER_RPC_RESULT)})
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/customer-accounts/{CLIENT_ID}/movements/{MOVEMENT_ID}/due-date",
                json={"due_date": "2026-10-15", "reason": "x" * 201},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 422
        conn.fetchrow.assert_not_called()

    @pytest.mark.asyncio
    async def test_patch_null_due_date_clears(self, async_client, mock_pool):
        """due_date=null en el body limpia el vencimiento — no es un error."""
        pool, conn = mock_pool
        cleared = {**CUSTOMER_RPC_RESULT, "due_date": None}
        conn.fetchrow = AsyncMock(return_value={"result": json.dumps(cleared)})
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/customer-accounts/{CLIENT_ID}/movements/{MOVEMENT_ID}/due-date",
                json={"due_date": None},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        assert resp.json()["due_date"] is None


class TestSupplierChargeDueDateEndpoint:
    @pytest.mark.asyncio
    async def test_patch_owner_ok(self, async_client, mock_pool):
        """GREEN: espejo exacto del lado cliente."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value={"result": json.dumps(SUPPLIER_RPC_RESULT)})
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/supplier-accounts/{SUPPLIER_ID}/movements/{MOVEMENT_ID}/due-date",
                json={"due_date": "2026-10-20", "reason": "ajuste"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        assert resp.json()["due_date"] == "2026-10-20"

    @pytest.mark.asyncio
    async def test_patch_member_returns_403(self, async_client, mock_pool):
        pool, conn = mock_pool
        member_token = _account_role_token("member")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/supplier-accounts/{SUPPLIER_ID}/movements/{MOVEMENT_ID}/due-date",
                json={"due_date": "2026-10-20"},
                headers={"Authorization": f"Bearer {member_token}"},
            )

        assert resp.status_code == 403

    @pytest.mark.asyncio
    async def test_patch_not_found_returns_404(self, async_client, mock_pool):
        pool, conn = mock_pool
        err = asyncpg.PostgresError(f"charge_not_found: {MOVEMENT_ID}")
        err.sqlstate = "P0404"
        conn.fetchrow = AsyncMock(side_effect=err)
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/supplier-accounts/{SUPPLIER_ID}/movements/{MOVEMENT_ID}/due-date",
                json={"due_date": "2026-10-20"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 404
