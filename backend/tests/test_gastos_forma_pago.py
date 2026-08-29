"""
gastos-forma-pago — Grupo 7: backend Python (schemas, repositorio, servicio, router).

Strict TDD: este archivo se escribió ANTES de tocar
`backend/schemas/expenses.py`, `backend/schemas/cash.py`,
`backend/repositories/expense_repository.py`, `backend/services/expenses.py`,
`backend/routers/expenses.py` y `backend/core/errors.py`.

Qué cubre, por task:

  7.1/7.2 — Schemas de gasto
    · los cuatro campos nuevos de entrada son OPCIONALES (retrocompatibilidad
      con el payload actual, que es lo que manda el importador CSV);
    · `ExpenseUpdate` distingue AUSENTE de NULO EXPLÍCITO vía `model_fields_set`
      (contrato tri-estado D12) — se asserta el CONTRATO, no el tipo;
    · `ExpenseOut` expone los derivados de bloqueo con default seguro (False).

  7.3 — `MovementType.expense_reversal`
    · entra en `_INCOME_TYPES` (signo POSITIVO: revertir un egreso repone plata),
      NO en `_EXPENSE_TYPES`;
    · el rechazo del signo incoherente trae `loc == ('amount',)` (gotcha #442:
      el field_validator cross-field va sobre un campo declarado DESPUÉS);
    · control negativo: `sale_reversal` sigue siendo egreso — el espejo con
      `sale_reversal` es de FAMILIA de UI, no de signo (D9).

  7.4 — Repositorio: una llamada por operación
    · alta/edición/borrado despachan su RPC con parámetros POSICIONALES y los
      tipos que asyncpg realmente manda (uuid→str, Decimal, date, bool);
    · controles negativos: ya no queda ni un `INSERT INTO expenses`, ni un
      `UPDATE expenses SET`, ni un `DELETE FROM expenses` compuesto en Python.

  7.5 — Derivados de lectura
    · `is_payment_locked`/`has_cash_movement`/`has_bank_movement`/
      `is_delete_blocked` se calculan con los MISMOS predicados que los guards
      del servidor: el test los EXTRAE de la migración y exige que aparezcan,
      normalizados, en el SQL del repositorio.

  7.5b — `GET /expenses` paginado `{items,total,page,pages}` (D18, BREAKING).

  7.6/7.6b — Servicio + router: sólo validación y delegación; ERRCODEs
    traducidos a 7807, con el override de `P0412` → 422 + `field` sólo en el
    camino de gasto (D19), y el control negativo de que `P0412` conserva su
    404 global.

  7.7 — Triangulación por camino de negocio.

Run: python -m pytest backend/tests/test_gastos_forma_pago.py -q -p no:cacheprovider
"""
from __future__ import annotations

import datetime
import inspect
import json
import re
import uuid
from decimal import Decimal
from pathlib import Path
from unittest.mock import AsyncMock, patch

import asyncpg
import pytest
from pydantic import ValidationError

from backend.tests.conftest import make_token

# ── Constantes ────────────────────────────────────────────────────────────────
ACCOUNT_ID         = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
USER_ID            = "11111111-1111-1111-1111-111111111111"
EXPENSE_ID         = "55555555-5555-5555-5555-555555555555"
PAYMENT_METHOD_ID  = "77777777-7777-7777-7777-777777777777"
BRANCH_ID          = "88888888-8888-8888-8888-888888888888"
COST_CENTER_ID     = "99999999-9999-9999-9999-999999999999"
CASH_SESSION_ID    = "12121212-1212-1212-1212-121212121212"
BANK_ACCOUNT_ID    = "13131313-1313-1313-1313-131313131313"

_REPO_ROOT = Path(__file__).resolve().parents[2]
MIGRATION = _REPO_ROOT / "supabase" / "migrations" / "20261015000001_gastos_forma_pago.sql"
SQL_GATE = _REPO_ROOT / "supabase" / "tests" / "test_gastos_forma_pago.sql"

EXPENSE_ROW = {
    "id": EXPENSE_ID,
    "user_id": USER_ID,
    "category": "supplies",
    "amount": Decimal("150.00"),
    "description": "Paper",
    "date": datetime.date(2026, 8, 29),
    "created_at": datetime.datetime(2026, 8, 29, 10, 0, 0),
    "cost_center_id": None,
    "branch_id": BRANCH_ID,
    "payment_method_id": PAYMENT_METHOD_ID,
    "payment_method_name": "Efectivo",
    "payment_method_kind": "cash",
    "has_cash_movement": False,
    "has_bank_movement": False,
    "is_payment_locked": False,
    "is_delete_blocked": False,
}


def _pg_error(sqlstate: str, message: str = "boom") -> asyncpg.PostgresError:
    err = asyncpg.exceptions.RaiseError(message)
    err.sqlstate = sqlstate
    return err


# ══════════════════════════════════════════════════════════════════════════════
# Sección 1 — Schemas de gasto (7.1 / 7.2)
# ══════════════════════════════════════════════════════════════════════════════

class TestExpenseCreateSchema:
    def test_accepts_the_four_new_optional_fields(self):
        from backend.schemas.expenses import ExpenseCreate

        payload = ExpenseCreate(
            category="alquiler",
            amount=Decimal("2200.00"),
            date=datetime.date(2026, 8, 29),
            payment_method_id=uuid.UUID(PAYMENT_METHOD_ID),
            branch_id=uuid.UUID(BRANCH_ID),
            cash_session_id=uuid.UUID(CASH_SESSION_ID),
            bank_account_id=uuid.UUID(BANK_ACCOUNT_ID),
        )
        assert payload.payment_method_id == uuid.UUID(PAYMENT_METHOD_ID)
        assert payload.branch_id == uuid.UUID(BRANCH_ID)
        assert payload.cash_session_id == uuid.UUID(CASH_SESSION_ID)
        assert payload.bank_account_id == uuid.UUID(BANK_ACCOUNT_ID)

    def test_omitting_them_keeps_the_legacy_payload_valid(self):
        """Retrocompatibilidad: el importador CSV manda exactamente esto (D13)."""
        from backend.schemas.expenses import ExpenseCreate

        payload = ExpenseCreate(
            category="supplies", amount=Decimal("150.00"), date=datetime.date(2026, 8, 29)
        )
        assert payload.payment_method_id is None
        assert payload.branch_id is None
        assert payload.cash_session_id is None
        assert payload.bank_account_id is None


class TestExpenseUpdateTriState:
    """D12 — el contrato es por AUSENCIA, nunca por `is None`."""

    @pytest.mark.parametrize("field", ["payment_method_id", "branch_id", "cost_center_id"])
    def test_absent_key_is_not_in_fields_set(self, field):
        from backend.schemas.expenses import ExpenseUpdate

        payload = ExpenseUpdate.model_validate({"amount": "300.00"})
        assert field not in payload.model_fields_set
        # y el default sigue siendo None: `is None` NO alcanza para distinguir
        assert getattr(payload, field) is None

    @pytest.mark.parametrize("field", ["payment_method_id", "branch_id", "cost_center_id"])
    def test_explicit_null_is_in_fields_set(self, field):
        from backend.schemas.expenses import ExpenseUpdate

        payload = ExpenseUpdate.model_validate({field: None})
        assert field in payload.model_fields_set
        assert getattr(payload, field) is None

    @pytest.mark.parametrize(
        "field,value",
        [
            ("payment_method_id", PAYMENT_METHOD_ID),
            ("branch_id", BRANCH_ID),
            ("cost_center_id", COST_CENTER_ID),
        ],
    )
    def test_explicit_uuid_is_in_fields_set(self, field, value):
        from backend.schemas.expenses import ExpenseUpdate

        payload = ExpenseUpdate.model_validate({field: value})
        assert field in payload.model_fields_set
        assert getattr(payload, field) == uuid.UUID(value)

    def test_desimputar_uno_no_arrastra_a_los_otros(self):
        """Control negativo del tri-estado: sólo el campo enviado se marca."""
        from backend.schemas.expenses import ExpenseUpdate

        payload = ExpenseUpdate.model_validate({"payment_method_id": None})
        assert "payment_method_id" in payload.model_fields_set
        assert "branch_id" not in payload.model_fields_set
        assert "cost_center_id" not in payload.model_fields_set


class TestExpenseOutSchema:
    def test_exposes_derived_lock_flags_with_safe_defaults(self):
        from backend.schemas.expenses import ExpenseOut

        out = ExpenseOut.model_validate(
            {
                "id": EXPENSE_ID,
                "user_id": USER_ID,
                "category": "supplies",
                "amount": "150.00",
                "description": None,
                "date": "2026-08-29",
                "created_at": "2026-08-29T10:00:00",
            }
        )
        assert out.is_payment_locked is False
        assert out.has_cash_movement is False
        assert out.has_bank_movement is False
        assert out.is_delete_blocked is False
        assert out.payment_method_id is None
        assert out.payment_method_name is None
        assert out.branch_id is None

    def test_maps_the_derived_flags_when_the_server_sends_them(self):
        from backend.schemas.expenses import ExpenseOut

        out = ExpenseOut.model_validate(
            {**EXPENSE_ROW, "has_cash_movement": True, "is_payment_locked": True, "is_delete_blocked": True}
        )
        assert out.has_cash_movement is True
        assert out.has_bank_movement is False
        assert out.is_payment_locked is True
        assert out.is_delete_blocked is True
        assert out.payment_method_name == "Efectivo"
        assert out.branch_id == uuid.UUID(BRANCH_ID)

    def test_preserves_the_timestamptz_date_coercion(self):
        """No-regresión: expenses.date es timestamptz (test vivo desde 2026-06-13)."""
        from backend.schemas.expenses import ExpenseOut

        out = ExpenseOut.model_validate(
            {
                **EXPENSE_ROW,
                "date": datetime.datetime(2026, 4, 6, 16, 33, 40, 270406, tzinfo=datetime.timezone.utc),
            }
        )
        assert out.date == datetime.date(2026, 4, 6)


# ══════════════════════════════════════════════════════════════════════════════
# Sección 2 — `expense_reversal` en el vocabulario de caja (7.3, D9)
# ══════════════════════════════════════════════════════════════════════════════

class TestExpenseReversalMovementType:
    def test_enum_member_exists(self):
        from backend.schemas.cash import MovementType

        assert MovementType.expense_reversal.value == "expense_reversal"

    def test_is_income_not_expense(self):
        """Signo POSITIVO: revertir un egreso repone plata en el cajón."""
        from backend.schemas.cash import _EXPENSE_TYPES, _INCOME_TYPES, MovementType

        assert MovementType.expense_reversal in _INCOME_TYPES
        assert MovementType.expense_reversal not in _EXPENSE_TYPES

    def test_negative_amount_rejected_with_loc_amount(self):
        from backend.schemas.cash import RegisterMovementIn

        with pytest.raises(ValidationError) as exc_info:
            RegisterMovementIn(movement_type="expense_reversal", amount=Decimal("-100"))
        # gotcha #442: el validador cross-field tiene que ver movement_type YA
        # validado, y el 7807 exige field = campo ofensor.
        assert exc_info.value.errors()[0]["loc"] == ("amount",)

    def test_positive_amount_accepted(self):
        from backend.schemas.cash import MovementType, RegisterMovementIn

        payload = RegisterMovementIn(movement_type="expense_reversal", amount=Decimal("100"))
        assert payload.movement_type is MovementType.expense_reversal
        assert payload.amount == Decimal("100")

    def test_sale_reversal_sigue_siendo_egreso(self):
        """CONTROL NEGATIVO (D9): el espejo con sale_reversal es de FAMILIA de
        UI, no de signo — sale_reversal está en _EXPENSE_TYPES y ahí se queda.
        Sin este control, mover expense_reversal 'junto a sale_reversal' en el
        conjunto equivocado pasaría inadvertido."""
        from backend.schemas.cash import _EXPENSE_TYPES, _INCOME_TYPES, MovementType, RegisterMovementIn

        assert MovementType.sale_reversal in _EXPENSE_TYPES
        assert MovementType.sale_reversal not in _INCOME_TYPES
        with pytest.raises(ValidationError):
            RegisterMovementIn(movement_type="sale_reversal", amount=Decimal("100"))

    def test_expense_sigue_siendo_egreso(self):
        """Control negativo complementario: el tipo `expense` no cambia de signo."""
        from backend.schemas.cash import _EXPENSE_TYPES, MovementType, RegisterMovementIn

        assert MovementType.expense in _EXPENSE_TYPES
        with pytest.raises(ValidationError):
            RegisterMovementIn(movement_type="expense", amount=Decimal("100"))


# ══════════════════════════════════════════════════════════════════════════════
# Sección 3 — Repositorio: una llamada por operación (7.4)
# ══════════════════════════════════════════════════════════════════════════════

@pytest.fixture
def mock_conn():
    conn = AsyncMock()
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchrow = AsyncMock(return_value=None)
    conn.fetchval = AsyncMock(return_value=0)
    conn.execute = AsyncMock(return_value="SET")
    return conn


def _repo(conn):
    from backend.repositories.expense_repository import ExpenseRepository

    return ExpenseRepository(conn)


def _sql_of(call) -> str:
    return call.args[0]


class TestExpenseRepositoryCreate:
    @pytest.mark.asyncio
    async def test_dispatches_rpc_create_expense_with_positional_args(self, mock_conn):
        mock_conn.fetchrow.side_effect = [
            {"result": json.dumps({"expense_id": EXPENSE_ID, "branch_id": BRANCH_ID})},
            EXPENSE_ROW,
        ]
        row = await _repo(mock_conn).create(
            ACCOUNT_ID,
            category="alquiler",
            amount=Decimal("2200.00"),
            date=datetime.date(2026, 8, 29),
            description="agosto",
            branch_id=BRANCH_ID,
            cost_center_id=COST_CENTER_ID,
            payment_method_id=PAYMENT_METHOD_ID,
            cash_session_id=CASH_SESSION_ID,
            bank_account_id=BANK_ACCOUNT_ID,
        )

        rpc_call = mock_conn.fetchrow.call_args_list[0]
        assert "rpc_create_expense" in _sql_of(rpc_call)
        # Orden POSICIONAL exacto de la firma SQL (contrato del grupo 3).
        assert rpc_call.args[1:] == (
            "alquiler",
            Decimal("2200.00"),
            datetime.date(2026, 8, 29),
            "agosto",
            BRANCH_ID,
            COST_CENTER_ID,
            PAYMENT_METHOD_ID,
            CASH_SESSION_ID,
            BANK_ACCOUNT_ID,
        )
        assert row["id"] == EXPENSE_ID

    @pytest.mark.asyncio
    async def test_sends_the_real_transport_types(self, mock_conn):
        """Lección #436/#451: el mock replica el TRANSPORTE real, no el ideal.
        asyncpg recibe los uuid como str (el repo los normaliza), el importe
        como Decimal y la fecha como `datetime.date` — nunca como str ISO."""
        mock_conn.fetchrow.side_effect = [
            {"result": json.dumps({"expense_id": EXPENSE_ID})},
            EXPENSE_ROW,
        ]
        await _repo(mock_conn).create(
            ACCOUNT_ID,
            category="varios",
            amount=Decimal("10.50"),
            date=datetime.date(2026, 8, 29),
            payment_method_id=uuid.UUID(PAYMENT_METHOD_ID),
            branch_id=uuid.UUID(BRANCH_ID),
        )
        args = mock_conn.fetchrow.call_args_list[0].args
        assert isinstance(args[2], Decimal)
        assert isinstance(args[3], datetime.date) and not isinstance(args[3], datetime.datetime)
        assert isinstance(args[5], str) and args[5] == BRANCH_ID
        assert isinstance(args[7], str) and args[7] == PAYMENT_METHOD_ID
        # los opcionales que no viajan quedan en NULL, no en "None"
        assert args[8] is None and args[9] is None

    @pytest.mark.asyncio
    async def test_no_longer_composes_a_plain_insert(self, mock_conn):
        """CONTROL NEGATIVO — el repositorio no orquesta pasos de negocio."""
        mock_conn.fetchrow.side_effect = [
            {"result": json.dumps({"expense_id": EXPENSE_ID})},
            EXPENSE_ROW,
        ]
        await _repo(mock_conn).create(
            ACCOUNT_ID, category="x", amount=Decimal("1"), date=datetime.date(2026, 8, 29)
        )
        for call in mock_conn.fetchrow.call_args_list:
            assert "INSERT INTO" not in _sql_of(call).upper()


class TestExpenseRepositoryUpdate:
    @pytest.mark.asyncio
    async def test_dispatches_rpc_update_expense_with_tri_state_flags(self, mock_conn):
        mock_conn.fetchrow.side_effect = [
            {"result": json.dumps({"expense_id": EXPENSE_ID})},
            EXPENSE_ROW,
        ]
        await _repo(mock_conn).update(
            EXPENSE_ID,
            ACCOUNT_ID,
            category=None,
            amount=Decimal("300.00"),
            date=None,
            description=None,
            payment_method_id=None,
            payment_method_provided=True,
            branch_id=BRANCH_ID,
            branch_provided=True,
            cost_center_id=None,
            cost_center_provided=False,
        )
        rpc_call = mock_conn.fetchrow.call_args_list[0]
        assert "rpc_update_expense" in _sql_of(rpc_call)
        assert rpc_call.args[1:] == (
            EXPENSE_ID,
            None,
            Decimal("300.00"),
            None,
            None,
            None,
            True,
            BRANCH_ID,
            True,
            None,
            False,
        )

    @pytest.mark.asyncio
    async def test_no_longer_composes_set_clauses(self, mock_conn):
        """CONTROL NEGATIVO: el `UPDATE expenses SET {campos}` compuesto en
        Python (que además ignoraba los nulos explícitos) tiene que estar
        muerto."""
        mock_conn.fetchrow.side_effect = [
            {"result": json.dumps({"expense_id": EXPENSE_ID})},
            EXPENSE_ROW,
        ]
        await _repo(mock_conn).update(
            EXPENSE_ID, ACCOUNT_ID,
            category="x", amount=None, date=None, description=None,
            payment_method_id=None, payment_method_provided=False,
            branch_id=None, branch_provided=False,
            cost_center_id=None, cost_center_provided=False,
        )
        for call in mock_conn.fetchrow.call_args_list:
            assert "UPDATE EXPENSES" not in _sql_of(call).upper().replace("PUBLIC.", "")


class TestExpenseRepositoryDelete:
    @pytest.mark.asyncio
    async def test_dispatches_rpc_delete_expense_in_a_single_call(self, mock_conn):
        mock_conn.fetchrow.return_value = {
            "result": json.dumps(
                {"expense_id": EXPENSE_ID, "deleted": True, "cash_reversal_id": None, "bank_reversals": 0}
            )
        }
        result = await _repo(mock_conn).delete(EXPENSE_ID, ACCOUNT_ID)

        assert mock_conn.fetchrow.await_count == 1
        call = mock_conn.fetchrow.call_args_list[0]
        assert "rpc_delete_expense" in _sql_of(call)
        assert call.args[1:] == (EXPENSE_ID,)
        assert result["deleted"] is True

    @pytest.mark.asyncio
    async def test_no_longer_emits_a_plain_delete(self, mock_conn):
        """CONTROL NEGATIVO: el `DELETE FROM expenses` crudo (que borraba sin
        compensar los libros) tiene que estar muerto."""
        mock_conn.fetchrow.return_value = {"result": json.dumps({"deleted": True})}
        await _repo(mock_conn).delete(EXPENSE_ID, ACCOUNT_ID)
        assert "DELETE FROM" not in _sql_of(mock_conn.fetchrow.call_args_list[0]).upper()
        assert mock_conn.execute.await_count == 0


# ══════════════════════════════════════════════════════════════════════════════
# Sección 4 — Derivados de lectura y paginación (7.5 / 7.5b)
# ══════════════════════════════════════════════════════════════════════════════

def _norm(sql: str) -> str:
    """Normaliza para comparar predicados: colapsa espacios, saca comentarios
    `--`, saca los alias de tabla y unifica los identificadores del gasto y de
    la caja para que el predicado del guard y el del derivado sean comparables
    literalmente."""
    sql = re.sub(r"--[^\n]*", " ", sql)
    sql = sql.replace("p_expense_id", "<EXP>")
    sql = re.sub(r"\be\.id\b", "<EXP>", sql)
    sql = sql.replace("v_cashbox_id", "<CASHBOX>")
    sql = re.sub(r"\bcs\.cashbox_id\b", "<CASHBOX>", sql)
    sql = re.sub(r"\b(cm|bm|cs|os|e|pm)\.", "", sql)
    return re.sub(r"\s+", " ", sql)


class TestDerivedFlagsMatchServerGuards:
    """7.5 — cada derivado usa el MISMO predicado que el guard del servidor.
    Los fragmentos NO están escritos a mano acá: se extraen de la migración."""

    @pytest.fixture(scope="class")
    def migration_sql(self) -> str:
        return _norm(MIGRATION.read_text(encoding="utf-8"))

    @pytest.fixture(scope="class")
    def repo_sql(self) -> str:
        from backend.repositories import expense_repository

        return _norm(inspect.getsource(expense_repository))

    @pytest.fixture(scope="class")
    def gate_sql(self) -> str:
        """El gate SQL evalúa los mismos derivados contra el COMPORTAMIENTO real
        del guard sobre el mismo gasto (sección 7). Ese bloque necesita una copia
        de los predicados —SQL no puede importar Python—, así que este test es
        el que impide que las dos copias diverjan: los tres artefactos
        (migración, repositorio, gate) tienen que traer el MISMO fragmento."""
        return _norm(SQL_GATE.read_text(encoding="utf-8"))

    def test_cash_lock_predicate_is_the_p0423_guard(self, migration_sql, repo_sql, gate_sql):
        fragment = "reference_id = <EXP>"
        assert fragment in migration_sql, "el guard P0423 de caja cambió: revisar el derivado"
        assert fragment in repo_sql
        assert fragment in gate_sql

    def test_bank_lock_predicate_is_the_p0423_guard(self, migration_sql, repo_sql, gate_sql):
        fragment = "source_doc_type = 'expense' AND source_doc_ref = <EXP>"
        assert fragment in migration_sql, "el guard P0423 de banco cambió: revisar el derivado"
        assert fragment in repo_sql
        assert fragment in gate_sql

    def test_delete_block_predicate_is_the_p0426_guard(self, migration_sql, repo_sql, gate_sql):
        """El bloqueo de borrado combina los DOS fragmentos que evalúa
        rpc_delete_expense antes del P0426: los movimientos de caja del gasto
        y la ausencia de sesión abierta en ESA caja."""
        movements = "reference_id = <EXP> AND movement_type = 'expense'"
        open_session = "cashbox_id = <CASHBOX> AND status = 'open'"
        assert movements in migration_sql
        assert open_session in migration_sql
        assert movements in repo_sql
        assert open_session in repo_sql
        assert movements in gate_sql
        assert open_session in gate_sql


class TestExpenseRepositoryReads:
    @pytest.mark.asyncio
    async def test_get_by_id_returns_the_derived_flags(self, mock_conn):
        mock_conn.fetchrow.return_value = {**EXPENSE_ROW, "is_payment_locked": True}
        row = await _repo(mock_conn).get_by_id(EXPENSE_ID, ACCOUNT_ID)
        assert row["is_payment_locked"] is True
        # tenencia explícita: el account_id viaja como parámetro, no se confía
        # sólo en RLS (regla dura tras la fuga del PR #446)
        assert mock_conn.fetchrow.call_args_list[0].args[1:] == (EXPENSE_ID, ACCOUNT_ID)

    @pytest.mark.asyncio
    async def test_list_paginated_returns_rows_and_total(self, mock_conn):
        mock_conn.fetch.return_value = [EXPENSE_ROW]
        mock_conn.fetchval.return_value = 7
        rows, total = await _repo(mock_conn).list_paginated(ACCOUNT_ID, page=1, page_size=25)
        assert total == 7
        assert rows[0]["id"] == EXPENSE_ID
        # OFFSET = page * page_size, 0-based (contrato v3-api-standards §2)
        assert 25 in mock_conn.fetch.call_args_list[0].args

    @pytest.mark.asyncio
    async def test_list_paginated_filters_are_server_side(self, mock_conn):
        mock_conn.fetch.return_value = []
        mock_conn.fetchval.return_value = 0
        await _repo(mock_conn).list_paginated(
            ACCOUNT_ID,
            page=0,
            page_size=10,
            date_from=datetime.date(2026, 8, 1),
            date_to=datetime.date(2026, 8, 31),
            search="alquiler",
            cost_center_id=COST_CENTER_ID,
            payment_method_id=PAYMENT_METHOD_ID,
        )
        args = mock_conn.fetch.call_args_list[0].args
        assert ACCOUNT_ID in args
        assert datetime.date(2026, 8, 1) in args
        assert datetime.date(2026, 8, 31) in args
        assert COST_CENTER_ID in args
        assert PAYMENT_METHOD_ID in args
        assert any(isinstance(a, str) and "alquiler" in a for a in args)
        # el COUNT usa los MISMOS filtros que el SELECT (si no, `total` miente)
        count_args = mock_conn.fetchval.call_args_list[0].args
        assert count_args[1:] == args[1:len(count_args)]

    @pytest.mark.asyncio
    async def test_list_paginated_names_inactive_payment_methods(self, mock_conn):
        """D18: una forma de pago dada de baja tiene que SEGUIR nombrándose —
        el LEFT JOIN del nombre no filtra por is_active ni por deleted_at."""
        from backend.repositories.expense_repository import _EXPENSE_FROM

        assert "LEFT JOIN public.payment_methods" in _EXPENSE_FROM
        assert "is_active" not in _EXPENSE_FROM
        assert "deleted_at" not in _EXPENSE_FROM


# ══════════════════════════════════════════════════════════════════════════════
# Sección 5 — Router + servicio (7.6 / 7.6b / 7.7)
# ══════════════════════════════════════════════════════════════════════════════

class TestListEndpointPagination:
    async def test_returns_the_standard_envelope(self, async_client, valid_token, mock_pool):
        """D18 — BREAKING declarado: `GET /expenses` deja de devolver una lista
        plana y pasa a `{items,total,page,pages}`, igual que `GET /sales`."""
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[EXPENSE_ROW])
        conn.fetchval = AsyncMock(return_value=1)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/expenses", headers={"Authorization": f"Bearer {valid_token}"}
            )
        assert resp.status_code == 200
        body = resp.json()
        assert set(body) == {"items", "total", "page", "pages"}
        assert body["total"] == 1
        assert body["page"] == 0
        assert body["pages"] == 1
        assert body["items"][0]["payment_method_name"] == "Efectivo"
        assert body["items"][0]["is_payment_locked"] is False

    async def test_pages_is_zero_when_empty(self, async_client, valid_token, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[])
        conn.fetchval = AsyncMock(return_value=0)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/expenses", headers={"Authorization": f"Bearer {valid_token}"}
            )
        assert resp.json() == {"items": [], "total": 0, "page": 0, "pages": 0}

    async def test_query_filters_reach_the_repository(self, async_client, valid_token, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[])
        conn.fetchval = AsyncMock(return_value=0)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/expenses",
                params={
                    "page": 2,
                    "page_size": 5,
                    "date_from": "2026-08-01",
                    "date_to": "2026-08-31",
                    "search": "nafta",
                    "cost_center_id": COST_CENTER_ID,
                    "payment_method_id": PAYMENT_METHOD_ID,
                },
                headers={"Authorization": f"Bearer {valid_token}"},
            )
        assert resp.status_code == 200
        assert resp.json()["page"] == 2
        args = conn.fetch.call_args_list[0].args
        assert datetime.date(2026, 8, 1) in args
        assert PAYMENT_METHOD_ID in args
        assert COST_CENTER_ID in args


class TestCreateEndpointPaths:
    """7.7 — triangulación por camino de negocio."""

    def _owner(self):
        return make_token({"role": "user"})

    async def test_expense_without_payment_method(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(
            side_effect=[{"result": json.dumps({"expense_id": EXPENSE_ID})}, EXPENSE_ROW]
        )
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/expenses",
                json={"category": "supplies", "amount": "150.00", "date": "2026-08-29"},
                headers={"Authorization": f"Bearer {self._owner()}"},
            )
        assert resp.status_code == 201
        args = conn.fetchrow.call_args_list[0].args
        assert args[7] is None and args[8] is None and args[9] is None

    async def test_cash_expense_with_optin_threads_the_session(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(
            side_effect=[{"result": json.dumps({"expense_id": EXPENSE_ID})}, EXPENSE_ROW]
        )
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/expenses",
                json={
                    "category": "varios",
                    "amount": "500.00",
                    "date": "2026-08-29",
                    "payment_method_id": PAYMENT_METHOD_ID,
                    "cash_session_id": CASH_SESSION_ID,
                },
                headers={"Authorization": f"Bearer {self._owner()}"},
            )
        assert resp.status_code == 201
        args = conn.fetchrow.call_args_list[0].args
        assert args[7] == PAYMENT_METHOD_ID
        assert args[8] == CASH_SESSION_ID

    async def test_cash_expense_without_optin_sends_null_session(self, async_client, mock_pool):
        """Control complementario: sin opt-in la sesión viaja NULL → la RPC
        hace no-op en caja (D1). El backend NO decide nada acá."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(
            side_effect=[{"result": json.dumps({"expense_id": EXPENSE_ID})}, EXPENSE_ROW]
        )
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/expenses",
                json={
                    "category": "varios",
                    "amount": "500.00",
                    "date": "2026-08-29",
                    "payment_method_id": PAYMENT_METHOD_ID,
                },
                headers={"Authorization": f"Bearer {self._owner()}"},
            )
        assert resp.status_code == 201
        assert conn.fetchrow.call_args_list[0].args[8] is None

    async def test_bank_expense_threads_the_destination_account(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(
            side_effect=[{"result": json.dumps({"expense_id": EXPENSE_ID})}, EXPENSE_ROW]
        )
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/expenses",
                json={
                    "category": "alquiler",
                    "amount": "2200.00",
                    "date": "2026-08-29",
                    "payment_method_id": PAYMENT_METHOD_ID,
                    "bank_account_id": BANK_ACCOUNT_ID,
                },
                headers={"Authorization": f"Bearer {self._owner()}"},
            )
        assert resp.status_code == 201
        assert conn.fetchrow.call_args_list[0].args[9] == BANK_ACCOUNT_ID

    async def test_credit_payment_method_rejected_by_the_server(self, async_client, mock_pool):
        """D3 — la API no es un bypass del selector: P0400 → 400."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(side_effect=_pg_error("P0400", "credit_not_supported_for_expense"))
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/expenses",
                json={
                    "category": "varios",
                    "amount": "100.00",
                    "date": "2026-08-29",
                    "payment_method_id": PAYMENT_METHOD_ID,
                },
                headers={"Authorization": f"Bearer {self._owner()}"},
            )
        assert resp.status_code == 400
        body = resp.json()
        assert body["code"] == "P0400"
        assert "credit_not_supported_for_expense" in body["detail"]

    async def test_member_without_write_role_forbidden(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=None)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/expenses",
                json={"category": "x", "amount": "1.00", "date": "2026-08-29"},
                headers={"Authorization": f"Bearer {make_token({'role': 'member'})}"},
            )
        assert resp.status_code == 403
        assert conn.fetchrow.await_count == 0


class TestExpenseErrcodeMapping:
    """7.6 — los ERRCODEs llegan traducidos, en RFC 7807."""

    @pytest.mark.parametrize(
        "sqlstate,expected",
        [
            ("P0400", 400),
            ("P0401", 403),
            ("P0403", 403),
            ("P0404", 404),
            ("P0422", 422),
            ("P0423", 409),
            ("P0424", 409),
            ("P0426", 409),
        ],
    )
    async def test_business_codes(self, async_client, mock_pool, sqlstate, expected):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(side_effect=_pg_error(sqlstate, f"mensaje de {sqlstate}"))
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/expenses",
                json={"category": "x", "amount": "1.00", "date": "2026-08-29"},
                headers={"Authorization": f"Bearer {make_token({'role': 'user'})}"},
            )
        assert resp.status_code == expected
        body = resp.json()
        assert body["code"] == sqlstate
        assert body["detail"].endswith(f"mensaje de {sqlstate}") or f"mensaje de {sqlstate}" in body["detail"]

    async def test_p0412_on_the_expense_path_is_422_with_field(self, async_client, mock_pool):
        """D19 — 'falta elegir la cuenta bancaria' es una validación de payload,
        no un 404 sin campo ofensor."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(side_effect=_pg_error("P0412", "bank_account_required_for_expense"))
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/expenses",
                json={
                    "category": "alquiler",
                    "amount": "2200.00",
                    "date": "2026-08-29",
                    "payment_method_id": PAYMENT_METHOD_ID,
                },
                headers={"Authorization": f"Bearer {make_token({'role': 'user'})}"},
            )
        assert resp.status_code == 422
        body = resp.json()
        assert body["code"] == "P0412"
        assert body["field"] == "bank_account_id"

    async def test_unknown_sqlstate_does_not_leak(self, async_client, mock_pool):
        """CONTROL NEGATIVO: un código fuera del mapa sigue saliendo 500
        genérico — el override no es un catch-all que exponga internals."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(side_effect=_pg_error("XX000", "internal details must not leak"))
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/expenses",
                json={"category": "x", "amount": "1.00", "date": "2026-08-29"},
                headers={"Authorization": f"Bearer {make_token({'role': 'user'})}"},
            )
        assert resp.status_code == 500
        assert "internal details must not leak" not in resp.text

    def test_p0412_keeps_its_global_404(self):
        """CONTROL NEGATIVO de D19: el override es POR ENDPOINT. Fuera del
        camino de gasto, P0412 sigue significando 'cuenta bancaria no
        encontrada / inactiva' → 404."""
        from backend.core.errors import (
            EXPENSE_ERRCODE_STATUS,
            EXPENSE_FIELD_BY_ERRCODE,
            _BUSINESS_ERRCODE_STATUS,
            _FIELD_BY_ERRCODE,
        )

        assert _BUSINESS_ERRCODE_STATUS["P0412"] == 404
        assert "P0412" not in _FIELD_BY_ERRCODE
        assert EXPENSE_ERRCODE_STATUS["P0412"] == 422
        assert EXPENSE_FIELD_BY_ERRCODE["P0412"] == "bank_account_id"
        # el resto del mapa global se hereda sin tocar
        assert EXPENSE_ERRCODE_STATUS["P0423"] == _BUSINESS_ERRCODE_STATUS["P0423"]

    async def test_p0412_still_404_through_the_global_handler(self):
        """El control anterior mira el mapa; éste mira el HANDLER global vivo."""
        from backend.core.errors import asyncpg_error_handler

        class _Req:
            headers: dict = {}

        resp = await asyncpg_error_handler(_Req(), _pg_error("P0412", "cuenta no encontrada"))
        assert resp.status_code == 404
        assert json.loads(resp.body)["code"] == "P0412"
        assert "field" not in json.loads(resp.body)


class TestUpdateAndDeleteEndpoints:
    def _owner(self):
        return make_token({"role": "user"})

    async def test_update_marks_only_the_fields_present_in_the_payload(self, async_client, mock_pool):
        """D12 tri-estado end-to-end: se manda sólo `amount`, así que los tres
        `_provided` viajan en false y la RPC preserva los valores vigentes."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(
            side_effect=[{"result": json.dumps({"expense_id": EXPENSE_ID})}, EXPENSE_ROW]
        )
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                f"/expenses/{EXPENSE_ID}",
                json={"amount": "300.00"},
                headers={"Authorization": f"Bearer {self._owner()}"},
            )
        assert resp.status_code == 200
        args = conn.fetchrow.call_args_list[0].args
        assert "rpc_update_expense" in args[0]
        assert args[7] is False   # p_payment_method_provided
        assert args[9] is False   # p_branch_provided
        assert args[11] is False  # p_cost_center_provided

    async def test_update_explicit_null_desimputa(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(
            side_effect=[{"result": json.dumps({"expense_id": EXPENSE_ID})}, EXPENSE_ROW]
        )
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                f"/expenses/{EXPENSE_ID}",
                json={"payment_method_id": None},
                headers={"Authorization": f"Bearer {self._owner()}"},
            )
        assert resp.status_code == 200
        args = conn.fetchrow.call_args_list[0].args
        assert args[6] is None and args[7] is True

    async def test_update_of_a_locked_expense_is_409(self, async_client, mock_pool):
        """D11 — el gasto con dinero posteado es inmutable."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(
            side_effect=_pg_error("P0423", "expense_has_cash_movement_immutable")
        )
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                f"/expenses/{EXPENSE_ID}",
                json={"amount": "300.00"},
                headers={"Authorization": f"Bearer {self._owner()}"},
            )
        assert resp.status_code == 409
        assert resp.json()["code"] == "P0423"

    async def test_delete_ok_is_a_single_rpc_call(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(
            return_value={
                "result": json.dumps(
                    {"expense_id": EXPENSE_ID, "deleted": True, "cash_reversal_id": None, "bank_reversals": 0}
                )
            }
        )
        with patch("backend.core.database.pool", pool):
            resp = await async_client.delete(
                f"/expenses/{EXPENSE_ID}", headers={"Authorization": f"Bearer {self._owner()}"}
            )
        assert resp.status_code == 204
        assert conn.fetchrow.await_count == 1
        assert "rpc_delete_expense" in conn.fetchrow.call_args_list[0].args[0]

    async def test_delete_without_open_cash_session_is_409(self, async_client, mock_pool):
        """D8 — P0426: 'abrí la caja para poder borrar este gasto'."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(
            side_effect=_pg_error("P0426", "no_open_session_for_reversal: abrí la caja")
        )
        with patch("backend.core.database.pool", pool):
            resp = await async_client.delete(
                f"/expenses/{EXPENSE_ID}", headers={"Authorization": f"Bearer {self._owner()}"}
            )
        assert resp.status_code == 409
        body = resp.json()
        assert body["code"] == "P0426"
        assert "abrí la caja" in body["detail"]

    async def test_delete_of_another_tenant_expense_is_404(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(side_effect=_pg_error("P0404", "expense_not_found"))
        with patch("backend.core.database.pool", pool):
            resp = await async_client.delete(
                f"/expenses/{EXPENSE_ID}", headers={"Authorization": f"Bearer {self._owner()}"}
            )
        assert resp.status_code == 404
        assert resp.json()["code"] == "P0404"


class TestServiceHasNoBusinessLogic:
    """Requirement de spec: el repositorio no orquesta pasos de negocio y el
    service sólo valida y delega (DEC-24)."""

    def test_service_does_not_evaluate_ledger_guards(self):
        from backend.services import expenses as svc

        src = inspect.getsource(svc)
        for forbidden in ("cash_movements", "bank_movements", "cash_sessions", "reporting_local_today"):
            assert forbidden not in src, f"lógica de libros filtrada al service: {forbidden}"

    def test_router_only_wires_dependencies(self):
        from backend.routers import expenses as router_mod

        src = inspect.getsource(router_mod)
        assert "require_role" not in src, "el guard de rol vive en el service, no en el router"
        assert "rpc_" not in src, "el router no habla SQL"
