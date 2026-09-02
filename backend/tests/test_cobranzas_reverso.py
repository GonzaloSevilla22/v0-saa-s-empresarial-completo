"""
cobranzas-reverso — Tests TDD (Strict TDD Mode).

Anular un cobro de cuenta corriente (payments_received) o un pago a
proveedor (payments_made), compensando cuenta corriente + caja + banco en
una sola transacción SQL y emitiendo el evento que revierte el libro diario
por outbox. Espejo casi exacto del par register_payment_received/_made ya
existente en test_c30_customer_supplier_accounts.py — mismo patrón de tests,
mismos fixtures (async_client, mock_pool, make_token, TEST_ACCOUNT_ID).

Comportamientos cubiertos:
  ── Schema (cash.py) ──────────────────────────────────────────────────────
  - MovementType suma payment_received_reversal / payment_made_reversal
  - _INCOME_TYPES / _EXPENSE_TYPES clasifican los dos con signo OPUESTO entre sí

  ── Schema (customer_accounts.py / supplier_accounts.py) ─────────────────
  - AccountMovementOut/SupplierMovementOut ganan is_reversible/is_reversal_blocked,
    default False
  - PaymentReversalIn: reason opcional
  - PaymentReversalOut: shape de la respuesta del RPC

  ── Repository ────────────────────────────────────────────────────────────
  - reverse_payment_received invoca rpc_reverse_payment_received(uuid, text)
  - reverse_payment_made invoca rpc_reverse_payment_made(uuid, text)
  - list_movements_page suma is_reversible/is_reversal_blocked al SELECT

  ── Service ────────────────────────────────────────────────────────────────
  - rol insuficiente → HTTPException 403, repo NO se llama
  - propaga P0404 (tenencia) como 404
  - propaga P0426 (sin sesión abierta) como 409
  - propaga P0451 (asiento original no encontrado) como 409
  - happy path devuelve reversed=true

  ── Endpoint HTTP ─────────────────────────────────────────────────────────
  - DELETE /customer-accounts/payments/{id} → 200, con y sin body
  - DELETE /supplier-accounts/payments/{id} → 200
  - member token → 403

Run: python -m pytest backend/tests/test_cobranzas_reverso.py
"""
from __future__ import annotations

import json
import sys
import types
import uuid
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
import asyncpg

from backend.tests.conftest import make_token, TEST_ACCOUNT_ID

# ── Workaround fpdf2 (pre-existing issue, mismo patrón que test_c30_*.py) ────
try:
    import fpdf  # noqa: F401
except ImportError:
    _fpdf_stub = types.ModuleType("fpdf")
    _fpdf_stub.FPDF = MagicMock  # type: ignore[attr-defined]
    sys.modules["fpdf"] = _fpdf_stub

# ── Constantes de test ─────────────────────────────────────────────────────────
ACCOUNT_ID          = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
PAYMENT_ID          = "11111111-1111-1111-1111-111111111111"
MOVEMENT_ID         = "22222222-2222-2222-2222-222222222222"
CASH_MOVEMENT_ID    = "33333333-3333-3333-3333-333333333333"

REVERSE_RECEIVED_RPC_RESULT = {
    "payment_id":           PAYMENT_ID,
    "reversed":              True,
    "account_movement_id":  MOVEMENT_ID,
    "cash_reversal_id":      CASH_MOVEMENT_ID,
    "bank_reversals":        0,
}

REVERSE_MADE_RPC_RESULT = {
    "payment_id":           PAYMENT_ID,
    "reversed":              True,
    "account_movement_id":  MOVEMENT_ID,
    "cash_reversal_id":      None,
    "bank_reversals":        1,
}


def _jsonb(val):
    return json.loads(val) if isinstance(val, str) else val


# ═══════════════════════════════════════════════════════════════════════════════
# Section 1: Schema — MovementType (cash.py)
# ═══════════════════════════════════════════════════════════════════════════════

class TestCashMovementTypeSchema:
    """RED → GREEN: los dos tipos nuevos en el enum y sus taxonomías de signo."""

    def test_movement_type_enum_has_the_two_new_values(self):
        from backend.schemas.cash import MovementType
        assert MovementType.payment_received_reversal == "payment_received_reversal"
        assert MovementType.payment_made_reversal == "payment_made_reversal"

    def test_payment_received_reversal_is_expense_egress(self):
        """D10: anular un COBRO saca plata del cajón — egreso, signo negativo esperado."""
        from backend.schemas.cash import MovementType, _EXPENSE_TYPES, _INCOME_TYPES
        assert MovementType.payment_received_reversal in _EXPENSE_TYPES
        assert MovementType.payment_received_reversal not in _INCOME_TYPES

    def test_payment_made_reversal_is_income_ingress(self):
        """D10: anular un PAGO repone plata en el cajón — ingreso, signo positivo esperado."""
        from backend.schemas.cash import MovementType, _EXPENSE_TYPES, _INCOME_TYPES
        assert MovementType.payment_made_reversal in _INCOME_TYPES
        assert MovementType.payment_made_reversal not in _EXPENSE_TYPES

    def test_the_two_reversals_have_opposite_signs(self):
        """TRIANGULATE: no comparten conjunto pese a compartir familia UI
        (Reversas) — son el par de signo opuesto que D10 describe."""
        from backend.schemas.cash import MovementType, _EXPENSE_TYPES, _INCOME_TYPES
        in_expense = MovementType.payment_received_reversal in _EXPENSE_TYPES
        in_income = MovementType.payment_made_reversal in _INCOME_TYPES
        assert in_expense and in_income

    def test_register_movement_in_validates_sign_for_payment_received_reversal(self):
        """El validador de coherencia signo↔tipo (RegisterMovementIn) rechaza
        un payment_received_reversal con importe positivo."""
        from backend.schemas.cash import RegisterMovementIn
        from pydantic import ValidationError
        with pytest.raises(ValidationError):
            RegisterMovementIn(movement_type="payment_received_reversal", amount="100")

    def test_register_movement_in_validates_sign_for_payment_made_reversal(self):
        from backend.schemas.cash import RegisterMovementIn
        from pydantic import ValidationError
        with pytest.raises(ValidationError):
            RegisterMovementIn(movement_type="payment_made_reversal", amount="-100")

    def test_register_movement_in_accepts_correct_signs(self):
        """TRIANGULATE: el signo correcto para cada uno pasa sin error."""
        from backend.schemas.cash import RegisterMovementIn
        egress = RegisterMovementIn(movement_type="payment_received_reversal", amount="-100")
        ingress = RegisterMovementIn(movement_type="payment_made_reversal", amount="100")
        assert egress.amount == -100
        assert ingress.amount == 100


# ═══════════════════════════════════════════════════════════════════════════════
# Section 2: Schema — AccountMovementOut / SupplierMovementOut derivados
# ═══════════════════════════════════════════════════════════════════════════════

class TestAccountMovementDerivedFields:
    """RED → GREEN: is_reversible/is_reversal_blocked, default False (D12)."""

    def test_customer_movement_out_defaults_derived_fields_to_false(self):
        from backend.schemas.customer_accounts import AccountMovementOut
        m = AccountMovementOut(
            id=uuid.UUID(MOVEMENT_ID),
            customer_account_id=uuid.UUID(ACCOUNT_ID),
            account_id=uuid.UUID(ACCOUNT_ID),
            amount="400.00",
            balance_after="600.00",
            movement_type="payment_received",
            created_by=uuid.UUID(ACCOUNT_ID),
            created_at="2026-09-02T00:00:00+00:00",
        )
        assert m.is_reversible is False
        assert m.is_reversal_blocked is False

    def test_customer_movement_out_accepts_derived_fields_true(self):
        from backend.schemas.customer_accounts import AccountMovementOut
        m = AccountMovementOut(
            id=uuid.UUID(MOVEMENT_ID),
            customer_account_id=uuid.UUID(ACCOUNT_ID),
            account_id=uuid.UUID(ACCOUNT_ID),
            amount="400.00",
            balance_after="600.00",
            movement_type="payment_received",
            created_by=uuid.UUID(ACCOUNT_ID),
            created_at="2026-09-02T00:00:00+00:00",
            is_reversible=True,
            is_reversal_blocked=True,
        )
        assert m.is_reversible is True
        assert m.is_reversal_blocked is True

    def test_supplier_movement_out_defaults_derived_fields_to_false(self):
        from backend.schemas.supplier_accounts import SupplierMovementOut
        m = SupplierMovementOut(
            id=uuid.UUID(MOVEMENT_ID),
            supplier_account_id=uuid.UUID(ACCOUNT_ID),
            account_id=uuid.UUID(ACCOUNT_ID),
            amount="300.00",
            balance_after="700.00",
            movement_type="payment_made",
            created_by=uuid.UUID(ACCOUNT_ID),
            created_at="2026-09-02T00:00:00+00:00",
        )
        assert m.is_reversible is False
        assert m.is_reversal_blocked is False


class TestPaymentReversalSchemas:
    """PaymentReversalIn/Out — motivo opcional, shape de la respuesta."""

    def test_reversal_in_reason_is_optional(self):
        from backend.schemas.customer_accounts import PaymentReversalIn
        assert PaymentReversalIn().reason is None
        assert PaymentReversalIn(reason="cobro duplicado").reason == "cobro duplicado"

    def test_reversal_out_shape(self):
        from backend.schemas.customer_accounts import PaymentReversalOut
        out = PaymentReversalOut(**REVERSE_RECEIVED_RPC_RESULT)
        assert out.reversed is True
        assert str(out.payment_id) == PAYMENT_ID

    def test_supplier_reversal_in_reason_is_optional(self):
        from backend.schemas.supplier_accounts import PaymentReversalIn as SupplierPaymentReversalIn
        assert SupplierPaymentReversalIn().reason is None


# ═══════════════════════════════════════════════════════════════════════════════
# Section 3: Repository — CustomerAccountRepository.reverse_payment_received
# ═══════════════════════════════════════════════════════════════════════════════

class TestCustomerAccountRepositoryReversal:
    @pytest.fixture
    def mock_conn(self):
        conn = AsyncMock()
        conn.fetchrow = AsyncMock(return_value=None)
        conn.fetch = AsyncMock(return_value=[])
        conn.fetchval = AsyncMock(return_value=0)
        conn.execute = AsyncMock(return_value="SET")
        return conn

    @pytest.mark.asyncio
    async def test_reverse_payment_received_calls_rpc_with_payment_id_and_reason(self, mock_conn):
        from backend.repositories.customer_account_repository import CustomerAccountRepository
        mock_conn.fetchrow.return_value = {"result": json.dumps(REVERSE_RECEIVED_RPC_RESULT)}

        repo = CustomerAccountRepository(mock_conn)
        result = await repo.reverse_payment_received(PAYMENT_ID, "motivo de prueba")

        call = mock_conn.fetchrow.call_args
        assert "rpc_reverse_payment_received" in call[0][0]
        assert call[0][1] == PAYMENT_ID
        assert call[0][2] == "motivo de prueba"
        assert result["reversed"] is True

    @pytest.mark.asyncio
    async def test_reverse_payment_received_passes_none_reason(self, mock_conn):
        """TRIANGULATE: sin motivo, el RPC recibe NULL (no una cadena vacía)."""
        from backend.repositories.customer_account_repository import CustomerAccountRepository
        mock_conn.fetchrow.return_value = {"result": json.dumps(REVERSE_RECEIVED_RPC_RESULT)}

        repo = CustomerAccountRepository(mock_conn)
        await repo.reverse_payment_received(PAYMENT_ID, None)

        call = mock_conn.fetchrow.call_args
        assert call[0][2] is None

    @pytest.mark.asyncio
    async def test_list_movements_page_selects_derived_columns(self, mock_conn):
        """D12 (task 9.2): el SELECT paginado suma is_reversible/is_reversal_blocked
        con el mismo predicado EXISTS que evalúa el servidor."""
        from backend.repositories.customer_account_repository import CustomerAccountRepository
        mock_conn.fetch.return_value = []
        mock_conn.fetchval.return_value = 0

        repo = CustomerAccountRepository(mock_conn)
        await repo.list_movements_page(MOVEMENT_ID, account_id=ACCOUNT_ID, page=0, size=50)

        select_sql = mock_conn.fetch.call_args[0][0]
        assert "is_reversible" in select_sql
        assert "is_reversal_blocked" in select_sql
        assert "payments_received" in select_sql
        assert "cash_sessions" in select_sql


# ═══════════════════════════════════════════════════════════════════════════════
# Section 4: Repository — SupplierAccountRepository.reverse_payment_made
# ═══════════════════════════════════════════════════════════════════════════════

class TestSupplierAccountRepositoryReversal:
    @pytest.fixture
    def mock_conn(self):
        conn = AsyncMock()
        conn.fetchrow = AsyncMock(return_value=None)
        conn.fetch = AsyncMock(return_value=[])
        conn.fetchval = AsyncMock(return_value=0)
        conn.execute = AsyncMock(return_value="SET")
        return conn

    @pytest.mark.asyncio
    async def test_reverse_payment_made_calls_rpc(self, mock_conn):
        from backend.repositories.supplier_account_repository import SupplierAccountRepository
        mock_conn.fetchrow.return_value = {"result": json.dumps(REVERSE_MADE_RPC_RESULT)}

        repo = SupplierAccountRepository(mock_conn)
        result = await repo.reverse_payment_made(PAYMENT_ID, "gate")

        call = mock_conn.fetchrow.call_args
        assert "rpc_reverse_payment_made" in call[0][0]
        assert call[0][1] == PAYMENT_ID
        assert call[0][2] == "gate"
        assert result["bank_reversals"] == 1

    @pytest.mark.asyncio
    async def test_list_movements_page_selects_derived_columns(self, mock_conn):
        from backend.repositories.supplier_account_repository import SupplierAccountRepository
        mock_conn.fetch.return_value = []
        mock_conn.fetchval.return_value = 0

        repo = SupplierAccountRepository(mock_conn)
        await repo.list_movements_page(MOVEMENT_ID, account_id=ACCOUNT_ID, page=0, size=50)

        select_sql = mock_conn.fetch.call_args[0][0]
        assert "is_reversible" in select_sql
        assert "is_reversal_blocked" in select_sql
        assert "payments_made" in select_sql


# ═══════════════════════════════════════════════════════════════════════════════
# Section 5: Service — reverse_payment_received / reverse_payment_made
# ═══════════════════════════════════════════════════════════════════════════════

class TestCustomerAccountReversalService:
    def _make_auth(self, role: str = "user") -> dict:
        return {"sub": "test-uid", "role": role}

    @pytest.mark.asyncio
    async def test_insufficient_role_raises_403_and_repo_not_called(self):
        from backend.services import customer_accounts as svc
        from backend.schemas.customer_accounts import PaymentReversalIn
        from fastapi import HTTPException

        mock_repo = AsyncMock()
        auth = self._make_auth("member")

        with pytest.raises(HTTPException) as exc_info:
            await svc.reverse_payment_received(mock_repo, auth, PAYMENT_ID, PaymentReversalIn())

        assert exc_info.value.status_code == 403
        mock_repo.reverse_payment_received.assert_not_called()

    @pytest.mark.asyncio
    async def test_propagates_p0404_as_404(self):
        """D8: pago ajeno o inexistente → 404."""
        from backend.services import customer_accounts as svc
        from backend.schemas.customer_accounts import PaymentReversalIn
        from fastapi import HTTPException

        err = asyncpg.PostgresError()
        err.sqlstate = "P0404"
        mock_repo = AsyncMock()
        mock_repo.reverse_payment_received.side_effect = err

        with pytest.raises(HTTPException) as exc_info:
            await svc.reverse_payment_received(
                mock_repo, self._make_auth(), PAYMENT_ID, PaymentReversalIn()
            )

        assert exc_info.value.status_code == 404

    @pytest.mark.asyncio
    async def test_propagates_p0426_as_409(self):
        """D7: sin sesión de caja abierta → 409."""
        from backend.services import customer_accounts as svc
        from backend.schemas.customer_accounts import PaymentReversalIn
        from fastapi import HTTPException

        err = asyncpg.PostgresError()
        err.sqlstate = "P0426"
        mock_repo = AsyncMock()
        mock_repo.reverse_payment_received.side_effect = err

        with pytest.raises(HTTPException) as exc_info:
            await svc.reverse_payment_received(
                mock_repo, self._make_auth(), PAYMENT_ID, PaymentReversalIn()
            )

        assert exc_info.value.status_code == 409

    @pytest.mark.asyncio
    async def test_propagates_p0451_as_409(self):
        """D5: asiento original no encontrado todavía (carrera del outbox) → 409."""
        from backend.services import customer_accounts as svc
        from backend.schemas.customer_accounts import PaymentReversalIn
        from fastapi import HTTPException

        err = asyncpg.PostgresError()
        err.sqlstate = "P0451"
        mock_repo = AsyncMock()
        mock_repo.reverse_payment_received.side_effect = err

        with pytest.raises(HTTPException) as exc_info:
            await svc.reverse_payment_received(
                mock_repo, self._make_auth(), PAYMENT_ID, PaymentReversalIn()
            )

        assert exc_info.value.status_code == 409

    @pytest.mark.asyncio
    async def test_happy_path_returns_reversed_true(self):
        from backend.services import customer_accounts as svc
        from backend.schemas.customer_accounts import PaymentReversalIn

        mock_repo = AsyncMock()
        mock_repo.reverse_payment_received.return_value = dict(REVERSE_RECEIVED_RPC_RESULT)

        result = await svc.reverse_payment_received(
            mock_repo, self._make_auth(), PAYMENT_ID, PaymentReversalIn(reason="test")
        )

        assert result["reversed"] is True
        mock_repo.reverse_payment_received.assert_called_once_with(PAYMENT_ID, "test")

    @pytest.mark.asyncio
    async def test_role_guard_evaluated_before_repo_call(self):
        """10.6: el guard de rol se evalúa ANTES de tocar el repo — verificado
        por orden de llamadas: con rol insuficiente, el repo NUNCA se invoca
        (ya cubierto arriba), y con rol suficiente SIEMPRE se invoca."""
        from backend.services import customer_accounts as svc
        from backend.schemas.customer_accounts import PaymentReversalIn

        mock_repo = AsyncMock()
        mock_repo.reverse_payment_received.return_value = dict(REVERSE_RECEIVED_RPC_RESULT)

        await svc.reverse_payment_received(
            mock_repo, self._make_auth("admin"), PAYMENT_ID, PaymentReversalIn()
        )
        mock_repo.reverse_payment_received.assert_called_once()


class TestSupplierAccountReversalService:
    def _make_auth(self, role: str = "user") -> dict:
        return {"sub": "test-uid", "role": role}

    @pytest.mark.asyncio
    async def test_insufficient_role_raises_403(self):
        from backend.services import supplier_accounts as svc
        from backend.schemas.supplier_accounts import PaymentReversalIn
        from fastapi import HTTPException

        mock_repo = AsyncMock()
        with pytest.raises(HTTPException) as exc_info:
            await svc.reverse_payment_made(
                mock_repo, self._make_auth("member"), PAYMENT_ID, PaymentReversalIn()
            )
        assert exc_info.value.status_code == 403

    @pytest.mark.asyncio
    async def test_propagates_p0404_as_404(self):
        from backend.services import supplier_accounts as svc
        from backend.schemas.supplier_accounts import PaymentReversalIn
        from fastapi import HTTPException

        err = asyncpg.PostgresError()
        err.sqlstate = "P0404"
        mock_repo = AsyncMock()
        mock_repo.reverse_payment_made.side_effect = err

        with pytest.raises(HTTPException) as exc_info:
            await svc.reverse_payment_made(
                mock_repo, self._make_auth(), PAYMENT_ID, PaymentReversalIn()
            )
        assert exc_info.value.status_code == 404

    @pytest.mark.asyncio
    async def test_happy_path_returns_reversed_true(self):
        from backend.services import supplier_accounts as svc
        from backend.schemas.supplier_accounts import PaymentReversalIn

        mock_repo = AsyncMock()
        mock_repo.reverse_payment_made.return_value = dict(REVERSE_MADE_RPC_RESULT)

        result = await svc.reverse_payment_made(
            mock_repo, self._make_auth(), PAYMENT_ID, PaymentReversalIn()
        )
        assert result["reversed"] is True


# ═══════════════════════════════════════════════════════════════════════════════
# Section 6: Endpoint HTTP
# ═══════════════════════════════════════════════════════════════════════════════

class TestCustomerAccountReversalEndpoint:
    @pytest.mark.asyncio
    async def test_delete_payment_received_returns_200_with_body(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value={"result": json.dumps(REVERSE_RECEIVED_RPC_RESULT)})

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.request(
                "DELETE",
                f"/customer-accounts/payments/{PAYMENT_ID}",
                json={"reason": "cobro duplicado"},
                headers=headers,
            )

        assert response.status_code == 200
        assert response.json()["reversed"] is True

    @pytest.mark.asyncio
    async def test_delete_payment_received_returns_200_without_body(self, async_client, mock_pool):
        """TRIANGULATE: sin body en absoluto (motivo opcional, D9) — misma
        respuesta 200."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value={"result": json.dumps(REVERSE_RECEIVED_RPC_RESULT)})

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.request(
                "DELETE",
                f"/customer-accounts/payments/{PAYMENT_ID}",
                headers=headers,
            )

        assert response.status_code == 200

    @pytest.mark.asyncio
    async def test_delete_payment_received_member_token_returns_403(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value={"result": "{}"})

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'member'})}"}
            response = await async_client.request(
                "DELETE",
                f"/customer-accounts/payments/{PAYMENT_ID}",
                headers=headers,
            )

        assert response.status_code == 403

    @pytest.mark.asyncio
    async def test_delete_payment_received_foreign_tenant_returns_404(self, async_client, mock_pool):
        """D8: la RPC rechaza con P0404 → el endpoint responde 404."""
        pool, conn = mock_pool
        err = asyncpg.PostgresError()
        err.sqlstate = "P0404"
        conn.fetchrow = AsyncMock(side_effect=err)

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.request(
                "DELETE",
                f"/customer-accounts/payments/{PAYMENT_ID}",
                headers=headers,
            )

        assert response.status_code == 404


class TestSupplierAccountReversalEndpoint:
    @pytest.mark.asyncio
    async def test_delete_payment_made_returns_200(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value={"result": json.dumps(REVERSE_MADE_RPC_RESULT)})

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.request(
                "DELETE",
                f"/supplier-accounts/payments/{PAYMENT_ID}",
                json={"reason": "pago duplicado"},
                headers=headers,
            )

        assert response.status_code == 200
        assert response.json()["reversed"] is True

    @pytest.mark.asyncio
    async def test_delete_payment_made_member_token_returns_403(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value={"result": "{}"})

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'member'})}"}
            response = await async_client.request(
                "DELETE",
                f"/supplier-accounts/payments/{PAYMENT_ID}",
                headers=headers,
            )

        assert response.status_code == 403
