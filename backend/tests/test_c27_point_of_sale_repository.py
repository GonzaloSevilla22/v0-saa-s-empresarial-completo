"""
C-27 v21-fiscal-profile — PointOfSaleRepository + API (TDD).

TDD RED→GREEN:
  3.3 RED: PointOfSaleRepository.list/create/deactivate;
           UNIQUE(fiscal_profile_id, numero) rechaza duplicado (409);
           member no puede crear/desactivar PV (403);
           listar solo PVs de la cuenta.
  3.4 GREEN: point_of_sale_repository.py + schemas + endpoints.

Spec ref: fiscal-profile/spec.md §"API de puntos de venta"
"""
from __future__ import annotations

import asyncpg
from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import TEST_ACCOUNT_ID, make_token

ACCOUNT_ID = str(TEST_ACCOUNT_ID)
FISCAL_PROFILE_ID = "ffffffff-ffff-ffff-ffff-ffffffffffff"

PV_ROW = {
    "id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
    "fiscal_profile_id": FISCAL_PROFILE_ID,
    "account_id": ACCOUNT_ID,
    "branch_id": None,
    "numero": 1,
    "is_active": True,
    "created_at": "2026-06-27T00:00:00+00:00",
}

PV_ROW_2 = {**PV_ROW, "id": "cccccccc-cccc-cccc-cccc-cccccccccccc", "numero": 2}

FISCAL_PROFILE_ROW = {
    "id": FISCAL_PROFILE_ID,
    "account_id": ACCOUNT_ID,
    "cuit": "20123456789",
    "iva_condition": "responsable_inscripto",
    "iibb_condition": None,
    "certificado_afip_path": None,
    "ambiente": "homologacion",
    "created_at": "2026-06-27T00:00:00+00:00",
}


class TestPointOfSaleRepository:
    """3.3 RED → 3.4 GREEN: repository con DB mockeada."""

    @pytest.fixture
    def pv_repo(self):
        from backend.repositories.point_of_sale_repository import PointOfSaleRepository
        conn = AsyncMock()
        return PointOfSaleRepository(conn), conn

    @pytest.mark.asyncio
    async def test_list_by_account_queries_account_id(self, pv_repo):
        repo, conn = pv_repo
        conn.fetch = AsyncMock(return_value=[PV_ROW, PV_ROW_2])

        rows = await repo.list_by_account(ACCOUNT_ID)

        query = conn.fetch.call_args[0][0].lower()
        assert "points_of_sale" in query
        assert "account_id" in query
        assert len(rows) == 2

    @pytest.mark.asyncio
    async def test_create_uses_correct_fields(self, pv_repo):
        repo, conn = pv_repo
        conn.fetchrow = AsyncMock(return_value=PV_ROW)

        result = await repo.create(
            account_id=ACCOUNT_ID,
            fiscal_profile_id=FISCAL_PROFILE_ID,
            data={"numero": 1, "branch_id": None},
        )

        query = conn.fetchrow.call_args[0][0].lower()
        assert "points_of_sale" in query
        assert "insert" in query
        assert result["numero"] == 1

    @pytest.mark.asyncio
    async def test_deactivate_sets_is_active_false(self, pv_repo):
        repo, conn = pv_repo
        conn.fetchrow = AsyncMock(return_value={**PV_ROW, "is_active": False})

        result = await repo.deactivate(PV_ROW["id"], ACCOUNT_ID)

        query = conn.fetchrow.call_args[0][0].lower()
        assert "is_active" in query
        assert result["is_active"] is False

    @pytest.mark.asyncio
    async def test_deactivate_returns_none_when_not_found(self, pv_repo):
        repo, conn = pv_repo
        conn.fetchrow = AsyncMock(return_value=None)

        result = await repo.deactivate("non-existent", ACCOUNT_ID)
        assert result is None


class TestPointOfSaleEndpoints:
    """3.3 RED → 3.4 GREEN: endpoints de points_of_sale."""

    async def test_list_points_of_sale_returns_all_pvs(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[PV_ROW, PV_ROW_2])
        owner_token = make_token({"role": "user"})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/fiscal/points-of-sale",
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 200
        assert len(resp.json()) == 2

    async def test_create_pv_returns_201(self, async_client, mock_pool):
        pool, conn = mock_pool
        # fetchrow: primera para get_by_account_id del FP, segunda para create del PV
        conn.fetchrow = AsyncMock(side_effect=[FISCAL_PROFILE_ROW, PV_ROW])
        owner_token = make_token({"role": "user"})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/fiscal/points-of-sale",
                json={"numero": 1},
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 201
        assert resp.json()["numero"] == 1

    async def test_create_pv_duplicate_returns_409(self, async_client, mock_pool):
        """UNIQUE(fiscal_profile_id, numero) → asyncpg UniqueViolation → 409."""
        pool, conn = mock_pool
        # Primera fetchrow: perfil existe; segunda: UNIQUE violation
        conn.fetchrow = AsyncMock(
            side_effect=[
                FISCAL_PROFILE_ROW,
                asyncpg.UniqueViolationError(
                    "duplicate key value violates unique constraint"
                ),
            ]
        )
        owner_token = make_token({"role": "user"})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/fiscal/points-of-sale",
                json={"numero": 1},
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 409

    async def test_member_cannot_create_pv(self, async_client, mock_pool):
        pool, conn = mock_pool
        member_token = make_token({"role": "member"})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/fiscal/points-of-sale",
                json={"numero": 1},
                headers={"Authorization": f"Bearer {member_token}"},
            )
        assert resp.status_code == 403

    async def test_deactivate_pv_returns_200(self, async_client, mock_pool):
        pool, conn = mock_pool
        pv_id = PV_ROW["id"]
        conn.fetchrow = AsyncMock(return_value={**PV_ROW, "is_active": False})
        owner_token = make_token({"role": "user"})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/fiscal/points-of-sale/{pv_id}",
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 200
        assert resp.json()["is_active"] is False

    async def test_member_cannot_deactivate_pv(self, async_client, mock_pool):
        pool, conn = mock_pool
        pv_id = PV_ROW["id"]
        member_token = make_token({"role": "member"})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.patch(
                f"/fiscal/points-of-sale/{pv_id}",
                headers={"Authorization": f"Bearer {member_token}"},
            )
        assert resp.status_code == 403
