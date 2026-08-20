"""
pos-catalogo-pagos — Tests TDD (Strict TDD Mode), tasks 4.1-4.6.

Comportamientos cubiertos:
  ── Schemas ───────────────────────────────────────────────────────────────────
  - PaymentMethod acepta los 7 kind del catálogo (cash,transfer,card,check,
    wallet,credit,other)
  - payment_method_id opcional se serializa en ConfirmIn y QuickSaleIn
  - el validador cash ⇒ cash_session_id sigue vigente (D6: no se mueve al
    service — el schema no puede resolver el kind desde el id, así que sigue
    validando sobre el texto)

  ── Repository ────────────────────────────────────────────────────────────────
  - confirm invoca rpc_confirm_sales_order con 9 argumentos posicionales
    (payment_method_id trailing)
  - quick_sale invoca rpc_quick_sale con 10 argumentos posicionales
    (payment_method_id trailing)
  - payment_method_id=None (default) preserva compatibilidad con callers
    existentes que no lo pasan

  ── Service ───────────────────────────────────────────────────────────────────
  - confirm/quick_sale pasan payment_method_id sin tocarlo (passthrough, D2:
    la RPC resuelve el kind, no el service)

  ── Endpoint HTTP (task 4.6 TRIANGULATE) ─────────────────────────────────────
  - POST /sales-orders/quick-sale con payment_method_id + payment_method=
    'credit' sin client_id: el P0400 del backend (credit_requires_client)
    se propaga como 400 (api-standards)
  - POST /sales-orders/quick-sale con kind='cash' sin cash_session_id sigue
    rechazado por Pydantic (422) ANTES de tocar la DB (regresión: el nuevo
    campo payment_method_id no debe desactivar ese validador)
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

from backend.tests.conftest import make_token, TEST_USER_ID

# ── Workaround fpdf2 (pre-existing issue, ver test_c29_quote_salesorder.py) ───
try:
    import fpdf  # noqa: F401
except ImportError:
    _fpdf_stub = types.ModuleType("fpdf")
    _fpdf_stub.FPDF = MagicMock  # type: ignore[attr-defined]
    sys.modules["fpdf"] = _fpdf_stub

# ── Constantes de test ─────────────────────────────────────────────────────────
ACCOUNT_ID       = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
SALES_ORDER_ID   = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
OPERATION_ID     = "ffffffff-ffff-ffff-ffff-ffffffffffff"
PRODUCT_ID       = "22222222-2222-2222-2222-222222222222"
SESSION_ID       = "33333333-3333-3333-3333-333333333333"
CLIENT_ID        = "cccccccc-cccc-cccc-cccc-cccccccccccc"
PAYMENT_METHOD_ID = "44444444-4444-4444-4444-444444444444"
IDEMPOTENCY_KEY  = "test-idempotency-key-pos-cpm"

CONFIRM_RPC_RESULT = {
    "sales_order_id": SALES_ORDER_ID,
    "operation_id":   OPERATION_ID,
    "total":          1500.00,
    "fiscal_doc_id":  None,
    "replayed":       False,
}

QUICK_SALE_RPC_RESULT = dict(CONFIRM_RPC_RESULT)


@pytest.fixture
def sales_order_repo():
    from backend.repositories.sales_order_repository import SalesOrderRepository
    conn = AsyncMock()
    return SalesOrderRepository(conn), conn


# ══════════════════════════════════════════════════════════════════════════════
# TASK 4.1/4.2 — SCHEMAS
# ══════════════════════════════════════════════════════════════════════════════

class TestPaymentMethodSchema:

    def test_payment_method_accepts_all_7_kinds(self):
        """PaymentMethod SHALL aceptar los 7 kind del catálogo (D4)."""
        from backend.schemas.sales_orders import PaymentMethod

        expected = {"cash", "transfer", "card", "check", "wallet", "credit", "other"}
        actual = {m.value for m in PaymentMethod}
        assert actual == expected

    def test_confirm_in_accepts_payment_method_id(self):
        """ConfirmIn serializa payment_method_id opcional (uuid | None)."""
        from backend.schemas.sales_orders import ConfirmIn

        payload = ConfirmIn(
            payment_method="other",
            payment_method_id=uuid.UUID(PAYMENT_METHOD_ID),
        )
        assert str(payload.payment_method_id) == PAYMENT_METHOD_ID

    def test_confirm_in_payment_method_id_defaults_to_none(self):
        """Camino legacy: payment_method_id es opcional, default None."""
        from backend.schemas.sales_orders import ConfirmIn

        payload = ConfirmIn(payment_method="other")
        assert payload.payment_method_id is None

    def test_quick_sale_in_accepts_payment_method_id(self):
        from backend.schemas.sales_orders import QuickSaleIn, SalesOrderItemIn

        payload = QuickSaleIn(
            items=[SalesOrderItemIn(quantity=Decimal("1"), price=Decimal("100"))],
            payment_method="credit",
            payment_method_id=uuid.UUID(PAYMENT_METHOD_ID),
        )
        assert str(payload.payment_method_id) == PAYMENT_METHOD_ID

    def test_confirm_in_cash_without_session_still_rejected(self):
        """D6: el validador cash ⇒ cash_session_id NO se mueve al service —
        sigue viviendo en el schema, ahora también con payment_method_id presente."""
        from backend.schemas.sales_orders import ConfirmIn

        with pytest.raises(ValueError):
            ConfirmIn(
                payment_method="cash",
                payment_method_id=uuid.UUID(PAYMENT_METHOD_ID),
                cash_session_id=None,
            )

    def test_quick_sale_in_cash_without_session_still_rejected(self):
        from backend.schemas.sales_orders import QuickSaleIn, SalesOrderItemIn

        with pytest.raises(ValueError):
            QuickSaleIn(
                items=[SalesOrderItemIn(quantity=Decimal("1"), price=Decimal("100"))],
                payment_method="cash",
                payment_method_id=uuid.UUID(PAYMENT_METHOD_ID),
                cash_session_id=None,
            )


# ══════════════════════════════════════════════════════════════════════════════
# TASK 4.3/4.4 — REPOSITORY
# ══════════════════════════════════════════════════════════════════════════════

class TestSalesOrderRepositoryPaymentMethodId:

    @pytest.mark.asyncio
    async def test_confirm_passes_9_positional_args(self, sales_order_repo):
        """confirm invoca rpc_confirm_sales_order con 10 args posicionales
        (payment_method_id $9, bank_account_id trailing $10 — pos-banco-
        movimientos)."""
        repo, conn = sales_order_repo
        conn.fetchrow = AsyncMock(return_value={"result": json.dumps(CONFIRM_RPC_RESULT)})

        await repo.confirm(
            idempotency_key=IDEMPOTENCY_KEY,
            sales_order_id=SALES_ORDER_ID,
            payment_method="credit",
            cash_session_id=None,
            comprobante_type=None,
            point_of_sale_id=None,
            branch_id=None,
            canal=None,
            payment_method_id=PAYMENT_METHOD_ID,
        )

        query, *bound_args = conn.fetchrow.call_args[0]
        assert "rpc_confirm_sales_order" in query.lower()
        assert len(bound_args) == 10, f"esperaba 10 args posicionales, hay {len(bound_args)}"
        assert bound_args[-2] == PAYMENT_METHOD_ID, "payment_method_id debe ser $9"
        assert bound_args[-1] is None, "bank_account_id debe ser el arg trailing ($10), default None"

    @pytest.mark.asyncio
    async def test_confirm_payment_method_id_defaults_to_none(self, sales_order_repo):
        """Compat: callers existentes que no pasan payment_method_id siguen andando."""
        repo, conn = sales_order_repo
        conn.fetchrow = AsyncMock(return_value={"result": json.dumps(CONFIRM_RPC_RESULT)})

        await repo.confirm(
            idempotency_key=IDEMPOTENCY_KEY,
            sales_order_id=SALES_ORDER_ID,
            payment_method="other",
            cash_session_id=None,
            comprobante_type=None,
            point_of_sale_id=None,
            branch_id=None,
            canal=None,
        )

        query, *bound_args = conn.fetchrow.call_args[0]
        assert len(bound_args) == 10
        assert bound_args[-2] is None
        assert bound_args[-1] is None

    @pytest.mark.asyncio
    async def test_quick_sale_passes_10_positional_args(self, sales_order_repo):
        """quick_sale invoca rpc_quick_sale con 11 args posicionales
        (payment_method_id $10, bank_account_id trailing $11 — pos-banco-
        movimientos)."""
        repo, conn = sales_order_repo
        conn.fetchrow = AsyncMock(return_value={"result": json.dumps(QUICK_SALE_RPC_RESULT)})
        items = [{"product_id": PRODUCT_ID, "quantity": 1, "price": 1000, "subtotal": 1000}]

        await repo.quick_sale(
            idempotency_key=IDEMPOTENCY_KEY,
            client_id=CLIENT_ID,
            items=items,
            payment_method="credit",
            cash_session_id=None,
            comprobante_type=None,
            point_of_sale_id=None,
            branch_id=None,
            canal=None,
            payment_method_id=PAYMENT_METHOD_ID,
        )

        query, *bound_args = conn.fetchrow.call_args[0]
        assert "rpc_quick_sale" in query.lower()
        assert len(bound_args) == 11, f"esperaba 11 args posicionales, hay {len(bound_args)}"
        assert bound_args[-2] == PAYMENT_METHOD_ID, "payment_method_id debe ser $10"
        assert bound_args[-1] is None, "bank_account_id debe ser el arg trailing ($11), default None"

    @pytest.mark.asyncio
    async def test_quick_sale_payment_method_id_defaults_to_none(self, sales_order_repo):
        repo, conn = sales_order_repo
        conn.fetchrow = AsyncMock(return_value={"result": json.dumps(QUICK_SALE_RPC_RESULT)})
        items = [{"product_id": PRODUCT_ID, "quantity": 1, "price": 1000, "subtotal": 1000}]

        await repo.quick_sale(
            idempotency_key=IDEMPOTENCY_KEY,
            client_id=None,
            items=items,
            payment_method="other",
            cash_session_id=None,
            comprobante_type=None,
            point_of_sale_id=None,
            branch_id=None,
            canal=None,
        )

        query, *bound_args = conn.fetchrow.call_args[0]
        assert len(bound_args) == 11
        assert bound_args[-2] is None
        assert bound_args[-1] is None


# ══════════════════════════════════════════════════════════════════════════════
# TASK 4.5 — SERVICE PASSTHROUGH
# ══════════════════════════════════════════════════════════════════════════════

class TestSalesOrderServicePassthrough:

    @pytest.mark.asyncio
    async def test_confirm_passes_payment_method_id_to_repo(self):
        from backend.services import sales_orders as so_service
        from backend.schemas.sales_orders import ConfirmIn

        repo = AsyncMock()
        repo.confirm = AsyncMock(return_value=CONFIRM_RPC_RESULT)
        payload = ConfirmIn(
            idempotency_key=IDEMPOTENCY_KEY,
            payment_method="credit",
            payment_method_id=uuid.UUID(PAYMENT_METHOD_ID),
        )
        auth = {"user_id": TEST_USER_ID, "role": "user"}

        await so_service.confirm(repo, auth, SALES_ORDER_ID, payload)

        _, kwargs = repo.confirm.call_args
        assert kwargs["payment_method_id"] == PAYMENT_METHOD_ID

    @pytest.mark.asyncio
    async def test_quick_sale_passes_payment_method_id_to_repo(self):
        from backend.services import sales_orders as so_service
        from backend.schemas.sales_orders import QuickSaleIn, SalesOrderItemIn

        repo = AsyncMock()
        repo.quick_sale = AsyncMock(return_value=QUICK_SALE_RPC_RESULT)
        payload = QuickSaleIn(
            idempotency_key=IDEMPOTENCY_KEY,
            items=[SalesOrderItemIn(product_id=uuid.UUID(PRODUCT_ID), quantity=Decimal("1"), price=Decimal("1000"))],
            payment_method="credit",
            payment_method_id=uuid.UUID(PAYMENT_METHOD_ID),
            client_id=uuid.UUID(CLIENT_ID),
        )
        auth = {"user_id": TEST_USER_ID, "role": "user"}

        await so_service.quick_sale(repo, auth, payload, ACCOUNT_ID)

        _, kwargs = repo.quick_sale.call_args
        assert kwargs["payment_method_id"] == PAYMENT_METHOD_ID

    @pytest.mark.asyncio
    async def test_quick_sale_passes_none_when_omitted(self):
        """Camino legacy: sin payment_method_id, el service pasa None (no
        inventa un valor)."""
        from backend.services import sales_orders as so_service
        from backend.schemas.sales_orders import QuickSaleIn, SalesOrderItemIn

        repo = AsyncMock()
        repo.quick_sale = AsyncMock(return_value=QUICK_SALE_RPC_RESULT)
        payload = QuickSaleIn(
            idempotency_key=IDEMPOTENCY_KEY,
            items=[SalesOrderItemIn(product_id=uuid.UUID(PRODUCT_ID), quantity=Decimal("1"), price=Decimal("1000"))],
            payment_method="other",
        )
        auth = {"user_id": TEST_USER_ID, "role": "user"}

        await so_service.quick_sale(repo, auth, payload, ACCOUNT_ID)

        _, kwargs = repo.quick_sale.call_args
        assert kwargs["payment_method_id"] is None


# ══════════════════════════════════════════════════════════════════════════════
# TASK 4.6 — ENDPOINT (TRIANGULATE)
# ══════════════════════════════════════════════════════════════════════════════

@pytest.mark.asyncio
class TestQuickSaleEndpointPaymentMethodId:

    async def test_credit_without_client_propagates_400(self, async_client, mock_pool):
        """P0400 credit_requires_client del backend → HTTP 400 (api-standards)."""
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        err = asyncpg.exceptions.RaiseError("credit_requires_client")
        err.sqlstate = "P0400"
        conn.fetchrow = AsyncMock(side_effect=err)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/sales-orders/quick-sale",
                json={
                    "idempotency_key": IDEMPOTENCY_KEY,
                    "items": [
                        {"product_id": PRODUCT_ID, "quantity": "1.0", "price": "1000.00"}
                    ],
                    "payment_method": "credit",
                    "payment_method_id": PAYMENT_METHOD_ID,
                },
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 400

    async def test_cash_without_session_still_returns_422_before_db(self, async_client, mock_pool):
        """Regresión: payment_method_id no debe desactivar el validador
        cash ⇒ cash_session_id — sigue rechazando ANTES de tocar la DB."""
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(side_effect=AssertionError("no debería llegar a la DB"))

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/sales-orders/quick-sale",
                json={
                    "idempotency_key": IDEMPOTENCY_KEY,
                    "items": [
                        {"product_id": PRODUCT_ID, "quantity": "1.0", "price": "1000.00"}
                    ],
                    "payment_method": "cash",
                    "payment_method_id": PAYMENT_METHOD_ID,
                },
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 422

    async def test_quick_sale_with_payment_method_id_returns_200(self, async_client, mock_pool):
        """Camino feliz: payment_method_id viaja end-to-end y la respuesta es 200."""
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(return_value={"result": json.dumps(QUICK_SALE_RPC_RESULT)})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/sales-orders/quick-sale",
                json={
                    "idempotency_key": IDEMPOTENCY_KEY,
                    "items": [
                        {"product_id": PRODUCT_ID, "quantity": "1.0", "price": "1000.00"}
                    ],
                    "payment_method": "wallet",
                    "payment_method_id": PAYMENT_METHOD_ID,
                },
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        assert resp.json()["sales_order_id"] == SALES_ORDER_ID
