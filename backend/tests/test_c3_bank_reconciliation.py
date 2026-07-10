"""
bank-reconciliation C3 — Tests TDD (Strict TDD Mode).

Comportamientos cubiertos:
  ── Migración SQL (contenido) ─────────────────────────────────────────────────
  - El CHECK de operation_idempotency incluye 'bank_statement_import' (regla C-30)
  - Índices UNIQUE parciales: anti doble-apertura + anti doble-match
  - Las 5 RPCs de C3 existen en la migración y no referencian el journal
  - rpc_register_bank_movement amplía tipos manuales (fee/tax_debit/interest)

  ── errors.py ─────────────────────────────────────────────────────────────────
  - P0431/P0432/P0433/P0434 (C3) y P0410/P0411/P0412 (C1, gap) mapeados a HTTP

  ── Schemas Pydantic ──────────────────────────────────────────────────────────
  - StatementImportIn: happy, cap 5000, lines vacías, línea sin value_date
  - MatchCreateIn: al menos 1 línea y 1 movimiento
  - UndoMatchIn: undo_reason obligatorio (RN-A5)

  ── Repository ────────────────────────────────────────────────────────────────
  - import_statement / open_session / create_match / undo_match / close_session
    invocan la RPC correcta con los args correctos
  - suggestions: query con ventana de fecha ±3 días y ambos sin match activo

  ── Service ───────────────────────────────────────────────────────────────────
  - Mutaciones exigen require_role(["user","admin"]) y propagan al repo

  ── Endpoints HTTP ────────────────────────────────────────────────────────────
  - POST import → 200; POST open → 200; POST match → 200; POST undo → 200;
    POST close → 200; GET suggestions → 200
  - Errores de dominio: P0433 → 422, P0434 → 409, P0432 → 409, P0431 → 422

Run: python -m pytest backend/tests/test_c3_bank_reconciliation.py
"""
from __future__ import annotations

import json
import sys
import types
import uuid
from datetime import date
from decimal import Decimal
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import asyncpg
import pytest

from backend.tests.conftest import make_token

# ── Workaround fpdf2 (pre-existing issue, mismo patrón que test_c30/test_c2) ──
try:
    import fpdf  # noqa: F401
except ImportError:
    _fpdf_stub = types.ModuleType("fpdf")
    _fpdf_stub.FPDF = MagicMock  # type: ignore[attr-defined]
    sys.modules["fpdf"] = _fpdf_stub

# ── Constantes de test ─────────────────────────────────────────────────────────
ACCOUNT_ID      = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
BANK_ACCOUNT_ID = "99999999-9999-9999-9999-999999999999"
IMPORT_ID       = "22222222-2222-2222-2222-222222222222"
SESSION_ID      = "33333333-3333-3333-3333-333333333333"
MATCH_GROUP     = "44444444-4444-4444-4444-444444444444"
LINE_ID         = "55555555-5555-5555-5555-555555555555"
MOVEMENT_ID     = "66666666-6666-6666-6666-666666666666"
IDEMPOTENCY_KEY = "test-idem-c3-recon-001"

MIGRATION_PATH = Path("supabase/migrations/20260805000001_bank_reconciliation.sql")


def _lines(n: int = 1) -> list[dict]:
    return [
        {
            "line_no": i + 1,
            "value_date": "2026-07-15",
            "description": f"linea {i + 1}",
            "amount": "100.00",
            "balance": None,
        }
        for i in range(n)
    ]


def _pg_error(sqlstate: str, message: str = "err") -> asyncpg.PostgresError:
    """Construye un asyncpg.PostgresError con sqlstate custom (como los RAISE de las RPCs)."""
    err = asyncpg.PostgresError(message)
    err.sqlstate = sqlstate
    return err


# ═══════════════════════════════════════════════════════════════════════════════
# Section 1: Migración SQL — contenido (corre desde la RAÍZ del repo, gotcha C-25)
# ═══════════════════════════════════════════════════════════════════════════════

class TestMigrationContent:
    @pytest.fixture(scope="class")
    def sql(self) -> str:
        assert MIGRATION_PATH.exists(), f"migración no encontrada: {MIGRATION_PATH}"
        return MIGRATION_PATH.read_text(encoding="utf-8")

    def test_operation_kind_check_extended(self, sql):
        """Regla C-30: el CHECK se extiende en la misma migración que agrega el kind."""
        assert "'bank_statement_import'" in sql
        assert "operation_idempotency_operation_kind_check" in sql

    def test_operation_kind_check_preserves_all_existing_kinds(self, sql):
        """Regresión del incidente de deploy 2026-07-02: el DROP+ADD debe reproducir
        la UNIÓN de kinds vigente en prod — omitir uno con filas existentes rompe el
        db push con 23514 (CI no lo atrapa: su DB nace vacía)."""
        for kind in (
            "'sale'",
            "'purchase'",
            "'payment_received'",
            "'payment_made'",
            "'supplier_charge'",
            "'bank_movement'",
            "'event_consumer'",  # hotfix outbox 20260804000005 — el que faltó
            "'bank_statement_import'",
        ):
            assert kind in sql, f"falta {kind} en el CHECK de operation_kind"

    def test_anti_double_open_unique_partial_index(self, sql):
        assert "reconciliation_sessions_one_open_idx" in sql
        assert "WHERE status = 'open'" in sql

    def test_anti_double_match_unique_partial_indexes(self, sql):
        assert "reconciliation_matches_active_line_uq" in sql
        assert "reconciliation_matches_active_movement_uq" in sql

    def test_all_five_rpcs_present(self, sql):
        for rpc in (
            "rpc_import_bank_statement",
            "rpc_open_reconciliation_session",
            "rpc_close_reconciliation_session",
            "rpc_create_reconciliation_match",
            "rpc_undo_reconciliation_match",
        ):
            assert f"CREATE OR REPLACE FUNCTION public.{rpc}" in sql, rpc

    def test_manual_movement_types_expanded(self, sql):
        """C3 amplía la carga manual: fee/tax_debit/interest; card_settlement sigue P0410."""
        assert "'fee', 'tax_debit', 'interest'" in sql
        assert "P0410" in sql

    def test_reconciliation_rpcs_do_not_touch_journal(self, sql):
        """Gate negativo: la conciliación NUNCA postea al journal (dos ledgers)."""
        # El único uso permitido de la palabra journal es en comentarios/gates;
        # ninguna RPC de C3 debe hacer INSERT INTO journal_*.
        assert "INSERT INTO public.journal_entries" not in sql
        assert "INSERT INTO public.journal_lines" not in sql

    def test_bank_movements_reconciliation_columns(self, sql):
        assert "reconciliation_status" in sql
        assert "'unreconciled'" in sql
        assert "reconciled_at" in sql


# ═══════════════════════════════════════════════════════════════════════════════
# Section 2: errors.py — mapeo de ERRCODEs nuevos
# ═══════════════════════════════════════════════════════════════════════════════

class TestBusinessErrcodeMapping:
    def test_c3_errcodes_mapped(self):
        from backend.core.errors import _BUSINESS_ERRCODE_STATUS

        assert _BUSINESS_ERRCODE_STATUS["P0431"] == 422  # motivo requerido
        assert _BUSINESS_ERRCODE_STATUS["P0432"] == 409  # sesión cerrada (terminal)
        assert _BUSINESS_ERRCODE_STATUS["P0433"] == 422  # sumas desbalanceadas
        assert _BUSINESS_ERRCODE_STATUS["P0434"] == 409  # ya matcheado

    def test_c1_errcodes_gap_fixed(self):
        """P0410/P0411/P0412 (C1 bank-ledger) no estaban mapeados → caían en 500."""
        from backend.core.errors import _BUSINESS_ERRCODE_STATUS

        assert _BUSINESS_ERRCODE_STATUS["P0410"] == 422  # tipo reservado
        assert _BUSINESS_ERRCODE_STATUS["P0411"] == 422  # CBU inválido
        assert _BUSINESS_ERRCODE_STATUS["P0412"] == 404  # cuenta no encontrada/inactiva


# ═══════════════════════════════════════════════════════════════════════════════
# Section 3: Schemas Pydantic v2
# ═══════════════════════════════════════════════════════════════════════════════

class TestStatementImportSchema:
    def test_happy_path(self):
        from backend.schemas.bank_reconciliation import StatementImportIn

        payload = StatementImportIn(
            idempotency_key=IDEMPOTENCY_KEY,
            file_name="extracto-julio.csv",
            file_hash="a" * 64,
            lines=_lines(3),
        )
        assert payload.lines[0].line_no == 1
        assert payload.lines[0].value_date == date(2026, 7, 15)
        assert payload.lines[0].amount == Decimal("100.00")

    def test_rejects_empty_lines(self):
        from pydantic import ValidationError

        from backend.schemas.bank_reconciliation import StatementImportIn

        with pytest.raises(ValidationError):
            StatementImportIn(
                idempotency_key=IDEMPOTENCY_KEY,
                file_name="x.csv",
                file_hash="a" * 64,
                lines=[],
            )

    def test_rejects_over_cap_5000(self):
        from pydantic import ValidationError

        from backend.schemas.bank_reconciliation import StatementImportIn

        with pytest.raises(ValidationError):
            StatementImportIn(
                idempotency_key=IDEMPOTENCY_KEY,
                file_name="x.csv",
                file_hash="a" * 64,
                lines=_lines(5001),
            )

    def test_rejects_line_without_value_date(self):
        from pydantic import ValidationError

        from backend.schemas.bank_reconciliation import StatementImportIn

        bad = _lines(1)
        bad[0]["value_date"] = None
        with pytest.raises(ValidationError):
            StatementImportIn(
                idempotency_key=IDEMPOTENCY_KEY,
                file_name="x.csv",
                file_hash="a" * 64,
                lines=bad,
            )


class TestMatchAndUndoSchemas:
    def test_match_requires_both_sides(self):
        from pydantic import ValidationError

        from backend.schemas.bank_reconciliation import MatchCreateIn

        with pytest.raises(ValidationError):
            MatchCreateIn(statement_line_ids=[], bank_movement_ids=[uuid.UUID(MOVEMENT_ID)])
        with pytest.raises(ValidationError):
            MatchCreateIn(statement_line_ids=[uuid.UUID(LINE_ID)], bank_movement_ids=[])

    def test_match_accepts_one_to_many(self):
        from backend.schemas.bank_reconciliation import MatchCreateIn

        payload = MatchCreateIn(
            statement_line_ids=[uuid.UUID(LINE_ID)],
            bank_movement_ids=[uuid.UUID(MOVEMENT_ID), uuid.UUID(SESSION_ID)],
        )
        assert len(payload.bank_movement_ids) == 2

    def test_undo_requires_reason(self):
        from pydantic import ValidationError

        from backend.schemas.bank_reconciliation import UndoMatchIn

        with pytest.raises(ValidationError):
            UndoMatchIn(undo_reason="")
        ok = UndoMatchIn(undo_reason="monto correspondía a otra transferencia")
        assert ok.undo_reason.startswith("monto")

    def test_close_reason_optional(self):
        from backend.schemas.bank_reconciliation import SessionCloseIn

        assert SessionCloseIn().close_reason is None
        assert SessionCloseIn(close_reason="dif por transferencia pendiente").close_reason


# ═══════════════════════════════════════════════════════════════════════════════
# Section 4: Repository — invocación de RPCs y queries de lectura
# ═══════════════════════════════════════════════════════════════════════════════

def _repo(fetchrow_result=None, fetch_result=None):
    from backend.repositories.bank_reconciliation_repository import (
        BankReconciliationRepository,
    )

    conn = AsyncMock()
    conn.fetchrow = AsyncMock(return_value=fetchrow_result)
    conn.fetch = AsyncMock(return_value=fetch_result or [])
    return BankReconciliationRepository(conn), conn


class TestRepositoryRpcCalls:
    @pytest.mark.asyncio
    async def test_import_statement_calls_rpc(self):
        result = json.dumps({"import_id": IMPORT_ID, "line_count": 1, "replayed": False})
        repo, conn = _repo(fetchrow_result={"result": result})

        out = await repo.import_statement(
            idempotency_key=IDEMPOTENCY_KEY,
            bank_account_id=BANK_ACCOUNT_ID,
            file_name="x.csv",
            file_hash="a" * 64,
            lines_json=json.dumps(_lines(1)),
        )

        query = conn.fetchrow.call_args.args[0]
        assert "rpc_import_bank_statement" in query
        assert out["import_id"] == IMPORT_ID

    @pytest.mark.asyncio
    async def test_open_session_calls_rpc(self):
        result = json.dumps({"session_id": SESSION_ID, "status": "open"})
        repo, conn = _repo(fetchrow_result={"result": result})

        out = await repo.open_session(
            bank_account_id=BANK_ACCOUNT_ID,
            period_from=date(2026, 7, 1),
            period_to=date(2026, 7, 31),
            statement_closing_balance=Decimal("14750.00"),
        )

        query = conn.fetchrow.call_args.args[0]
        assert "rpc_open_reconciliation_session" in query
        assert out["session_id"] == SESSION_ID

    @pytest.mark.asyncio
    async def test_create_match_calls_rpc_with_arrays(self):
        result = json.dumps({"match_group": MATCH_GROUP, "line_count": 1, "movement_count": 1})
        repo, conn = _repo(fetchrow_result={"result": result})

        out = await repo.create_match(
            session_id=SESSION_ID,
            statement_line_ids=[LINE_ID],
            bank_movement_ids=[MOVEMENT_ID],
        )

        query = conn.fetchrow.call_args.args[0]
        assert "rpc_create_reconciliation_match" in query
        assert out["match_group"] == MATCH_GROUP

    @pytest.mark.asyncio
    async def test_undo_match_calls_rpc(self):
        result = json.dumps({"match_group": MATCH_GROUP, "status": "undone"})
        repo, conn = _repo(fetchrow_result={"result": result})

        out = await repo.undo_match(match_group=MATCH_GROUP, undo_reason="error de carga")

        query = conn.fetchrow.call_args.args[0]
        assert "rpc_undo_reconciliation_match" in query
        assert out["status"] == "undone"

    @pytest.mark.asyncio
    async def test_close_session_calls_rpc(self):
        result = json.dumps({"session_id": SESSION_ID, "status": "closed", "difference": "0.00"})
        repo, conn = _repo(fetchrow_result={"result": result})

        out = await repo.close_session(session_id=SESSION_ID, close_reason=None)

        query = conn.fetchrow.call_args.args[0]
        assert "rpc_close_reconciliation_session" in query
        assert out["status"] == "closed"


class TestRepositoryReads:
    @pytest.mark.asyncio
    async def test_suggestions_query_shape(self):
        """Sugerencias 1:1: monto exacto + ventana ±3 días + ambos sin match activo."""
        repo, conn = _repo(fetch_result=[])

        await repo.suggestions(
            bank_account_id=BANK_ACCOUNT_ID,
            period_from=date(2026, 7, 1),
            period_to=date(2026, 7, 31),
        )

        query = conn.fetch.call_args.args[0]
        assert "l.amount = bm.amount" in query
        assert "3" in query  # ventana ±3 días (D4)
        assert "status = 'active'" in query

    @pytest.mark.asyncio
    async def test_pending_lines_excludes_matched(self):
        repo, conn = _repo(fetch_result=[])

        await repo.pending_lines(
            bank_account_id=BANK_ACCOUNT_ID,
            period_from=date(2026, 7, 1),
            period_to=date(2026, 7, 31),
        )

        query = conn.fetch.call_args.args[0]
        assert "NOT EXISTS" in query
        assert "reconciliation_matches" in query

    @pytest.mark.asyncio
    async def test_pending_movements_filters_unreconciled(self):
        repo, conn = _repo(fetch_result=[])

        await repo.pending_movements(
            bank_account_id=BANK_ACCOUNT_ID,
            period_to=date(2026, 7, 31),
        )

        query = conn.fetch.call_args.args[0]
        assert "reconciliation_status = 'unreconciled'" in query


# ═══════════════════════════════════════════════════════════════════════════════
# Section 5: Service — guards y propagación
# ═══════════════════════════════════════════════════════════════════════════════

class TestService:
    @pytest.mark.asyncio
    async def test_import_requires_role(self):
        from fastapi import HTTPException

        from backend.services import bank_reconciliation as svc

        repo = AsyncMock()
        with pytest.raises(HTTPException) as exc:
            await svc.import_statement(
                repo,
                {"role": "viewer"},
                bank_account_id=BANK_ACCOUNT_ID,
                idempotency_key=IDEMPOTENCY_KEY,
                file_name="x.csv",
                file_hash="a" * 64,
                lines_json="[]",
            )
        assert exc.value.status_code == 403
        repo.import_statement.assert_not_called()

    @pytest.mark.asyncio
    async def test_import_propagates_to_repo(self):
        from backend.services import bank_reconciliation as svc

        repo = AsyncMock()
        repo.import_statement = AsyncMock(return_value={"import_id": IMPORT_ID, "replayed": False})

        out = await svc.import_statement(
            repo,
            {"role": "user"},
            bank_account_id=BANK_ACCOUNT_ID,
            idempotency_key=IDEMPOTENCY_KEY,
            file_name="x.csv",
            file_hash="a" * 64,
            lines_json="[]",
        )
        assert out["import_id"] == IMPORT_ID
        repo.import_statement.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_close_propagates_reason(self):
        from backend.services import bank_reconciliation as svc

        repo = AsyncMock()
        repo.close_session = AsyncMock(return_value={"status": "closed"})

        await svc.close_session(
            repo, {"role": "admin"}, session_id=SESSION_ID, close_reason="dif pendiente"
        )
        repo.close_session.assert_awaited_once_with(
            session_id=SESSION_ID, close_reason="dif pendiente"
        )


# ═══════════════════════════════════════════════════════════════════════════════
# Section 6: Endpoints HTTP
# ═══════════════════════════════════════════════════════════════════════════════

class TestEndpoints:
    @pytest.mark.asyncio
    async def test_post_import_returns_200(self, async_client, mock_pool):
        pool, conn = mock_pool
        rpc_result = json.dumps({
            "import_id": IMPORT_ID,
            "line_count": 3,
            "period_from": "2026-07-15",
            "period_to": "2026-07-25",
            "replayed": False,
        })
        conn.fetchrow = AsyncMock(return_value={"result": rpc_result})

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.post(
                f"/bank-accounts/{BANK_ACCOUNT_ID}/statement-imports",
                json={
                    "idempotency_key": IDEMPOTENCY_KEY,
                    "file_name": "extracto-julio.csv",
                    "file_hash": "a" * 64,
                    "lines": _lines(3),
                },
                headers=headers,
            )

        assert response.status_code == 200
        assert response.json()["import_id"] == IMPORT_ID

    @pytest.mark.asyncio
    async def test_post_open_session_returns_200(self, async_client, mock_pool):
        pool, conn = mock_pool
        rpc_result = json.dumps({
            "session_id": SESSION_ID,
            "bank_account_id": BANK_ACCOUNT_ID,
            "status": "open",
            "period_from": "2026-07-01",
            "period_to": "2026-07-31",
            "statement_closing_balance": "14750.00",
        })
        conn.fetchrow = AsyncMock(return_value={"result": rpc_result})

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.post(
                f"/bank-accounts/{BANK_ACCOUNT_ID}/reconciliation-sessions",
                json={
                    "period_from": "2026-07-01",
                    "period_to": "2026-07-31",
                    "statement_closing_balance": "14750.00",
                },
                headers=headers,
            )

        assert response.status_code == 200
        assert response.json()["session_id"] == SESSION_ID

    @pytest.mark.asyncio
    async def test_post_match_returns_200(self, async_client, mock_pool):
        pool, conn = mock_pool
        rpc_result = json.dumps({
            "match_group": MATCH_GROUP,
            "session_id": SESSION_ID,
            "line_count": 1,
            "movement_count": 1,
            "amount": "5000.00",
        })
        conn.fetchrow = AsyncMock(return_value={"result": rpc_result})

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.post(
                f"/reconciliation-sessions/{SESSION_ID}/matches",
                json={
                    "statement_line_ids": [LINE_ID],
                    "bank_movement_ids": [MOVEMENT_ID],
                },
                headers=headers,
            )

        assert response.status_code == 200
        assert response.json()["match_group"] == MATCH_GROUP

    @pytest.mark.asyncio
    async def test_post_match_amounts_mismatch_returns_422(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(side_effect=_pg_error("P0433", "amounts_mismatch"))

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.post(
                f"/reconciliation-sessions/{SESSION_ID}/matches",
                json={
                    "statement_line_ids": [LINE_ID],
                    "bank_movement_ids": [MOVEMENT_ID],
                },
                headers=headers,
            )

        assert response.status_code == 422

    @pytest.mark.asyncio
    async def test_post_match_already_matched_returns_409(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(side_effect=_pg_error("P0434", "already_matched"))

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.post(
                f"/reconciliation-sessions/{SESSION_ID}/matches",
                json={
                    "statement_line_ids": [LINE_ID],
                    "bank_movement_ids": [MOVEMENT_ID],
                },
                headers=headers,
            )

        assert response.status_code == 409

    @pytest.mark.asyncio
    async def test_post_undo_returns_200(self, async_client, mock_pool):
        pool, conn = mock_pool
        rpc_result = json.dumps({
            "match_group": MATCH_GROUP,
            "undone_rows": 2,
            "movement_count": 1,
            "status": "undone",
        })
        conn.fetchrow = AsyncMock(return_value={"result": rpc_result})

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.post(
                f"/reconciliation-sessions/{SESSION_ID}/matches/{MATCH_GROUP}/undo",
                json={"undo_reason": "monto correspondía a otra transferencia"},
                headers=headers,
            )

        assert response.status_code == 200
        assert response.json()["status"] == "undone"

    @pytest.mark.asyncio
    async def test_post_close_with_difference_no_reason_returns_422(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(side_effect=_pg_error("P0431", "motivo_requerido"))

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.post(
                f"/reconciliation-sessions/{SESSION_ID}/close",
                json={},
                headers=headers,
            )

        assert response.status_code == 422

    @pytest.mark.asyncio
    async def test_post_on_closed_session_returns_409(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(side_effect=_pg_error("P0432", "session_closed"))

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.post(
                f"/reconciliation-sessions/{SESSION_ID}/close",
                json={"close_reason": "x"},
                headers=headers,
            )

        assert response.status_code == 409

    @pytest.mark.asyncio
    async def test_get_suggestions_returns_200(self, async_client, mock_pool):
        pool, conn = mock_pool
        # get_session (fetchrow) + suggestions (fetch)
        conn.fetchrow = AsyncMock(return_value={
            "id": SESSION_ID,
            "bank_account_id": BANK_ACCOUNT_ID,
            "status": "open",
            "period_from": date(2026, 7, 1),
            "period_to": date(2026, 7, 31),
        })
        conn.fetch = AsyncMock(return_value=[
            {
                "statement_line_id": LINE_ID,
                "bank_movement_id": MOVEMENT_ID,
                "amount": Decimal("5000.00"),
                "line_value_date": date(2026, 7, 15),
                "movement_value_date": date(2026, 7, 15),
                "line_description": "Transferencia recibida",
                "movement_description": "transferencia test",
            }
        ])

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.get(
                f"/reconciliation-sessions/{SESSION_ID}/suggestions",
                headers=headers,
            )

        assert response.status_code == 200
        body = response.json()
        assert len(body) == 1
        assert body[0]["statement_line_id"] == LINE_ID

    @pytest.mark.asyncio
    async def test_get_matches_returns_200(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[
            {
                "match_group": MATCH_GROUP,
                "matched_at": "2026-07-02T10:00:00Z",
                "line_count": 1,
                "movement_count": 1,
                "amount": Decimal("5000.00"),
            }
        ])

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.get(
                f"/reconciliation-sessions/{SESSION_ID}/matches",
                headers=headers,
            )

        assert response.status_code == 200
        assert response.json()[0]["match_group"] == MATCH_GROUP

    @pytest.mark.asyncio
    async def test_post_manual_movement_fee_returns_200(self, async_client, mock_pool):
        """'Solo anotar' (V1): registrar una comisión del extracto como movimiento manual."""
        pool, conn = mock_pool
        rpc_result = json.dumps({
            "movement_id": MOVEMENT_ID,
            "balance_after": "14650.00",
            "replayed": False,
            "operation_id": IMPORT_ID,
        })
        conn.fetchrow = AsyncMock(return_value={"result": rpc_result})

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.post(
                f"/bank-accounts/{BANK_ACCOUNT_ID}/movements",
                json={
                    "idempotency_key": IDEMPOTENCY_KEY,
                    "amount": "-350.00",
                    "movement_type": "fee",
                    "value_date": "2026-07-20",
                    "description": "Comisión mantenimiento",
                },
                headers=headers,
            )

        assert response.status_code == 200
        assert response.json()["movement_id"] == MOVEMENT_ID

    @pytest.mark.asyncio
    async def test_post_manual_movement_card_settlement_rejected_by_schema(self, async_client, mock_pool):
        """card_settlement sigue reservado a C2 — el schema lo corta antes de la DB (doble red con P0410)."""
        pool, conn = mock_pool

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.post(
                f"/bank-accounts/{BANK_ACCOUNT_ID}/movements",
                json={
                    "idempotency_key": IDEMPOTENCY_KEY,
                    "amount": "1000.00",
                    "movement_type": "card_settlement",
                },
                headers=headers,
            )

        assert response.status_code == 422
        conn.fetchrow.assert_not_called()

    @pytest.mark.asyncio
    async def test_post_import_invalid_payload_returns_422(self, async_client, mock_pool):
        """Pydantic rechaza lines vacías antes de tocar la DB."""
        pool, conn = mock_pool

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.post(
                f"/bank-accounts/{BANK_ACCOUNT_ID}/statement-imports",
                json={
                    "idempotency_key": IDEMPOTENCY_KEY,
                    "file_name": "x.csv",
                    "file_hash": "a" * 64,
                    "lines": [],
                },
                headers=headers,
            )

        assert response.status_code == 422
        conn.fetchrow.assert_not_called()
