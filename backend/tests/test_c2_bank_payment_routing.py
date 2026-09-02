"""
bank-payment-routing C2 — Tests TDD (Strict TDD Mode).

cobranzas-catalogo-pagos (2026-09-02, D1/D2): payment_method (str) →
payment_method_id (uuid, opcional) en PaymentReceivedIn/PaymentMadeIn y en
CustomerAccountRepository.register_payment_received /
SupplierAccountRepository.register_payment_made. Las validaciones de
taxonomía y de "bank_account_id exigido para método bancario" que vivían en
el schema se RETIRARON (no se pueden decidir sin consultar el catálogo desde
Pydantic) — la RPC es la única autoridad. La Section 1 de este archivo se
redujo en consecuencia; la cobertura de PaymentReceivedIn/PaymentMadeIn con
payment_method_id vive en test_c30_customer_supplier_accounts.py (que
también fija, con un test dedicado, que el retiro fue deliberado).

Comportamientos cubiertos:
  ── Schemas Pydantic ──────────────────────────────────────────────────────────
  - PaymentReceivedIn / PaymentMadeIn aceptan payment_method_id + bank_account_id
    (opcionales) — cobertura completa en test_c30_customer_supplier_accounts.py

  ── Repository ────────────────────────────────────────────────────────────────
  - register_payment_received invoca rpc_register_payment_received con los 7 args
    (incluye payment_method_id + bank_account_id + cash_session_id)
  - register_payment_made invoca rpc_register_payment_made con los 7 args
  - BankAccountRepository.list_active lee bank_accounts activas de la cuenta

  ── Service ───────────────────────────────────────────────────────────────────
  - register_payment_received propaga payment_method_id/bank_account_id al repo
  - register_payment_made propaga payment_method_id/bank_account_id al repo
  - P0412 (bank_account no encontrada/inactiva) → HTTPException 412... mapeado a 400
    (reutiliza _ERRCODE_STATUS; P0412 no whitelisteado → 500 salvo que se agregue)

  ── Endpoint HTTP ─────────────────────────────────────────────────────────────
  - POST /customer-accounts/payments con payment_method_id + bank_account_id → 200
  - POST /supplier-accounts/payments con payment_method_id + bank_account_id → 200
  - GET  /bank-accounts → 200, lista de cuentas activas

  ── Regresión (retrocompatibilidad) ───────────────────────────────────────────
  - Payload sin payment_method_id/bank_account_id sigue funcionando (default
    None = sin imputar, D3)

Run: python -m pytest backend/tests/test_c2_bank_payment_routing.py
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

# ── Workaround fpdf2 (pre-existing issue, mismo patrón que test_c30) ─────────
try:
    import fpdf  # noqa: F401
except ImportError:
    _fpdf_stub = types.ModuleType("fpdf")
    _fpdf_stub.FPDF = MagicMock  # type: ignore[attr-defined]
    sys.modules["fpdf"] = _fpdf_stub

# ── Constantes de test ─────────────────────────────────────────────────────────
ACCOUNT_ID          = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
CLIENT_ID           = "cccccccc-cccc-cccc-cccc-cccccccccccc"
SUPPLIER_ID         = "dddddddd-dddd-dddd-dddd-dddddddddddd"
CUSTOMER_ACCOUNT_ID = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
SUPPLIER_ACCOUNT_ID = "ffffffff-ffff-ffff-ffff-ffffffffffff"
BANK_ACCOUNT_ID     = "99999999-9999-9999-9999-999999999999"
PAYMENT_METHOD_ID   = "77777777-7777-7777-7777-777777777777"
PAYMENT_ID          = "11111111-1111-1111-1111-111111111111"
OPERATION_ID        = "33333333-3333-3333-3333-333333333333"
IDEMPOTENCY_KEY     = "test-idempotency-key-c2-bank-001"


def _jsonb(val):
    return json.loads(val) if isinstance(val, str) else val


# ═══════════════════════════════════════════════════════════════════════════════
# Section 1: Schemas — PaymentReceivedIn / PaymentMadeIn
# ═══════════════════════════════════════════════════════════════════════════════

class TestPaymentReceivedSchemaBankRouting:
    """cobranzas-catalogo-pagos: el schema acepta payment_method_id (uuid) +
    bank_account_id. La taxonomía y la exigencia de bank_account_id para un
    kind bancario YA NO se validan acá (no hay forma de saber el kind sin
    consultar el catálogo) — cobertura completa, incluido el test que fija
    el retiro como deliberado, en test_c30_customer_supplier_accounts.py."""

    def test_defaults_to_none_when_omitted(self):
        """Sin payment_method_id → None (sin imputar, D3), bank_account_id None."""
        from backend.schemas.customer_accounts import PaymentReceivedIn

        payload = PaymentReceivedIn(
            idempotency_key=IDEMPOTENCY_KEY,
            client_id=uuid.UUID(CLIENT_ID),
            amount=Decimal("400"),
        )
        assert payload.payment_method_id is None
        assert payload.bank_account_id is None

    def test_accepts_payment_method_id_with_bank_account_id(self):
        from backend.schemas.customer_accounts import PaymentReceivedIn

        payload = PaymentReceivedIn(
            idempotency_key=IDEMPOTENCY_KEY,
            client_id=uuid.UUID(CLIENT_ID),
            amount=Decimal("400"),
            payment_method_id=uuid.UUID(PAYMENT_METHOD_ID),
            bank_account_id=uuid.UUID(BANK_ACCOUNT_ID),
        )
        assert str(payload.payment_method_id) == PAYMENT_METHOD_ID
        assert str(payload.bank_account_id) == BANK_ACCOUNT_ID


class TestPaymentMadeSchemaBankRouting:
    """cobranzas-catalogo-pagos: espejo de arriba para PaymentMadeIn."""

    def test_defaults_to_none_when_omitted(self):
        from backend.schemas.supplier_accounts import PaymentMadeIn

        payload = PaymentMadeIn(
            idempotency_key=IDEMPOTENCY_KEY,
            supplier_id=uuid.UUID(SUPPLIER_ID),
            amount=Decimal("400"),
        )
        assert payload.payment_method_id is None
        assert payload.bank_account_id is None

    def test_accepts_payment_method_id_with_bank_account_id(self):
        from backend.schemas.supplier_accounts import PaymentMadeIn

        payload = PaymentMadeIn(
            idempotency_key=IDEMPOTENCY_KEY,
            supplier_id=uuid.UUID(SUPPLIER_ID),
            amount=Decimal("400"),
            payment_method_id=uuid.UUID(PAYMENT_METHOD_ID),
            bank_account_id=uuid.UUID(BANK_ACCOUNT_ID),
        )
        assert str(payload.payment_method_id) == PAYMENT_METHOD_ID


# ═══════════════════════════════════════════════════════════════════════════════
# Section 2: Repository — payment_method/bank_account_id threading
# ═══════════════════════════════════════════════════════════════════════════════

class TestCustomerAccountRepositoryBankRouting:
    @pytest.fixture
    def mock_conn(self):
        conn = AsyncMock()
        conn.fetchrow = AsyncMock(return_value=None)
        conn.fetch = AsyncMock(return_value=[])
        conn.execute = AsyncMock(return_value="SET")
        return conn

    @pytest.mark.asyncio
    async def test_register_payment_received_passes_method_and_bank_account(self, mock_conn):
        from backend.repositories.customer_account_repository import CustomerAccountRepository

        rpc_result = json.dumps({
            "payment_id":          PAYMENT_ID,
            "customer_account_id": CUSTOMER_ACCOUNT_ID,
            "balance_after":       "600.00",
            "replayed":            False,
            "operation_id":        OPERATION_ID,
        })
        mock_conn.fetchrow.return_value = {"result": rpc_result}

        repo = CustomerAccountRepository(mock_conn)
        result = await repo.register_payment_received(
            idempotency_key=IDEMPOTENCY_KEY,
            client_id=CLIENT_ID,
            amount=400.0,
            reference_sale_id=None,
            payment_method_id=PAYMENT_METHOD_ID,
            bank_account_id=BANK_ACCOUNT_ID,
        )

        call_args, call_params = mock_conn.fetchrow.call_args[0][0], mock_conn.fetchrow.call_args[0][1:]
        assert "rpc_register_payment_received" in call_args
        assert PAYMENT_METHOD_ID in call_params
        assert BANK_ACCOUNT_ID in call_params
        assert result["replayed"] is False

    @pytest.mark.asyncio
    async def test_register_payment_received_defaults_method_to_none(self, mock_conn):
        """cobranzas-catalogo-pagos (D3): sin especificar payment_method_id,
        el repo pasa None (sin imputar) — ya NO 'cash' (el default de texto
        de bank-payment-routing quedó retirado junto con la taxonomía)."""
        from backend.repositories.customer_account_repository import CustomerAccountRepository

        rpc_result = json.dumps({
            "payment_id":          PAYMENT_ID,
            "customer_account_id": CUSTOMER_ACCOUNT_ID,
            "balance_after":       "600.00",
            "replayed":            False,
            "operation_id":        OPERATION_ID,
        })
        mock_conn.fetchrow.return_value = {"result": rpc_result}

        repo = CustomerAccountRepository(mock_conn)
        await repo.register_payment_received(
            idempotency_key=IDEMPOTENCY_KEY,
            client_id=CLIENT_ID,
            amount=400.0,
        )

        call_params = mock_conn.fetchrow.call_args[0][1:]
        assert "cash" not in call_params
        # payment_method_id (posición 5) y bank_account_id (posición 6) son
        # ambos None cuando no se informan.
        assert call_params.count(None) >= 2


class TestSupplierAccountRepositoryBankRouting:
    @pytest.fixture
    def mock_conn(self):
        conn = AsyncMock()
        conn.fetchrow = AsyncMock(return_value=None)
        conn.fetch = AsyncMock(return_value=[])
        conn.execute = AsyncMock(return_value="SET")
        return conn

    @pytest.mark.asyncio
    async def test_register_payment_made_passes_method_and_bank_account(self, mock_conn):
        from backend.repositories.supplier_account_repository import SupplierAccountRepository

        rpc_result = json.dumps({
            "payment_id":          PAYMENT_ID,
            "supplier_account_id": SUPPLIER_ACCOUNT_ID,
            "balance_after":       "600.00",
            "replayed":            False,
            "operation_id":        OPERATION_ID,
        })
        mock_conn.fetchrow.return_value = {"result": rpc_result}

        repo = SupplierAccountRepository(mock_conn)
        result = await repo.register_payment_made(
            idempotency_key=IDEMPOTENCY_KEY,
            supplier_id=SUPPLIER_ID,
            amount=400.0,
            reference_purchase_id=None,
            payment_method_id=PAYMENT_METHOD_ID,
            bank_account_id=BANK_ACCOUNT_ID,
        )

        call_args, call_params = mock_conn.fetchrow.call_args[0][0], mock_conn.fetchrow.call_args[0][1:]
        assert "rpc_register_payment_made" in call_args
        assert PAYMENT_METHOD_ID in call_params
        assert BANK_ACCOUNT_ID in call_params
        assert result["replayed"] is False


class TestBankAccountRepository:
    """RED → GREEN: repository de solo-lectura para el picker de cuenta bancaria (task 7.4)."""

    @pytest.fixture
    def mock_conn(self):
        conn = AsyncMock()
        conn.fetch = AsyncMock(return_value=[])
        return conn

    @pytest.mark.asyncio
    async def test_list_active_selects_active_bank_accounts(self, mock_conn):
        from backend.repositories.bank_account_repository import BankAccountRepository

        mock_conn.fetch.return_value = [{
            "id": BANK_ACCOUNT_ID,
            "account_id": ACCOUNT_ID,
            "name": "Cuenta Santander",
            "bank_name": "Santander",
            "cbu": None,
            "alias": "empresa.santander",
            "currency": "ARS",
            "is_active": True,
        }]

        repo = BankAccountRepository(mock_conn)
        results = await repo.list_active(ACCOUNT_ID)

        call_args = mock_conn.fetch.call_args[0][0]
        assert "bank_accounts" in call_args
        assert "is_active" in call_args
        assert len(results) == 1
        assert results[0]["name"] == "Cuenta Santander"


# ═══════════════════════════════════════════════════════════════════════════════
# Section 3: Service — propagación de payment_method/bank_account_id
# ═══════════════════════════════════════════════════════════════════════════════

class TestCustomerAccountServiceBankRouting:
    def _make_auth(self, role: str = "user") -> dict:
        return {"sub": "test-uid", "role": role}

    @pytest.mark.asyncio
    async def test_register_payment_propagates_bank_fields(self):
        from backend.services import customer_accounts as svc
        from backend.schemas.customer_accounts import PaymentReceivedIn

        mock_repo = AsyncMock()
        mock_repo.register_payment_received.return_value = {
            "payment_id": PAYMENT_ID,
            "customer_account_id": CUSTOMER_ACCOUNT_ID,
            "balance_after": "600.00",
            "replayed": False,
        }

        auth = self._make_auth("user")
        payload = PaymentReceivedIn(
            idempotency_key=IDEMPOTENCY_KEY,
            client_id=uuid.UUID(CLIENT_ID),
            amount=Decimal("400"),
            payment_method_id=uuid.UUID(PAYMENT_METHOD_ID),
            bank_account_id=uuid.UUID(BANK_ACCOUNT_ID),
        )

        await svc.register_payment_received(mock_repo, auth, payload)

        _, kwargs = mock_repo.register_payment_received.call_args
        assert kwargs["payment_method_id"] == PAYMENT_METHOD_ID
        assert kwargs["bank_account_id"] == BANK_ACCOUNT_ID

    @pytest.mark.asyncio
    async def test_register_payment_propagates_p0412_as_400(self):
        """P0412 (bank_account no encontrada/inactiva) → HTTPException con status mapeado."""
        from backend.services import customer_accounts as svc
        from backend.schemas.customer_accounts import PaymentReceivedIn
        from fastapi import HTTPException

        err = asyncpg.PostgresError()
        err.sqlstate = "P0412"

        mock_repo = AsyncMock()
        mock_repo.register_payment_received.side_effect = err

        auth = self._make_auth("user")
        payload = PaymentReceivedIn(
            idempotency_key=IDEMPOTENCY_KEY,
            client_id=uuid.UUID(CLIENT_ID),
            amount=Decimal("400"),
            payment_method_id=uuid.UUID(PAYMENT_METHOD_ID),
            bank_account_id=uuid.UUID(BANK_ACCOUNT_ID),
        )

        with pytest.raises(HTTPException) as exc_info:
            await svc.register_payment_received(mock_repo, auth, payload)

        assert exc_info.value.status_code == 400


class TestSupplierAccountServiceBankRouting:
    def _make_auth(self, role: str = "user") -> dict:
        return {"sub": "test-uid", "role": role}

    @pytest.mark.asyncio
    async def test_register_payment_made_propagates_bank_fields(self):
        from backend.services import supplier_accounts as svc
        from backend.schemas.supplier_accounts import PaymentMadeIn

        mock_repo = AsyncMock()
        mock_repo.register_payment_made.return_value = {
            "payment_id": PAYMENT_ID,
            "supplier_account_id": SUPPLIER_ACCOUNT_ID,
            "balance_after": "600.00",
            "replayed": False,
        }

        auth = self._make_auth("user")
        payload = PaymentMadeIn(
            idempotency_key=IDEMPOTENCY_KEY,
            supplier_id=uuid.UUID(SUPPLIER_ID),
            amount=Decimal("400"),
            payment_method_id=uuid.UUID(PAYMENT_METHOD_ID),
            bank_account_id=uuid.UUID(BANK_ACCOUNT_ID),
        )

        await svc.register_payment_made(mock_repo, auth, payload)

        _, kwargs = mock_repo.register_payment_made.call_args
        assert kwargs["payment_method_id"] == PAYMENT_METHOD_ID
        assert kwargs["bank_account_id"] == BANK_ACCOUNT_ID


# ═══════════════════════════════════════════════════════════════════════════════
# Section 4: Endpoint HTTP
# ═══════════════════════════════════════════════════════════════════════════════

class TestBankPaymentRoutingEndpoints:
    @pytest.mark.asyncio
    async def test_post_payment_received_with_transfer_returns_200(self, async_client, mock_pool):
        pool, conn = mock_pool
        rpc_result = json.dumps({
            "payment_id":          PAYMENT_ID,
            "customer_account_id": CUSTOMER_ACCOUNT_ID,
            "balance_after":       "600.00",
            "replayed":            False,
            "operation_id":        OPERATION_ID,
        })
        conn.fetchrow = AsyncMock(return_value={"result": rpc_result})

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.post(
                "/customer-accounts/payments",
                json={
                    "idempotency_key":    IDEMPOTENCY_KEY,
                    "client_id":          CLIENT_ID,
                    "amount":             "400.00",
                    "payment_method_id":  PAYMENT_METHOD_ID,
                    "bank_account_id":    BANK_ACCOUNT_ID,
                },
                headers=headers,
            )

        assert response.status_code == 200

    @pytest.mark.asyncio
    async def test_post_payment_made_with_card_returns_200(self, async_client, mock_pool):
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
                    "idempotency_key":    IDEMPOTENCY_KEY,
                    "supplier_id":        SUPPLIER_ID,
                    "amount":             "400.00",
                    "payment_method_id":  PAYMENT_METHOD_ID,
                    "bank_account_id":    BANK_ACCOUNT_ID,
                },
                headers=headers,
            )

        assert response.status_code == 200

    @pytest.mark.asyncio
    async def test_post_payment_received_without_method_still_works(self, async_client, mock_pool):
        """Regresión: payload sin payment_method_id/bank_account_id sigue
        funcionando — default None (sin imputar, D3), no 'cash'."""
        pool, conn = mock_pool
        rpc_result = json.dumps({
            "payment_id":          PAYMENT_ID,
            "customer_account_id": CUSTOMER_ACCOUNT_ID,
            "balance_after":       "600.00",
            "replayed":            False,
            "operation_id":        OPERATION_ID,
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
    async def test_get_bank_accounts_returns_200(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetch = AsyncMock(return_value=[{
            "id": BANK_ACCOUNT_ID,
            "account_id": ACCOUNT_ID,
            "name": "Cuenta Santander",
            "bank_name": "Santander",
            "cbu": None,
            "alias": "empresa.santander",
            "currency": "ARS",
            "is_active": True,
        }])

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.get("/bank-accounts", headers=headers)

        assert response.status_code == 200
        body = response.json()
        assert len(body) == 1
        assert body[0]["name"] == "Cuenta Santander"
