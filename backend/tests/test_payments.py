from __future__ import annotations

import hashlib
import hmac
import json
import time
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from backend.services.payments import verify_mp_signature

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
    conn.fetchrow = AsyncMock(side_effect=[None, member_row])

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
