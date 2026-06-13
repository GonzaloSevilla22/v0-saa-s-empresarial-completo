from __future__ import annotations

import datetime
import hashlib
import hmac
import json
import time
import uuid
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from backend.services.payments import verify_mp_signature
from backend.tests.conftest import make_token

# ── Helpers ──────────────────────────────────────────────────────────────────

SECRET = "test-webhook-secret"
REQUEST_ID = "req-123"


def _make_signature(notification_id: str, ts: str | None = None) -> str:
    ts = ts or str(int(time.time()))
    template = f"id:{notification_id};request-id:{REQUEST_ID};ts:{ts};"
    digest = hmac.new(SECRET.encode(), template.encode(), hashlib.sha256).hexdigest()
    return f"ts={ts},v1={digest}"


def _mp_body(notification_id: str = "pay-123", type_: str = "payment") -> bytes:
    return json.dumps({"type": type_, "data": {"id": notification_id}}).encode()


def _mp_payment_row(
    status: str = "approved",
    user_id: str = "user-uuid-1",
    plan: str = "avanzado",
    amount: float = 1500.0,
) -> dict:
    return {
        "status": status,
        "external_reference": f"{user_id}::plan",
        "transaction_amount": amount,
        "preference_id": "pref-abc",
    }


# ── Unit tests: verify_mp_signature ──────────────────────────────────────────

def test_verify_signature_valid():
    body = _mp_body()
    sig = _make_signature("pay-123")
    assert verify_mp_signature(body, sig, REQUEST_ID, SECRET) is True


def test_verify_signature_invalid_digest():
    body = _mp_body()
    bad_sig = _make_signature("pay-123").replace("v1=", "v1=bad")
    assert verify_mp_signature(body, bad_sig, REQUEST_ID, SECRET) is False


def test_verify_signature_missing_header():
    body = _mp_body()
    assert verify_mp_signature(body, None, REQUEST_ID, SECRET) is False
    assert verify_mp_signature(body, _make_signature("pay-123"), None, SECRET) is False


def test_verify_signature_empty_secret():
    body = _mp_body()
    sig = _make_signature("pay-123")
    assert verify_mp_signature(body, sig, REQUEST_ID, "") is False


# ── Integration tests: POST /payments/webhook ─────────────────────────────────

@pytest.fixture
def mock_service_pool():
    pool = MagicMock()
    conn = AsyncMock()
    pool.acquire.return_value.__aenter__ = AsyncMock(return_value=conn)
    pool.acquire.return_value.__aexit__ = AsyncMock(return_value=False)
    conn.fetchrow = AsyncMock(return_value=None)
    conn.execute = AsyncMock(return_value="OK")
    return pool, conn


async def _post_webhook(async_client, body: bytes, sig: str, shadow: bool = False):
    url = "/payments/webhook" + ("?shadow=true" if shadow else "")
    return await async_client.post(
        url,
        content=body,
        headers={
            "x-signature": sig,
            "x-request-id": REQUEST_ID,
            "content-type": "application/json",
        },
    )


async def test_webhook_approved_upgrades_plan(async_client, mock_service_pool):
    pool, conn = mock_service_pool
    body = _mp_body("pay-001")
    sig = _make_signature("pay-001")

    member_row = {"account_id": "acc-uuid-1", "billing_plan": "gratis"}
    event_row = {"id": "be-uuid-1", "receipt_number": "RC-2026-000099"}
    conn.fetchrow = AsyncMock(side_effect=[None, member_row, event_row])

    mp_response = MagicMock()
    mp_response.status_code = 200
    mp_response.json.return_value = {
        "status": "approved",
        "external_reference": "user-uuid-1::avanzado",
        "transaction_amount": 1500.0,
        "preference_id": "pref-abc",
    }

    with (
        patch("backend.core.database.pool", pool),
        patch("backend.core.config.settings.mercadopago_webhook_secret", SECRET),
        patch("backend.core.config.settings.mercadopago_access_token", "mp-token"),
        patch("backend.services.payments._fetch_user_email", new_callable=AsyncMock, return_value="user@example.com"),
        patch("httpx.AsyncClient.get", new_callable=AsyncMock, return_value=mp_response),
    ):
        resp = await _post_webhook(async_client, body, sig)

    assert resp.status_code == 200
    assert resp.json()["ok"] is True
    assert resp.json().get("idempotent") is None
    # El email_logs del recibo debe incluir el PDF en base64 + el N° de recibo.
    email_insert = [c for c in conn.execute.await_args_list if "email_logs" in str(c.args[0])]
    assert email_insert, "no se insertó el email_logs del recibo"
    meta_json = email_insert[0].args[4]
    assert "receipt_pdf_base64" in meta_json
    assert "RC-2026-000099" in meta_json


async def test_webhook_invalid_signature_returns_400(async_client, mock_service_pool):
    pool, _ = mock_service_pool
    body = _mp_body("pay-002")
    bad_sig = "ts=0,v1=invalidsig"

    with (
        patch("backend.core.database.pool", pool),
        patch("backend.core.config.settings.mercadopago_webhook_secret", SECRET),
    ):
        resp = await _post_webhook(async_client, body, bad_sig)

    assert resp.status_code == 400


async def test_webhook_duplicate_payment_is_idempotent(async_client, mock_service_pool):
    pool, conn = mock_service_pool
    body = _mp_body("pay-003")
    sig = _make_signature("pay-003")

    conn.fetchrow = AsyncMock(return_value={"id": "existing-event-id"})

    mp_response = MagicMock()
    mp_response.status_code = 200
    mp_response.json.return_value = {
        "status": "approved",
        "external_reference": "user-uuid-1::avanzado",
        "transaction_amount": 1500.0,
        "preference_id": "pref-abc",
    }

    with (
        patch("backend.core.database.pool", pool),
        patch("backend.core.config.settings.mercadopago_webhook_secret", SECRET),
        patch("backend.core.config.settings.mercadopago_access_token", "mp-token"),
        patch("httpx.AsyncClient.get", new_callable=AsyncMock, return_value=mp_response),
    ):
        resp = await _post_webhook(async_client, body, sig)

    assert resp.status_code == 200
    assert resp.json()["idempotent"] is True
    conn.execute.assert_not_called()


async def test_webhook_invalid_external_reference_returns_400(async_client, mock_service_pool):
    pool, conn = mock_service_pool
    body = _mp_body("pay-004")
    sig = _make_signature("pay-004")

    conn.fetchrow = AsyncMock(return_value=None)

    mp_response = MagicMock()
    mp_response.status_code = 200
    mp_response.json.return_value = {
        "status": "approved",
        "external_reference": "malformed-no-separator",
        "transaction_amount": 500.0,
        "preference_id": None,
    }

    with (
        patch("backend.core.database.pool", pool),
        patch("backend.core.config.settings.mercadopago_webhook_secret", SECRET),
        patch("backend.core.config.settings.mercadopago_access_token", "mp-token"),
        patch("httpx.AsyncClient.get", new_callable=AsyncMock, return_value=mp_response),
    ):
        resp = await _post_webhook(async_client, body, sig)

    assert resp.status_code == 400


async def test_webhook_mp_payment_not_found_returns_skipped(async_client, mock_service_pool):
    """MP devuelve 404 para IDs de test (ej. "123456") — debe retornar ok+skipped, no 502."""
    pool, conn = mock_service_pool
    body = _mp_body("123456")
    sig = _make_signature("123456")

    conn.fetchrow = AsyncMock(return_value=None)

    mp_response = MagicMock()
    mp_response.status_code = 404

    with (
        patch("backend.core.database.pool", pool),
        patch("backend.core.config.settings.mercadopago_webhook_secret", SECRET),
        patch("backend.core.config.settings.mercadopago_access_token", "mp-token"),
        patch("httpx.AsyncClient.get", new_callable=AsyncMock, return_value=mp_response),
    ):
        resp = await _post_webhook(async_client, body, sig)

    assert resp.status_code == 200
    assert resp.json()["ok"] is True
    assert resp.json()["skipped"] is True
    conn.execute.assert_not_called()


async def test_webhook_shadow_mode_no_db_writes(async_client, mock_service_pool):
    pool, conn = mock_service_pool
    body = _mp_body("pay-005")
    sig = _make_signature("pay-005")

    member_row = {"account_id": "acc-uuid-2", "billing_plan": "inicial"}
    conn.fetchrow = AsyncMock(side_effect=[None, member_row])

    mp_response = MagicMock()
    mp_response.status_code = 200
    mp_response.json.return_value = {
        "status": "approved",
        "external_reference": "user-uuid-2::avanzado",
        "transaction_amount": 1500.0,
        "preference_id": "pref-xyz",
    }

    with (
        patch("backend.core.database.pool", pool),
        patch("backend.core.config.settings.mercadopago_webhook_secret", SECRET),
        patch("backend.core.config.settings.mercadopago_access_token", "mp-token"),
        patch("httpx.AsyncClient.get", new_callable=AsyncMock, return_value=mp_response),
    ):
        resp = await _post_webhook(async_client, body, sig, shadow=True)

    assert resp.status_code == 200
    assert resp.json()["shadow"] is True
    conn.execute.assert_not_called()


# ── Recibos de pago — vista admin (#4 comprobante) ────────────────────────────

RECEIPT_ROW = {
    "id": uuid.UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
    "receipt_number": "RC-2026-000001",
    "payment_id": "163134506523",
    "plan": "pro",
    "amount": Decimal("69900.00"),
    "created_at": datetime.datetime(2026, 6, 13, 16, 33, 40, tzinfo=datetime.timezone.utc),
    "customer_email": "danielsevilla64@gmail.com",
    "customer_name": "Roberto Daniel Sevilla",
}


async def test_list_receipts_requires_admin(async_client, mock_service_pool):
    """Un usuario no admin (profiles.role != 'admin') recibe 403."""
    pool, conn = mock_service_pool
    conn.fetchval = AsyncMock(return_value="user")
    token = make_token({"role": "user"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/payments/receipts", headers={"Authorization": f"Bearer {token}"}
        )
    assert resp.status_code == 403


async def test_list_receipts_admin_ok(async_client, mock_service_pool):
    """Admin lista pagos aprobados con sus datos de recibo."""
    pool, conn = mock_service_pool
    conn.fetchval = AsyncMock(side_effect=["admin", 1])  # 1=role check, 2=count
    conn.fetch = AsyncMock(return_value=[RECEIPT_ROW])
    token = make_token({"role": "user"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/payments/receipts", headers={"Authorization": f"Bearer {token}"}
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] == 1
    assert body["items"][0]["receipt_number"] == "RC-2026-000001"
    assert body["items"][0]["customer_email"] == "danielsevilla64@gmail.com"


async def test_download_receipt_pdf_admin_ok(async_client, mock_service_pool):
    """Admin descarga el PDF del recibo (application/pdf con bytes válidos)."""
    pool, conn = mock_service_pool
    conn.fetchval = AsyncMock(return_value="admin")
    conn.fetchrow = AsyncMock(return_value=RECEIPT_ROW)
    token = make_token({"role": "user"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            f"/payments/receipt/{RECEIPT_ROW['id']}",
            headers={"Authorization": f"Bearer {token}"},
        )
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "application/pdf"
    assert resp.content.startswith(b"%PDF")


async def test_download_receipt_not_found_returns_404(async_client, mock_service_pool):
    pool, conn = mock_service_pool
    conn.fetchval = AsyncMock(return_value="admin")
    conn.fetchrow = AsyncMock(return_value=None)
    token = make_token({"role": "user"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            f"/payments/receipt/{uuid.uuid4()}",
            headers={"Authorization": f"Bearer {token}"},
        )
    assert resp.status_code == 404


async def test_download_receipt_non_admin_forbidden(async_client, mock_service_pool):
    pool, conn = mock_service_pool
    conn.fetchval = AsyncMock(return_value=None)  # sin perfil admin
    token = make_token({"role": "user"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            f"/payments/receipt/{RECEIPT_ROW['id']}",
            headers={"Authorization": f"Bearer {token}"},
        )
    assert resp.status_code == 403


async def test_resend_receipt_admin_queues_email_with_pdf(async_client, mock_service_pool):
    """Admin reenvía: inserta email_logs 'payment_receipt' con el PDF en base64."""
    pool, conn = mock_service_pool
    conn.fetchval = AsyncMock(return_value="admin")   # require_admin
    conn.fetchrow = AsyncMock(return_value=RECEIPT_ROW)  # get_receipt
    conn.execute = AsyncMock(return_value="INSERT 0 1")
    token = make_token({"role": "user"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            f"/payments/receipts/{RECEIPT_ROW['id']}/resend",
            headers={"Authorization": f"Bearer {token}"},
        )
    assert resp.status_code == 202
    assert resp.json()["ok"] is True
    insert_call = conn.execute.await_args_list[-1]
    assert "email_logs" in str(insert_call.args[0])
    assert "payment_receipt" in str(insert_call.args[0])
    assert "receipt_pdf_base64" in insert_call.args[4]  # metadata json ($4)


async def test_resend_receipt_requires_admin(async_client, mock_service_pool):
    pool, conn = mock_service_pool
    conn.fetchval = AsyncMock(return_value="user")
    token = make_token({"role": "user"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            f"/payments/receipts/{RECEIPT_ROW['id']}/resend",
            headers={"Authorization": f"Bearer {token}"},
        )
    assert resp.status_code == 403
