"""
cost-center-dimension — Router TDD tests (tasks 4.1-4.3).
v31-authz-token-hook — task 6.1-6.3 (D9): los tokens de escritura (create/
update/deactivate) ahora llevan el rol de TENANT en `app_metadata.account_role`
— espacio de nombres separado del rol de PLATAFORMA que viaja en el campo
`role` de nivel superior del JWT de prueba (que `make_token` usa para simular
`payload["role"]`, no para `app_metadata`). Antes de este change, estos tests
"hackeaban" el campo `role` de nivel superior para simular el rol de cuenta
— eso dejó de ser válido: cost_centers gatea contra `account_role` (D1/D9).

Tests cover HTTP endpoints for /cost-centers CRUD via async_client.
Service/repository layers are mocked via asyncpg connection mock.
"""
from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import make_token

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
CC_ID = "cccccccc-cccc-cccc-cccc-cccccccccccc"

CC_ROW = {
    "id": CC_ID,
    "account_id": ACCOUNT_ID,
    "name": "Marketing",
    "code": "MKTO",
    "is_active": True,
    "created_at": "2026-08-02T10:00:00+00:00",
}

CC_ROW_DEACTIVATED = {**CC_ROW, "is_active": False}


def _account_role_token(account_role: str) -> str:
    """v31-authz-token-hook D1: el rol de TENANT viaja en
    `app_metadata.account_role`, nunca en el `role` de plataforma."""
    return make_token({"app_metadata": {"account_role": account_role}})


# ── 4.1 RED: GET /cost-centers ───────────────────────────────────────────────

class TestCostCenterListEndpoint:
    @pytest.mark.asyncio
    async def test_get_list_ok_for_member(self, async_client, mock_pool):
        """Any authenticated member can list cost centers."""
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[CC_ROW])
        member_token = _account_role_token("member")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/cost-centers",
                headers={"Authorization": f"Bearer {member_token}"},
            )

        assert resp.status_code == 200
        data = resp.json()
        assert isinstance(data, list)
        assert data[0]["name"] == "Marketing"

    @pytest.mark.asyncio
    async def test_get_list_active_only_by_default(self, async_client, mock_pool):
        """GET /cost-centers returns active centers only by default."""
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[CC_ROW])
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/cost-centers",
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200

    @pytest.mark.asyncio
    async def test_get_list_all_with_include_inactive(self, async_client, mock_pool):
        """GET /cost-centers?include_inactive=true returns all centers."""
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[CC_ROW, CC_ROW_DEACTIVATED])
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/cost-centers?include_inactive=true",
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        assert len(resp.json()) == 2

    @pytest.mark.asyncio
    async def test_get_list_unauthenticated_returns_401(self, async_client, mock_pool):
        """Unauthenticated request to /cost-centers returns 401."""
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/cost-centers")

        assert resp.status_code == 401


# ── 6.1 RED (D9): POST /cost-centers gatea contra account_role (tenant) ─────

class TestCostCenterCreateEndpoint:
    @pytest.mark.asyncio
    async def test_create_owner_returns_201(self, async_client, mock_pool):
        """POST /cost-centers returns 201 with the created resource for owner
        (account_role) — antes de este change daba 403 universal (criterio (a))."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=CC_ROW)
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/cost-centers",
                json={"name": "Marketing", "code": "MKTO"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 201
        data = resp.json()
        assert data["name"] == "Marketing"
        assert data["is_active"] is True

    @pytest.mark.asyncio
    async def test_create_admin_returns_201(self, async_client, mock_pool):
        """POST /cost-centers returns 201 for admin (account_role)."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=CC_ROW)
        admin_token = _account_role_token("admin")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/cost-centers",
                json={"name": "Marketing"},
                headers={"Authorization": f"Bearer {admin_token}"},
            )

        assert resp.status_code == 201

    @pytest.mark.asyncio
    async def test_create_member_returns_403(self, async_client, mock_pool):
        """POST /cost-centers returns 403 for member (account_role, no write access)."""
        pool, conn = mock_pool
        member_token = _account_role_token("member")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/cost-centers",
                json={"name": "Test"},
                headers={"Authorization": f"Bearer {member_token}"},
            )

        assert resp.status_code == 403

    @pytest.mark.asyncio
    async def test_create_invalid_payload_returns_422(self, async_client, mock_pool):
        """POST /cost-centers with missing required fields returns 422."""
        pool, conn = mock_pool
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/cost-centers",
                json={},  # missing required 'name'
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 422

    @pytest.mark.asyncio
    async def test_create_without_code_ok(self, async_client, mock_pool):
        """POST /cost-centers without optional 'code' field returns 201."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value={**CC_ROW, "code": None})
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/cost-centers",
                json={"name": "Logística"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 201

    @pytest.mark.asyncio
    async def test_create_claim_absent_falls_back_to_db_owner_succeeds(self, async_client, mock_pool):
        """TRIANGULATE (6.3b, D6): token SIN el claim account_role (emitido
        antes de habilitar el hook) + membresía owner resuelta contra la DB
        → 201 igual (camino de transición, sin default permisivo)."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=CC_ROW)
        conn.fetchval = AsyncMock(return_value="owner")  # fallback DB de require_account_role
        legacy_token = make_token({})  # sin app_metadata.account_role

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/cost-centers",
                json={"name": "Marketing"},
                headers={"Authorization": f"Bearer {legacy_token}"},
            )

        assert resp.status_code == 201

    @pytest.mark.asyncio
    async def test_create_claim_absent_and_no_membership_returns_403(self, async_client, mock_pool):
        """TRIANGULATE (D6): token sin claim Y sin membresía en la DB → 403,
        nunca un default permisivo."""
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=None)
        legacy_token = make_token({})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/cost-centers",
                json={"name": "Marketing"},
                headers={"Authorization": f"Bearer {legacy_token}"},
            )

        assert resp.status_code == 403


# ── 6.1 RED (D9): PATCH /cost-centers/{id} gatea contra account_role ───────

class TestCostCenterUpdateEndpoint:
    @pytest.mark.asyncio
    async def test_patch_owner_ok(self, async_client, mock_pool):
        """PATCH /cost-centers/{id} updates name for owner (account_role)."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value={**CC_ROW, "name": "Marketing Digital"})
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/cost-centers/{CC_ID}",
                json={"name": "Marketing Digital"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        assert resp.json()["name"] == "Marketing Digital"

    @pytest.mark.asyncio
    async def test_patch_member_returns_403(self, async_client, mock_pool):
        """PATCH /cost-centers/{id} returns 403 for member (account_role)."""
        pool, conn = mock_pool
        member_token = _account_role_token("member")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/cost-centers/{CC_ID}",
                json={"name": "X"},
                headers={"Authorization": f"Bearer {member_token}"},
            )

        assert resp.status_code == 403


# ── 6.1 RED (D9): PATCH /cost-centers/{id}/deactivate gatea contra account_role ─

class TestCostCenterDeactivateEndpoint:
    @pytest.mark.asyncio
    async def test_deactivate_owner_ok(self, async_client, mock_pool):
        """PATCH /cost-centers/{id}/deactivate sets is_active=false."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=CC_ROW_DEACTIVATED)
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/cost-centers/{CC_ID}/deactivate",
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        assert resp.json()["is_active"] is False

    @pytest.mark.asyncio
    async def test_deactivate_member_returns_403(self, async_client, mock_pool):
        """PATCH /cost-centers/{id}/deactivate returns 403 for member (account_role)."""
        pool, conn = mock_pool
        member_token = _account_role_token("member")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/cost-centers/{CC_ID}/deactivate",
                headers={"Authorization": f"Bearer {member_token}"},
            )

        assert resp.status_code == 403


# ── 4.3/6.3 TRIANGULATE ──────────────────────────────────────────────────────

class TestCostCenterRouterTriangulate:
    @pytest.mark.asyncio
    async def test_create_returns_201_with_out_schema(self, async_client, mock_pool):
        """TRIANGULATE: create returns 201 with full CostCenterOut schema."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=CC_ROW)
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/cost-centers",
                json={"name": "Marketing", "code": "MKTO"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 201
        data = resp.json()
        assert "id" in data
        assert "account_id" in data
        assert "is_active" in data
        assert "created_at" in data

    @pytest.mark.asyncio
    async def test_deactivate_returns_is_active_false_in_response(self, async_client, mock_pool):
        """TRIANGULATE: deactivate → is_active=false in response."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=CC_ROW_DEACTIVATED)
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/cost-centers/{CC_ID}/deactivate",
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        assert resp.json()["is_active"] is False

    @pytest.mark.asyncio
    async def test_invalid_payload_422(self, async_client, mock_pool):
        """TRIANGULATE: payload missing 'name' → 422."""
        pool, conn = mock_pool
        owner_token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/cost-centers",
                json={"code": "only-code"},  # missing required name
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 422

    @pytest.mark.asyncio
    async def test_platform_admin_without_tenant_membership_still_403(self, async_client, mock_pool):
        """TRIANGULATE (D1, no-op de autorización inverso): un usuario que ES
        admin de PLATAFORMA (role="admin", profiles.role) pero NO tiene rol
        de tenant habilitado en la cuenta (account_role="member") sigue sin
        poder crear cost centers — la fuente es exclusivamente account_role,
        nunca el rol de plataforma."""
        pool, conn = mock_pool
        token = make_token({"app_metadata": {"role": "admin", "account_role": "member"}})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/cost-centers",
                json={"name": "Test"},
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 403
