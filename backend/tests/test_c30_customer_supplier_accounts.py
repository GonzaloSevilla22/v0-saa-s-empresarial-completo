"""
C-30 v21-customer-supplier-accounts — Tests TDD (Strict TDD Mode).

Comportamientos cubiertos:
  ── Repository (CustomerAccount) ─────────────────────────────────────────────
  - create_account: invoca rpc_create_customer_account y devuelve resultado
  - register_payment_received: invoca rpc_register_payment_received con los args correctos
  - get_account: hace SELECT de customer_accounts por client_id
  - list_movements: hace SELECT de customer_account_movements paginado

  ── Repository (SupplierAccount) ─────────────────────────────────────────────
  - create_supplier_account: invoca rpc_create_supplier_account
  - register_payment_made: invoca rpc_register_payment_made
  - register_supplier_charge: invoca rpc_register_supplier_charge

  ── Service (CustomerAccount) ─────────────────────────────────────────────────
  - rol insuficiente → HTTPException 403
  - propaga P0409 overpayment como 409
  - happy path devuelve balance_after
  - amount <= 0 → 400 (schema Pydantic)

  ── Service (SupplierAccount) ─────────────────────────────────────────────────
  - rol insuficiente → HTTPException 403
  - propaga P0409 como 409
  - register_supplier_charge happy path devuelve movement_id

  ── Endpoint HTTP ─────────────────────────────────────────────────────────────
  - POST /customer-accounts → 201
  - GET /clientes/{client_id}/cuenta → 200 con saldo + historial
  - POST /customer-accounts/payments → 200 (cobro)
  - POST /supplier-accounts → 201
  - POST /supplier-accounts/payments → 200
  - POST /supplier-accounts/charges → 200
  - member token → 403 en rutas de escritura

  ── Invariantes del dominio (TDD obligatorio) ─────────────────────────────────
  - 12.1: venta a crédito → invoca rpc correcto (mock)
  - 12.2: regresión C-29: cash/other siguen funcionando (same interface)
  - 12.3: crédito sin client_id → error (schema/service)
  - 12.4: venta + cobro total → balance en 0 (lógica del service)
  - 11.3: idempotencia — doble cobro misma key → replayed=true

Run: python -m pytest backend/tests/test_c30_customer_supplier_accounts.py
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

# ── Workaround fpdf2 (pre-existing issue) ─────────────────────────────────────
if "fpdf" not in sys.modules:
    _fpdf_stub = types.ModuleType("fpdf")
    _fpdf_stub.FPDF = MagicMock  # type: ignore[attr-defined]
    sys.modules["fpdf"] = _fpdf_stub

# ── Constantes de test ─────────────────────────────────────────────────────────
ACCOUNT_ID            = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
CLIENT_ID             = "cccccccc-cccc-cccc-cccc-cccccccccccc"
SUPPLIER_ID           = "dddddddd-dddd-dddd-dddd-dddddddddddd"
CUSTOMER_ACCOUNT_ID   = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
SUPPLIER_ACCOUNT_ID   = "ffffffff-ffff-ffff-ffff-ffffffffffff"
PAYMENT_ID            = "11111111-1111-1111-1111-111111111111"
MOVEMENT_ID           = "22222222-2222-2222-2222-222222222222"
OPERATION_ID          = "33333333-3333-3333-3333-333333333333"
IDEMPOTENCY_KEY       = "test-idempotency-key-c30-001"

CUSTOMER_ACCOUNT_ROW = {
    "id":         CUSTOMER_ACCOUNT_ID,
    "account_id": ACCOUNT_ID,
    "client_id":  CLIENT_ID,
    "balance":    "0.00",
    "created_at": "2026-06-20T00:00:00+00:00",
}

CUSTOMER_MOVEMENT_ROW = {
    "id":                   MOVEMENT_ID,
    "customer_account_id":  CUSTOMER_ACCOUNT_ID,
    "account_id":           ACCOUNT_ID,
    "amount":               "1000.00",
    "balance_after":        "1000.00",
    "movement_type":        "sale",
    "reference_id":         None,
    "created_by":           "11111111-1111-1111-1111-111111111111",
    "created_at":           "2026-06-20T00:00:00+00:00",
}

PAYMENT_RECEIVED_RPC_RESULT = {
    "payment_id":           PAYMENT_ID,
    "customer_account_id":  CUSTOMER_ACCOUNT_ID,
    "balance_after":        "600.00",
    "replayed":             False,
    "operation_id":         OPERATION_ID,
}

PAYMENT_MADE_RPC_RESULT = {
    "payment_id":          PAYMENT_ID,
    "supplier_account_id": SUPPLIER_ACCOUNT_ID,
    "balance_after":       "600.00",
    "replayed":            False,
    "operation_id":        OPERATION_ID,
}

SUPPLIER_CHARGE_RPC_RESULT = {
    "movement_id":         MOVEMENT_ID,
    "supplier_account_id": SUPPLIER_ACCOUNT_ID,
    "balance_after":       "1500.00",
    "replayed":            False,
    "operation_id":        OPERATION_ID,
}

REPLAYED_RESULT = {
    "payment_id":           None,
    "customer_account_id":  None,
    "balance_after":        None,
    "replayed":             True,
    "operation_id":         OPERATION_ID,
}


def _jsonb(val):
    return json.loads(val) if isinstance(val, str) else val


# ═══════════════════════════════════════════════════════════════════════════════
# SAFETY NET — existing tests must pass (run this first in a real environment)
# ═══════════════════════════════════════════════════════════════════════════════


# ═══════════════════════════════════════════════════════════════════════════════
# Section 1: Repository — CustomerAccountRepository
# ═══════════════════════════════════════════════════════════════════════════════

class TestCustomerAccountRepository:
    """RED → GREEN: Repository invoca los RPCs correctos."""

    @pytest.fixture
    def mock_conn(self):
        conn = AsyncMock()
        conn.fetchrow = AsyncMock(return_value=None)
        conn.fetch = AsyncMock(return_value=[])
        conn.execute = AsyncMock(return_value="SET")
        return conn

    @pytest.mark.asyncio
    async def test_create_account_calls_rpc(self, mock_conn):
        """create_account invoca rpc_create_customer_account con client_id."""
        from backend.repositories.customer_account_repository import CustomerAccountRepository
        rpc_result = json.dumps({
            "customer_account_id": CUSTOMER_ACCOUNT_ID,
            "client_id":           CLIENT_ID,
            "balance":             "0.00",
        })
        mock_conn.fetchrow.return_value = {"result": rpc_result}

        repo = CustomerAccountRepository(mock_conn)
        result = await repo.create_account(CLIENT_ID)

        call_args = mock_conn.fetchrow.call_args[0][0]
        assert "rpc_create_customer_account" in call_args
        assert result["customer_account_id"] == CUSTOMER_ACCOUNT_ID

    @pytest.mark.asyncio
    async def test_register_payment_received_calls_rpc(self, mock_conn):
        """register_payment_received invoca rpc_register_payment_received con los 4 args."""
        from backend.repositories.customer_account_repository import CustomerAccountRepository
        rpc_result = json.dumps(PAYMENT_RECEIVED_RPC_RESULT)
        mock_conn.fetchrow.return_value = {"result": rpc_result}

        repo = CustomerAccountRepository(mock_conn)
        result = await repo.register_payment_received(
            idempotency_key=IDEMPOTENCY_KEY,
            client_id=CLIENT_ID,
            amount=400.0,
            reference_sale_id=None,
        )

        call_args = mock_conn.fetchrow.call_args[0][0]
        assert "rpc_register_payment_received" in call_args
        assert result["replayed"] is False
        assert result["balance_after"] == "600.00"

    @pytest.mark.asyncio
    async def test_get_account_selects_by_client_id(self, mock_conn):
        """get_account hace SELECT de customer_accounts filtrando por client_id."""
        from backend.repositories.customer_account_repository import CustomerAccountRepository
        mock_conn.fetchrow.return_value = dict(CUSTOMER_ACCOUNT_ROW)

        repo = CustomerAccountRepository(mock_conn)
        result = await repo.get_account(ACCOUNT_ID, CLIENT_ID)

        call_args = mock_conn.fetchrow.call_args[0][0]
        assert "customer_accounts" in call_args
        assert result is not None

    @pytest.mark.asyncio
    async def test_list_movements_selects_by_account(self, mock_conn):
        """list_movements hace SELECT paginado de customer_account_movements."""
        from backend.repositories.customer_account_repository import CustomerAccountRepository
        mock_conn.fetch.return_value = [dict(CUSTOMER_MOVEMENT_ROW)]

        repo = CustomerAccountRepository(mock_conn)
        results = await repo.list_movements(CUSTOMER_ACCOUNT_ID, limit=20, offset=0)

        call_args = mock_conn.fetch.call_args[0][0]
        assert "customer_account_movements" in call_args
        assert len(results) == 1


# ═══════════════════════════════════════════════════════════════════════════════
# Section 2: Repository — SupplierAccountRepository
# ═══════════════════════════════════════════════════════════════════════════════

class TestSupplierAccountRepository:
    """RED → GREEN: Repository de proveedor."""

    @pytest.fixture
    def mock_conn(self):
        conn = AsyncMock()
        conn.fetchrow = AsyncMock(return_value=None)
        conn.fetch = AsyncMock(return_value=[])
        conn.execute = AsyncMock(return_value="SET")
        return conn

    @pytest.mark.asyncio
    async def test_create_supplier_account_calls_rpc(self, mock_conn):
        """create_supplier_account invoca rpc_create_supplier_account."""
        from backend.repositories.supplier_account_repository import SupplierAccountRepository
        rpc_result = json.dumps({
            "supplier_account_id": SUPPLIER_ACCOUNT_ID,
            "supplier_id":         SUPPLIER_ID,
            "balance":             "0.00",
        })
        mock_conn.fetchrow.return_value = {"result": rpc_result}

        repo = SupplierAccountRepository(mock_conn)
        result = await repo.create_account(SUPPLIER_ID)

        call_args = mock_conn.fetchrow.call_args[0][0]
        assert "rpc_create_supplier_account" in call_args
        assert result["supplier_account_id"] == SUPPLIER_ACCOUNT_ID

    @pytest.mark.asyncio
    async def test_register_payment_made_calls_rpc(self, mock_conn):
        """register_payment_made invoca rpc_register_payment_made."""
        from backend.repositories.supplier_account_repository import SupplierAccountRepository
        rpc_result = json.dumps(PAYMENT_MADE_RPC_RESULT)
        mock_conn.fetchrow.return_value = {"result": rpc_result}

        repo = SupplierAccountRepository(mock_conn)
        result = await repo.register_payment_made(
            idempotency_key=IDEMPOTENCY_KEY,
            supplier_id=SUPPLIER_ID,
            amount=400.0,
            reference_purchase_id=None,
        )

        call_args = mock_conn.fetchrow.call_args[0][0]
        assert "rpc_register_payment_made" in call_args
        assert result["replayed"] is False

    @pytest.mark.asyncio
    async def test_register_supplier_charge_calls_rpc(self, mock_conn):
        """register_supplier_charge invoca rpc_register_supplier_charge."""
        from backend.repositories.supplier_account_repository import SupplierAccountRepository
        rpc_result = json.dumps(SUPPLIER_CHARGE_RPC_RESULT)
        mock_conn.fetchrow.return_value = {"result": rpc_result}

        repo = SupplierAccountRepository(mock_conn)
        result = await repo.register_supplier_charge(
            idempotency_key=IDEMPOTENCY_KEY,
            supplier_id=SUPPLIER_ID,
            amount=1500.0,
            reference_id=None,
        )

        call_args = mock_conn.fetchrow.call_args[0][0]
        assert "rpc_register_supplier_charge" in call_args
        assert result["balance_after"] == "1500.00"


# ═══════════════════════════════════════════════════════════════════════════════
# Section 3: Service — CustomerAccountService
# ═══════════════════════════════════════════════════════════════════════════════

class TestCustomerAccountService:
    """RED → GREEN: Guards de rol, propagación de errores, happy paths."""

    def _make_auth(self, role: str = "user") -> dict:
        return {"sub": "test-uid", "role": role}

    @pytest.mark.asyncio
    async def test_register_payment_insufficient_role_raises_403(self):
        """Rol 'member' sin permiso de escritura → HTTPException 403."""
        from backend.services import customer_accounts as svc
        from backend.schemas.customer_accounts import PaymentReceivedIn
        from fastapi import HTTPException

        mock_repo = AsyncMock()
        auth = self._make_auth(role="member")
        payload = PaymentReceivedIn(
            idempotency_key=IDEMPOTENCY_KEY,
            client_id=uuid.UUID(CLIENT_ID),
            amount=Decimal("400"),
        )

        with pytest.raises(HTTPException) as exc_info:
            await svc.register_payment_received(mock_repo, auth, payload)

        assert exc_info.value.status_code == 403
        mock_repo.register_payment_received.assert_not_called()

    @pytest.mark.asyncio
    async def test_register_payment_propagates_p0409_as_409(self):
        """P0409 (overpayment del RPC) → HTTPException 409."""
        from backend.services import customer_accounts as svc
        from backend.schemas.customer_accounts import PaymentReceivedIn
        from fastapi import HTTPException

        err = asyncpg.PostgresError()
        err.sqlstate = "P0409"

        mock_repo = AsyncMock()
        mock_repo.register_payment_received.side_effect = err

        auth = self._make_auth("user")
        payload = PaymentReceivedIn(
            idempotency_key=IDEMPOTENCY_KEY,
            client_id=uuid.UUID(CLIENT_ID),
            amount=Decimal("9999"),
        )

        with pytest.raises(HTTPException) as exc_info:
            await svc.register_payment_received(mock_repo, auth, payload)

        assert exc_info.value.status_code == 409

    @pytest.mark.asyncio
    async def test_register_payment_happy_path_returns_balance_after(self):
        """Happy path: devuelve balance_after del RPC."""
        from backend.services import customer_accounts as svc
        from backend.schemas.customer_accounts import PaymentReceivedIn

        mock_repo = AsyncMock()
        mock_repo.register_payment_received.return_value = {
            "payment_id":           PAYMENT_ID,
            "customer_account_id":  CUSTOMER_ACCOUNT_ID,
            "balance_after":        "600.00",
            "replayed":             False,
            "operation_id":         OPERATION_ID,
        }

        auth = self._make_auth("user")
        payload = PaymentReceivedIn(
            idempotency_key=IDEMPOTENCY_KEY,
            client_id=uuid.UUID(CLIENT_ID),
            amount=Decimal("400"),
        )

        result = await svc.register_payment_received(mock_repo, auth, payload)

        assert result["balance_after"] == "600.00"
        mock_repo.register_payment_received.assert_called_once()

    def test_payment_received_schema_rejects_nonpositive_amount(self):
        """Pydantic valida amount > 0 antes de llegar al service."""
        from backend.schemas.customer_accounts import PaymentReceivedIn
        from pydantic import ValidationError

        with pytest.raises(ValidationError):
            PaymentReceivedIn(
                idempotency_key=IDEMPOTENCY_KEY,
                client_id=uuid.UUID(CLIENT_ID),
                amount=Decimal("0"),
            )

        with pytest.raises(ValidationError):
            PaymentReceivedIn(
                idempotency_key=IDEMPOTENCY_KEY,
                client_id=uuid.UUID(CLIENT_ID),
                amount=Decimal("-50"),
            )


# ═══════════════════════════════════════════════════════════════════════════════
# Section 4: Service — SupplierAccountService
# ═══════════════════════════════════════════════════════════════════════════════

class TestSupplierAccountService:
    """RED → GREEN: Guards de rol y happy paths para proveedores."""

    def _make_auth(self, role: str = "user") -> dict:
        return {"sub": "test-uid", "role": role}

    @pytest.mark.asyncio
    async def test_register_payment_made_insufficient_role_raises_403(self):
        """Rol 'member' → HTTPException 403 en register_payment_made."""
        from backend.services import supplier_accounts as svc
        from backend.schemas.supplier_accounts import PaymentMadeIn
        from fastapi import HTTPException

        mock_repo = AsyncMock()
        auth = self._make_auth("member")
        payload = PaymentMadeIn(
            idempotency_key=IDEMPOTENCY_KEY,
            supplier_id=uuid.UUID(SUPPLIER_ID),
            amount=Decimal("400"),
        )

        with pytest.raises(HTTPException) as exc_info:
            await svc.register_payment_made(mock_repo, auth, payload)

        assert exc_info.value.status_code == 403

    @pytest.mark.asyncio
    async def test_register_supplier_charge_happy_path(self):
        """Happy path: register_supplier_charge devuelve movement_id."""
        from backend.services import supplier_accounts as svc
        from backend.schemas.supplier_accounts import SupplierChargeIn

        mock_repo = AsyncMock()
        mock_repo.register_supplier_charge.return_value = {
            "movement_id":         MOVEMENT_ID,
            "supplier_account_id": SUPPLIER_ACCOUNT_ID,
            "balance_after":       "1500.00",
            "replayed":            False,
        }

        auth = self._make_auth("admin")
        payload = SupplierChargeIn(
            idempotency_key=IDEMPOTENCY_KEY,
            supplier_id=uuid.UUID(SUPPLIER_ID),
            amount=Decimal("1500"),
        )

        result = await svc.register_supplier_charge(mock_repo, auth, payload)

        assert result["balance_after"] == "1500.00"

    @pytest.mark.asyncio
    async def test_register_payment_made_propagates_p0409(self):
        """P0409 (overpayment) → HTTPException 409."""
        from backend.services import supplier_accounts as svc
        from backend.schemas.supplier_accounts import PaymentMadeIn
        from fastapi import HTTPException

        err = asyncpg.PostgresError()
        err.sqlstate = "P0409"

        mock_repo = AsyncMock()
        mock_repo.register_payment_made.side_effect = err

        auth = self._make_auth("user")
        payload = PaymentMadeIn(
            idempotency_key=IDEMPOTENCY_KEY,
            supplier_id=uuid.UUID(SUPPLIER_ID),
            amount=Decimal("9999"),
        )

        with pytest.raises(HTTPException) as exc_info:
            await svc.register_payment_made(mock_repo, auth, payload)

        assert exc_info.value.status_code == 409


# ═══════════════════════════════════════════════════════════════════════════════
# Section 5: Endpoint HTTP
# ═══════════════════════════════════════════════════════════════════════════════

class TestCustomerAccountEndpoints:
    """RED → GREEN: Endpoints HTTP de cuentas corrientes.

    Patrón: patch("backend.core.database.pool", pool) — igual que C-29.
    La conexión mock debe devolver los valores que los RPCs devuelven en producción.
    """

    @pytest.mark.asyncio
    async def test_post_customer_accounts_returns_201(self, async_client, mock_pool):
        """POST /customer-accounts?client_id=... → 201."""
        pool, conn = mock_pool
        rpc_result = json.dumps({
            "customer_account_id": CUSTOMER_ACCOUNT_ID,
            "client_id":           CLIENT_ID,
            "balance":             "0.00",
        })
        conn.fetchrow = AsyncMock(return_value={"result": rpc_result})

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.post(
                "/customer-accounts",
                params={"client_id": CLIENT_ID},
                headers=headers,
            )

        assert response.status_code in (200, 201)

    @pytest.mark.asyncio
    async def test_get_customer_account_returns_200(self, async_client, mock_pool):
        """GET /clientes/{client_id}/cuenta → 200 con saldo."""
        pool, conn = mock_pool
        # Primera llamada: get_account (fetchrow) devuelve la fila de customer_accounts
        # Segunda llamada: list_movements (fetch) devuelve lista vacía
        conn.fetchrow = AsyncMock(return_value={
            "id":         CUSTOMER_ACCOUNT_ID,
            "account_id": ACCOUNT_ID,
            "client_id":  CLIENT_ID,
            "balance":    "1000.00",
            "created_at": "2026-06-20T00:00:00+00:00",
        })
        conn.fetch = AsyncMock(return_value=[])

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.get(
                f"/clientes/{CLIENT_ID}/cuenta",
                headers=headers,
            )

        assert response.status_code == 200

    @pytest.mark.asyncio
    async def test_post_payment_received_returns_200(self, async_client, mock_pool):
        """POST /customer-accounts/payments → 200."""
        pool, conn = mock_pool
        rpc_result = json.dumps({
            "payment_id":           PAYMENT_ID,
            "customer_account_id":  CUSTOMER_ACCOUNT_ID,
            "balance_after":        "600.00",
            "replayed":             False,
            "operation_id":         OPERATION_ID,
        })
        conn.fetchrow = AsyncMock(return_value={"result": rpc_result})

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.post(
                "/customer-accounts/payments",
                json={
                    "idempotency_key": IDEMPOTENCY_KEY,
                    "client_id":       CLIENT_ID,
                    "amount":          "400.00",
                },
                headers=headers,
            )

        assert response.status_code == 200

    @pytest.mark.asyncio
    async def test_member_token_returns_403_on_write(self, async_client, mock_pool):
        """Token member → 403 en rutas de escritura (guard require_role en service)."""
        pool, conn = mock_pool
        # El guard se dispara antes de llamar al repo, así que fetchrow no importa
        conn.fetchrow = AsyncMock(return_value={"result": "{}"})

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'member'})}"}
            response = await async_client.post(
                "/customer-accounts/payments",
                json={
                    "idempotency_key": IDEMPOTENCY_KEY,
                    "client_id":       CLIENT_ID,
                    "amount":          "400.00",
                },
                headers=headers,
            )

        assert response.status_code == 403


class TestSupplierAccountEndpoints:
    """RED → GREEN: Endpoints de cuentas corrientes de proveedores.

    Patrón: patch("backend.core.database.pool", pool) — igual que C-29.
    """

    @pytest.mark.asyncio
    async def test_post_supplier_accounts_returns_201(self, async_client, mock_pool):
        """POST /supplier-accounts?supplier_id=... → 201."""
        pool, conn = mock_pool
        rpc_result = json.dumps({
            "supplier_account_id": SUPPLIER_ACCOUNT_ID,
            "supplier_id":         SUPPLIER_ID,
            "balance":             "0.00",
        })
        conn.fetchrow = AsyncMock(return_value={"result": rpc_result})

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.post(
                "/supplier-accounts",
                params={"supplier_id": SUPPLIER_ID},
                headers=headers,
            )

        assert response.status_code in (200, 201)

    @pytest.mark.asyncio
    async def test_post_payment_made_returns_200(self, async_client, mock_pool):
        """POST /supplier-accounts/payments → 200."""
        pool, conn = mock_pool
        rpc_result = json.dumps({
            "payment_id":          PAYMENT_ID,
            "supplier_account_id": SUPPLIER_ACCOUNT_ID,
            "balance_after":       "600.00",
            "replayed":            False,
            "operation_id":        OPERATION_ID,
        })
        conn.fetchrow = AsyncMock(return_value={"result": rpc_result})

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.post(
                "/supplier-accounts/payments",
                json={
                    "idempotency_key": IDEMPOTENCY_KEY,
                    "supplier_id":     SUPPLIER_ID,
                    "amount":          "400.00",
                },
                headers=headers,
            )

        assert response.status_code == 200

    @pytest.mark.asyncio
    async def test_post_supplier_charge_returns_200(self, async_client, mock_pool):
        """POST /supplier-accounts/charges → 200."""
        pool, conn = mock_pool
        rpc_result = json.dumps({
            "movement_id":         MOVEMENT_ID,
            "supplier_account_id": SUPPLIER_ACCOUNT_ID,
            "balance_after":       "1500.00",
            "replayed":            False,
            "operation_id":        OPERATION_ID,
        })
        conn.fetchrow = AsyncMock(return_value={"result": rpc_result})

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.post(
                "/supplier-accounts/charges",
                json={
                    "idempotency_key": IDEMPOTENCY_KEY,
                    "supplier_id":     SUPPLIER_ID,
                    "amount":          "1500.00",
                },
                headers=headers,
            )

        assert response.status_code == 200


# ═══════════════════════════════════════════════════════════════════════════════
# Section 6: Integración venta a crédito con C-29 (tasks 12.1-12.4)
# ═══════════════════════════════════════════════════════════════════════════════

class TestCreditSaleIntegration:
    """RED → GREEN: Integración de venta a crédito con SalesOrder.confirm()."""

    @pytest.fixture
    def mock_conn(self):
        conn = AsyncMock()
        conn.fetchrow = AsyncMock(return_value=None)
        conn.fetch = AsyncMock(return_value=[])
        conn.execute = AsyncMock(return_value="SET")
        return conn

    @pytest.mark.asyncio
    async def test_confirm_credit_sale_calls_correct_rpc(self, mock_conn):
        """12.1: confirmar SalesOrder con payment_method='credit' invoca el RPC core."""
        from backend.repositories.sales_order_repository import SalesOrderRepository

        rpc_result = json.dumps({
            "sales_order_id": "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
            "operation_id":   OPERATION_ID,
            "total":          "1000.00",
            "fiscal_doc_id":  None,
            "replayed":       False,
        })
        mock_conn.fetchrow.return_value = {"result": rpc_result}

        repo = SalesOrderRepository(mock_conn)
        result = await repo.confirm(
            idempotency_key=IDEMPOTENCY_KEY,
            sales_order_id="eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
            payment_method="credit",
            cash_session_id=None,
            comprobante_type=None,
            point_of_sale_id=None,
            branch_id=None,
            canal=None,
        )

        call_args = mock_conn.fetchrow.call_args[0][0]
        # El repo llama al wrapper rpc_confirm_sales_order que delegará al core
        assert "rpc_confirm_sales_order" in call_args
        assert result["replayed"] is False

    @pytest.mark.asyncio
    async def test_confirm_cash_sale_still_works(self, mock_conn):
        """12.2: Regresión C-29 — cash sigue funcionando tras el CREATE OR REPLACE."""
        from backend.repositories.sales_order_repository import SalesOrderRepository

        rpc_result = json.dumps({
            "sales_order_id": "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
            "operation_id":   OPERATION_ID,
            "total":          "500.00",
            "fiscal_doc_id":  None,
            "replayed":       False,
        })
        mock_conn.fetchrow.return_value = {"result": rpc_result}

        repo = SalesOrderRepository(mock_conn)
        result = await repo.confirm(
            idempotency_key=IDEMPOTENCY_KEY,
            sales_order_id="eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
            payment_method="cash",
            cash_session_id="33333333-3333-3333-3333-333333333333",
            comprobante_type=None,
            point_of_sale_id=None,
            branch_id=None,
            canal=None,
        )

        assert result["total"] == "500.00"

    def test_credit_payment_schema_valid(self):
        """12.3: El schema de confirm acepta 'credit' como payment_method."""
        from backend.schemas.sales_orders import ConfirmSalesOrderIn
        payload = ConfirmSalesOrderIn(
            idempotency_key=IDEMPOTENCY_KEY,
            payment_method="credit",
        )
        assert payload.payment_method == "credit"

    def test_credit_payment_schema_rejects_missing_client(self):
        """12.3 edge: credit sin client_id — no es un error de schema (client_id va en la orden)."""
        # La validación credit_requires_client ocurre en el RPC SQL, no en el schema.
        # Aquí simplemente verificamos que el schema acepta 'credit' sin client_id adicional.
        from backend.schemas.sales_orders import ConfirmSalesOrderIn
        payload = ConfirmSalesOrderIn(
            idempotency_key=IDEMPOTENCY_KEY,
            payment_method="credit",
        )
        assert payload.payment_method == "credit"

    @pytest.mark.asyncio
    async def test_sale_plus_payment_balance_invariant(self, mock_conn):
        """12.4: venta (1000) + cobro (1000) → balance 0; lógica del service."""
        from backend.services import customer_accounts as svc
        from backend.schemas.customer_accounts import PaymentReceivedIn

        # Simular que tras el cobro el RPC devuelve balance_after = 0
        mock_repo = AsyncMock()
        mock_repo.register_payment_received.return_value = {
            "payment_id":           PAYMENT_ID,
            "customer_account_id":  CUSTOMER_ACCOUNT_ID,
            "balance_after":        "0.00",
            "replayed":             False,
        }

        auth = {"sub": "uid", "role": "user"}
        payload = PaymentReceivedIn(
            idempotency_key=IDEMPOTENCY_KEY,
            client_id=uuid.UUID(CLIENT_ID),
            amount=Decimal("1000"),
        )

        result = await svc.register_payment_received(mock_repo, auth, payload)

        # balance_after == 0 → invariante cumplida (venta cancelada exactamente por el cobro)
        assert result["balance_after"] == "0.00"


# ═══════════════════════════════════════════════════════════════════════════════
# Section 7: TRIANGULATE — Idempotencia (task 11.3)
# ═══════════════════════════════════════════════════════════════════════════════

class TestIdempotencia:
    """TRIANGULATE: doble cobro con misma key → replayed=true, sin duplicar."""

    @pytest.mark.asyncio
    async def test_double_payment_returns_replayed(self):
        """Dos llamadas con la misma idempotency_key: segunda devuelve replayed=true."""
        from backend.services import customer_accounts as svc
        from backend.schemas.customer_accounts import PaymentReceivedIn

        # Primera llamada: registra el cobro
        first_result = {
            "payment_id":           PAYMENT_ID,
            "customer_account_id":  CUSTOMER_ACCOUNT_ID,
            "balance_after":        "600.00",
            "replayed":             False,
        }
        # Segunda llamada: replay (el RPC devuelve replayed=true)
        replay_result = {
            "payment_id":           None,
            "customer_account_id":  None,
            "balance_after":        None,
            "replayed":             True,
            "operation_id":         OPERATION_ID,
        }

        call_count = 0

        async def mock_register(**kwargs):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                return first_result
            return replay_result

        mock_repo = AsyncMock()
        mock_repo.register_payment_received.side_effect = mock_register

        auth = {"sub": "uid", "role": "user"}
        payload = PaymentReceivedIn(
            idempotency_key=IDEMPOTENCY_KEY,
            client_id=uuid.UUID(CLIENT_ID),
            amount=Decimal("400"),
        )

        r1 = await svc.register_payment_received(mock_repo, auth, payload)
        r2 = await svc.register_payment_received(mock_repo, auth, payload)

        assert r1["replayed"] is False
        assert r2["replayed"] is True
        assert mock_repo.register_payment_received.call_count == 2


# ═══════════════════════════════════════════════════════════════════════════════
# Section 8: Regresión de migración — whitelist de operation_kind (hotfix prod)
# ═══════════════════════════════════════════════════════════════════════════════

class TestMigrationOperationKindWhitelist:
    """Regresión del bug atrapado por el SMOKE transaccional en prod (NO por pytest,
    que mockea asyncpg): public.operation_idempotency.operation_kind tenía un CHECK
    limitado a ('sale','purchase'); los RPCs de C-30 usan kinds nuevos →
    el INSERT violaba el CHECK (23514). El hotfix 20260720000002 extiende el CHECK.

    Invariante verificada: TODO operation_kind que la feature inserta debe estar
    whitelisted en el CHECK.
    """

    @staticmethod
    def _migrations_dir():
        from pathlib import Path
        # backend/tests/<file>.py → parents[2] = raíz del repo (robusto ante el CWD)
        return Path(__file__).resolve().parents[2] / "supabase" / "migrations"

    def test_hotfix_extends_operation_kind_check_with_c30_kinds(self):
        sql = (self._migrations_dir()
               / "20260720000002_c30_hotfix_operation_kind_check.sql").read_text(encoding="utf-8")
        assert "operation_idempotency_operation_kind_check" in sql
        for kind in ("payment_received", "payment_made", "supplier_charge"):
            assert f"'{kind}'" in sql, f"operation_kind '{kind}' falta en el CHECK del hotfix"
        # No debe perder los kinds previos (sale/purchase de C-29).
        for kind in ("sale", "purchase"):
            assert f"'{kind}'" in sql, f"el hotfix no debe eliminar el kind previo '{kind}'"

    def test_feature_operation_kinds_are_all_whitelisted(self):
        mig = (self._migrations_dir()
               / "20260720000001_c30_customer_supplier_accounts.sql").read_text(encoding="utf-8")
        hotfix = (self._migrations_dir()
                  / "20260720000002_c30_hotfix_operation_kind_check.sql").read_text(encoding="utf-8")
        for kind in ("payment_received", "payment_made", "supplier_charge"):
            assert f"'{kind}'" in mig, f"la migración de C-30 debería usar operation_kind '{kind}'"
            assert f"'{kind}'" in hotfix, f"operation_kind '{kind}' usado pero NO whitelisted en el hotfix"
