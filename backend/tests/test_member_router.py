"""
v3-rbac-multirole Parte C — /members router TDD tests (grupo 14, task 14.5).

3 capas: router (validación + DI) -> service (CAN_CONFIGURE) -> repository
(RPCs). Sólo la conexión de asyncpg se mockea; router+service+repository
corren de verdad. Mismo patrón que test_cost_center_router.py.
"""
from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import make_token

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
USER_ID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

MEMBER_ROW = {
    "member_id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
    "user_id": USER_ID,
    "legacy_role": "member",
    "created_at": "2026-09-01T10:00:00+00:00",
    "name": "Ana",
    "email": "ana@test.local",
    "roles": '[{"role": "seller", "expires_at": null, "is_active": true}]',
}


def _account_role_token(account_role: str) -> str:
    return make_token({"app_metadata": {"account_role": account_role}})


def _mock_get_account_id(pool, conn):
    """get_account_id resuelve el account_id activo vía fetchval — separado
    del fetchval que usa el fallback de require_account_role (D6), así que
    se configura como side_effect fijo por posición de llamada cuando ambos
    conviven en el mismo test."""
    conn.fetchval = AsyncMock(return_value=ACCOUNT_ID)


# ── GET /members ─────────────────────────────────────────────────────────────


class TestMembersListEndpoint:
    @pytest.mark.asyncio
    async def test_get_list_ok_for_viewer(self, async_client, mock_pool):
        """Cualquier miembro (incluso solo-lectura) puede listar."""
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[MEMBER_ROW])
        conn.fetchval = AsyncMock(return_value=ACCOUNT_ID)  # get_account_id
        token = _account_role_token("member")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/members", headers={"Authorization": f"Bearer {token}"})

        assert resp.status_code == 200
        data = resp.json()
        assert data[0]["email"] == "ana@test.local"
        assert data[0]["roles"][0]["role"] == "seller"

    @pytest.mark.asyncio
    async def test_get_list_unauthenticated_returns_401(self, async_client, mock_pool):
        pool, conn = mock_pool
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/members")
        assert resp.status_code == 401


# ── POST /members/{user_id}/roles ───────────────────────────────────────────


class TestMembersAssignRoleEndpoint:
    @pytest.mark.asyncio
    async def test_owner_assigns_role_returns_201(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=ACCOUNT_ID)  # get_account_id
        conn.fetchrow = AsyncMock(
            return_value={"result": '{"account_id": "%s", "user_id": "%s", "role": "seller", "expires_at": null}' % (ACCOUNT_ID, USER_ID)}
        )
        token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/members/{USER_ID}/roles",
                json={"role": "seller"},
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 201
        assert resp.json()["role"] == "seller"

    @pytest.mark.asyncio
    async def test_member_assigns_role_returns_403(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=ACCOUNT_ID)  # get_account_id
        token = _account_role_token("member")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/members/{USER_ID}/roles",
                json={"role": "seller"},
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 403

    @pytest.mark.asyncio
    async def test_invalid_payload_returns_422(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=ACCOUNT_ID)
        token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/members/{USER_ID}/roles",
                json={},  # falta 'role'
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 422

    @pytest.mark.asyncio
    async def test_rpc_p0403_propagates_as_403_problem_json(self, async_client, mock_pool):
        """TRIANGULATE: la RPC rechaza (admin intentando otorgar owner) ->
        asyncpg_error_handler lo convierte en 403 RFC 7807."""
        import asyncpg

        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=ACCOUNT_ID)

        class _FakeError(asyncpg.PostgresError):
            def __init__(self):
                super().__init__("El administrador no puede otorgar el rol de propietario ni de administrador")
                self.sqlstate = "P0403"

        conn.fetchrow = AsyncMock(side_effect=_FakeError())
        token = _account_role_token("admin")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/members/{USER_ID}/roles",
                json={"role": "owner"},
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 403
        assert resp.json()["code"] == "P0403"


# ── DELETE /members/{user_id}/roles/{role} ──────────────────────────────────


class TestMembersRevokeRoleEndpoint:
    @pytest.mark.asyncio
    async def test_owner_revokes_role_ok(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=ACCOUNT_ID)
        conn.fetchrow = AsyncMock(
            return_value={"result": '{"account_id": "%s", "user_id": "%s", "role": "seller"}' % (ACCOUNT_ID, USER_ID)}
        )
        token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.delete(
                f"/members/{USER_ID}/roles/seller",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        assert resp.json()["role"] == "seller"

    @pytest.mark.asyncio
    async def test_revoke_sole_owner_returns_409_p0405(self, async_client, mock_pool):
        """Ronda 2 adversarial (finding MAJOR): revocar el ÚNICO owner activo
        de la cuenta debe responder 409/P0405 -- ANTES del fix, la RPC
        devolvía 200 (la escritura la revertía sólo el constraint trigger
        DIFERIDO de la Parte A, evaluado al COMMIT, que bajo
        v31-tenancy-pool-rls ocurre en el teardown de get_db_conn DESPUÉS de
        que FastAPI ya serializó la respuesta 200 -- el P0405->409 quedaba
        inalcanzable por esta vía). Con el chequeo síncrono nuevo (paso 3.5
        de rpc_revoke_member_role), la RPC lanza P0405 dentro del propio
        `await fetchrow`, antes de construir la respuesta -- este test sólo
        verifica la propagación de errores del router/asyncpg_error_handler,
        igual que test_rpc_p0403_propagates_as_403_problem_json arriba."""
        import asyncpg

        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=ACCOUNT_ID)

        class _FakeError(asyncpg.PostgresError):
            def __init__(self):
                super().__init__("La cuenta debe conservar al menos un propietario activo")
                self.sqlstate = "P0405"

        conn.fetchrow = AsyncMock(side_effect=_FakeError())
        token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.delete(
                f"/members/{USER_ID}/roles/owner",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 409
        assert resp.json()["code"] == "P0405"

    @pytest.mark.asyncio
    async def test_member_revokes_role_returns_403(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=ACCOUNT_ID)
        token = _account_role_token("member")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.delete(
                f"/members/{USER_ID}/roles/seller",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 403


# ── DELETE /members/{user_id} ────────────────────────────────────────────────


class TestMembersRemoveEndpoint:
    @pytest.mark.asyncio
    async def test_owner_removes_member_ok(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=ACCOUNT_ID)
        conn.fetchrow = AsyncMock(return_value={"result": '{"ok": true}'})
        token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.delete(
                f"/members/{USER_ID}",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 200
        assert resp.json()["ok"] is True

    @pytest.mark.asyncio
    async def test_legacy_error_contract_returns_403(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=ACCOUNT_ID)
        conn.fetchrow = AsyncMock(return_value={"result": '{"error": "No se puede expulsar al owner"}'})
        token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.delete(
                f"/members/{USER_ID}",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 403

    @pytest.mark.asyncio
    async def test_member_removes_member_returns_403(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=ACCOUNT_ID)
        token = _account_role_token("member")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.delete(
                f"/members/{USER_ID}",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 403

    @pytest.mark.asyncio
    async def test_owner_removes_non_member_returns_404(self, async_client, mock_pool):
        """Ronda 1 adversarial (finding MINOR): un target que no es miembro
        de esta cuenta devolvía 200 {ok:true} sin haber quitado a nadie
        (rpc_remove_member hace un DELETE sin verificar tenencia) --
        inconsistente con assign_role/revoke_role, que para el MISMO uuid
        dan 404/P0404. El pre-chequeo de tenencia ni siquiera debe llegar a
        invocar rpc_remove_member."""
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=ACCOUNT_ID)  # get_account_id

        async def _fetchrow(sql, *args):
            if "rpc_remove_member" in sql:
                raise AssertionError("rpc_remove_member no debía llamarse -- el target no es miembro")
            return None  # member_exists: 0 filas -- no es miembro

        conn.fetchrow = AsyncMock(side_effect=_fetchrow)
        token = _account_role_token("owner")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.delete(
                f"/members/{USER_ID}",
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 404
        assert resp.json()["code"] == "P0404"
