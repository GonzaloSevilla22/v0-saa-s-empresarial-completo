"""
C-26 v21-branch-as-root — lifecycle de Branch + historial de transferencias (TDD).

  - BranchRepository.open_branch / close_branch invocan las RPCs del lifecycle.
  - BranchRepository.list_transfers consulta stock_transfers de la sucursal
    (como origen o destino), aislada por cuenta, orden descendente.
  - Endpoints: POST /branches/{id}/open, POST /branches/{id}/close,
    GET /branches/{id}/transfers.
"""
from __future__ import annotations

import json
from decimal import Decimal
from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import make_token

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
BRANCH_ID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
TRANSFER_ROW = {
    "id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
    "account_id": ACCOUNT_ID,
    "product_id": "22222222-2222-2222-2222-222222222222",
    "product_name": "Reel Fly Limay",
    "from_branch_id": BRANCH_ID,
    "from_branch_name": "Casa Central",
    "to_branch_id": "dddddddd-dddd-dddd-dddd-dddddddddddd",
    "to_branch_name": "Godoy Cruz",
    "quantity": Decimal("3.0000"),
    "status": "completed",
    "created_at": "2026-06-12T20:00:00",
}


@pytest.fixture
def branch_repo():
    from backend.repositories.branch_repository import BranchRepository

    conn = AsyncMock()
    return BranchRepository(conn), conn


class TestBranchLifecycleRepository:
    @pytest.mark.asyncio
    async def test_open_branch_calls_rpc(self, branch_repo):
        repo, conn = branch_repo
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps({"branch_id": BRANCH_ID, "status": "active", "changed": True})}
        )

        result = await repo.open_branch(BRANCH_ID)

        query = conn.fetchrow.call_args[0][0].lower()
        assert "rpc_open_branch" in query
        assert BRANCH_ID in conn.fetchrow.call_args[0]
        assert result["status"] == "active"

    @pytest.mark.asyncio
    async def test_close_branch_calls_rpc(self, branch_repo):
        repo, conn = branch_repo
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps({"branch_id": BRANCH_ID, "status": "closed", "changed": True})}
        )

        result = await repo.close_branch(BRANCH_ID)

        query = conn.fetchrow.call_args[0][0].lower()
        assert "rpc_close_branch" in query
        assert result["status"] == "closed"

    @pytest.mark.asyncio
    async def test_list_transfers_queries_stock_transfers_both_directions(self, branch_repo):
        repo, conn = branch_repo
        conn.fetch = AsyncMock(return_value=[TRANSFER_ROW])

        rows = await repo.list_transfers(BRANCH_ID, ACCOUNT_ID)

        query = conn.fetch.call_args[0][0].lower()
        assert "stock_transfers" in query
        assert "from_branch_id" in query and "to_branch_id" in query, (
            "must include transfers where the branch is origin OR destination"
        )
        assert "account_id" in query, "tenancy filter required"
        assert "order by" in query and "desc" in query
        assert rows == [TRANSFER_ROW]


class TestBranchLifecycleEndpoints:
    async def test_open_branch_endpoint(self, async_client, mock_pool):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps({"branch_id": BRANCH_ID, "status": "active", "changed": True})}
        )
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/branches/{BRANCH_ID}/open",
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 200
        assert resp.json()["status"] == "active"

    async def test_close_branch_endpoint(self, async_client, mock_pool):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps({"branch_id": BRANCH_ID, "status": "closed", "changed": True})}
        )
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/branches/{BRANCH_ID}/close",
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 200
        assert resp.json()["status"] == "closed"

    async def test_lifecycle_member_forbidden(self, async_client, mock_pool):
        pool, conn = mock_pool
        member_token = make_token({"role": "member"})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/branches/{BRANCH_ID}/close",
                headers={"Authorization": f"Bearer {member_token}"},
            )
        assert resp.status_code == 403

    async def test_list_transfers_endpoint(self, async_client, mock_pool):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetch = AsyncMock(return_value=[TRANSFER_ROW])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/branches/{BRANCH_ID}/transfers",
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 200
        body = resp.json()
        assert len(body) == 1
        assert body[0]["product_name"] == "Reel Fly Limay"
        assert body[0]["from_branch_name"] == "Casa Central"
