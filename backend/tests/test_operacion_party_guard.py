"""
operacion-party-guard — fix ad-hoc (2026-09-10), último candidato de código
del programa "cero candidatos". Cierra OQ-4 de cuenta-corriente-party-guard:
la venta/compra AL CONTADO con client_id/supplier_id AJENO no tenía guard —
la migración 20261045000001 agrega un guard explícito (mismo P0404
`client_not_found: %s` / `supplier_not_found: %s` del choke point) en
rpc_create_sale_operation_v2, _c29_confirm_order_core,
rpc_atomic_update_sale_operation y (RONDA 1 de revisión adversarial,
finding MAJOR) rpc_accept_quote.

Estos tests son el CANDADO de que ese P0404 sigue llegando al cliente HTTP
como 404 (no 500) por los CINCO caminos que la migración toca (formulario,
POS/confirm, EDICIÓN de venta, y — RONDA 1 de revisión adversarial —
PRESUPUESTO→ACEPTAR, con su propio candado de mapeo HTTP más abajo, además
del gate SQL de supabase/tests/test_operacion_party_guard.sql que ejercita
el guard en sí), con MOLDE en backend/tests/test_cuenta_corriente_party_guard.py:

  1. "sale" (rpc_create_sale_operation_v2, vía POST /sales) — YA CUBIERTO por
     TestSaleOperationPartyGuardHttp en test_cuenta_corriente_party_guard.py:
     el mock ahí simula un P0404 "client_not_found" sin payment_method en el
     payload — exactamente el camino AL CONTADO que este fix guarda. No se
     duplica ese test acá (reutilización antes que repetición, regla PO
     2026-08-02); se referencia.

  2. "confirm order" (rpc_quick_sale / _c29_confirm_order_core, vía
     sales_orders_service.quick_sale/confirm) — NUEVO en este archivo. A
     diferencia del camino de venta, este servicio SÍ tiene su propio
     try/except (`_map_postgres_error` en backend/services/sales_orders.py),
     que mapea P0404 → HTTPException(404) ANTES de llegar al handler global
     RFC 7807 — por eso el test es a nivel service con repo mockeado (mismo
     nivel que TestCustomerAccountPartyGuard), no HTTP end-to-end.

  3. "purchase" (rpc_create_purchase_operation, vía POST /purchases) — NUEVO.
     `purchases_service.create_purchase_operation` NO tiene try/except propio
     (verificado en backend/services/purchases.py): el PostgresError sube
     hasta el handler global `asyncpg_error_handler`, igual que el camino de
     venta — se verifica el cuerpo RFC 7807 completo, mismo molde que
     TestSaleOperationPartyGuardHttp. Nota: el guard del lado compra NO es
     nuevo (D6 de compras-proveedor-cuenta-corriente, 2026-08-23) — este test
     es un candado de no regresión del mapeo HTTP, no del guard SQL en sí.

  4. "update" (rpc_atomic_update_sale_operation, vía PUT /sales/operation) —
     NUEVO [RONDA 1, finding NIT: el camino de EDICIÓN es el HALLAZGO NUEVO
     de este change y era el único de los tres originales sin test HTTP de
     backend]. `sales_service.update_sale_operation` NO tiene try/except
     propio (verificado en backend/services/sales.py) — mismo molde que
     "purchase": sube al handler global RFC 7807. `SalesRepository.
     update_operation` llama `conn.execute(...)` (no `fetchrow`), a
     diferencia de purchase — el mock se monta sobre `conn.execute`.

  5. "accept quote" (rpc_accept_quote, vía POST /quotes/{id}/accept) — NUEVO
     [RONDA 1, MAJOR: el guard nuevo de esta ronda]. `quotes_service.
     accept_quote` tiene su PROPIO `_map_postgres_error` (backend/services/
     quotes.py) — mismo patrón que "confirm order": P0404 genérico →
     HTTPException(404, "No encontrado: ..."), sin distinguir el ERRCODE por
     mensaje (a diferencia de sales_orders.py, que sí discrimina). Test a
     nivel service con repo mockeado, mismo nivel que "confirm order".

  6. "create quote" (QuoteRepository.create_quote, vía POST /quotes) — NUEVO
     [RONDA 2, finding MINOR]. A diferencia de los 5 anteriores, este guard
     NO vive en una RPC SQL: `quotes` no es una de las 3 tablas en alcance de
     la migración 20261045000001 (sales/purchases/sales_orders), pero
     `QuoteRepository.create_quote` hacía un INSERT directo de `client_id`
     SIN validar tenencia (sólo RLS de `account_id`, que no scopea el FK a
     `clients`) — el hueco real que `rpc_accept_quote` (5) sólo intercepta en
     el momento de ACEPTAR, no al crearse. El guard vive en
     `quotes_service.create_quote` (`QuoteRepository.client_belongs_to_account`,
     nuevo), ANTES de invocar `repo.create_quote` — nunca confía sólo en la
     RLS. Mismo ERRCODE/mensaje (`P0404`, `client_not_found: <id>`) para que
     `humanizeOperationError` lo traduzca igual sin importar qué capa lo
     rechazó. Test a nivel service con repo mockeado.

Control negativo: un sqlstate NO mapeado sigue dando 500 en los CUATRO
caminos SQL nuevos — sin esto, un `except` demasiado ancho haría pasar todo
lo anterior por accidente (mismo patrón que 7.4 en el archivo molde).

Run: python -m pytest backend/tests/test_operacion_party_guard.py
"""
from __future__ import annotations

import sys
import types
import uuid
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
import asyncpg
from fastapi import HTTPException

from backend.tests.conftest import make_token, TEST_ACCOUNT_ID

# ── Workaround fpdf2 (pre-existing issue, mismo molde que
#    backend/tests/test_cuenta_corriente_party_guard.py) ──────────────────────
try:
    import fpdf  # noqa: F401
except ImportError:
    _fpdf_stub = types.ModuleType("fpdf")
    _fpdf_stub.FPDF = MagicMock  # type: ignore[attr-defined]
    sys.modules["fpdf"] = _fpdf_stub

FOREIGN_CLIENT_ID   = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
FOREIGN_SUPPLIER_ID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbc"
PRODUCT_ID          = "99999999-9999-9999-9999-999999999999"
IDEMPOTENCY_KEY     = "test-operacion-party-guard-001"

CLIENT_NOT_FOUND_MSG   = f"client_not_found: {FOREIGN_CLIENT_ID}"
SUPPLIER_NOT_FOUND_MSG = f"supplier_not_found: {FOREIGN_SUPPLIER_ID}"


def _pg_error(sqlstate: str, message: str) -> asyncpg.PostgresError:
    """Construye el PostgresError que asyncpg entrega cuando una RPC hace
    RAISE EXCEPTION ... USING ERRCODE. Mismo molde que
    test_cuenta_corriente_party_guard.py / test_c30_customer_supplier_accounts.py."""
    err = asyncpg.PostgresError(message)
    err.sqlstate = sqlstate
    return err


def _auth(role: str = "user") -> dict:
    return {"sub": "test-uid", "user_id": "test-uid", "role": role}


# ═══════════════════════════════════════════════════════════════════════════════
# 2 — "confirm order" (POS: rpc_quick_sale / _c29_confirm_order_core)
# ═══════════════════════════════════════════════════════════════════════════════

class TestConfirmOrderPartyGuardHttp:
    """sales_orders_service.quick_sale/confirm mapean el PostgresError con SU
    PROPIO `_map_postgres_error` (backend/services/sales_orders.py) — no pasan
    por el handler global. P0404 → HTTPException(404, detail="No encontrado: ...")."""

    @pytest.mark.asyncio
    async def test_quick_sale_with_foreign_client_returns_404(self):
        """POS: venta rápida con un client_id de otro tenant → 404, no 500."""
        from backend.services import sales_orders as svc
        from backend.schemas.sales_orders import QuickSaleIn, SalesOrderItemIn

        mock_repo = AsyncMock()
        mock_repo.quick_sale.side_effect = _pg_error("P0404", CLIENT_NOT_FOUND_MSG)

        payload = QuickSaleIn(
            idempotency_key=IDEMPOTENCY_KEY,
            client_id=uuid.UUID(FOREIGN_CLIENT_ID),
            items=[SalesOrderItemIn(product_id=uuid.UUID(PRODUCT_ID), quantity=1, price=1000)],
        )

        with pytest.raises(HTTPException) as exc_info:
            await svc.quick_sale(mock_repo, _auth(), payload, str(TEST_ACCOUNT_ID))

        assert exc_info.value.status_code == 404
        assert "client_not_found" in str(exc_info.value.detail)

    @pytest.mark.asyncio
    async def test_confirm_order_with_foreign_client_returns_404(self):
        """rpc_confirm_sales_order (wrapper de _c29_confirm_order_core): una
        orden cuyo client_id resultó ser ajeno también se rechaza con 404 al
        confirmarla."""
        from backend.services import sales_orders as svc
        from backend.schemas.sales_orders import ConfirmIn, PaymentMethod

        mock_repo = AsyncMock()
        mock_repo.confirm.side_effect = _pg_error("P0404", CLIENT_NOT_FOUND_MSG)

        payload = ConfirmIn(
            idempotency_key=IDEMPOTENCY_KEY,
            payment_method=PaymentMethod.other,
        )

        with pytest.raises(HTTPException) as exc_info:
            await svc.confirm(mock_repo, _auth(), "11111111-1111-1111-1111-111111111111", payload)

        assert exc_info.value.status_code == 404
        assert "client_not_found" in str(exc_info.value.detail)

    @pytest.mark.asyncio
    async def test_unmapped_sqlstate_still_500(self):
        """CONTROL NEGATIVO: un sqlstate sin mapear sigue dando 500 — si esto
        diera 404, el test de arriba pasaría por un `except` demasiado ancho."""
        from backend.services import sales_orders as svc
        from backend.schemas.sales_orders import QuickSaleIn, SalesOrderItemIn

        mock_repo = AsyncMock()
        mock_repo.quick_sale.side_effect = _pg_error("P0999", "errcode inventado que nadie mapea")

        payload = QuickSaleIn(
            idempotency_key=IDEMPOTENCY_KEY,
            client_id=uuid.UUID(FOREIGN_CLIENT_ID),
            items=[SalesOrderItemIn(product_id=uuid.UUID(PRODUCT_ID), quantity=1, price=1000)],
        )

        with pytest.raises(HTTPException) as exc_info:
            await svc.quick_sale(mock_repo, _auth(), payload, str(TEST_ACCOUNT_ID))

        assert exc_info.value.status_code == 500


# ═══════════════════════════════════════════════════════════════════════════════
# 3 — "purchase" (rpc_create_purchase_operation) — guard D6 ya existente,
#     candado de no regresión del mapeo HTTP (mismo camino que la venta: sin
#     try/except propio, sube al handler global RFC 7807).
# ═══════════════════════════════════════════════════════════════════════════════

class TestPurchaseOperationPartyGuardHttp:

    @staticmethod
    def _payload() -> dict:
        return {
            "org_id": str(TEST_ACCOUNT_ID),
            "supplier_id": FOREIGN_SUPPLIER_ID,
            "items": [{"product_id": PRODUCT_ID, "amount": 500, "quantity": 1}],
        }

    @pytest.mark.asyncio
    async def test_purchase_with_foreign_supplier_returns_404_problem_json(
        self, async_client, mock_pool
    ):
        """Compra con proveedor de otro tenant → 404 con cuerpo 7807 completo.
        D6 (compras-proveedor-cuenta-corriente) no es nuevo — este test
        congela que el mapeo HTTP sigue funcionando, mismo molde que
        TestSaleOperationPartyGuardHttp en test_cuenta_corriente_party_guard.py."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(side_effect=_pg_error("P0404", SUPPLIER_NOT_FOUND_MSG))

        with patch("backend.core.database.pool", pool):
            headers = {
                "Authorization": f"Bearer {make_token({'role': 'user'})}",
                "Idempotency-Key": IDEMPOTENCY_KEY,
            }
            response = await async_client.post(
                "/purchases", json=self._payload(), headers=headers
            )

        assert response.status_code == 404
        body = response.json()
        assert body["type"] == "about:blank"
        assert body["status"] == 404
        assert body["code"] == "P0404"
        assert "supplier_not_found" in body["detail"]
        assert response.headers["content-type"].startswith("application/problem+json")

    @pytest.mark.asyncio
    async def test_unmapped_sqlstate_on_purchase_path_still_500(
        self, async_client, mock_pool
    ):
        """CONTROL NEGATIVO del camino global de compra."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(
            side_effect=_pg_error("P0999", "detalle interno que no debe filtrarse")
        )

        with patch("backend.core.database.pool", pool):
            headers = {
                "Authorization": f"Bearer {make_token({'role': 'user'})}",
                "Idempotency-Key": IDEMPOTENCY_KEY + "-neg",
            }
            response = await async_client.post(
                "/purchases", json=self._payload(), headers=headers
            )

        assert response.status_code == 500
        body = response.json()
        assert body["status"] == 500
        assert body["code"] == "internal_error"
        assert "detalle interno que no debe filtrarse" not in body["detail"]


# ═══════════════════════════════════════════════════════════════════════════════
# 4 — "update" (rpc_atomic_update_sale_operation, vía PUT /sales/operation)
#     [RONDA 1, finding NIT] — el camino de EDICIÓN es el HALLAZGO NUEVO de
#     este change (p_client_id era parámetro obligatorio, sin contrato
#     tri-estado _provided, escrito sin validar tenencia) y era el único de
#     los tres caminos originales sin candado HTTP de backend. Mismo molde
#     que TestPurchaseOperationPartyGuardHttp: sin try/except propio en
#     backend/services/sales.py, sube al handler global RFC 7807.
# ═══════════════════════════════════════════════════════════════════════════════

class TestUpdateSaleOperationPartyGuardHttp:

    @staticmethod
    def _payload() -> dict:
        return {
            "sale_ids": ["11111111-1111-1111-1111-111111111111"],
            "items": [{"product_id": PRODUCT_ID, "quantity": 1, "amount": 1000}],
            "date": "2026-09-10",
            "client_id": FOREIGN_CLIENT_ID,
        }

    @pytest.mark.asyncio
    async def test_update_sale_operation_with_foreign_client_returns_404_problem_json(
        self, async_client, mock_pool
    ):
        """Editar una venta propia reasignándole un client_id de otro tenant →
        404 con cuerpo 7807 completo. SalesRepository.update_operation llama
        conn.execute (no fetchrow) — a diferencia del molde de purchase."""
        pool, conn = mock_pool
        conn.execute = AsyncMock(side_effect=_pg_error("P0404", CLIENT_NOT_FOUND_MSG))

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.put(
                "/sales/operation", json=self._payload(), headers=headers
            )

        assert response.status_code == 404
        body = response.json()
        assert body["type"] == "about:blank"
        assert body["status"] == 404
        assert body["code"] == "P0404"
        assert "client_not_found" in body["detail"]
        assert response.headers["content-type"].startswith("application/problem+json")

    @pytest.mark.asyncio
    async def test_unmapped_sqlstate_on_update_path_still_500(
        self, async_client, mock_pool
    ):
        """CONTROL NEGATIVO del camino global de edición — mismo propósito
        que 7.4 en el archivo molde: sin esto, un `except` demasiado ancho
        haría pasar el test de arriba por accidente."""
        pool, conn = mock_pool
        conn.execute = AsyncMock(
            side_effect=_pg_error("P0999", "detalle interno que no debe filtrarse")
        )

        with patch("backend.core.database.pool", pool):
            headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
            response = await async_client.put(
                "/sales/operation", json=self._payload(), headers=headers
            )

        assert response.status_code == 500
        body = response.json()
        assert body["status"] == 500
        assert body["code"] == "internal_error"
        assert "detalle interno que no debe filtrarse" not in body["detail"]


# ═══════════════════════════════════════════════════════════════════════════════
# 5 — "accept quote" (rpc_accept_quote, vía POST /quotes/{id}/accept)
#     [RONDA 1, MAJOR] — guard nuevo de esta ronda. quotes_service.accept_quote
#     tiene su PROPIO _map_postgres_error (backend/services/quotes.py), mismo
#     patrón que "confirm order": P0404 -> HTTPException(404, "No encontrado: ...").
# ═══════════════════════════════════════════════════════════════════════════════

class TestAcceptQuotePartyGuardHttp:

    @pytest.mark.asyncio
    async def test_accept_quote_with_foreign_client_returns_404(self):
        """Aceptar un presupuesto cuyo client_id resultó ser de otro tenant
        (guard nuevo de la RONDA 1 en rpc_accept_quote) → 404, no 500."""
        from backend.services import quotes as svc

        mock_repo = AsyncMock()
        mock_repo.accept_quote.side_effect = _pg_error("P0404", CLIENT_NOT_FOUND_MSG)

        with pytest.raises(HTTPException) as exc_info:
            await svc.accept_quote(
                mock_repo, _auth(), "11111111-1111-1111-1111-111111111111"
            )

        assert exc_info.value.status_code == 404
        assert "client_not_found" in str(exc_info.value.detail)

    @pytest.mark.asyncio
    async def test_unmapped_sqlstate_on_accept_quote_path_still_500(self):
        """CONTROL NEGATIVO: un sqlstate sin mapear sigue dando 500 — sin
        esto, el test de arriba pasaría por un `except` demasiado ancho."""
        from backend.services import quotes as svc

        mock_repo = AsyncMock()
        mock_repo.accept_quote.side_effect = _pg_error(
            "P0999", "errcode inventado que nadie mapea"
        )

        with pytest.raises(HTTPException) as exc_info:
            await svc.accept_quote(
                mock_repo, _auth(), "11111111-1111-1111-1111-111111111111"
            )

        assert exc_info.value.status_code == 500


# ═══════════════════════════════════════════════════════════════════════════════
# 6 — "create quote" (QuoteRepository.create_quote, vía POST /quotes)
#     [RONDA 2, finding MINOR] — guard EN PYTHON, no en una RPC SQL: `quotes`
#     no es una de las 3 tablas en alcance de la migración 20261045000001,
#     pero el INSERT directo de client_id sin validar tenencia dejaba
#     materializar un quote cross-tenant que rpc_accept_quote (5, arriba) sólo
#     intercepta al ACEPTAR, no al crearse. El guard vive en
#     quotes_service.create_quote (ANTES de repo.create_quote), consultando
#     repo.client_belongs_to_account (nuevo en QuoteRepository) — nunca
#     confía sólo en la RLS de account_id.
# ═══════════════════════════════════════════════════════════════════════════════

class TestCreateQuotePartyGuard:

    @pytest.mark.asyncio
    async def test_create_quote_with_foreign_client_returns_404(self):
        """Un client_id de otro tenant se rechaza con 404 ANTES del INSERT —
        el guard es Python puro (no un PostgresError), y repo.create_quote
        nunca llega a invocarse."""
        from backend.services import quotes as svc
        from backend.schemas.quotes import QuoteIn, QuoteItemIn

        mock_repo = AsyncMock()
        mock_repo.client_belongs_to_account.return_value = False

        payload = QuoteIn(
            client_id=uuid.UUID(FOREIGN_CLIENT_ID),
            items=[
                QuoteItemIn(
                    product_id=uuid.UUID(PRODUCT_ID),
                    quantity=Decimal("1"),
                    price=Decimal("1000"),
                    subtotal=Decimal("1000"),
                )
            ],
        )

        with pytest.raises(HTTPException) as exc_info:
            await svc.create_quote(
                repo=mock_repo,
                auth=_auth(),
                payload=payload,
                created_by="test-uid",
                account_id=str(TEST_ACCOUNT_ID),
            )

        assert exc_info.value.status_code == 404
        assert "client_not_found" in str(exc_info.value.detail)
        mock_repo.client_belongs_to_account.assert_awaited_once_with(
            FOREIGN_CLIENT_ID, str(TEST_ACCOUNT_ID)
        )
        mock_repo.create_quote.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_create_quote_with_own_client_still_creates(self):
        """CONTROL POSITIVO: client_id PROPIO no debe sobre-bloquear — el
        guard no debe romper el camino feliz."""
        from backend.services import quotes as svc
        from backend.schemas.quotes import QuoteIn, QuoteItemIn

        mock_repo = AsyncMock()
        mock_repo.client_belongs_to_account.return_value = True
        mock_repo.create_quote.return_value = {
            "id": "dddddddd-dddd-dddd-dddd-dddddddddddd",
            "account_id": str(TEST_ACCOUNT_ID),
            "branch_id": None,
            "client_id": FOREIGN_CLIENT_ID,  # reusado solo como uuid válido; acá es "propio"
            "status": "draft",
            "valid_until": None,
            "total": Decimal("1000.00"),
            "created_by": "test-uid",
            "created_at": "2026-09-10T00:00:00",
        }

        payload = QuoteIn(
            client_id=uuid.UUID(FOREIGN_CLIENT_ID),
            items=[
                QuoteItemIn(
                    product_id=uuid.UUID(PRODUCT_ID),
                    quantity=Decimal("1"),
                    price=Decimal("1000"),
                    subtotal=Decimal("1000"),
                )
            ],
        )

        result = await svc.create_quote(
            repo=mock_repo,
            auth=_auth(),
            payload=payload,
            created_by="test-uid",
            account_id=str(TEST_ACCOUNT_ID),
        )

        mock_repo.create_quote.assert_awaited_once()
        assert result["id"] == "dddddddd-dddd-dddd-dddd-dddddddddddd"

    @pytest.mark.asyncio
    async def test_create_quote_without_client_skips_guard(self):
        """TRIANGULATE: client_id=None sigue siendo opcional — el guard no se
        ejercita en absoluto (mismo criterio que el guard SQL, que también
        sólo corre `IF p_client_id IS NOT NULL`)."""
        from backend.services import quotes as svc
        from backend.schemas.quotes import QuoteIn, QuoteItemIn

        mock_repo = AsyncMock()
        mock_repo.create_quote.return_value = {
            "id": "dddddddd-dddd-dddd-dddd-dddddddddddd",
            "account_id": str(TEST_ACCOUNT_ID),
            "branch_id": None,
            "client_id": None,
            "status": "draft",
            "valid_until": None,
            "total": Decimal("1000.00"),
            "created_by": "test-uid",
            "created_at": "2026-09-10T00:00:00",
        }

        payload = QuoteIn(
            client_id=None,
            items=[
                QuoteItemIn(
                    product_id=uuid.UUID(PRODUCT_ID),
                    quantity=Decimal("1"),
                    price=Decimal("1000"),
                    subtotal=Decimal("1000"),
                )
            ],
        )

        await svc.create_quote(
            repo=mock_repo,
            auth=_auth(),
            payload=payload,
            created_by="test-uid",
            account_id=str(TEST_ACCOUNT_ID),
        )

        mock_repo.client_belongs_to_account.assert_not_awaited()
        mock_repo.create_quote.assert_awaited_once()
