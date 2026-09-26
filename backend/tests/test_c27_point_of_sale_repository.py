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


# ── punto-venta-seleccion (2026-09-26): PV predeterminado por cuenta ──────────
#
# D9: marcar = DOS sentencias en orden (quitar la marca vieja, poner la nueva)
# dentro de una transacción, ambas filtradas por account_id explícito (la RLS
# es red, no guard único). El índice único parcial no admite DEFERRABLE, así
# que una sola sentencia puede fallar según el orden físico de las filas.

PV_DEFAULT_ROW = {**PV_ROW, "is_default": True}


def _ctx_conn():
    """Conn mockeada con `transaction()` como context manager async real."""
    from unittest.mock import MagicMock

    conn = AsyncMock()
    tx = AsyncMock()
    tx.__aenter__ = AsyncMock(return_value=None)
    tx.__aexit__ = AsyncMock(return_value=False)
    conn.transaction = MagicMock(return_value=tx)
    return conn, tx


class TestPointOfSaleDefaultRepository:
    """2.1 RED → 2.2 GREEN: set_default / clear_default / deactivate limpia la marca."""

    @pytest.mark.asyncio
    async def test_set_default_clears_then_sets_in_order_scoped_by_account(self):
        from backend.repositories.point_of_sale_repository import PointOfSaleRepository

        conn, tx = _ctx_conn()
        order: list[str] = []
        conn.execute = AsyncMock(side_effect=lambda *a: order.append("clear") or "UPDATE 1")
        conn.fetchrow = AsyncMock(side_effect=lambda *a: order.append("set") or PV_DEFAULT_ROW)

        result = await PointOfSaleRepository(conn).set_default(PV_ROW["id"], ACCOUNT_ID)

        assert order == ["clear", "set"]
        conn.transaction.assert_called_once()
        clear_sql, *clear_args = conn.execute.await_args.args
        set_sql, *set_args = conn.fetchrow.await_args.args
        # Quitar la marca vieja: sólo en ESTA cuenta y sin tocar el pedido.
        assert "is_default = false" in clear_sql.lower()
        assert "account_id = $1" in clear_sql
        assert "id <> $2" in clear_sql
        assert clear_args == [ACCOUNT_ID, PV_ROW["id"]]
        # Poner la nueva: sólo si el PV es de la cuenta y está activo.
        assert "is_default = true" in set_sql.lower()
        assert "account_id = $2" in set_sql
        assert "is_active" in set_sql
        assert set_args == [PV_ROW["id"], ACCOUNT_ID]
        assert result["is_default"] is True

    @pytest.mark.asyncio
    async def test_set_default_foreign_or_inactive_returns_none_and_rolls_back(self):
        """PV de otra cuenta / inactivo / inexistente: None y la transacción se
        REVIERTE (la marca vieja queda intacta) — el __aexit__ recibe la
        excepción interna."""
        from backend.repositories.point_of_sale_repository import PointOfSaleRepository

        conn, tx = _ctx_conn()
        conn.execute = AsyncMock(return_value="UPDATE 1")
        conn.fetchrow = AsyncMock(return_value=None)

        result = await PointOfSaleRepository(conn).set_default(PV_ROW_2["id"], ACCOUNT_ID)

        assert result is None
        exc_type = tx.__aexit__.await_args.args[0]
        assert exc_type is not None, "sin excepción dentro del bloque la transacción COMMITEA y la cuenta queda sin predeterminado"

    @pytest.mark.asyncio
    async def test_clear_default_scoped_by_account(self):
        from backend.repositories.point_of_sale_repository import PointOfSaleRepository

        conn = AsyncMock()
        conn.execute = AsyncMock(return_value="UPDATE 1")

        await PointOfSaleRepository(conn).clear_default(ACCOUNT_ID)

        sql, *args = conn.execute.await_args.args
        assert "is_default = false" in sql.lower()
        assert "account_id = $1" in sql
        assert args == [ACCOUNT_ID]

    @pytest.mark.asyncio
    async def test_deactivate_also_clears_default_in_same_statement(self):
        """Desactivar el predeterminado le quita la marca en la MISMA sentencia
        (el CHECK points_of_sale_default_is_active rechazaría lo contrario)."""
        from backend.repositories.point_of_sale_repository import PointOfSaleRepository

        conn = AsyncMock()
        conn.fetchrow = AsyncMock(return_value={**PV_ROW, "is_active": False, "is_default": False})

        await PointOfSaleRepository(conn).deactivate(PV_ROW["id"], ACCOUNT_ID)

        sql = conn.fetchrow.await_args.args[0].lower()
        assert "is_active = false" in sql
        assert "is_default = false" in sql
        assert "account_id = $2" in sql


def _account_role_token(account_role: str) -> str:
    """El rol de TENANT viaja en `app_metadata.account_role` (v31-authz-token-hook D1)."""
    return make_token({"app_metadata": {"account_role": account_role}})


class TestPointOfSaleDefaultEndpoints:
    """2.3 RED → 2.4 GREEN: POST /{id}/default, DELETE /default, is_default en GET.

    Guard: require_account_role(conn, auth, CAN_CONFIGURE) — capacidad SENSIBLE,
    así que la base se consulta siempre (fetchval → rpc_my_active_account_roles)."""

    async def test_owner_marks_default_returns_200_with_flag(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=["owner"])
        conn.fetchrow = AsyncMock(return_value=PV_DEFAULT_ROW)
        token = _account_role_token("owner")
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/fiscal/points-of-sale/{PV_ROW['id']}/default",
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 200
        assert resp.json()["is_default"] is True
        assert resp.json()["id"] == PV_ROW["id"]

    async def test_mark_default_foreign_inactive_or_missing_returns_404(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=["owner"])
        conn.fetchrow = AsyncMock(return_value=None)  # ajeno / inactivo / inexistente
        token = _account_role_token("owner")
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/fiscal/points-of-sale/{PV_ROW_2['id']}/default",
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 404

    async def test_mark_default_invalid_uuid_returns_422(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=["owner"])
        token = _account_role_token("owner")
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/fiscal/points-of-sale/no-es-un-uuid/default",
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 422

    async def test_owner_clears_default_returns_204(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=["owner"])
        token = _account_role_token("owner")
        with patch("backend.core.database.pool", pool):
            resp = await async_client.delete(
                "/fiscal/points-of-sale/default",
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 204
        clear_calls = [c for c in conn.execute.await_args_list if "is_default = false" in str(c.args[0]).lower()]
        assert len(clear_calls) == 1
        assert clear_calls[0].args[1] == ACCOUNT_ID

    async def test_member_cannot_mark_default(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=["member"])
        conn.fetchrow = AsyncMock(return_value=PV_DEFAULT_ROW)
        token = _account_role_token("member")
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/fiscal/points-of-sale/{PV_ROW['id']}/default",
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 403
        conn.fetchrow.assert_not_awaited()

    async def test_member_cannot_clear_default(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=["member"])
        token = _account_role_token("member")
        with patch("backend.core.database.pool", pool):
            resp = await async_client.delete(
                "/fiscal/points-of-sale/default",
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 403
        assert not any("is_default" in str(c.args[0]) for c in conn.execute.await_args_list)

    async def test_revoked_owner_token_but_db_says_member_is_403(self, async_client, mock_pool):
        """Capacidad sensible: la base manda aunque el token diga owner (D12)."""
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(return_value=["member"])
        token = _account_role_token("owner")
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/fiscal/points-of-sale/{PV_ROW['id']}/default",
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 403

    async def test_list_exposes_is_default(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[PV_DEFAULT_ROW, {**PV_ROW_2, "is_default": False}])
        token = make_token({"role": "user"})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/fiscal/points-of-sale",
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 200
        body = resp.json()
        assert [pv["is_default"] for pv in body] == [True, False]
