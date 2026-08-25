"""
sucursal-guard-vaciado-auditoria (G1/G2) — capa backend (TDD).

  - PUT /branches/{id} intentando desactivar (is_active=False) una sucursal
    con contenido operativo bloqueante debe devolver 409 RFC 7807 con el
    detalle del RAISE (P0428) — antes de este change, BranchUpdate no
    aceptaba is_active y el disparador de la migración 20261014000001 ni
    siquiera existía, así que este camino ("actualización directa que hace
    el backend contra la tabla" — design.md, el camino #3 de los 4 caminos
    de baja) no tenía NINGÚN guard. task 5.3.
  - BranchOut expone lo que la pantalla necesita (is_active, address,
    account_id, autoría) y deja de declarar `user_id`, columna que NO existe
    en `branches` — el modelo mentía. task 5.4.
"""
from __future__ import annotations

import asyncpg
import pytest

from backend.tests.conftest import make_token

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
BRANCH_ID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
USER_ID = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"

BRANCH_ROW_FULL = {
    "id": BRANCH_ID,
    "account_id": ACCOUNT_ID,
    "name": "Casa Central",
    "address": "Av. San Martín 123",
    "is_active": True,
    "created_at": "2026-06-07T10:00:00",
    "status": "active",
    "opened_at": "2026-06-07T10:00:00",
    "closed_at": None,
    "created_by": USER_ID,
    "deactivated_at": None,
    "deactivated_by": None,
}


class TestPutBranchesDeactivateGuard:
    """task 5.3 — PUT /branches/{id} cruza el disparador (P0428 -> 409)."""

    async def test_deactivate_with_stock_via_put_returns_409_not_500(
        self, async_client, mock_pool
    ):
        from unittest.mock import AsyncMock, patch

        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})

        err = asyncpg.exceptions.RaiseError(
            "branch_has_stock: la sucursal tiene 585 unidades en 518 "
            "producto(s) — transferí el stock a otra sucursal antes de "
            "darla de baja"
        )
        err.sqlstate = "P0428"
        conn.fetchrow = AsyncMock(side_effect=err)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                f"/branches/{BRANCH_ID}",
                json={"is_active": False},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 409
        body = resp.json()
        assert body["code"] == "P0428"
        assert "branch_has_stock" in body["detail"]
        assert "585" in body["detail"]

    async def test_rename_without_touching_is_active_still_works(
        self, async_client, mock_pool
    ):
        """Control positivo — task 3.9 en la capa backend: el guard no rompe
        la edición legítima de nombre que ya funcionaba antes de este change."""
        from unittest.mock import AsyncMock, patch

        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(return_value={**BRANCH_ROW_FULL, "name": "Nueva sucursal"})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                f"/branches/{BRANCH_ID}",
                json={"name": "Nueva sucursal"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        assert resp.json()["name"] == "Nueva sucursal"


class TestBranchOutSchema:
    """task 5.4 — BranchOut expone is_active/address/account_id/autoría, y
    deja de declarar `user_id` (columna inexistente en `branches`)."""

    def test_branch_out_does_not_declare_nonexistent_user_id(self):
        from backend.schemas.branches import BranchOut

        assert "user_id" not in BranchOut.model_fields, (
            "BranchOut declaraba user_id, una columna que NO existe en la "
            "tabla branches — el modelo mentía (design.md, task 5.4)."
        )

    def test_branch_out_exposes_activity_address_account_and_authorship(self):
        from backend.schemas.branches import BranchOut

        for field in (
            "is_active", "address", "account_id",
            "created_by", "deactivated_at", "deactivated_by",
        ):
            assert field in BranchOut.model_fields, f"BranchOut debería exponer {field!r}"

    async def test_get_branch_endpoint_serializes_full_shape(self, async_client, mock_pool):
        from unittest.mock import AsyncMock, patch

        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(return_value=BRANCH_ROW_FULL)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/branches/{BRANCH_ID}",
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        body = resp.json()
        assert body["is_active"] is True
        assert body["address"] == "Av. San Martín 123"
        assert body["account_id"] == ACCOUNT_ID
        assert body["created_by"] == USER_ID
        assert body["deactivated_at"] is None
        assert body["deactivated_by"] is None
        assert "user_id" not in body
