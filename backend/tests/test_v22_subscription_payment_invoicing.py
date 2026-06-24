"""
v22-afip-delegation-billing — TDD tests: subscription payment invoicing (admin).

Verifica:
  §1 RED→GREEN: EmitSubscriptionPaymentRequest schema valida campos obligatorios.
  §2 RED→GREEN: emit_subscription_payment_cae requiere rol admin.
  §3 GREEN: emit retorna already_emitted=True para receipt ya facturado.
  §4 TRIANGULATE: CUIT=80, DNI=96; rol user → 403; receipt nuevo → RPC call.
  §5 GREEN: router endpoint emit-subscription-payment admin ok.
  §6 GREEN: router GET by-receipt/id retorna doc o None.

Gate: python -m pytest backend/tests/test_v22_subscription_payment_invoicing.py -m "not integration" -v
Design ref: v22-admin — PO sign-off 2026-06-24.
"""
from __future__ import annotations

import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest


# =============================================================================
# §1 RED→GREEN — Schema EmitSubscriptionPaymentRequest
# =============================================================================

class TestEmitSubscriptionPaymentRequestSchema:
    """§1: schema válida tipos y campos obligatorios."""

    def test_valid_cuit_doc_tipo(self):
        """§1 RED: receptor_doc_tipo=80 (CUIT) debe ser aceptado."""
        from backend.schemas.fiscal import EmitSubscriptionPaymentRequest
        r = EmitSubscriptionPaymentRequest(
            receipt_id="aaaa-bbbb",
            receptor_doc_tipo=80,
            receptor_doc_nro="20422662457",
        )
        assert r.receptor_doc_tipo == 80
        assert r.receptor_doc_nro == "20422662457"

    def test_valid_dni_doc_tipo(self):
        """§1 RED: receptor_doc_tipo=96 (DNI) debe ser aceptado."""
        from backend.schemas.fiscal import EmitSubscriptionPaymentRequest
        r = EmitSubscriptionPaymentRequest(
            receipt_id="aaaa-bbbb",
            receptor_doc_tipo=96,
            receptor_doc_nro="12345678",
        )
        assert r.receptor_doc_tipo == 96

    def test_invalid_doc_tipo_rejected(self):
        """§1 TRIANGULATE: DocTipo fuera de {80,96} debe rechazarse (Pydantic Literal)."""
        from backend.schemas.fiscal import EmitSubscriptionPaymentRequest
        from pydantic import ValidationError
        with pytest.raises(ValidationError):
            EmitSubscriptionPaymentRequest(
                receipt_id="aaaa",
                receptor_doc_tipo=99,   # 99 no está en Literal[80, 96]
                receptor_doc_nro="0",
            )

    def test_missing_receipt_id_rejected(self):
        """§1 TRIANGULATE: receipt_id es obligatorio."""
        from backend.schemas.fiscal import EmitSubscriptionPaymentRequest
        from pydantic import ValidationError
        with pytest.raises(ValidationError):
            EmitSubscriptionPaymentRequest(  # type: ignore[call-arg]
                receptor_doc_tipo=80,
                receptor_doc_nro="20422662457",
            )

    def test_point_of_sale_id_is_optional(self):
        """§1 GREEN: point_of_sale_id es opcional (None por defecto)."""
        from backend.schemas.fiscal import EmitSubscriptionPaymentRequest
        r = EmitSubscriptionPaymentRequest(
            receipt_id="x",
            receptor_doc_tipo=80,
            receptor_doc_nro="20422662457",
        )
        assert r.point_of_sale_id is None


# =============================================================================
# §2 RED→GREEN — emit_subscription_payment_cae requiere rol admin
# =============================================================================

class TestEmitSubscriptionPaymentRoleGuard:
    """§2: solo admin puede emitir; user → 403."""

    @pytest.mark.asyncio
    async def test_user_role_raises_403(self):
        """§2 RED: rol 'user' no puede emitir comprobante de suscripción."""
        from backend.services.fiscal import fiscal_profile_service as svc
        from backend.schemas.fiscal import EmitSubscriptionPaymentRequest
        from fastapi import HTTPException

        mock_conn = AsyncMock()
        auth = {"user_id": "00000000-0000-0000-0000-000000000001", "role": "user"}
        mock_conn.fetchval.return_value = "user"  # profiles.role en la DB (no admin)

        payload = EmitSubscriptionPaymentRequest(
            receipt_id="some-receipt-id",
            receptor_doc_tipo=80,
            receptor_doc_nro="20422662457",
        )

        with pytest.raises(HTTPException) as exc_info:
            await svc.emit_subscription_payment_cae(mock_conn, auth, payload)

        assert exc_info.value.status_code == 403, (
            f"User debe recibir 403. Status: {exc_info.value.status_code}"
        )
        # La conexión no debe haber sido tocada
        mock_conn.fetchrow.assert_not_called()

    @pytest.mark.asyncio
    async def test_member_role_raises_403(self):
        """§2 TRIANGULATE: rol 'member' tampoco puede emitir."""
        from backend.services.fiscal import fiscal_profile_service as svc
        from backend.schemas.fiscal import EmitSubscriptionPaymentRequest
        from fastapi import HTTPException

        mock_conn = AsyncMock()
        auth = {"user_id": "00000000-0000-0000-0000-000000000001", "role": "member"}
        mock_conn.fetchval.return_value = "member"  # profiles.role en la DB (no admin)

        payload = EmitSubscriptionPaymentRequest(
            receipt_id="some-receipt-id",
            receptor_doc_tipo=96,
            receptor_doc_nro="12345678",
        )

        with pytest.raises(HTTPException) as exc_info:
            await svc.emit_subscription_payment_cae(mock_conn, auth, payload)

        assert exc_info.value.status_code == 403


# =============================================================================
# §3 GREEN — Idempotency: receipt ya facturado → already_emitted=True
# =============================================================================

class TestEmitSubscriptionPaymentIdempotency:
    """§3: si ya existe un fiscal_document para el receipt_id, retorna already_emitted."""

    @pytest.mark.asyncio
    async def test_already_emitted_receipt_returns_existing_doc(self):
        """§3 RED→GREEN: receipt ya facturado retorna already_emitted=True."""
        from backend.services.fiscal import fiscal_profile_service as svc
        from backend.schemas.fiscal import EmitSubscriptionPaymentRequest
        import datetime

        mock_conn = AsyncMock()
        existing_doc = {
            "id": "dddddddd-dddd-dddd-dddd-dddddddddddd",
            "status": "authorized",
            "cae": "86250464989491",
            "cae_due_date": datetime.date(2026, 7, 14),
            "comprobante_type": "factura_c",
            "total": 1500.0,
        }
        # First fetchrow: existing doc check → returns the existing doc
        mock_conn.fetchrow.return_value = existing_doc

        auth = {"user_id": "00000000-0000-0000-0000-000000000099", "role": "admin"}
        mock_conn.fetchval.return_value = "admin"  # profiles.role en la DB
        payload = EmitSubscriptionPaymentRequest(
            receipt_id="receipt-already-invoiced",
            receptor_doc_tipo=80,
            receptor_doc_nro="20422662457",
        )

        result = await svc.emit_subscription_payment_cae(mock_conn, auth, payload)

        assert result["already_emitted"] is True, "Debe retornar already_emitted=True"
        assert result["fiscal_document_id"] == "dddddddd-dddd-dddd-dddd-dddddddddddd"
        assert result["status"] == "authorized"
        assert result["cae"] == "86250464989491"

    @pytest.mark.asyncio
    async def test_already_emitted_pending_receipt_returns_existing_doc(self):
        """§3 TRIANGULATE: receipt en pending_cae también retorna already_emitted=True."""
        from backend.services.fiscal import fiscal_profile_service as svc
        from backend.schemas.fiscal import EmitSubscriptionPaymentRequest

        mock_conn = AsyncMock()
        existing_doc = {
            "id": "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
            "status": "pending_cae",
            "cae": None,
            "cae_due_date": None,
            "comprobante_type": "factura_c",
            "total": 500.0,
        }
        mock_conn.fetchrow.return_value = existing_doc

        auth = {"user_id": "00000000-0000-0000-0000-000000000099", "role": "admin"}
        mock_conn.fetchval.return_value = "admin"  # profiles.role en la DB
        payload = EmitSubscriptionPaymentRequest(
            receipt_id="receipt-pending",
            receptor_doc_tipo=96,
            receptor_doc_nro="12345678",
        )

        result = await svc.emit_subscription_payment_cae(mock_conn, auth, payload)

        assert result["already_emitted"] is True
        assert result["status"] == "pending_cae"
        assert result["cae"] is None


# =============================================================================
# §4 TRIANGULATE — nuevo receipt: llama a la RPC correctamente
# =============================================================================

class TestEmitSubscriptionPaymentNewReceipt:
    """§4: receipt nuevo → llama rpc_emit_subscription_payment_cae en la DB."""

    @pytest.mark.asyncio
    async def test_new_receipt_calls_rpc(self):
        """§4 RED→GREEN: receipt nuevo llama la RPC y retorna el resultado."""
        from backend.services.fiscal import fiscal_profile_service as svc
        from backend.schemas.fiscal import EmitSubscriptionPaymentRequest

        mock_conn = AsyncMock()
        # First fetchrow: idempotency check → None (no existing doc)
        # Second fetchrow: RPC call result
        rpc_result = {
            "fiscal_document_id": "ffffffff-ffff-ffff-ffff-ffffffffffff",
            "punto_de_venta": 1,
            "comprobante_type": "factura_c",
            "number": 42,
            "status": "pending_cae",
            "subscription_payment_id": "new-receipt-id",
            "total": 2000.0,
        }
        mock_conn.fetchrow.side_effect = [
            None,                    # idempotency check: no existing doc
            {"result": json.dumps(rpc_result)},  # RPC result
        ]

        auth = {"user_id": "00000000-0000-0000-0000-000000000099", "role": "admin"}
        mock_conn.fetchval.return_value = "admin"  # profiles.role en la DB
        payload = EmitSubscriptionPaymentRequest(
            receipt_id="new-receipt-id",
            receptor_doc_tipo=80,
            receptor_doc_nro="20422662457",
        )

        result = await svc.emit_subscription_payment_cae(mock_conn, auth, payload)

        # Should NOT have already_emitted flag (or False)
        assert not result.get("already_emitted", False), (
            "Nuevo receipt no debe retornar already_emitted=True"
        )
        assert result["fiscal_document_id"] == "ffffffff-ffff-ffff-ffff-ffffffffffff"
        assert result["status"] == "pending_cae"

        # Verify the RPC was called (second fetchrow)
        assert mock_conn.fetchrow.call_count == 2, (
            "Debe hacer 2 fetchrow calls: idempotency check + RPC call"
        )

    @pytest.mark.asyncio
    async def test_new_receipt_with_pv_id_passes_it_to_rpc(self):
        """§4 TRIANGULATE: point_of_sale_id se pasa a la RPC cuando se especifica."""
        from backend.services.fiscal import fiscal_profile_service as svc
        from backend.schemas.fiscal import EmitSubscriptionPaymentRequest
        import uuid

        mock_conn = AsyncMock()
        pv_id = uuid.UUID("11111111-1111-1111-1111-111111111111")
        rpc_result = {
            "fiscal_document_id": "aaaa1111-1111-1111-1111-111111111111",
            "status": "pending_cae",
        }
        mock_conn.fetchrow.side_effect = [
            None,  # no existing doc
            {"result": json.dumps(rpc_result)},
        ]

        auth = {"user_id": "00000000-0000-0000-0000-000000000099", "role": "admin"}
        mock_conn.fetchval.return_value = "admin"  # profiles.role en la DB
        payload = EmitSubscriptionPaymentRequest(
            receipt_id="receipt-with-pv",
            receptor_doc_tipo=96,
            receptor_doc_nro="12345678",
            point_of_sale_id=pv_id,
        )

        result = await svc.emit_subscription_payment_cae(mock_conn, auth, payload)

        # Verify the second call (RPC) received the pv_id
        rpc_call_args = mock_conn.fetchrow.call_args_list[1][0]
        # Args: SQL_query, receipt_id, pv_id_str, doc_tipo, doc_nro
        assert str(pv_id) in rpc_call_args, (
            f"point_of_sale_id {pv_id} debe pasarse a la RPC. Args: {rpc_call_args}"
        )


# =============================================================================
# §5 GREEN — Router endpoint emit-subscription-payment
# =============================================================================

class TestEmitSubscriptionPaymentRouter:
    """§5: router endpoint POST /fiscal/documents/emit-subscription-payment."""

    @pytest.mark.asyncio
    async def test_non_admin_gets_403(self):
        """§5 RED: usuario sin rol admin recibe 403."""
        import uuid
        from unittest.mock import AsyncMock, patch
        from fastapi.testclient import TestClient
        from backend.main import app

        # Override get_current_user to return a non-admin
        from backend.core.auth import get_current_user
        from backend.core.database import get_db_conn

        mock_conn = AsyncMock()

        def fake_non_admin():
            return {"user_id": str(uuid.uuid4()), "role": "user"}

        async def fake_conn():
            yield mock_conn

        app.dependency_overrides[get_current_user] = fake_non_admin
        app.dependency_overrides[get_db_conn] = fake_conn

        try:
            # Use async test client pattern
            from httpx import AsyncClient, ASGITransport
            async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
                resp = await client.post(
                    "/fiscal/documents/emit-subscription-payment",
                    json={
                        "receipt_id": "some-receipt",
                        "receptor_doc_tipo": 80,
                        "receptor_doc_nro": "20422662457",
                    },
                )
            assert resp.status_code == 403, f"Expected 403, got {resp.status_code}: {resp.text}"
        finally:
            app.dependency_overrides.pop(get_current_user, None)
            app.dependency_overrides.pop(get_db_conn, None)

    @pytest.mark.asyncio
    async def test_admin_gets_201_for_new_receipt(self):
        """§5 GREEN: admin con receipt nuevo recibe 201 + fiscal_document_id."""
        import uuid
        from httpx import AsyncClient, ASGITransport
        from backend.main import app
        from backend.core.auth import get_current_user
        from backend.core.database import get_db_conn

        mock_conn = AsyncMock()
        rpc_result = {
            "fiscal_document_id": "bbbb2222-2222-2222-2222-222222222222",
            "status": "pending_cae",
            "comprobante_type": "factura_c",
            "total": 1200.0,
            "subscription_payment_id": "receipt-001",
        }
        mock_conn.fetchrow.side_effect = [
            None,  # idempotency check
            {"result": json.dumps(rpc_result)},  # RPC result
        ]
        mock_conn.fetchval.return_value = "admin"  # profiles.role en la DB (guard)

        def fake_admin():
            return {"user_id": str(uuid.uuid4()), "role": "admin"}

        async def fake_conn():
            yield mock_conn

        # Patch background_tasks to avoid background processing in tests
        with patch(
            "backend.services.fiscal.fiscal_profile_service.process_doc_by_id_background",
            new_callable=AsyncMock,
        ):
            app.dependency_overrides[get_current_user] = fake_admin
            app.dependency_overrides[get_db_conn] = fake_conn
            try:
                async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
                    resp = await client.post(
                        "/fiscal/documents/emit-subscription-payment",
                        json={
                            "receipt_id": "receipt-001",
                            "receptor_doc_tipo": 80,
                            "receptor_doc_nro": "20422662457",
                        },
                    )
                assert resp.status_code == 201, f"Expected 201, got {resp.status_code}: {resp.text}"
                body = resp.json()
                assert body["fiscal_document_id"] == "bbbb2222-2222-2222-2222-222222222222"
                assert body["status"] == "pending_cae"
            finally:
                app.dependency_overrides.pop(get_current_user, None)
                app.dependency_overrides.pop(get_db_conn, None)


# =============================================================================
# §6 GREEN — Router GET /fiscal/documents/by-receipt/{receipt_id}
# =============================================================================

class TestGetFiscalDocByReceipt:
    """§6: GET endpoint retorna el doc para un receipt o None."""

    @pytest.mark.asyncio
    async def test_returns_none_when_no_doc_exists(self):
        """§6 RED→GREEN: retorna null cuando no hay comprobante para el receipt."""
        import uuid
        from httpx import AsyncClient, ASGITransport
        from backend.main import app
        from backend.core.auth import get_current_user
        from backend.core.database import get_db_conn

        mock_conn = AsyncMock()
        mock_conn.fetchrow.return_value = None  # No doc found
        mock_conn.fetchval.return_value = "admin"  # profiles.role en la DB (guard)

        def fake_admin():
            return {"user_id": str(uuid.uuid4()), "role": "admin"}

        async def fake_conn():
            yield mock_conn

        app.dependency_overrides[get_current_user] = fake_admin
        app.dependency_overrides[get_db_conn] = fake_conn
        try:
            async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
                resp = await client.get("/fiscal/documents/by-receipt/nonexistent-receipt-id")
            assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.text}"
            assert resp.json() is None
        finally:
            app.dependency_overrides.pop(get_current_user, None)
            app.dependency_overrides.pop(get_db_conn, None)

    @pytest.mark.asyncio
    async def test_returns_doc_when_exists(self):
        """§6 GREEN: retorna el doc cuando existe."""
        import uuid
        import datetime
        from httpx import AsyncClient, ASGITransport
        from backend.main import app
        from backend.core.auth import get_current_user
        from backend.core.database import get_db_conn

        mock_conn = AsyncMock()
        mock_conn.fetchval.return_value = "admin"  # profiles.role en la DB (guard)
        doc_id = uuid.UUID("cccc3333-3333-3333-3333-333333333333")
        mock_conn.fetchrow.return_value = {
            "id": doc_id,
            "status": "authorized",
            "cae": "86250464989491",
            "cae_due_date": datetime.date(2026, 7, 14),
            "comprobante_type": "factura_c",
            "total": 1500.0,
            "subscription_payment_id": "receipt-with-cae",
        }

        def fake_admin():
            return {"user_id": str(uuid.uuid4()), "role": "admin"}

        async def fake_conn():
            yield mock_conn

        app.dependency_overrides[get_current_user] = fake_admin
        app.dependency_overrides[get_db_conn] = fake_conn
        try:
            async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
                resp = await client.get("/fiscal/documents/by-receipt/receipt-with-cae")
            assert resp.status_code == 200, f"Expected 200, got {resp.status_code}: {resp.text}"
            body = resp.json()
            assert body["id"] == str(doc_id)
            assert body["status"] == "authorized"
            assert body["cae"] == "86250464989491"
        finally:
            app.dependency_overrides.pop(get_current_user, None)
            app.dependency_overrides.pop(get_db_conn, None)

    @pytest.mark.asyncio
    async def test_non_admin_gets_403(self):
        """§6 TRIANGULATE: usuario sin rol admin recibe 403 en GET by-receipt."""
        import uuid
        from httpx import AsyncClient, ASGITransport
        from backend.main import app
        from backend.core.auth import get_current_user
        from backend.core.database import get_db_conn

        mock_conn = AsyncMock()

        def fake_user():
            return {"user_id": str(uuid.uuid4()), "role": "user"}

        async def fake_conn():
            yield mock_conn

        app.dependency_overrides[get_current_user] = fake_user
        app.dependency_overrides[get_db_conn] = fake_conn
        try:
            async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
                resp = await client.get("/fiscal/documents/by-receipt/some-receipt")
            assert resp.status_code == 403, f"Expected 403, got {resp.status_code}: {resp.text}"
        finally:
            app.dependency_overrides.pop(get_current_user, None)
            app.dependency_overrides.pop(get_db_conn, None)
