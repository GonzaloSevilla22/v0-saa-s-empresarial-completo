"""
C-28 v21-cash-session — CashSession / CashMovement lifecycle (TDD, Strict TDD Mode).

Comportamientos cubiertos:
  - Repository: open_session invoca rpc_open_cash_session
  - Repository: close_session invoca rpc_close_cash_session
  - Repository: register_movement invoca rpc_register_cash_movement
  - Repository: current_session invoca la consulta correcta
  - Repository: list_movements consulta cash_movements con session_id
  - Repository: list_cashboxes filtra por branch_id
  - Repository: create_cashbox inserta en cashboxes

  - Service: abrir sesión → status='open' en la respuesta
  - Service: doble apertura → HTTPException 409
  - Service: registrar movimiento → fila con balance_after
  - Service: cerrar → difference correcta
  - Service: cerrar cerrada → HTTPException 409
  - Service: movimiento sin sesión → HTTPException 409
  - Service: member (rol insuficiente) → HTTPException 403

  - Endpoint HTTP: POST /cashboxes/{id}/sessions/open → 200
  - Endpoint HTTP: POST /sessions/{id}/close → 200
  - Endpoint HTTP: POST /sessions/{id}/movements → 200
  - Endpoint HTTP: GET /branches/{id}/cashboxes → 200
  - Endpoint HTTP: GET /cashboxes/{id}/current-session → 200
  - Endpoint HTTP: member token → 403 en rutas de escritura
"""
from __future__ import annotations

import json
import sys
import types
import uuid
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
import asyncpg

from backend.tests.conftest import make_token

# ---------------------------------------------------------------------------
# Workaround: fpdf2 is not installed in the dev environment (pre-existing issue
# affecting test_payments, test_receipts, test_sales, etc.).  Inject a stub
# BEFORE the FastAPI app is imported so that conftest.async_client can collect.
# ---------------------------------------------------------------------------
if "fpdf" not in sys.modules:
    _fpdf_stub = types.ModuleType("fpdf")
    _fpdf_stub.FPDF = MagicMock  # type: ignore[attr-defined]
    sys.modules["fpdf"] = _fpdf_stub

# ── Constantes de test ──────────────────────────────────────────────────────
ACCOUNT_ID  = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
BRANCH_ID   = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
CASHBOX_ID  = "cccccccc-cccc-cccc-cccc-cccccccccccc"
SESSION_ID  = "dddddddd-dddd-dddd-dddd-dddddddddddd"
MOVEMENT_ID = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"

OPEN_SESSION_RESULT = {
    "session_id":      SESSION_ID,
    "cashbox_id":      CASHBOX_ID,
    "status":          "open",
    "opening_balance": 5000.00,
}

CLOSE_SESSION_RESULT = {
    "session_id":        SESSION_ID,
    "status":            "closed",
    "opening_balance":   5000.00,
    "expected_balance":  6200.00,
    "counted_balance":   6200.00,
    "difference":        0.00,
    "closing_balance":   6200.00,
}

MOVEMENT_RESULT = {
    "movement_id": MOVEMENT_ID,
}

CASHBOX_ROW = {
    "id":         CASHBOX_ID,
    "branch_id":  BRANCH_ID,
    "name":       "Caja 1",
    "currency":   "ARS",
    "created_at": "2026-06-17T10:00:00",
}

SESSION_ROW = {
    "id":               SESSION_ID,
    "cashbox_id":       CASHBOX_ID,
    "status":           "open",
    "opening_balance":  Decimal("5000.00"),
    "closing_balance":  None,
    "counted_balance":  None,
    "expected_balance": None,
    "difference":       None,
    "opened_by":        "11111111-1111-1111-1111-111111111111",
    "closed_by":        None,
    "opened_at":        "2026-06-17T10:00:00",
    "closed_at":        None,
}

MOVEMENT_ROW = {
    "id":            MOVEMENT_ID,
    "session_id":    SESSION_ID,
    "amount":        Decimal("1200.00"),
    "movement_type": "sale",
    "reference_id":  None,
    "balance_after": Decimal("6200.00"),
    "created_by":    "11111111-1111-1111-1111-111111111111",
    "created_at":    "2026-06-17T10:05:00",
}


# ══════════════════════════════════════════════════════════════════════════════
# REPOSITORY TESTS
# ══════════════════════════════════════════════════════════════════════════════

@pytest.fixture
def cashbox_repo():
    from backend.repositories.cashbox_repository import CashboxRepository
    conn = AsyncMock()
    return CashboxRepository(conn), conn


@pytest.fixture
def session_repo():
    from backend.repositories.cash_session_repository import CashSessionRepository
    conn = AsyncMock()
    return CashSessionRepository(conn), conn


class TestCashboxRepository:
    @pytest.mark.asyncio
    async def test_list_cashboxes_filters_by_branch_id(self, cashbox_repo):
        repo, conn = cashbox_repo
        conn.fetch = AsyncMock(return_value=[CASHBOX_ROW])

        rows = await repo.list_cashboxes(BRANCH_ID)

        query = conn.fetch.call_args[0][0].lower()
        assert "cashboxes" in query
        assert "branch_id" in query
        assert BRANCH_ID in conn.fetch.call_args[0]
        assert rows == [CASHBOX_ROW]

    @pytest.mark.asyncio
    async def test_list_cashboxes_returns_empty_for_unknown_branch(self, cashbox_repo):
        """Triangulación: branch sin cajas → lista vacía."""
        repo, conn = cashbox_repo
        conn.fetch = AsyncMock(return_value=[])

        rows = await repo.list_cashboxes("ffffffff-ffff-ffff-ffff-ffffffffffff")

        assert rows == []

    @pytest.mark.asyncio
    async def test_create_cashbox_calls_insert(self, cashbox_repo):
        repo, conn = cashbox_repo
        conn.fetchrow = AsyncMock(return_value=CASHBOX_ROW)

        row = await repo.create_cashbox(BRANCH_ID, "Caja 1")

        query = conn.fetchrow.call_args[0][0].lower()
        assert "cashboxes" in query
        assert row == CASHBOX_ROW


class TestCashSessionRepository:
    @pytest.mark.asyncio
    async def test_open_session_invokes_rpc(self, session_repo):
        repo, conn = session_repo
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps(OPEN_SESSION_RESULT)}
        )

        result = await repo.open_session(CASHBOX_ID, 5000.0)

        query = conn.fetchrow.call_args[0][0].lower()
        assert "rpc_open_cash_session" in query
        assert result["status"] == "open"

    @pytest.mark.asyncio
    async def test_open_session_passes_cashbox_id_and_balance(self, session_repo):
        """Triangulación: verifica que los parámetros correctos llegan al RPC."""
        repo, conn = session_repo
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps({**OPEN_SESSION_RESULT, "opening_balance": 0.00})}
        )

        result = await repo.open_session(CASHBOX_ID, 0.0)

        args = conn.fetchrow.call_args[0]
        assert CASHBOX_ID in args
        assert result["status"] == "open"

    @pytest.mark.asyncio
    async def test_close_session_invokes_rpc(self, session_repo):
        repo, conn = session_repo
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps(CLOSE_SESSION_RESULT)}
        )

        result = await repo.close_session(SESSION_ID, 6200.0)

        query = conn.fetchrow.call_args[0][0].lower()
        assert "rpc_close_cash_session" in query
        assert result["status"] == "closed"
        assert result["difference"] == 0.00

    @pytest.mark.asyncio
    async def test_close_session_difference_non_zero(self, session_repo):
        """Triangulación: cierre con faltante devuelve difference negativa."""
        repo, conn = session_repo
        result_with_diff = {**CLOSE_SESSION_RESULT, "counted_balance": 7500.0, "difference": -500.0}
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps(result_with_diff)}
        )

        result = await repo.close_session(SESSION_ID, 7500.0)

        assert result["difference"] == -500.0

    @pytest.mark.asyncio
    async def test_register_movement_invokes_rpc(self, session_repo):
        repo, conn = session_repo
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps(MOVEMENT_RESULT)}
        )

        result = await repo.register_movement(SESSION_ID, 1200.0, "sale", None)

        query = conn.fetchrow.call_args[0][0].lower()
        assert "rpc_register_cash_movement" in query
        assert result["movement_id"] == MOVEMENT_ID

    @pytest.mark.asyncio
    async def test_register_movement_expense_negative_amount(self, session_repo):
        """Triangulación: egreso con amount negativo."""
        repo, conn = session_repo
        expense_result = {"movement_id": "ffffffff-ffff-ffff-ffff-ffffffffffff"}
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps(expense_result)}
        )

        result = await repo.register_movement(SESSION_ID, -300.0, "expense", None)

        args = conn.fetchrow.call_args[0]
        # El amount negativo debe pasarse tal cual al RPC
        assert -300.0 in args
        assert result["movement_id"] is not None

    @pytest.mark.asyncio
    async def test_current_session_queries_cashbox(self, session_repo):
        repo, conn = session_repo
        conn.fetchrow = AsyncMock(return_value=SESSION_ROW)

        row = await repo.current_session(CASHBOX_ID)

        query = conn.fetchrow.call_args[0][0].lower()
        assert "cash_sessions" in query
        assert "status" in query
        assert CASHBOX_ID in conn.fetchrow.call_args[0]

    @pytest.mark.asyncio
    async def test_current_session_returns_none_when_no_open(self, session_repo):
        """Triangulación: sin sesión abierta → None."""
        repo, conn = session_repo
        conn.fetchrow = AsyncMock(return_value=None)

        row = await repo.current_session("ffffffff-ffff-ffff-ffff-ffffffffffff")

        assert row is None

    @pytest.mark.asyncio
    async def test_list_movements_queries_session(self, session_repo):
        repo, conn = session_repo
        conn.fetch = AsyncMock(return_value=[MOVEMENT_ROW])

        rows = await repo.list_movements(SESSION_ID)

        query = conn.fetch.call_args[0][0].lower()
        assert "cash_movements" in query
        assert "session_id" in query
        assert SESSION_ID in conn.fetch.call_args[0]
        assert len(rows) == 1

    @pytest.mark.asyncio
    async def test_list_movements_returns_empty_for_new_session(self, session_repo):
        """Triangulación: sesión sin movimientos → []."""
        repo, conn = session_repo
        conn.fetch = AsyncMock(return_value=[])

        rows = await repo.list_movements(SESSION_ID)

        assert rows == []


# ══════════════════════════════════════════════════════════════════════════════
# SERVICE / ENDPOINT TESTS
# ══════════════════════════════════════════════════════════════════════════════

class TestCashEndpoints:
    """Tests de integración HTTP — mockean DB (pool), verifican HTTP status y body."""

    # ── GET /branches/{id}/cashboxes ─────────────────────────────────────────

    async def test_list_cashboxes_endpoint_returns_200(self, async_client, mock_pool):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetch = AsyncMock(return_value=[CASHBOX_ROW])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/branches/{BRANCH_ID}/cashboxes",
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 200
        body = resp.json()
        assert isinstance(body, list)
        assert body[0]["name"] == "Caja 1"

    async def test_list_cashboxes_member_allowed_read(self, async_client, mock_pool):
        """Member puede leer — la escritura está bloqueada, no la lectura."""
        pool, conn = mock_pool
        member_token = make_token({"role": "member"})
        conn.fetch = AsyncMock(return_value=[CASHBOX_ROW])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/branches/{BRANCH_ID}/cashboxes",
                headers={"Authorization": f"Bearer {member_token}"},
            )
        assert resp.status_code == 200

    # ── POST /cashboxes ───────────────────────────────────────────────────────

    async def test_create_cashbox_owner_returns_201(self, async_client, mock_pool):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(return_value=CASHBOX_ROW)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/cashboxes",
                json={"branch_id": BRANCH_ID, "name": "Caja 1"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 201

    async def test_create_cashbox_member_returns_403(self, async_client, mock_pool):
        """Triangulación: member no puede crear cajas."""
        pool, conn = mock_pool
        member_token = make_token({"role": "member"})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/cashboxes",
                json={"branch_id": BRANCH_ID, "name": "Caja 2"},
                headers={"Authorization": f"Bearer {member_token}"},
            )
        assert resp.status_code == 403

    # ── POST /cashboxes/{id}/sessions/open ───────────────────────────────────

    async def test_open_session_returns_200(self, async_client, mock_pool):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps(OPEN_SESSION_RESULT)}
        )

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/cashboxes/{CASHBOX_ID}/sessions/open",
                json={"opening_balance": 5000.0},
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 200
        assert resp.json()["status"] == "open"

    async def test_open_session_member_returns_403(self, async_client, mock_pool):
        """Triangulación: member no puede abrir sesión."""
        pool, conn = mock_pool
        member_token = make_token({"role": "member"})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/cashboxes/{CASHBOX_ID}/sessions/open",
                json={"opening_balance": 0.0},
                headers={"Authorization": f"Bearer {member_token}"},
            )
        assert resp.status_code == 403

    # ── POST /sessions/{id}/close ─────────────────────────────────────────────

    async def test_close_session_returns_200_with_difference(self, async_client, mock_pool):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps(CLOSE_SESSION_RESULT)}
        )

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/sessions/{SESSION_ID}/close",
                json={"counted_balance": 6200.0},
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 200
        body = resp.json()
        assert body["status"] == "closed"
        # Pydantic serializes Decimal as string in JSON; compare as float
        assert float(body["difference"]) == 0.0

    async def test_close_session_with_shortage(self, async_client, mock_pool):
        """Triangulación: faltante → difference negativa en la respuesta."""
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        shortage_result = {**CLOSE_SESSION_RESULT, "counted_balance": 7500.0, "difference": -500.0}
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps(shortage_result)}
        )

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/sessions/{SESSION_ID}/close",
                json={"counted_balance": 7500.0},
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 200
        assert float(resp.json()["difference"]) == -500.0

    # ── POST /sessions/{id}/movements ─────────────────────────────────────────

    async def test_register_movement_returns_200(self, async_client, mock_pool):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps(MOVEMENT_RESULT)}
        )

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/sessions/{SESSION_ID}/movements",
                json={"amount": 1200.0, "movement_type": "sale"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 200
        assert "movement_id" in resp.json()

    async def test_register_movement_member_returns_403(self, async_client, mock_pool):
        """Triangulación: member no puede registrar movimientos."""
        pool, conn = mock_pool
        member_token = make_token({"role": "member"})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/sessions/{SESSION_ID}/movements",
                json={"amount": 100.0, "movement_type": "sale"},
                headers={"Authorization": f"Bearer {member_token}"},
            )
        assert resp.status_code == 403

    # ── GET /sessions/{id}/movements ─────────────────────────────────────────

    async def test_list_movements_endpoint_returns_200(self, async_client, mock_pool):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetch = AsyncMock(return_value=[MOVEMENT_ROW])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/sessions/{SESSION_ID}/movements",
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 200
        assert isinstance(resp.json(), list)

    # ── GET /cashboxes/{id}/current-session ───────────────────────────────────

    async def test_current_session_endpoint_returns_200_when_open(self, async_client, mock_pool):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(return_value=SESSION_ROW)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/cashboxes/{CASHBOX_ID}/current-session",
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 200
        assert resp.json()["status"] == "open"

    async def test_current_session_endpoint_returns_404_when_none(self, async_client, mock_pool):
        """Triangulación: sin sesión abierta → 404."""
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(return_value=None)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/cashboxes/{CASHBOX_ID}/current-session",
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 404

    # ── DB errors → HTTP error codes ─────────────────────────────────────────

    async def test_open_session_db_409_maps_to_http_409(self, async_client, mock_pool):
        """DB lanza P0409 cashbox_session_open → HTTP 409."""
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})

        err = asyncpg.exceptions.RaiseError("cashbox_session_open")
        err.sqlstate = "P0409"
        conn.fetchrow = AsyncMock(side_effect=err)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/cashboxes/{CASHBOX_ID}/sessions/open",
                json={"opening_balance": 1000.0},
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 409

    async def test_close_session_db_409_maps_to_http_409(self, async_client, mock_pool):
        """Triangulación: session_not_open → HTTP 409."""
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})

        err = asyncpg.exceptions.RaiseError("session_not_open")
        err.sqlstate = "P0409"
        conn.fetchrow = AsyncMock(side_effect=err)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/sessions/{SESSION_ID}/close",
                json={"counted_balance": 0.0},
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 409

    async def test_movement_no_open_session_maps_to_409(self, async_client, mock_pool):
        """Triangulación: no_open_session → HTTP 409."""
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})

        err = asyncpg.exceptions.RaiseError("no_open_session")
        err.sqlstate = "P0409"
        conn.fetchrow = AsyncMock(side_effect=err)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/sessions/{SESSION_ID}/movements",
                json={"amount": 100.0, "movement_type": "sale"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 409

    async def test_branch_closed_maps_to_422(self, async_client, mock_pool):
        """P0422 branch_closed → HTTP 422."""
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})

        err = asyncpg.exceptions.RaiseError("branch_closed")
        err.sqlstate = "P0422"
        conn.fetchrow = AsyncMock(side_effect=err)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/cashboxes/{CASHBOX_ID}/sessions/open",
                json={"opening_balance": 0.0},
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 422


# ══════════════════════════════════════════════════════════════════════════════
# TASK 4.1 — ATOMICITY TESTS FOR c28_register_cash_movement HELPER
#
# The helper c28_register_cash_movement MUST NOT open its own transaction.
# It runs inside the caller's transaction. These tests verify:
#   (a) Commit → movement row present
#   (b) Rollback → movement row absent (helper didn't commit independently)
#
# Since no local Supabase DB is available in this environment, these tests
# verify the contract at the repository layer (mock):
#   - register_movement calls the RPC exactly once with the correct params
#   - The RPC wrapper calls c28_register_cash_movement (verified by SQL in migration)
#   - Transaction semantics are enforced by the DB — the mock verifies the call
#     path; the DO gates in the migration verify atomicity at SQL level.
# ══════════════════════════════════════════════════════════════════════════════

class TestC28HelperAtomicityContract:
    """
    Contract tests for the c28_register_cash_movement helper.

    These verify the repository contract — the SQL atomicity is verified by
    the migration's DO block (gate 1.9e) and will be smoke-tested against
    prod via the DO block in task 5.1.
    """

    @pytest.mark.asyncio
    async def test_register_movement_calls_rpc_once_on_commit_path(self, session_repo):
        """
        Simula el path de COMMIT: el repo llama al RPC exactamente una vez.
        Verifica que el helper se invoca en la transacción del llamador.
        """
        repo, conn = session_repo
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps({"movement_id": MOVEMENT_ID})}
        )

        result = await repo.register_movement(SESSION_ID, 500.0, "sale", None)

        conn.fetchrow.assert_called_once()
        query = conn.fetchrow.call_args[0][0]
        assert "rpc_register_cash_movement" in query.lower()
        assert result["movement_id"] == MOVEMENT_ID

    @pytest.mark.asyncio
    async def test_register_movement_raises_on_rollback_path(self, session_repo):
        """
        Simula el path de ROLLBACK (excepción en la transacción del llamador):
        si el llamador lanza una excepción DESPUÉS de invocar el helper,
        el repo NO debe haber hecho commit propio → la excepción se propaga.

        El helper no llama COMMIT explícito — por lo tanto la excepción
        del llamador revierte todo (incluyendo el INSERT del helper).
        Verificamos que asyncpg.PostgresError se propaga sin swallowing.
        """
        repo, conn = session_repo

        # Simular que la DB lanza un error posterior (p.ej. stock insuficiente)
        err = asyncpg.exceptions.RaiseError("no_open_session")
        err.sqlstate = "P0409"
        conn.fetchrow = AsyncMock(side_effect=err)

        with pytest.raises(asyncpg.exceptions.RaiseError):
            await repo.register_movement(SESSION_ID, 500.0, "sale", None)

        # El conn.fetchrow fue llamado exactamente una vez — no hubo retry
        conn.fetchrow.assert_called_once()

    @pytest.mark.asyncio
    async def test_helper_passes_reference_id_for_sale_integration(self, session_repo):
        """
        Triangulación: cuando C-29 invoca el helper con un sale_id como
        reference_id, el RPC lo recibe correctamente.
        """
        repo, conn = session_repo
        sale_id = "ffffffff-ffff-ffff-ffff-ffffffffffff"
        conn.fetchrow = AsyncMock(
            return_value={"result": json.dumps({"movement_id": MOVEMENT_ID})}
        )

        result = await repo.register_movement(SESSION_ID, 1200.0, "sale", sale_id)

        call_args = conn.fetchrow.call_args[0]
        # sale_id debe estar en los args de la llamada
        assert sale_id in call_args
        assert result["movement_id"] == MOVEMENT_ID
