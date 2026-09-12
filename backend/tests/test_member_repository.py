"""
v3-rbac-multirole Parte C — MemberRepository TDD tests (grupo 14, task 14.5).

Tests cover MemberRepository methods via asyncpg mock. No real DB is touched
— all SQL is verified through call_args. Mirrors the pattern of
test_cost_center_repository.py.
"""
from __future__ import annotations

import json
from unittest.mock import AsyncMock

import pytest

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
USER_ID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

MEMBER_ROW = {
    "member_id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
    "user_id": USER_ID,
    "legacy_role": "member",
    "created_at": "2026-09-01T10:00:00+00:00",
    "name": "Ana",
    "email": "ana@test.local",
    "roles": json.dumps([{"role": "seller", "expires_at": None, "is_active": True}]),
}


@pytest.fixture
def member_repo():
    from backend.repositories.member_repository import MemberRepository

    conn = AsyncMock()
    return MemberRepository(conn), conn


# ── list_members ──────────────────────────────────────────────────────────


class TestMemberRepositoryList:
    @pytest.mark.asyncio
    async def test_list_members_calls_the_rpc(self, member_repo):
        repo, conn = member_repo
        conn.fetch = AsyncMock(return_value=[MEMBER_ROW])

        result = await repo.list_members(ACCOUNT_ID)

        sql = conn.fetch.call_args[0][0]
        assert "rpc_list_account_members" in sql
        assert conn.fetch.call_args[0][1] == ACCOUNT_ID
        assert result[0]["email"] == "ana@test.local"

    @pytest.mark.asyncio
    async def test_list_members_decodes_roles_jsonb_string(self, member_repo):
        """asyncpg devuelve jsonb como str sin codec registrado — la
        columna `roles` debe llegar decodificada como list, no como texto."""
        repo, conn = member_repo
        conn.fetch = AsyncMock(return_value=[MEMBER_ROW])

        result = await repo.list_members(ACCOUNT_ID)

        assert isinstance(result[0]["roles"], list)
        assert result[0]["roles"][0]["role"] == "seller"

    @pytest.mark.asyncio
    async def test_list_members_empty(self, member_repo):
        repo, conn = member_repo
        conn.fetch = AsyncMock(return_value=[])

        result = await repo.list_members(ACCOUNT_ID)

        assert result == []


# ── assign_role ────────────────────────────────────────────────────────────


class TestMemberRepositoryAssignRole:
    @pytest.mark.asyncio
    async def test_assign_role_calls_rpc_with_positional_args(self, member_repo):
        repo, conn = member_repo
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps({"account_id": ACCOUNT_ID, "user_id": USER_ID, "role": "seller", "expires_at": None})}
        )

        result = await repo.assign_role(ACCOUNT_ID, USER_ID, "seller", None)

        sql = conn.fetchrow.call_args[0][0]
        assert "rpc_assign_member_role" in sql
        args = conn.fetchrow.call_args[0][1:]
        assert args == (ACCOUNT_ID, USER_ID, "seller", None)
        assert result["role"] == "seller"

    @pytest.mark.asyncio
    async def test_assign_role_passes_expires_at(self, member_repo):
        repo, conn = member_repo
        conn.fetchrow = AsyncMock(return_value={"result": json.dumps({"account_id": ACCOUNT_ID, "user_id": USER_ID, "role": "cashier", "expires_at": "2026-12-01T00:00:00+00:00"})})

        await repo.assign_role(ACCOUNT_ID, USER_ID, "cashier", "2026-12-01T00:00:00+00:00")

        args = conn.fetchrow.call_args[0][1:]
        assert args[3] == "2026-12-01T00:00:00+00:00"


# ── revoke_role ────────────────────────────────────────────────────────────


class TestMemberRepositoryRevokeRole:
    @pytest.mark.asyncio
    async def test_revoke_role_calls_rpc(self, member_repo):
        repo, conn = member_repo
        conn.fetchrow = AsyncMock(return_value={"result": json.dumps({"account_id": ACCOUNT_ID, "user_id": USER_ID, "role": "seller"})})

        result = await repo.revoke_role(ACCOUNT_ID, USER_ID, "seller")

        sql = conn.fetchrow.call_args[0][0]
        assert "rpc_revoke_member_role" in sql
        assert conn.fetchrow.call_args[0][1:] == (ACCOUNT_ID, USER_ID, "seller")
        assert result["role"] == "seller"


# ── remove_member ────────────────────────────────────────────────────────────


class TestMemberRepositoryRemoveMember:
    @pytest.mark.asyncio
    async def test_remove_member_calls_rpc_remove_member(self, member_repo):
        """Reutiliza rpc_remove_member (Parte A) -- contrato legacy {ok}|{error}."""
        repo, conn = member_repo
        conn.fetchrow = AsyncMock(return_value={"result": json.dumps({"ok": True})})

        result = await repo.remove_member(ACCOUNT_ID, USER_ID)

        sql = conn.fetchrow.call_args[0][0]
        assert "rpc_remove_member" in sql
        assert conn.fetchrow.call_args[0][1:] == (ACCOUNT_ID, USER_ID)
        assert result["ok"] is True

    @pytest.mark.asyncio
    async def test_remove_member_surfaces_error_shape(self, member_repo):
        repo, conn = member_repo
        conn.fetchrow = AsyncMock(return_value={"result": json.dumps({"error": "Sin permisos"})})

        result = await repo.remove_member(ACCOUNT_ID, USER_ID)

        assert result == {"error": "Sin permisos"}


# ── member_exists (ronda 1 adversarial, finding MINOR) ──────────────────────


class TestMemberRepositoryMemberExists:
    @pytest.mark.asyncio
    async def test_member_exists_true_when_row_found(self, member_repo):
        repo, conn = member_repo
        conn.fetchrow = AsyncMock(return_value={"?column?": 1})

        result = await repo.member_exists(ACCOUNT_ID, USER_ID)

        assert result is True
        sql = conn.fetchrow.call_args[0][0]
        assert "account_members" in sql
        assert conn.fetchrow.call_args[0][1:] == (ACCOUNT_ID, USER_ID)

    @pytest.mark.asyncio
    async def test_member_exists_false_when_no_row(self, member_repo):
        """TRIANGULATE: un target que NO es miembro de esta cuenta."""
        repo, conn = member_repo
        conn.fetchrow = AsyncMock(return_value=None)

        result = await repo.member_exists(ACCOUNT_ID, USER_ID)

        assert result is False
