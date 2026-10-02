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
     update_operation` llama `conn.fetchval(...)` (no `fetchrow`) desde
     venta-editable-sin-cae, a diferencia de purchase — el mock se monta
     sobre `conn.fetchval`.

  5. "accept quote" (rpc_accept_quote, vía POST /quotes/{id}/accept) — RETIRADO
     por presupuestos-modulo (tanda A, task 2.6): el endpoint y
     `quotes_service.accept_quote` ya no existen (D12; la única vía a `accepted`
     es la conversión a venta). El bloque vuelve en la tanda B (task 6.5)
     reescrito sobre `convert_quote`: `P0404 client_not_found` y `P0404
     quote_client_unavailable` -> 404 RFC 7807 con su `code`, más el control
     negativo. La regresión del guard SQL de `rpc_accept_quote` sigue en el gate
     supabase/tests/test_operacion_party_guard.sql.

  6. "create quote" (rpc_create_quote, vía POST /quotes) — REESCRITO por
     presupuestos-modulo (task 2.6). Antes el guard era un pre-chequeo Python
     (`QuoteRepository.client_belongs_to_account`) porque el alta era un INSERT
     directo. Ahora la tenencia del cliente la resuelve la RPC con el mismo
     `P0404 client_not_found: <id>` y el service lo mapea a 404 RFC 7807 con
     `code = client_not_found`: un `client_id` ajeno sigue respondiendo
     `client_not_found`, pero desde la base y no desde Python. Test a nivel
     service con repo mockeado.

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
        diera 404, el test de arriba pasaría por un `except` demasiado ancho.

        venta-editable-vs-promocion-legacy: el service ya no lo envuelve en un
        HTTPException 500 con el texto del motor; lo RE-LANZA intacto y el 500
        lo arma asyncpg_error_handler (problem+json genérico, code
        internal_error). El control sigue siendo el mismo: NO es un 404."""
        from backend.core.errors import _BUSINESS_ERRCODE_STATUS
        from backend.services import sales_orders as svc
        from backend.schemas.sales_orders import QuickSaleIn, SalesOrderItemIn

        mock_repo = AsyncMock()
        mock_repo.quick_sale.side_effect = _pg_error("P0999", "errcode inventado que nadie mapea")

        payload = QuickSaleIn(
            idempotency_key=IDEMPOTENCY_KEY,
            client_id=uuid.UUID(FOREIGN_CLIENT_ID),
            items=[SalesOrderItemIn(product_id=uuid.UUID(PRODUCT_ID), quantity=1, price=1000)],
        )

        with pytest.raises(asyncpg.PostgresError) as exc_info:
            await svc.quick_sale(mock_repo, _auth(), payload, str(TEST_ACCOUNT_ID))

        assert not isinstance(exc_info.value, HTTPException)
        assert exc_info.value.sqlstate == "P0999"
        # El handler global responde 500 a todo sqlstate fuera del mapa.
        assert "P0999" not in _BUSINESS_ERRCODE_STATUS


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
        404 con cuerpo 7807 completo. venta-editable-sin-cae migró
        SalesRepository.update_operation de conn.execute a conn.fetchval (la RPC
        pasó a devolver jsonb con el comprobante anulado): el mock se monta
        sobre fetchval, o dejaría de interceptar y el test pasaría por la
        razón equivocada."""
        pool, conn = mock_pool
        conn.fetchval = AsyncMock(side_effect=_pg_error("P0404", CLIENT_NOT_FOUND_MSG))

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
        conn.fetchval = AsyncMock(
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
# 5 — "accept quote": RETIRADO hasta la tanda B (ver el docstring del módulo).
# ═══════════════════════════════════════════════════════════════════════════════


# ═══════════════════════════════════════════════════════════════════════════════
# 6 — "create quote" (rpc_create_quote, vía POST /quotes)
#     presupuestos-modulo (task 2.6): el guard de tenencia del cliente vive en la
#     RPC (P0404 `client_not_found: <id>`, el mismo literal que los otros cuatro
#     caminos) y el service lo traduce a 404 RFC 7807 con su `code` estable.
# ═══════════════════════════════════════════════════════════════════════════════

def _quote_payload_for(client_id: str):
    from backend.schemas.quotes import QuoteIn, QuoteItemIn

    return QuoteIn(
        client_id=uuid.UUID(client_id),
        items=[
            QuoteItemIn(
                product_id=uuid.UUID(PRODUCT_ID),
                quantity=Decimal("1"),
                price=Decimal("1000"),
                subtotal=Decimal("1000"),
            )
        ],
    )


def _seller_auth() -> dict:
    return {**_auth(), "account_roles": ["seller"]}


class TestCreateQuotePartyGuard:

    @pytest.mark.asyncio
    async def test_create_quote_with_foreign_client_returns_404_client_not_found(self):
        """Un client_id de otro tenant lo rechaza la RPC con P0404 y el service
        lo devuelve como 404 `client_not_found` — no 500, no un detalle opaco."""
        from backend.services import quotes as svc

        mock_repo = AsyncMock()
        mock_repo.create_quote.side_effect = _pg_error("P0404", CLIENT_NOT_FOUND_MSG)

        with pytest.raises(HTTPException) as exc_info:
            await svc.create_quote(
                mock_repo, _seller_auth(), str(TEST_ACCOUNT_ID),
                _quote_payload_for(FOREIGN_CLIENT_ID), conn=AsyncMock(),
            )

        assert exc_info.value.status_code == 404
        assert exc_info.value.code == "client_not_found"
        assert FOREIGN_CLIENT_ID in str(exc_info.value.detail)
        mock_repo.get_quote.assert_not_awaited()  # no se leyó nada: la RPC falló antes de escribir

    @pytest.mark.asyncio
    async def test_create_quote_with_own_client_still_creates(self):
        """CONTROL POSITIVO: un client_id propio no se sobre-bloquea."""
        from backend.services import quotes as svc

        mock_repo = AsyncMock()
        mock_repo.create_quote.return_value = {
            "id": "dddddddd-dddd-dddd-dddd-dddddddddddd",
            "account_id": str(TEST_ACCOUNT_ID),
        }
        mock_repo.get_quote.return_value = {
            "id": "dddddddd-dddd-dddd-dddd-dddddddddddd",
            "account_id": str(TEST_ACCOUNT_ID),
            "branch_id": None,
            "client_id": FOREIGN_CLIENT_ID,  # reusado sólo como uuid válido; acá es "propio"
            "status": "draft",
            "valid_until": None,
            "total": Decimal("1000.00"),
            "created_by": "11111111-1111-1111-1111-111111111111",
            "created_at": "2026-09-10T00:00:00",
            "number": 1,
            "revision": 1,
            "items": [],
            "history": [],
        }

        result = await svc.create_quote(
            mock_repo, _seller_auth(), str(TEST_ACCOUNT_ID),
            _quote_payload_for(FOREIGN_CLIENT_ID), conn=AsyncMock(),
        )

        mock_repo.create_quote.assert_awaited_once()
        assert result["id"] == "dddddddd-dddd-dddd-dddd-dddddddddddd"

    @pytest.mark.asyncio
    async def test_unmapped_sqlstate_on_create_quote_path_is_not_disguised(self):
        """CONTROL NEGATIVO: un sqlstate sin mapear no se disfraza de
        `client_not_found` (ni de nada): sube tal cual y el handler global lo
        resuelve como 500 genérico. Sin esto, el test de arriba pasaría por un
        `except` demasiado ancho."""
        from backend.services import quotes as svc

        mock_repo = AsyncMock()
        mock_repo.create_quote.side_effect = _pg_error("P0999", "errcode inventado que nadie mapea")

        with pytest.raises(asyncpg.PostgresError) as exc_info:
            await svc.create_quote(
                mock_repo, _seller_auth(), str(TEST_ACCOUNT_ID),
                _quote_payload_for(FOREIGN_CLIENT_ID), conn=AsyncMock(),
            )

        assert exc_info.value.sqlstate == "P0999"
