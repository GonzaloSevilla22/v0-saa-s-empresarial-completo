"""
metodos-pago-operaciones — Router TDD tests (task 4.1-4.2).

Espejo de test_cost_center_router.py. Tests cover HTTP endpoints for
/payment-methods CRUD + GET /reports/payment-methods via async_client.
Service/repository layers are mocked via asyncpg connection mock.
"""
from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import make_token

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

PM_ROW_DEACTIVATED = {**PM_ROW, "is_active": False}


def _account_role_token(account_role: str) -> str:
    return make_token({"app_metadata": {"account_role": account_role}})


# ── 4.1 RED: GET /payment-methods ────────────────────────────────────────────

class TestPaymentMethodListEndpoint:
    @pytest.mark.asyncio
    async def test_get_list_ok_for_member(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[PM_ROW])
        member_token = _account_role_token("member")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/payment-methods",
                headers={"Authorization": f"Bearer {member_token}"},
            )

        assert resp.status_code == 200
        data = resp.json()
        assert isinstance(data, list)
        assert data[0]["name"] == "Efectivo"
        assert data[0]["kind"] == "cash"

    @pytest.mark.asyncio
    async def test_get_list_all_with_include_inactive(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[PM_ROW, PM_ROW_DEACTIVATED])
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/payment-methods?include_inactive=true",
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        assert len(resp.json()) == 2

    @pytest.mark.asyncio
    async def test_get_list_unauthenticated_returns_401(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/payment-methods")

        assert resp.status_code == 401


# ── 4.1 RED: POST /payment-methods gatea contra account_role (tenant) ──────

class TestPaymentMethodCreateEndpoint:
    @pytest.mark.asyncio
    async def test_create_owner_returns_201(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=PM_ROW)
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/payment-methods",
                json={"name": "Efectivo", "kind": "cash"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 201
        data = resp.json()
        assert data["name"] == "Efectivo"
        assert data["is_active"] is True

    @pytest.mark.asyncio
    async def test_create_admin_returns_201(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=PM_ROW)
        admin_token = _account_role_token("admin")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/payment-methods",
                json={"name": "Efectivo", "kind": "cash"},
                headers={"Authorization": f"Bearer {admin_token}"},
            )

        assert resp.status_code == 201

    @pytest.mark.asyncio
    async def test_create_member_returns_403(self, async_client, mock_pool):
        pool, conn = mock_pool
        member_token = _account_role_token("member")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/payment-methods",
                json={"name": "Test", "kind": "other"},
                headers={"Authorization": f"Bearer {member_token}"},
            )

        assert resp.status_code == 403

    @pytest.mark.asyncio
    async def test_create_invalid_payload_returns_422(self, async_client, mock_pool):
        """Falta 'kind' (requerido) → 422."""
        pool, conn = mock_pool
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/payment-methods",
                json={"name": "Efectivo"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 422

    @pytest.mark.asyncio
    async def test_create_invalid_kind_returns_422(self, async_client, mock_pool):
        """kind fuera del vocabulario cerrado (D2) → 422, sin tocar la base."""
        pool, conn = mock_pool
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/payment-methods",
                json={"name": "Cripto", "kind": "crypto"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 422
        conn.fetchrow.assert_not_awaited()


# ── 4.1 RED: PATCH /payment-methods/{id} gatea contra account_role ─────────

class TestPaymentMethodUpdateEndpoint:
    @pytest.mark.asyncio
    async def test_patch_owner_ok(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value={**PM_ROW, "name": "Banco Nación"})
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/payment-methods/{PM_ID}",
                json={"name": "Banco Nación"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        assert resp.json()["name"] == "Banco Nación"

    @pytest.mark.asyncio
    async def test_patch_member_returns_403(self, async_client, mock_pool):
        pool, conn = mock_pool
        member_token = _account_role_token("member")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/payment-methods/{PM_ID}",
                json={"name": "X"},
                headers={"Authorization": f"Bearer {member_token}"},
            )

        assert resp.status_code == 403

    @pytest.mark.asyncio
    async def test_patch_does_not_accept_kind(self, async_client, mock_pool):
        """D2: kind es inmutable — un kind en el body se ignora (Pydantic
        extra field ignorado por default), el nombre igual se actualiza."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value={**PM_ROW, "name": "Banco Nación"})
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/payment-methods/{PM_ID}",
                json={"name": "Banco Nación", "kind": "transfer"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        assert resp.json()["kind"] == "cash"  # el kind sembrado NO cambió


# ── pos-banco-movimientos (D7, task 8.1/8.6): PATCH bank_account_id ────────

class TestPaymentMethodUpdateBankAccountEndpoint:
    @pytest.mark.asyncio
    async def test_patch_assigns_bank_account_ok(self, async_client, mock_pool):
        pool, conn = mock_pool
        pm_transfer = {**PM_ROW, "kind": "transfer"}
        bank_account_id = "dddddddd-dddd-dddd-dddd-dddddddddddd"
        # Orden real de llamadas en el service: get_by_id (kind) →
        # get_bank_account_for_validation (pertenencia/activa) → update.
        conn.fetchrow = AsyncMock(side_effect=[
            pm_transfer,
            {"id": bank_account_id},
            {**pm_transfer, "bank_account_id": bank_account_id},
        ])
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/payment-methods/{PM_ID}",
                json={"name": "Transferencia bancaria", "bank_account_id": bank_account_id},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        assert resp.json()["bank_account_id"] == bank_account_id

    @pytest.mark.asyncio
    async def test_patch_without_bank_account_field_preserves_it(self, async_client, mock_pool):
        """Ausencia de la clave en el JSON = tri-estado 'preservar' — un
        único fetchrow (el UPDATE liso), sin tocar la validación bancaria."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value={**PM_ROW, "name": "Banco Nación"})
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/payment-methods/{PM_ID}",
                json={"name": "Banco Nación"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        conn.fetchrow.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_patch_bank_account_on_cash_kind_returns_422(self, async_client, mock_pool):
        pool, conn = mock_pool
        bank_account_id = "dddddddd-dddd-dddd-dddd-dddddddddddd"
        conn.fetchrow = AsyncMock(return_value=PM_ROW)  # kind='cash'
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/payment-methods/{PM_ID}",
                json={"name": "Efectivo", "bank_account_id": bank_account_id},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 422


# ── 4.1 RED: PATCH /payment-methods/{id}/deactivate ─────────────────────────

class TestPaymentMethodDeactivateEndpoint:
    @pytest.mark.asyncio
    async def test_deactivate_owner_ok(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=PM_ROW_DEACTIVATED)
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/payment-methods/{PM_ID}/deactivate",
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        assert resp.json()["is_active"] is False

    @pytest.mark.asyncio
    async def test_deactivate_member_returns_403(self, async_client, mock_pool):
        pool, conn = mock_pool
        member_token = _account_role_token("member")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/payment-methods/{PM_ID}/deactivate",
                headers={"Authorization": f"Bearer {member_token}"},
            )

        assert resp.status_code == 403


# ── 4.6 RED: GET /reports/payment-methods ────────────────────────────────────

class TestPaymentMethodReportEndpoint:
    @pytest.mark.asyncio
    async def test_report_ok_for_member(self, async_client, mock_pool):
        """Sin gate de plan (D10): cualquier miembro puede leer el reporte."""
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[
            {
                "payment_method_id": PM_ID,
                "payment_method_name": "Efectivo",
                "payment_method_kind": "cash",
                "is_active": True,
                "total_sold": 15000.0,
                "total_purchased": 3000.0,
                "operation_count": 3,
            }
        ])
        member_token = _account_role_token("member")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/payment-methods?start=2026-08-01&end=2026-08-19",
                headers={"Authorization": f"Bearer {member_token}"},
            )

        assert resp.status_code == 200
        data = resp.json()
        assert data[0]["payment_method_name"] == "Efectivo"
        assert data[0]["total_sold"] == 15000.0

    @pytest.mark.asyncio
    async def test_report_missing_range_returns_422(self, async_client, mock_pool):
        pool, conn = mock_pool
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/payment-methods",
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 422

    @pytest.mark.asyncio
    async def test_report_unauthenticated_returns_401(self, async_client, mock_pool):
        pool, conn = mock_pool

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/reports/payment-methods?start=2026-08-01&end=2026-08-19"
            )

        assert resp.status_code == 401


# ── 4.3 TRIANGULATE ──────────────────────────────────────────────────────────

class TestPaymentMethodRouterTriangulate:
    @pytest.mark.asyncio
    async def test_create_returns_201_with_out_schema(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=PM_ROW)
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/payment-methods",
                json={"name": "Efectivo", "kind": "cash"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 201
        data = resp.json()
        assert "id" in data
        assert "account_id" in data
        assert "sort_order" in data
        assert "created_at" in data

    @pytest.mark.asyncio
    async def test_deactivate_returns_is_active_false_in_response(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=PM_ROW_DEACTIVATED)
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/payment-methods/{PM_ID}/deactivate",
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        assert resp.json()["is_active"] is False
