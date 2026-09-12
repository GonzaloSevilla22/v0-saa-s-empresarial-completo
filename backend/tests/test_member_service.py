"""
v3-rbac-multirole Parte C — members service TDD tests (grupo 14, task 14.5).

list_members: sin guard (abierto a cualquier miembro de la cuenta —
account-membership-roles, "la lectura no se restringe por rol"; el guard de
tenencia lo hace el propio RPC).
assign_role / revoke_role / remove_member: requieren CAN_CONFIGURE
(owner/admin de TENANT) en el service, ANTES de tocar el repositorio — la
RPC hace además la distinción fina (owner vs admin) del lado de la base.
remove_member traduce el contrato legacy {error} a HTTPException 403.
"""
from __future__ import annotations

from unittest.mock import AsyncMock

import pytest
from fastapi import HTTPException

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
USER_ID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

MEMBER_ROW = {
    "member_id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
    "user_id": USER_ID,
    "legacy_role": "member",
    "created_at": "2026-09-01T10:00:00+00:00",
    "name": "Ana",
    "email": "ana@test.local",
    "roles": [{"role": "seller", "expires_at": None, "is_active": True}],
}


def _auth(account_role: str | None = None, account_roles=None) -> dict:
    return {
        "user_id": "11111111-1111-1111-1111-111111111111",
        "role": "user",
        "account_role": account_role,
        "account_roles": account_roles,
        "plan": "pro",
    }


def _make_conn(fallback_role=object()) -> AsyncMock:
    conn = AsyncMock()
    return conn


_SENTINEL = object()


def _make_repo(
    *,
    list_result=_SENTINEL,
    assign_result=_SENTINEL,
    revoke_result=_SENTINEL,
    remove_result=_SENTINEL,
    member_exists=True,
):
    repo = AsyncMock()
    repo.list_members = AsyncMock(return_value=[MEMBER_ROW] if list_result is _SENTINEL else list_result)
    repo.assign_role = AsyncMock(
        return_value={"account_id": ACCOUNT_ID, "user_id": USER_ID, "role": "seller", "expires_at": None}
        if assign_result is _SENTINEL else assign_result
    )
    repo.revoke_role = AsyncMock(
        return_value={"account_id": ACCOUNT_ID, "user_id": USER_ID, "role": "seller"}
        if revoke_result is _SENTINEL else revoke_result
    )
    repo.remove_member = AsyncMock(return_value={"ok": True} if remove_result is _SENTINEL else remove_result)
    # Ronda 1 adversarial (finding MINOR): por defecto el target SÍ es
    # miembro -- los tests existentes de remove_member no necesitan tocar
    # esto para seguir pasando.
    repo.member_exists = AsyncMock(return_value=member_exists)
    return repo


# ── list_members ──────────────────────────────────────────────────────────


class TestMembersServiceList:
    @pytest.mark.asyncio
    async def test_list_permitted_for_viewer(self):
        """RED (account-membership-roles: la lectura no se restringe por rol)."""
        from backend.services.members import list_members

        repo = _make_repo()
        auth = _auth(account_role="member")

        result = await list_members(repo, auth, ACCOUNT_ID)

        assert result == [MEMBER_ROW]
        repo.list_members.assert_awaited_once_with(ACCOUNT_ID)

    @pytest.mark.asyncio
    async def test_list_permitted_for_owner(self):
        from backend.services.members import list_members

        repo = _make_repo()
        auth = _auth(account_role="owner")

        result = await list_members(repo, auth, ACCOUNT_ID)

        assert len(result) == 1


# ── assign_role ─────────────────────────────────────────────────────────────


class TestMembersServiceAssignRole:
    @pytest.mark.asyncio
    async def test_member_raises_403(self):
        from backend.services.members import assign_role

        repo = _make_repo()
        auth = _auth(account_role="member")

        with pytest.raises(HTTPException) as exc_info:
            await assign_role(repo, auth, ACCOUNT_ID, USER_ID, "seller", None, conn=_make_conn())

        assert exc_info.value.status_code == 403
        repo.assign_role.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_owner_ok(self):
        from backend.services.members import assign_role

        repo = _make_repo()
        auth = _auth(account_role="owner")

        result = await assign_role(repo, auth, ACCOUNT_ID, USER_ID, "seller", None, conn=_make_conn())

        assert result["role"] == "seller"
        repo.assign_role.assert_awaited_once_with(ACCOUNT_ID, USER_ID, "seller", None)

    @pytest.mark.asyncio
    async def test_admin_ok(self):
        from backend.services.members import assign_role

        repo = _make_repo()
        auth = _auth(account_role="admin")

        result = await assign_role(repo, auth, ACCOUNT_ID, USER_ID, "cashier", None, conn=_make_conn())

        assert result is not None

    @pytest.mark.asyncio
    async def test_passes_expires_at_through(self):
        from backend.services.members import assign_role

        repo = _make_repo()
        auth = _auth(account_role="owner")

        await assign_role(repo, auth, ACCOUNT_ID, USER_ID, "cashier", "2026-12-01T00:00:00+00:00", conn=_make_conn())

        repo.assign_role.assert_awaited_once_with(ACCOUNT_ID, USER_ID, "cashier", "2026-12-01T00:00:00+00:00")


# ── revoke_role ──────────────────────────────────────────────────────────────


class TestMembersServiceRevokeRole:
    @pytest.mark.asyncio
    async def test_member_raises_403(self):
        from backend.services.members import revoke_role

        repo = _make_repo()
        auth = _auth(account_role="member")

        with pytest.raises(HTTPException) as exc_info:
            await revoke_role(repo, auth, ACCOUNT_ID, USER_ID, "seller", conn=_make_conn())

        assert exc_info.value.status_code == 403
        repo.revoke_role.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_owner_ok(self):
        from backend.services.members import revoke_role

        repo = _make_repo()
        auth = _auth(account_role="owner")

        result = await revoke_role(repo, auth, ACCOUNT_ID, USER_ID, "seller", conn=_make_conn())

        assert result["role"] == "seller"
        repo.revoke_role.assert_awaited_once_with(ACCOUNT_ID, USER_ID, "seller")


# ── remove_member ────────────────────────────────────────────────────────────


class TestMembersServiceRemoveMember:
    @pytest.mark.asyncio
    async def test_member_raises_403_before_touching_repo(self):
        from backend.services.members import remove_member

        repo = _make_repo()
        auth = _auth(account_role="member")

        with pytest.raises(HTTPException) as exc_info:
            await remove_member(repo, auth, ACCOUNT_ID, USER_ID, conn=_make_conn())

        assert exc_info.value.status_code == 403
        repo.remove_member.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_owner_ok(self):
        from backend.services.members import remove_member

        repo = _make_repo(remove_result={"ok": True})
        auth = _auth(account_role="owner")

        result = await remove_member(repo, auth, ACCOUNT_ID, USER_ID, conn=_make_conn())

        assert result == {"ok": True}

    @pytest.mark.asyncio
    async def test_legacy_error_contract_becomes_403(self):
        """TRIANGULATE: rpc_remove_member devuelve {error:...} (contrato
        legacy, nunca lanza excepción) -- el service lo traduce a 403."""
        from backend.services.members import remove_member

        repo = _make_repo(remove_result={"error": "No se puede expulsar al owner"})
        auth = _auth(account_role="owner")

        with pytest.raises(HTTPException) as exc_info:
            await remove_member(repo, auth, ACCOUNT_ID, USER_ID, conn=_make_conn())

        assert exc_info.value.status_code == 403
        assert "expulsar" in exc_info.value.detail

    @pytest.mark.asyncio
    async def test_target_not_a_member_returns_404_without_calling_the_rpc(self):
        """RED (ronda 1 adversarial, finding MINOR): un target que NO es
        miembro de esta cuenta devolvía 200 {ok:true} sin haber quitado a
        nadie (rpc_remove_member hace un DELETE sin verificar tenencia,
        0 filas afectadas, sin señal) -- inconsistente con assign_role/
        revoke_role, que para el MISMO uuid dan 404/P0404. El service ahora
        pre-chequea la tenencia y ni siquiera llama a la RPC."""
        from backend.services.members import remove_member

        repo = _make_repo(member_exists=False)
        auth = _auth(account_role="owner")

        with pytest.raises(HTTPException) as exc_info:
            await remove_member(repo, auth, ACCOUNT_ID, USER_ID, conn=_make_conn())

        assert exc_info.value.status_code == 404
        assert getattr(exc_info.value, "code", None) == "P0404"
        repo.remove_member.assert_not_awaited()


# ── TRIANGULATE ──────────────────────────────────────────────────────────────


class TestMembersServiceTriangulate:
    @pytest.mark.asyncio
    async def test_member_reads_ok_but_cannot_assign(self):
        from backend.services.members import assign_role, list_members

        repo = _make_repo()
        member = _auth(account_role="member")

        result = await list_members(repo, member, ACCOUNT_ID)
        assert isinstance(result, list)

        with pytest.raises(HTTPException) as exc_info:
            await assign_role(repo, member, ACCOUNT_ID, USER_ID, "seller", None, conn=_make_conn())
        assert exc_info.value.status_code == 403

    def test_service_module_uses_require_account_role_not_platform_role(self):
        """REFACTOR: members.py NUNCA debe comparar el rol de TENANT contra
        require_role (espacio de plataforma) -- mismo barrido estático que
        cost_centers/product_categories."""
        import inspect

        import backend.services.members as module

        source = inspect.getsource(module)
        assert "require_account_role" in source
        assert "require_role(auth" not in source
