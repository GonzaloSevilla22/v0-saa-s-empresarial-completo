"""
cost-center-dimension — CostCenterService TDD tests (tasks 3.1-3.3).
v31-authz-token-hook — task 6.1-6.3 (D9): los 3 guards de mutación migran de
`require_role(auth, ["owner","admin"])` (espacio de PLATAFORMA) a
`await require_account_role(conn, auth, ["owner","admin"])` (espacio de
TENANT) — cost_centers es el único consumidor de rol de tenant y es la razón
de que la tabla tuviera 0 filas en prod (criterio de aceptación (a)).

Tests cover guard behaviour (require_account_role) + normalisation logic.
Repository is mocked — no DB interaction on the happy path (claim presente).
"""
from __future__ import annotations

from unittest.mock import AsyncMock

import pytest
from fastapi import HTTPException

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


def _make_auth(account_role: str | None) -> dict:
    """v31-authz-token-hook D1: `role` es SIEMPRE el de plataforma (irrelevante
    acá) — cost_centers gatea exclusivamente contra `account_role` (tenant)."""
    return {
        "user_id": "11111111-1111-1111-1111-111111111111",
        "role": "user",
        "account_role": account_role,
        "plan": "pro",
    }


def _make_conn(fallback_role: object = "__unset__") -> AsyncMock:
    """Mock de conexión para el fallback de `require_account_role` (D6). Con
    el claim presente (caso normal de estos tests) NUNCA se toca — se deja
    sin configurar (fetchval sin awaits) para probar justamente eso."""
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
    get_result=None,
):
    repo = AsyncMock()
    repo.list_by_account = AsyncMock(return_value=[CC_ROW] if list_result is _SENTINEL else list_result)
    repo.create = AsyncMock(return_value=CC_ROW if create_result is _SENTINEL else create_result)
    repo.update = AsyncMock(return_value=CC_ROW if update_result is _SENTINEL else update_result)
    repo.deactivate = AsyncMock(
        return_value={**CC_ROW, "is_active": False} if deactivate_result is _SENTINEL else deactivate_result
    )
    repo.get_by_id = AsyncMock(return_value=get_result)
    return repo


# ── 3.1 RED: list is permitted to any member ──────────────────────────────────
# (list_cost_centers no llama a ningún guard — abierto a cualquier miembro,
# sin cambios por este change).


class TestCostCenterServiceList:
    @pytest.mark.asyncio
    async def test_list_permitted_for_member(self):
        """list is accessible to member (read-only role)."""
        from backend.services.cost_centers import list_cost_centers

        repo = _make_repo()
        auth = _make_auth("member")

        result = await list_cost_centers(repo, auth, ACCOUNT_ID, active_only=True)

        assert isinstance(result, list)
        repo.list_by_account.assert_awaited_once_with(ACCOUNT_ID, active_only=True)

    @pytest.mark.asyncio
    async def test_list_permitted_for_owner(self):
        """list is accessible to owner."""
        from backend.services.cost_centers import list_cost_centers

        repo = _make_repo()
        auth = _make_auth("owner")

        result = await list_cost_centers(repo, auth, ACCOUNT_ID, active_only=True)

        assert len(result) == 1

    @pytest.mark.asyncio
    async def test_list_active_only_true_passes_flag(self):
        """list passes active_only=True down to the repo."""
        from backend.services.cost_centers import list_cost_centers

        repo = _make_repo()
        auth = _make_auth("admin")

        await list_cost_centers(repo, auth, ACCOUNT_ID, active_only=True)

        repo.list_by_account.assert_awaited_once_with(ACCOUNT_ID, active_only=True)


# ── 6.1 RED / D9: create requiere account_role owner/admin (tenant) ─────────


class TestCostCenterServiceCreate:
    @pytest.mark.asyncio
    async def test_create_member_raises_403(self):
        """member (account_role) cannot create a cost center."""
        from backend.services.cost_centers import create_cost_center

        repo = _make_repo()
        auth = _make_auth("member")

        with pytest.raises(HTTPException) as exc_info:
            await create_cost_center(repo, auth, ACCOUNT_ID, name="Logística", code=None, conn=_make_conn())

        assert exc_info.value.status_code == 403

    @pytest.mark.asyncio
    async def test_create_owner_ok(self):
        """RED (6.1): owner (account_role, TENANT) can create a cost center —
        antes de este change esto daba 403 universal (criterio de aceptación (a))."""
        from backend.services.cost_centers import create_cost_center

        repo = _make_repo(create_result=CC_ROW)
        auth = _make_auth("owner")

        result = await create_cost_center(repo, auth, ACCOUNT_ID, name="Marketing", code="MKTO", conn=_make_conn())

        assert result["name"] == "Marketing"
        repo.create.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_create_admin_ok(self):
        """admin (account_role) can create a cost center."""
        from backend.services.cost_centers import create_cost_center

        repo = _make_repo(create_result=CC_ROW)
        auth = _make_auth("admin")

        result = await create_cost_center(repo, auth, ACCOUNT_ID, name="Marketing", code=None, conn=_make_conn())

        assert result is not None
        repo.create.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_create_normalizes_name_trim(self):
        """create strips leading/trailing whitespace from name."""
        from backend.services.cost_centers import create_cost_center

        repo = _make_repo(create_result={**CC_ROW, "name": "Marketing"})
        auth = _make_auth("owner")

        await create_cost_center(repo, auth, ACCOUNT_ID, name="  Marketing  ", code=None, conn=_make_conn())

        # Verify the name passed to repo.create was trimmed
        call_kwargs = repo.create.call_args
        name_arg = call_kwargs[1].get("name") or call_kwargs[0][1]
        assert name_arg == "Marketing"

    @pytest.mark.asyncio
    async def test_create_claim_present_never_touches_conn(self):
        """6.1 (defensa): con el claim account_role presente, require_account_role
        NUNCA debe tocar la conexión — camino caliente sin query extra (D6)."""
        from backend.services.cost_centers import create_cost_center

        repo = _make_repo(create_result=CC_ROW)
        auth = _make_auth("owner")
        conn = _make_conn()

        await create_cost_center(repo, auth, ACCOUNT_ID, name="Marketing", code=None, conn=conn)

        conn.fetchval.assert_not_awaited()


# ── 6.1 RED: update requires account_role owner/admin (tenant) ─────────────


class TestCostCenterServiceUpdate:
    @pytest.mark.asyncio
    async def test_update_member_raises_403(self):
        """member cannot update a cost center."""
        from backend.services.cost_centers import update_cost_center

        repo = _make_repo()
        auth = _make_auth("member")

        with pytest.raises(HTTPException) as exc_info:
            await update_cost_center(repo, auth, ACCOUNT_ID, CC_ID, name="X", code=None, conn=_make_conn())

        assert exc_info.value.status_code == 403

    @pytest.mark.asyncio
    async def test_update_owner_ok(self):
        """owner can update a cost center."""
        from backend.services.cost_centers import update_cost_center

        repo = _make_repo(update_result={**CC_ROW, "name": "Marketing Digital"})
        auth = _make_auth("owner")

        result = await update_cost_center(
            repo, auth, ACCOUNT_ID, CC_ID, name="Marketing Digital", code=None, conn=_make_conn()
        )

        assert result["name"] == "Marketing Digital"

    @pytest.mark.asyncio
    async def test_update_not_found_raises_404(self):
        """update raises 404 when cost center not found."""
        from backend.services.cost_centers import update_cost_center

        repo = _make_repo(update_result=None)
        auth = _make_auth("owner")

        with pytest.raises(HTTPException) as exc_info:
            await update_cost_center(repo, auth, ACCOUNT_ID, "nonexistent", name="X", code=None, conn=_make_conn())

        assert exc_info.value.status_code == 404


# ── 6.1 RED: deactivate requires account_role owner/admin (tenant) ─────────


class TestCostCenterServiceDeactivate:
    @pytest.mark.asyncio
    async def test_deactivate_member_raises_403(self):
        """member cannot deactivate a cost center."""
        from backend.services.cost_centers import deactivate_cost_center

        repo = _make_repo()
        auth = _make_auth("member")

        with pytest.raises(HTTPException) as exc_info:
            await deactivate_cost_center(repo, auth, ACCOUNT_ID, CC_ID, conn=_make_conn())

        assert exc_info.value.status_code == 403

    @pytest.mark.asyncio
    async def test_deactivate_owner_ok(self):
        """owner can deactivate a cost center."""
        from backend.services.cost_centers import deactivate_cost_center

        repo = _make_repo(deactivate_result={**CC_ROW, "is_active": False})
        auth = _make_auth("owner")

        result = await deactivate_cost_center(repo, auth, ACCOUNT_ID, CC_ID, conn=_make_conn())

        assert result["is_active"] is False

    @pytest.mark.asyncio
    async def test_deactivate_not_found_raises_404(self):
        """deactivate raises 404 when cost center not found."""
        from backend.services.cost_centers import deactivate_cost_center

        repo = _make_repo(deactivate_result=None)
        auth = _make_auth("admin")

        with pytest.raises(HTTPException) as exc_info:
            await deactivate_cost_center(repo, auth, ACCOUNT_ID, "nonexistent", conn=_make_conn())

        assert exc_info.value.status_code == 404


# ── 6.3 TRIANGULATE (D9/D6) ──────────────────────────────────────────────────


class TestCostCenterServiceTriangulate:
    @pytest.mark.asyncio
    async def test_member_list_ok_but_member_create_forbidden(self):
        """TRIANGULATE: member reads ok but cannot write."""
        from backend.services.cost_centers import list_cost_centers, create_cost_center

        repo = _make_repo()
        member = _make_auth("member")

        # list: ok
        result = await list_cost_centers(repo, member, ACCOUNT_ID, active_only=True)
        assert isinstance(result, list)

        # create: forbidden
        with pytest.raises(HTTPException) as exc_info:
            await create_cost_center(repo, member, ACCOUNT_ID, name="Test", code=None, conn=_make_conn())
        assert exc_info.value.status_code == 403

    @pytest.mark.asyncio
    async def test_name_with_spaces_is_normalized(self):
        """TRIANGULATE: name with leading/trailing spaces is trimmed."""
        from backend.services.cost_centers import create_cost_center

        repo = _make_repo(create_result=CC_ROW)
        auth = _make_auth("owner")

        await create_cost_center(repo, auth, ACCOUNT_ID, name="  Logística  ", code=None, conn=_make_conn())

        call_args = repo.create.call_args
        name_arg = call_args[1].get("name") or call_args[0][1]
        assert name_arg == "Logística"

    @pytest.mark.asyncio
    async def test_admin_deactivate_sets_is_active_false(self):
        """TRIANGULATE: admin can deactivate and the row comes back is_active=false."""
        from backend.services.cost_centers import deactivate_cost_center

        repo = _make_repo(deactivate_result={**CC_ROW, "is_active": False})
        auth = _make_auth("admin")

        result = await deactivate_cost_center(repo, auth, ACCOUNT_ID, CC_ID, conn=_make_conn())

        assert result["is_active"] is False
        repo.deactivate.assert_awaited_once_with(CC_ID, ACCOUNT_ID)

    @pytest.mark.asyncio
    async def test_create_claim_absent_falls_back_to_db_owner_succeeds(self):
        """TRIANGULATE (6.3b, D6): claim account_role AUSENTE (token viejo) +
        membresía owner en la base → éxito igual (camino de transición)."""
        from backend.services.cost_centers import create_cost_center

        repo = _make_repo(create_result=CC_ROW)
        auth = _make_auth(None)  # sin claim — token emitido antes del hook
        conn = _make_conn(fallback_role="owner")

        result = await create_cost_center(repo, auth, ACCOUNT_ID, name="Marketing", code=None, conn=conn)

        assert result["name"] == "Marketing"
        conn.fetchval.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_create_claim_absent_and_no_membership_denies_never_permissive(self):
        """TRIANGULATE (D6): claim ausente Y sin membresía resoluble → 403.
        Nunca un default permisivo."""
        from backend.services.cost_centers import create_cost_center

        repo = _make_repo()
        auth = _make_auth(None)
        conn = _make_conn(fallback_role=None)

        with pytest.raises(HTTPException) as exc_info:
            await create_cost_center(repo, auth, ACCOUNT_ID, name="Test", code=None, conn=conn)

        assert exc_info.value.status_code == 403

    def test_service_module_uses_require_account_role_not_platform_role(self):
        """REFACTOR (6.4): barrido puntual — cost_centers NUNCA debe volver a
        comparar el rol de TENANT contra `require_role` (espacio de
        plataforma, D1). Prueba estática sobre el código fuente del módulo."""
        import inspect

        import backend.services.cost_centers as module

        source = inspect.getsource(module)
        assert "require_account_role" in source
        assert "require_role(auth" not in source
