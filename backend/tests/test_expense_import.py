"""
importador-gastos-transaccional — Grupo 6: backend Python (schemas, repository,
service, router).

Strict TDD: este archivo se escribió ANTES de tocar
`backend/schemas/expenses.py` (schemas del lote), `backend/repositories/
expense_repository.py` (`import_batch`), `backend/services/expenses.py`
(`import_expenses`) y `backend/routers/expenses.py` (`POST /expenses/import`).

Qué cubre, por task:

  6.1  — `ExpenseRepository.import_batch`: UNA sola llamada (`fetchrow`),
         orden POSICIONAL exacto de los 9 parámetros de la RPC, `rows`
         serializado a JSON string (no un dict crudo — asyncpg no castea
         automáticamente listas de dicts a `jsonb`).
  6.2  — Schemas: `ExpenseImportRowIn.amount` reusa `gt=0` (misma restricción
         que `ExpenseCreate.amount`); `rows` acotado a 500 (D8, sin trocear).
  6.4  — Service: CERO reglas de dominio nuevas — sólo `require_role` +
         `_pg_errors_as_problems()` (el que YA EXISTE, D4 del propose).
  6.5  — Router: `require_idempotency_key`, calcado de
         `POST /bank-accounts/{id}/statement-imports`.
  6.6  — `P0427` registrado en `backend/core/errors.py` con status 422.
  6.7  — Triangulación: lote aplicado, lote RECHAZADO (200 con errors[], NO
         4xx — D11 del design), simulación, replay por clave, replay por
         hash, sin rol de escritura (403), sin clave de idempotencia (422).
  6.8  — Un lote rechazado NO deja la conexión en estado inutilizable: es la
         razón de ser de D2 (el reporte viaja por el RETURN normal de la RPC,
         nunca por una excepción) — se verifica que el MISMO mock de conexión
         puede atender una llamada posterior tras un resultado rechazado.
  6.9  — El schema acepta el tope exacto (500 filas) y rechaza 501 con 422
         ANTES de llegar al repositorio (Pydantic, no la RPC) — mismo criterio
         que D8: el cliente también aplica el tope, el servidor es la
         autoridad final (verificado en el gate SQL, grupo 5).

Run: python -m pytest backend/tests/test_expense_import.py -q -p no:cacheprovider
"""
from __future__ import annotations

import datetime
import json
from decimal import Decimal
from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import make_token

ROW_1 = {
    "row_no": 1,
    "description": "Alquiler",
    "category": "Alquiler",
    "amount": "1000",
    "date": "2026-05-01",
}
ROW_2 = {
    "row_no": 2,
    "description": "Internet",
    "category": "Servicios",
    "amount": "2000",
    "date": "2026-05-02",
    "payment_method_name": "Transferencia bancaria",
    "branch_name": "Sucursal Centro",
    "cost_center_name": "Administración",
}

VALID_PAYLOAD = {
    "file_name": "gastos-mayo.csv",
    "file_hash": "abc123",
    "rows": [ROW_1, ROW_2],
}

APPLIED_RESULT = {
    "committed": True,
    "import_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    "imported": 2,
    "errors": [],
    "notices": [],
    "replayed": False,
    "dry_run": False,
}

REJECTED_RESULT = {
    "committed": False,
    "import_id": None,
    "imported": 0,
    "errors": [{"row": 2, "code": "P0404", "message": "payment_method_name_not_found"}],
    "notices": [],
    "replayed": False,
    "dry_run": False,
}


def _rpc_row(result: dict) -> dict:
    return {"result": json.dumps(result)}


# ══════════════════════════════════════════════════════════════════════════
# 6.1/6.2 — Repository: una sola llamada, orden posicional, rows como JSON
# ══════════════════════════════════════════════════════════════════════════


class TestExpenseRepositoryImportBatch:
    async def test_single_fetchrow_call_with_positional_order(self):
        from backend.repositories.expense_repository import ExpenseRepository

        conn = AsyncMock()
        conn.fetchrow = AsyncMock(return_value=_rpc_row(APPLIED_RESULT))
        repo = ExpenseRepository(conn)

        rows_json = json.dumps([ROW_1, ROW_2])
        result = await repo.import_batch(
            idempotency_key="key-1",
            rows_json=rows_json,
            file_name="gastos-mayo.csv",
            file_hash="abc123",
            default_payment_method_id=None,
            default_branch_id=None,
            default_cost_center_id="cc-uuid-1",
            fallback_bank_account_id=None,
            dry_run=False,
        )

        conn.fetchrow.assert_awaited_once()
        args = conn.fetchrow.call_args.args
        # args[0] es la query SQL; el resto son los 9 parámetros posicionales
        # de rpc_import_expenses, en el MISMO orden que la firma SQL.
        assert args[1] == "key-1"
        assert args[2] == rows_json
        assert isinstance(args[2], str), "rows debe viajar como STRING json, no un dict/list crudo"
        assert args[3] == "gastos-mayo.csv"
        assert args[4] == "abc123"
        assert args[5] is None
        assert args[6] is None
        assert args[7] == "cc-uuid-1"
        assert args[8] is None
        assert args[9] is False
        assert result["committed"] is True

    async def test_rows_json_is_a_real_json_string_not_a_python_list(self):
        """Control negativo: pasar un `list[dict]` crudo (sin json.dumps) es
        el bug que asyncpg NO castea automáticamente a jsonb — el contrato
        del repository exige que el CALLER (router) ya lo serializó."""
        from backend.repositories.expense_repository import ExpenseRepository

        conn = AsyncMock()
        conn.fetchrow = AsyncMock(return_value=_rpc_row(APPLIED_RESULT))
        repo = ExpenseRepository(conn)

        rows_json = json.dumps([ROW_1])
        await repo.import_batch(
            idempotency_key="key-1", rows_json=rows_json,
            file_name="f.csv", file_hash="h1",
            default_payment_method_id=None, default_branch_id=None,
            default_cost_center_id=None, fallback_bank_account_id=None,
            dry_run=False,
        )
        passed_rows_arg = conn.fetchrow.call_args.args[2]
        assert isinstance(passed_rows_arg, str)
        json.loads(passed_rows_arg)  # no debe tirar — es JSON válido


# ══════════════════════════════════════════════════════════════════════════
# 6.2 — Schemas
# ══════════════════════════════════════════════════════════════════════════


class TestExpenseImportSchemas:
    def test_row_amount_must_be_positive(self):
        from pydantic import ValidationError

        from backend.schemas.expenses import ExpenseImportRowIn

        with pytest.raises(ValidationError):
            ExpenseImportRowIn(row_no=1, description="x", category="y", amount=Decimal("0"), date=datetime.date(2026, 1, 1))
        with pytest.raises(ValidationError):
            ExpenseImportRowIn(row_no=1, description="x", category="y", amount=Decimal("-5"), date=datetime.date(2026, 1, 1))

    def test_row_catalog_columns_are_optional(self):
        from backend.schemas.expenses import ExpenseImportRowIn

        row = ExpenseImportRowIn(row_no=1, description="x", category="y", amount=Decimal("10"), date=datetime.date(2026, 1, 1))
        assert row.payment_method_name is None
        assert row.branch_name is None
        assert row.cost_center_name is None

    def test_import_in_accepts_exactly_the_cap(self):
        from backend.schemas.expenses import EXPENSE_IMPORT_MAX_ROWS, ExpenseImportIn

        rows = [
            {"row_no": i, "description": f"gasto {i}", "category": "Servicios", "amount": "10", "date": "2026-05-01"}
            for i in range(1, EXPENSE_IMPORT_MAX_ROWS + 1)
        ]
        payload = ExpenseImportIn(file_name="f.csv", file_hash="h", rows=rows)
        assert len(payload.rows) == EXPENSE_IMPORT_MAX_ROWS

    def test_import_in_rejects_one_row_over_the_cap(self):
        """D8: el tope se verifica en el SERVIDOR aunque la superficie también
        lo aplique — acá, en Pydantic, ANTES de llegar a la RPC."""
        from pydantic import ValidationError

        from backend.schemas.expenses import EXPENSE_IMPORT_MAX_ROWS, ExpenseImportIn

        rows = [
            {"row_no": i, "description": f"gasto {i}", "category": "Servicios", "amount": "10", "date": "2026-05-01"}
            for i in range(1, EXPENSE_IMPORT_MAX_ROWS + 2)
        ]
        with pytest.raises(ValidationError):
            ExpenseImportIn(file_name="f.csv", file_hash="h", rows=rows)

    def test_import_in_rejects_empty_rows(self):
        from pydantic import ValidationError

        from backend.schemas.expenses import ExpenseImportIn

        with pytest.raises(ValidationError):
            ExpenseImportIn(file_name="f.csv", file_hash="h", rows=[])


# ══════════════════════════════════════════════════════════════════════════
# 6.6 — P0427 registrado con status 422
# ══════════════════════════════════════════════════════════════════════════


def test_p0427_registered_as_422():
    from backend.core.errors import _BUSINESS_ERRCODE_STATUS

    assert _BUSINESS_ERRCODE_STATUS["P0427"] == 422


def test_p0429_never_needs_mapping_it_never_escapes_the_rpc():
    """P0429 es la señal INTERNA de rollback del lote (D2) — se captura
    dentro de su propio EXCEPTION en rpc_import_expenses y NUNCA sale de la
    función, así que no necesita (ni debe tener) entrada en el mapeo global."""
    from backend.core.errors import _BUSINESS_ERRCODE_STATUS

    assert "P0429" not in _BUSINESS_ERRCODE_STATUS


# ══════════════════════════════════════════════════════════════════════════
# 6.4/6.5/6.7 — Service + router, end-to-end con mock_pool
# ══════════════════════════════════════════════════════════════════════════


class TestImportExpensesEndpoint:
    async def test_applied_batch_returns_200_with_report(self, async_client, mock_pool):
        pool, conn = mock_pool
        token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(return_value=_rpc_row(APPLIED_RESULT))

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/expenses/import",
                json=VALID_PAYLOAD,
                headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "batch-key-1"},
            )
        assert resp.status_code == 200
        body = resp.json()
        assert body["committed"] is True
        assert body["imported"] == 2
        assert body["errors"] == []

    async def test_rejected_batch_returns_200_not_4xx(self, async_client, mock_pool):
        """D11 del design: un lote rechazado por errores de fila NO es un
        error de protocolo — sigue respondiendo 200 con el reporte."""
        pool, conn = mock_pool
        token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(return_value=_rpc_row(REJECTED_RESULT))

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/expenses/import",
                json=VALID_PAYLOAD,
                headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "batch-key-2"},
            )
        assert resp.status_code == 200
        body = resp.json()
        assert body["committed"] is False
        assert body["errors"][0]["row"] == 2
        assert body["errors"][0]["code"] == "P0404"

    async def test_dry_run_forwarded_to_repository(self, async_client, mock_pool):
        pool, conn = mock_pool
        token = make_token({"role": "user"})
        dry_result = {**APPLIED_RESULT, "committed": False, "dry_run": True, "import_id": None}
        conn.fetchrow = AsyncMock(return_value=_rpc_row(dry_result))

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/expenses/import",
                json={**VALID_PAYLOAD, "dry_run": True},
                headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "batch-key-3"},
            )
        assert resp.status_code == 200
        assert resp.json()["dry_run"] is True
        # p_dry_run (9º parámetro posicional) debe haber viajado en True
        assert conn.fetchrow.call_args.args[9] is True

    async def test_replay_by_same_key_returns_replayed_true(self, async_client, mock_pool):
        pool, conn = mock_pool
        token = make_token({"role": "user"})
        replayed_result = {**APPLIED_RESULT, "replayed": True}
        conn.fetchrow = AsyncMock(return_value=_rpc_row(replayed_result))

        with patch("backend.core.database.pool", pool):
            first = await async_client.post(
                "/expenses/import", json=VALID_PAYLOAD,
                headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "replay-key"},
            )
            second = await async_client.post(
                "/expenses/import", json=VALID_PAYLOAD,
                headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "replay-key"},
            )
        assert first.status_code == 200
        assert second.status_code == 200
        assert second.json()["replayed"] is True
        # las DOS llamadas propagan la MISMA clave al RPC (reintento, no lote nuevo)
        assert conn.fetchrow.call_args_list[0].args[1] == "replay-key"
        assert conn.fetchrow.call_args_list[1].args[1] == "replay-key"

    async def test_replay_by_same_file_hash_different_key(self, async_client, mock_pool):
        """Dedupe de dominio (D7): mismo file_hash, otra clave -> replayed."""
        pool, conn = mock_pool
        token = make_token({"role": "user"})
        replayed_result = {**APPLIED_RESULT, "replayed": True}
        conn.fetchrow = AsyncMock(return_value=_rpc_row(replayed_result))

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/expenses/import", json=VALID_PAYLOAD,
                headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "otra-clave-distinta"},
            )
        assert resp.status_code == 200
        assert resp.json()["replayed"] is True

    async def test_member_without_write_role_forbidden(self, async_client, mock_pool):
        pool, conn = mock_pool
        member_token = make_token({"role": "member"})
        conn.fetchrow = AsyncMock(return_value=_rpc_row(APPLIED_RESULT))

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/expenses/import", json=VALID_PAYLOAD,
                headers={"Authorization": f"Bearer {member_token}", "Idempotency-Key": "k"},
            )
        assert resp.status_code == 403
        conn.fetchrow.assert_not_awaited()

    async def test_missing_idempotency_key_returns_422(self, async_client, mock_pool):
        pool, conn = mock_pool
        token = make_token({"role": "user"})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/expenses/import", json=VALID_PAYLOAD,
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 422
        assert resp.json()["code"] == "idempotency_key_required"
        conn.fetchrow.assert_not_awaited()

    async def test_malformed_payload_p0427_maps_to_422(self, async_client, mock_pool):
        """6.6: un P0427 que SÍ escapa (p.ej. un caller distinto al frontend,
        o una condición de forma no cubierta por Pydantic) se traduce a 422."""
        import asyncpg

        pool, conn = mock_pool
        token = make_token({"role": "user"})

        err = asyncpg.exceptions.RaiseError("import_payload_invalido: el archivo no tiene filas de datos")
        err.sqlstate = "P0427"
        conn.fetchrow = AsyncMock(side_effect=err)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/expenses/import", json=VALID_PAYLOAD,
                headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "k"},
            )
        assert resp.status_code == 422
        assert resp.json()["code"] == "P0427"

    async def test_connection_stays_usable_after_a_rejected_batch(self, async_client, mock_pool):
        """6.8 — D2: el reporte de un lote rechazado viaja por el RETURN
        normal de la RPC, NUNCA por una excepción — así que la conexión (y,
        con tenancy_tx_scope_enabled, la transacción del request) sigue sana
        para cualquier llamada posterior. Se simula con la MISMA conexión
        mockeada atendiendo dos requests seguidos: un rechazo y, después, un
        camino feliz — si el rechazo hubiera dejado algo "roto", el segundo
        `fetchrow` no se ejecutaría con normalidad."""
        pool, conn = mock_pool
        token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(side_effect=[_rpc_row(REJECTED_RESULT), _rpc_row(APPLIED_RESULT)])

        with patch("backend.core.database.pool", pool):
            rejected = await async_client.post(
                "/expenses/import", json=VALID_PAYLOAD,
                headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "k-rej"},
            )
            ok = await async_client.post(
                "/expenses/import", json=VALID_PAYLOAD,
                headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "k-ok"},
            )
        assert rejected.status_code == 200
        assert rejected.json()["committed"] is False
        assert ok.status_code == 200
        assert ok.json()["committed"] is True
        assert conn.fetchrow.await_count == 2


# ══════════════════════════════════════════════════════════════════════════
# 6.9 — tope grande: la solicitud completa el ciclo request/response sin
# ninguna regla de negocio en Python (mismo mock de un lote de 500 filas).
# ══════════════════════════════════════════════════════════════════════════


async def test_import_batch_at_the_row_cap_reaches_the_repository(async_client, mock_pool):
    from backend.schemas.expenses import EXPENSE_IMPORT_MAX_ROWS

    pool, conn = mock_pool
    token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value=_rpc_row({**APPLIED_RESULT, "imported": EXPENSE_IMPORT_MAX_ROWS}))

    rows = [
        {"row_no": i, "description": f"gasto {i}", "category": "Servicios", "amount": "10", "date": "2026-05-01"}
        for i in range(1, EXPENSE_IMPORT_MAX_ROWS + 1)
    ]
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/expenses/import",
            json={"file_name": "grande.csv", "file_hash": "h-grande", "rows": rows},
            headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "k-tope"},
        )
    assert resp.status_code == 200
    assert resp.json()["imported"] == EXPENSE_IMPORT_MAX_ROWS
    conn.fetchrow.assert_awaited_once()
