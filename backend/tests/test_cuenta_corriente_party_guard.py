"""
cuenta-corriente-party-guard — propagación del guard de tenencia a HTTP.

La migración 20261008000001 hace que las RPCs de cuenta corriente y el choke
point `c30_get_or_create_*` levanten `P0404 client_not_found` /
`P0404 supplier_not_found` cuando la parte recibida por parámetro no pertenece
al tenant de la sesión. Estos tests son el CANDADO de que ese P0404 llega al
cliente HTTP como 404 y no como 500, por los dos caminos que existen:

  1. Services con su propio `_ERRCODE_STATUS` + `_pg_to_http`
     (`customer_accounts` L26, `supplier_accounts` L23) → HTTPException(404).
     Esos mapas YA tenían "P0404": 404 antes de este change: los tests 7.1 y
     7.2 pasan sin tocar una línea de código de producción. Son un candado
     contra una regresión futura, NO un fix — el día que alguien saque P0404
     de esos mapas, un cobro con cliente ajeno pasaría a devolver 500 y el
     frontend perdería el mensaje del dominio.

  2. Camino de venta (`sales.create_sale_operation`), que NO tiene try/except
     propio: el `asyncpg.PostgresError` sube hasta el handler global
     (`asyncpg_error_handler` en backend/core/errors.py, registrado en
     backend/main.py) y sale como RFC 7807. Se verifica el CUERPO completo
     (type/title/status/detail/code y el media type), no sólo el status.

  3. Control negativo: un sqlstate NO mapeado sigue dando 500. Sin esto, un
     `except` demasiado ancho haría pasar todo lo anterior por accidente.

Run: python -m pytest backend/tests/test_cuenta_corriente_party_guard.py
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
from fastapi import HTTPException

from backend.tests.conftest import make_token, TEST_ACCOUNT_ID

# ── Workaround fpdf2 (pre-existing issue, mismo molde que
#    backend/tests/test_c30_customer_supplier_accounts.py) ─────────────────────
try:
    import fpdf  # noqa: F401
except ImportError:
    _fpdf_stub = types.ModuleType("fpdf")
    _fpdf_stub.FPDF = MagicMock  # type: ignore[attr-defined]
    sys.modules["fpdf"] = _fpdf_stub

# ── Constantes ────────────────────────────────────────────────────────────────
# El UUID de una parte que existe pero pertenece a OTRO tenant es
# indistinguible, desde el backend, del de una parte inexistente: la RPC
# devuelve el mismo P0404 con el mismo texto justamente para no filtrar qué
# ids existen en otros tenants (ver el assert 3.6 del gate SQL).
FOREIGN_CLIENT_ID   = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
FOREIGN_SUPPLIER_ID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbc"
PRODUCT_ID          = "99999999-9999-9999-9999-999999999999"
IDEMPOTENCY_KEY     = "test-party-guard-001"

CLIENT_NOT_FOUND_MSG   = f"client_not_found: {FOREIGN_CLIENT_ID}"
SUPPLIER_NOT_FOUND_MSG = f"supplier_not_found: {FOREIGN_SUPPLIER_ID}"


def _pg_error(sqlstate: str, message: str) -> asyncpg.PostgresError:
    """Construye el PostgresError que asyncpg entrega cuando una RPC hace
    RAISE EXCEPTION ... USING ERRCODE. Mismo molde que
    test_c30_customer_supplier_accounts.py."""
    err = asyncpg.PostgresError(message)
    err.sqlstate = sqlstate
    return err


def _auth(role: str = "user") -> dict:
    return {"sub": "test-uid", "user_id": "test-uid", "role": role}


# ═══════════════════════════════════════════════════════════════════════════════
# 7.1 — customer_accounts: P0404 del guard → HTTPException 404
# ═══════════════════════════════════════════════════════════════════════════════

class TestCustomerAccountPartyGuard:

    @pytest.mark.asyncio
    async def test_register_payment_received_p0404_becomes_404(self):
        """Cobro con un cliente que no pertenece al tenant → 404, no 500."""
        from backend.services import customer_accounts as svc
        from backend.schemas.customer_accounts import PaymentReceivedIn

        mock_repo = AsyncMock()
        mock_repo.register_payment_received.side_effect = _pg_error(
            "P0404", CLIENT_NOT_FOUND_MSG
        )

        payload = PaymentReceivedIn(
            idempotency_key=IDEMPOTENCY_KEY,
            client_id=uuid.UUID(FOREIGN_CLIENT_ID),
            amount=Decimal("400"),
        )

        with pytest.raises(HTTPException) as exc_info:
            await svc.register_payment_received(mock_repo, _auth(), payload)

        assert exc_info.value.status_code == 404
        # El detail conserva el mensaje del RPC: es texto escrito por nuestro
        # propio SQL, y es lo que el frontend muestra.
        assert "client_not_found" in str(exc_info.value.detail)

    @pytest.mark.asyncio
    async def test_create_account_p0404_becomes_404(self):
        """rpc_create_customer_account ya validaba desde C-30; el guard del
        choke point queda duplicado ahí a propósito. El mapeo no cambia."""
        from backend.services import customer_accounts as svc

        mock_repo = AsyncMock()
        mock_repo.create_account.side_effect = _pg_error("P0404", CLIENT_NOT_FOUND_MSG)

        with pytest.raises(HTTPException) as exc_info:
            await svc.create_account(mock_repo, _auth(), FOREIGN_CLIENT_ID)

        assert exc_info.value.status_code == 404

    @pytest.mark.asyncio
    async def test_unmapped_sqlstate_still_500(self):
        """CONTROL NEGATIVO (7.4): un sqlstate que no está en _ERRCODE_STATUS
        sigue cayendo en 500. Si esto diera 404, el test de arriba estaría
        pasando por un `except` demasiado ancho y no probaría nada."""
        from backend.services import customer_accounts as svc
        from backend.schemas.customer_accounts import PaymentReceivedIn

        mock_repo = AsyncMock()
        mock_repo.register_payment_received.side_effect = _pg_error(
            "P0999", "errcode inventado que nadie mapea"
        )

        payload = PaymentReceivedIn(
            idempotency_key=IDEMPOTENCY_KEY,
            client_id=uuid.UUID(FOREIGN_CLIENT_ID),
            amount=Decimal("400"),
        )

        with pytest.raises(HTTPException) as exc_info:
            await svc.register_payment_received(mock_repo, _auth(), payload)

        assert exc_info.value.status_code == 500


# ═══════════════════════════════════════════════════════════════════════════════
# 7.2 — supplier_accounts: espejo exacto
# ═══════════════════════════════════════════════════════════════════════════════

class TestSupplierAccountPartyGuard:

    @pytest.mark.asyncio
    async def test_register_payment_made_p0404_becomes_404(self):
        """Pago a un proveedor que no pertenece al tenant → 404."""
        from backend.services import supplier_accounts as svc
        from backend.schemas.supplier_accounts import PaymentMadeIn

        mock_repo = AsyncMock()
        mock_repo.register_payment_made.side_effect = _pg_error(
            "P0404", SUPPLIER_NOT_FOUND_MSG
        )

        payload = PaymentMadeIn(
            idempotency_key=IDEMPOTENCY_KEY,
            supplier_id=uuid.UUID(FOREIGN_SUPPLIER_ID),
            amount=Decimal("400"),
        )

        with pytest.raises(HTTPException) as exc_info:
            await svc.register_payment_made(mock_repo, _auth(), payload)

        assert exc_info.value.status_code == 404
        assert "supplier_not_found" in str(exc_info.value.detail)

    @pytest.mark.asyncio
    async def test_register_supplier_charge_p0404_becomes_404(self):
        """Cargo manual contra un proveedor ajeno → 404."""
        from backend.services import supplier_accounts as svc
        from backend.schemas.supplier_accounts import SupplierChargeIn

        mock_repo = AsyncMock()
        mock_repo.register_supplier_charge.side_effect = _pg_error(
            "P0404", SUPPLIER_NOT_FOUND_MSG
        )

        payload = SupplierChargeIn(
            idempotency_key=IDEMPOTENCY_KEY,
            supplier_id=uuid.UUID(FOREIGN_SUPPLIER_ID),
            amount=Decimal("250"),
        )

        with pytest.raises(HTTPException) as exc_info:
            await svc.register_supplier_charge(mock_repo, _auth(), payload)

        assert exc_info.value.status_code == 404

    @pytest.mark.asyncio
    async def test_unmapped_sqlstate_still_500(self):
        """CONTROL NEGATIVO del lado proveedor."""
        from backend.services import supplier_accounts as svc
        from backend.schemas.supplier_accounts import SupplierChargeIn

        mock_repo = AsyncMock()
        mock_repo.register_supplier_charge.side_effect = _pg_error("P0999", "sin mapear")

        payload = SupplierChargeIn(
            idempotency_key=IDEMPOTENCY_KEY,
            supplier_id=uuid.UUID(FOREIGN_SUPPLIER_ID),
            amount=Decimal("250"),
        )

        with pytest.raises(HTTPException) as exc_info:
            await svc.register_supplier_charge(mock_repo, _auth(), payload)

        assert exc_info.value.status_code == 500


# ═══════════════════════════════════════════════════════════════════════════════
# 7.3 — camino de venta: handler global + cuerpo RFC 7807
# ═══════════════════════════════════════════════════════════════════════════════

class TestSaleOperationPartyGuardHttp:
    """`sales.create_sale_operation` NO tiene try/except propio (verificado en
    backend/services/sales.py): el PostgresError sube hasta el handler global
    `asyncpg_error_handler`. Es el camino de MÁS VOLUMEN — la venta a crédito
    del formulario — y el que el guard del choke point cubre sin que
    rpc_create_sale_operation_v2 haya cambiado una línea."""

    @staticmethod
    def _payload() -> dict:
        return {
            "org_id": str(TEST_ACCOUNT_ID),
            "client_id": FOREIGN_CLIENT_ID,
            "currency": "ARS",
            "items": [{"product_id": PRODUCT_ID, "amount": 1000, "quantity": 1}],
        }

    @pytest.mark.asyncio
    async def test_credit_sale_with_foreign_client_returns_404_problem_json(
        self, async_client, mock_pool
    ):
        """Venta a crédito con cliente de otro tenant → 404 con cuerpo 7807
        completo (no sólo el status)."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(
            side_effect=_pg_error("P0404", CLIENT_NOT_FOUND_MSG)
        )

        with patch("backend.core.database.pool", pool):
            headers = {
                "Authorization": f"Bearer {make_token({'role': 'user'})}",
                "Idempotency-Key": IDEMPOTENCY_KEY,
            }
            response = await async_client.post(
                "/sales", json=self._payload(), headers=headers
            )

        assert response.status_code == 404

        body = response.json()
        # RFC 7807: los cuatro campos base + la extensión `code` con el sqlstate.
        assert body["type"] == "about:blank"
        assert body["status"] == 404
        assert body["code"] == "P0404"
        assert isinstance(body["title"], str) and body["title"]
        assert "client_not_found" in body["detail"]
        # P0404 no tiene entrada en _FIELD_BY_ERRCODE (sólo P0413), así que la
        # extensión `field` no debe aparecer.
        assert "field" not in body
        assert response.headers["content-type"].startswith("application/problem+json")

    @pytest.mark.asyncio
    async def test_unmapped_sqlstate_on_sale_path_still_500(
        self, async_client, mock_pool
    ):
        """CONTROL NEGATIVO (7.4) del camino global: un sqlstate no mapeado
        sale 500 y NO expone el mensaje crudo de la base."""
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
                "/sales", json=self._payload(), headers=headers
            )

        assert response.status_code == 500
        body = response.json()
        assert body["status"] == 500
        assert body["code"] == "internal_error"
        assert "detalle interno que no debe filtrarse" not in body["detail"]
