"""
facturar-venta-manual — Tests TDD (Strict TDD Mode).

Comportamientos cubiertos:
  ── Repository (SalesRepository.promote_to_order) ─────────────────────────────
  - happy path: invoca rpc_promote_legacy_sale_to_order y devuelve sales_order_id
  - idempotencia: segunda promoción devuelve replayed=true
  - error Postgres propagado sin swallowing (P0404 / P0401)

  ── Service (sales.promote_to_order) ─────────────────────────────────────────
  - guard require_role: miembro sin permiso → 403
  - happy path: devuelve el dict del repo
  - P0401 → 403 (sin permiso de escritura Supabase)
  - P0404 → 404 (operación no encontrada)
  - P0409 / P0422 → 409 (conflicto)

  ── Schema (PromoteToOrderOut) ────────────────────────────────────────────────
  - validación Pydantic v2: sales_order_id, sale_operation_id, replayed
  - campo faltante → ValidationError

  ── Endpoint HTTP (POST /sales/{operation_id}/promote-to-order) ───────────────
  - writer → 200 con schema correcto
  - member → 403
  - operación inexistente → 404
  - doble llamada → 200 con replayed=true (idempotencia)
"""
from __future__ import annotations

import json
import sys
import types
import uuid
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock, patch

import asyncpg
import pytest

from backend.tests.conftest import make_token

# ── Workaround fpdf2 (pre-existing issue) ─────────────────────────────────────
try:
    import fpdf  # noqa: F401
except ImportError:
    _fpdf_stub = types.ModuleType("fpdf")
    _fpdf_stub.FPDF = MagicMock  # type: ignore[attr-defined]
    sys.modules["fpdf"] = _fpdf_stub

# ── Constantes de test ─────────────────────────────────────────────────────────
ACCOUNT_ID     = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
OPERATION_ID   = "ffffffff-ffff-ffff-ffff-ffffffffffff"
ORDER_ID       = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"

PROMOTE_RPC_RESULT_NEW = {
    "sales_order_id":    ORDER_ID,
    "sale_operation_id": OPERATION_ID,
    "replayed":          False,
}

PROMOTE_RPC_RESULT_REPLAYED = {
    "sales_order_id":    ORDER_ID,
    "sale_operation_id": OPERATION_ID,
    "replayed":          True,
}


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture
def sales_repo():
    from backend.repositories.sales_repository import SalesRepository
    conn = AsyncMock()
    return SalesRepository(conn), conn


# ══════════════════════════════════════════════════════════════════════════════
# TASK 2.1 RED — SalesRepository.promote_to_order (happy path)
# ══════════════════════════════════════════════════════════════════════════════

class TestSalesRepositoryPromoteToOrder:
    """2.1/2.2/2.3 — Repository TDD."""

    @pytest.mark.asyncio
    async def test_promote_to_order_invokes_rpc(self, sales_repo):
        """
        2.1 RED / 2.2 GREEN:
        promote_to_order llama rpc_promote_legacy_sale_to_order y
        devuelve el sales_order_id del resultado.
        """
        repo, conn = sales_repo
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps(PROMOTE_RPC_RESULT_NEW)}
        )

        result = await repo.promote_to_order(OPERATION_ID)

        # La query debe llamar a la RPC
        query = conn.fetchrow.call_args[0][0].lower()
        assert "rpc_promote_legacy_sale_to_order" in query
        assert result["sales_order_id"] == ORDER_ID
        assert result["replayed"] is False

    @pytest.mark.asyncio
    async def test_promote_to_order_passes_operation_id(self, sales_repo):
        """
        2.2 GREEN / 2.3 TRIANGULATE:
        La RPC recibe el operation_id como argumento.
        """
        repo, conn = sales_repo
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps(PROMOTE_RPC_RESULT_NEW)}
        )

        await repo.promote_to_order(OPERATION_ID)

        args = conn.fetchrow.call_args[0]
        assert OPERATION_ID in args

    @pytest.mark.asyncio
    async def test_promote_to_order_idempotent_returns_replayed(self, sales_repo):
        """
        2.3 TRIANGULATE:
        Segunda promoción devuelve replayed=true y el mismo sales_order_id.
        """
        repo, conn = sales_repo
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps(PROMOTE_RPC_RESULT_REPLAYED)}
        )

        result = await repo.promote_to_order(OPERATION_ID)

        assert result["replayed"] is True
        assert result["sales_order_id"] == ORDER_ID

    @pytest.mark.asyncio
    async def test_promote_to_order_propagates_p0404(self, sales_repo):
        """
        2.3 TRIANGULATE:
        Error Postgres P0404 se propaga sin swallowing.
        """
        repo, conn = sales_repo
        err = asyncpg.exceptions.RaiseError("operation_not_found")
        err.sqlstate = "P0404"
        conn.fetchrow = AsyncMock(side_effect=err)

        with pytest.raises(asyncpg.exceptions.RaiseError):
            await repo.promote_to_order(OPERATION_ID)

    @pytest.mark.asyncio
    async def test_promote_to_order_propagates_p0401(self, sales_repo):
        """
        2.3 TRIANGULATE:
        Error Postgres P0401 (sin permiso de escritura) se propaga.
        """
        repo, conn = sales_repo
        err = asyncpg.exceptions.RaiseError("unauthorized")
        err.sqlstate = "P0401"
        conn.fetchrow = AsyncMock(side_effect=err)

        with pytest.raises(asyncpg.exceptions.RaiseError):
            await repo.promote_to_order(OPERATION_ID)


# ══════════════════════════════════════════════════════════════════════════════
# TASK 3.1/3.2/3.3 — Service promote_to_order (TDD)
# ══════════════════════════════════════════════════════════════════════════════

class TestSalesServicePromoteToOrder:
    """3.1/3.2/3.3 — Service TDD."""

    @pytest.mark.asyncio
    async def test_promote_member_returns_403(self):
        """
        3.1 RED / 3.2 GREEN:
        Rol 'member' no puede promover → HTTPException 403.
        """
        from fastapi import HTTPException
        from backend.services import sales as sales_service

        member_auth = {"role": "member"}
        repo = AsyncMock()

        with pytest.raises(HTTPException) as exc_info:
            await sales_service.promote_to_order(
                repo=repo, auth=member_auth, operation_id=OPERATION_ID
            )

        assert exc_info.value.status_code == 403

    @pytest.mark.asyncio
    async def test_promote_writer_returns_result(self):
        """
        3.2 GREEN:
        Escritor puede promover → devuelve el dict del repo.
        """
        from backend.services import sales as sales_service

        writer_auth = {"role": "user"}
        repo = AsyncMock()
        repo.promote_to_order = AsyncMock(return_value=PROMOTE_RPC_RESULT_NEW)

        result = await sales_service.promote_to_order(
            repo=repo, auth=writer_auth, operation_id=OPERATION_ID
        )

        assert result["sales_order_id"] == ORDER_ID
        assert result["replayed"] is False

    @pytest.mark.asyncio
    async def test_promote_p0401_maps_to_403(self):
        """
        3.3 TRIANGULATE:
        DB lanza P0401 (sin permiso de escritura sobre la cuenta) → 403.
        """
        from fastapi import HTTPException
        from backend.services import sales as sales_service

        writer_auth = {"role": "user"}
        repo = AsyncMock()
        err = asyncpg.exceptions.RaiseError("unauthorized")
        err.sqlstate = "P0401"
        repo.promote_to_order = AsyncMock(side_effect=err)

        with pytest.raises(HTTPException) as exc_info:
            await sales_service.promote_to_order(
                repo=repo, auth=writer_auth, operation_id=OPERATION_ID
            )

        assert exc_info.value.status_code == 403

    @pytest.mark.asyncio
    async def test_promote_p0404_maps_to_404(self):
        """
        3.3 TRIANGULATE:
        Operación inexistente (P0404) → 404.
        """
        from fastapi import HTTPException
        from backend.services import sales as sales_service

        writer_auth = {"role": "user"}
        repo = AsyncMock()
        err = asyncpg.exceptions.RaiseError("operation_not_found")
        err.sqlstate = "P0404"
        repo.promote_to_order = AsyncMock(side_effect=err)

        with pytest.raises(HTTPException) as exc_info:
            await sales_service.promote_to_order(
                repo=repo, auth=writer_auth, operation_id=OPERATION_ID
            )

        assert exc_info.value.status_code == 404

    @pytest.mark.asyncio
    async def test_promote_p0422_maps_to_409(self):
        """
        3.3 TRIANGULATE:
        Branch no resoluble (P0422) → 409.
        """
        from fastapi import HTTPException
        from backend.services import sales as sales_service

        writer_auth = {"role": "user"}
        repo = AsyncMock()
        err = asyncpg.exceptions.RaiseError("no_branch_found")
        err.sqlstate = "P0422"
        repo.promote_to_order = AsyncMock(side_effect=err)

        with pytest.raises(HTTPException) as exc_info:
            await sales_service.promote_to_order(
                repo=repo, auth=writer_auth, operation_id=OPERATION_ID
            )

        assert exc_info.value.status_code == 409

    @pytest.mark.asyncio
    async def test_promote_admin_can_promote(self):
        """
        3.3 TRIANGULATE:
        Rol 'admin' también puede promover (guard acepta user + admin).
        """
        from backend.services import sales as sales_service

        admin_auth = {"role": "admin"}
        repo = AsyncMock()
        repo.promote_to_order = AsyncMock(return_value=PROMOTE_RPC_RESULT_REPLAYED)

        result = await sales_service.promote_to_order(
            repo=repo, auth=admin_auth, operation_id=OPERATION_ID
        )

        assert result["replayed"] is True


# ══════════════════════════════════════════════════════════════════════════════
# TASK 4.1 RED — Schema PromoteToOrderOut (Pydantic v2)
# ══════════════════════════════════════════════════════════════════════════════

class TestPromoteToOrderSchema:
    """4.1 — Schema TDD."""

    def test_schema_valid_new_promotion(self):
        """
        4.1 RED / GREEN:
        Schema acepta sales_order_id, sale_operation_id, replayed=False.
        """
        from backend.schemas.sales import PromoteToOrderOut

        obj = PromoteToOrderOut(
            sales_order_id=uuid.UUID(ORDER_ID),
            sale_operation_id=uuid.UUID(OPERATION_ID),
            replayed=False,
        )

        assert str(obj.sales_order_id) == ORDER_ID
        assert obj.replayed is False

    def test_schema_valid_replayed(self):
        """
        4.1 TRIANGULATE:
        Schema acepta replayed=True (segunda llamada idempotente).
        """
        from backend.schemas.sales import PromoteToOrderOut

        obj = PromoteToOrderOut(
            sales_order_id=uuid.UUID(ORDER_ID),
            sale_operation_id=uuid.UUID(OPERATION_ID),
            replayed=True,
        )

        assert obj.replayed is True

    def test_schema_missing_sales_order_id_raises(self):
        """
        4.1 TRIANGULATE:
        Campo requerido faltante → ValidationError.
        """
        from pydantic import ValidationError
        from backend.schemas.sales import PromoteToOrderOut

        with pytest.raises(ValidationError):
            PromoteToOrderOut(  # type: ignore[call-arg]
                sale_operation_id=uuid.UUID(OPERATION_ID),
                replayed=False,
            )


# ══════════════════════════════════════════════════════════════════════════════
# TASK 4.2/4.3/4.4 — Endpoint HTTP (TDD)
# ══════════════════════════════════════════════════════════════════════════════

class TestPromoteToOrderEndpoint:
    """4.2/4.3/4.4 — Router TDD."""

    async def test_promote_writer_returns_200(self, async_client, mock_pool):
        """
        4.2 RED / 4.3 GREEN:
        POST /sales/{operation_id}/promote-to-order con token writer → 200.
        """
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps(PROMOTE_RPC_RESULT_NEW)}
        )

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/sales/{OPERATION_ID}/promote-to-order",
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        body = resp.json()
        assert body["sales_order_id"] == ORDER_ID
        assert body["replayed"] is False

    async def test_promote_member_returns_403(self, async_client, mock_pool):
        """
        4.4 TRIANGULATE:
        Token member → 403 sin tocar la DB.
        """
        pool, conn = mock_pool
        member_token = make_token({"role": "member"})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/sales/{OPERATION_ID}/promote-to-order",
                headers={"Authorization": f"Bearer {member_token}"},
            )

        assert resp.status_code == 403

    async def test_promote_operation_not_found_returns_404(self, async_client, mock_pool):
        """
        4.4 TRIANGULATE:
        DB lanza P0404 → 404.
        """
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        err = asyncpg.exceptions.RaiseError("operation_not_found")
        err.sqlstate = "P0404"
        conn.fetchrow = AsyncMock(side_effect=err)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/sales/{OPERATION_ID}/promote-to-order",
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 404

    async def test_promote_no_branch_returns_409(self, async_client, mock_pool):
        """
        4.4 TRIANGULATE:
        DB lanza P0422 (sin branch) → 409.
        """
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        err = asyncpg.exceptions.RaiseError("no_branch_found")
        err.sqlstate = "P0422"
        conn.fetchrow = AsyncMock(side_effect=err)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/sales/{OPERATION_ID}/promote-to-order",
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 409

    async def test_promote_idempotent_returns_200_replayed(self, async_client, mock_pool):
        """
        4.4 TRIANGULATE:
        Segunda llamada devuelve 200 con replayed=true (idempotencia).
        """
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps(PROMOTE_RPC_RESULT_REPLAYED)}
        )

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/sales/{OPERATION_ID}/promote-to-order",
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        assert resp.json()["replayed"] is True
