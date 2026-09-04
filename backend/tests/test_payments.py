from __future__ import annotations

import datetime
import hashlib
import hmac
import json
import logging
import time
import uuid
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from backend.services.payments import derive_signed_notification_id, verify_mp_signature
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


# ── mp-real-subscriptions D9 — derivación de data.id desde el query param ────
#
# MercadoPago firma el manifiesto con el `data.id` tal como viene en el
# **query param** de la URL de notificación, no el del cuerpo. Los IDs de
# `preapproval`/suscripción son alfanuméricos y MercadoPago los normaliza a
# minúsculas antes de firmar. La implementación previa a este fix derivaba el
# id únicamente del cuerpo, sin normalizar — funcionaba solo porque los IDs
# de pago son numéricos (bajar a minúsculas un número no lo altera).

def _signature_for_query_id(query_id_lowercased: str, ts: str | None = None) -> str:
    ts = ts or str(int(time.time()))
    template = f"id:{query_id_lowercased};request-id:{REQUEST_ID};ts:{ts};"
    digest = hmac.new(SECRET.encode(), template.encode(), hashlib.sha256).hexdigest()
    return f"ts={ts},v1={digest}"


def test_verify_signature_query_param_alphanumeric_uppercase_lowercased():
    """RED (3.2): un data.id alfanumérico en MAYÚSCULAS en el query param
    verifica correctamente cuando el manifiesto usa el valor en minúsculas —
    tal como lo firma MercadoPago para IDs de preapproval/suscripción."""
    query_id = "ABC123def456"
    # El cuerpo trae un id distinto a propósito, para probar que la fuente
    # de verdad es el query param, no el cuerpo, cuando ambos están presentes.
    body = _mp_body(notification_id="otro-id-en-el-body", type_="subscription_preapproval")
    sig = _signature_for_query_id(query_id.lower())

    assert verify_mp_signature(
        body, sig, REQUEST_ID, SECRET, query_data_id=query_id
    ) is True


def test_verify_signature_query_param_not_lowercased_fails():
    """RED (3.2, complemento): si el query param NO se pasa a minúsculas, la
    misma notificación se rechaza — prueba que la normalización es
    obligatoria, no cosmética."""
    query_id = "ABC123def456"
    body = _mp_body(notification_id="otro-id-en-el-body", type_="subscription_preapproval")
    sig = _signature_for_query_id(query_id.lower())

    # Manifiesto armado con el id SIN normalizar (bug que este fix corrige)
    bad_sig = _signature_for_query_id(query_id)
    assert bad_sig != sig
    assert verify_mp_signature(
        body, bad_sig, REQUEST_ID, SECRET, query_data_id=query_id
    ) is False


def test_verify_signature_payment_numeric_id_unaffected_non_regression():
    """TRIANGULATE (3.4) — no-regresión: una notificación `payment` con id
    NUMÉRICO sigue verificando exactamente igual que antes del fix, ya sea
    que el id venga del query param o (compatibilidad) solo del cuerpo."""
    body = _mp_body(notification_id="123456789", type_="payment")
    sig = _make_signature("123456789")

    # Camino nuevo: id vía query param (el camino real en producción)
    assert verify_mp_signature(
        body, sig, REQUEST_ID, SECRET, query_data_id="123456789"
    ) is True
    # Camino de compatibilidad: sin query param, cae al cuerpo (mismo resultado)
    assert verify_mp_signature(body, sig, REQUEST_ID, SECRET) is True


def test_verify_signature_falls_back_to_body_when_no_query_param():
    """TRIANGULATE (3.5): sin query param data.id, la derivación cae al
    cuerpo aplicando la misma regla de minúsculas."""
    body = _mp_body(notification_id="ABCdef123", type_="subscription_preapproval")
    sig = _signature_for_query_id("abcdef123")

    assert verify_mp_signature(body, sig, REQUEST_ID, SECRET, query_data_id=None) is True


def test_verify_signature_wrong_signature_rejected_for_subscription_topic():
    """TRIANGULATE (3.6): una firma que no corresponde al manifiesto se
    rechaza para los topics de suscripción igual que para `payment`."""
    query_id = "XYZ987abc654"
    body = _mp_body(notification_id="irrelevante", type_="subscription_authorized_payment")
    forged_sig = _signature_for_query_id("otro-id-cualquiera")

    assert verify_mp_signature(
        body, forged_sig, REQUEST_ID, SECRET, query_data_id=query_id
    ) is False


# ── REFACTOR (3.7) — derive_signed_notification_id como función pura ─────────

def test_derive_notification_id_prefers_query_param_over_body():
    body = _mp_body(notification_id="body-id-ignored")
    assert derive_signed_notification_id(body, "QueryID123") == "queryid123"


def test_derive_notification_id_falls_back_to_body_lowercased():
    body = _mp_body(notification_id="BodyID456")
    assert derive_signed_notification_id(body, None) == "bodyid456"


def test_derive_notification_id_returns_none_when_nothing_available():
    assert derive_signed_notification_id(b"not json", None) is None
    assert derive_signed_notification_id(b'{"type":"payment"}', None) is None


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


# ── v31-mp-upgrade-webhook-fix: equivalencia directo/reenviado + diagnóstico ──
# de secreto (grupo 4, tasks.md). El forwarder de Next.js agrega el header
# `x-relay-source: legacy-frontend` (fuera del template firmado — id +
# request-id + ts — así que no puede romper el HMAC) para que el backend
# distinga origen. Sin ese header, el origen es "direct".


async def test_webhook_relayed_notification_produces_identical_db_state(async_client, mock_service_pool):
    """4.1: misma notificación reenviada (mismos bytes, mismos headers de firma
    + el marcador de origen) produce exactamente el mismo estado de DB que una
    directa (comparar con test_webhook_approved_upgrades_plan)."""
    pool, conn = mock_service_pool
    body = _mp_body("pay-relay-001")
    sig = _make_signature("pay-relay-001")

    member_row = {"account_id": "acc-uuid-relay", "billing_plan": "gratis"}
    event_row = {"id": "be-uuid-relay", "receipt_number": "RC-2026-000200"}
    conn.fetchrow = AsyncMock(side_effect=[None, member_row, event_row])

    mp_response = MagicMock()
    mp_response.status_code = 200
    mp_response.json.return_value = {
        "status": "approved",
        "external_reference": "user-uuid-1::avanzado",
        "transaction_amount": 1500.0,
        "preference_id": "pref-relay",
    }

    with (
        patch("backend.core.database.pool", pool),
        patch("backend.core.config.settings.mercadopago_webhook_secret", SECRET),
        patch("backend.core.config.settings.mercadopago_access_token", "mp-token"),
        patch("backend.services.payments._fetch_user_email", new_callable=AsyncMock, return_value="user@example.com"),
        patch("httpx.AsyncClient.get", new_callable=AsyncMock, return_value=mp_response),
    ):
        resp = await async_client.post(
            "/payments/webhook",
            content=body,
            headers={
                "x-signature": sig,
                "x-request-id": REQUEST_ID,
                "content-type": "application/json",
                "x-relay-source": "legacy-frontend",
            },
        )

    assert resp.status_code == 200
    assert resp.json()["ok"] is True
    executed_queries = [str(c.args[0]) for c in conn.execute.await_args_list]
    fetchrow_queries = [str(c.args[0]) for c in conn.fetchrow.await_args_list]
    assert any("UPDATE accounts" in q for q in executed_queries), "el reenvío no actualizó accounts.billing_plan"
    assert any("INSERT INTO billing_events" in q for q in fetchrow_queries), "el reenvío no insertó billing_events"
    assert any("INSERT INTO email_logs" in q for q in executed_queries), "el reenvío no encoló el email"


async def test_webhook_same_payment_relayed_then_direct_is_idempotent(async_client, mock_service_pool):
    """4.2: el mismo mercadopago_payment_id entregado por las dos vías deja
    UNA sola fila en billing_events; la segunda entrega responde idempotent."""
    pool, conn = mock_service_pool
    body = _mp_body("pay-relay-dup")
    sig = _make_signature("pay-relay-dup")

    # La idempotency check (primer fetchrow) ya encuentra la fila insertada
    # por la primera entrega (sea cual sea el origen de esa primera entrega).
    conn.fetchrow = AsyncMock(return_value={"id": "existing-event-id"})

    with (
        patch("backend.core.database.pool", pool),
        patch("backend.core.config.settings.mercadopago_webhook_secret", SECRET),
    ):
        resp = await async_client.post(
            "/payments/webhook",
            content=body,
            headers={
                "x-signature": sig,
                "x-request-id": REQUEST_ID,
                "content-type": "application/json",
                "x-relay-source": "legacy-frontend",
            },
        )

    assert resp.status_code == 200
    assert resp.json()["ok"] is True
    assert resp.json()["idempotent"] is True
    conn.execute.assert_not_called()


async def test_webhook_missing_secret_rejects_and_logs_configuration_fault(async_client, mock_service_pool, caplog):
    """4.4: MERCADOPAGO_WEBHOOK_SECRET vacía -> rechaza sin tocar la DB y el
    log distingue "falta de configuración" de "firma inválida"."""
    pool, conn = mock_service_pool
    body = _mp_body("pay-nosecret")
    sig = _make_signature("pay-nosecret")  # firmado con SECRET, pero el server no tiene ningún secreto configurado

    with (
        patch("backend.core.database.pool", pool),
        patch("backend.core.config.settings.mercadopago_webhook_secret", ""),
        caplog.at_level(logging.WARNING, logger="backend"),
    ):
        resp = await _post_webhook(async_client, body, sig)

    assert resp.status_code == 400
    conn.fetchrow.assert_not_called()
    conn.execute.assert_not_called()
    logs = caplog.text.lower()
    assert "not configured" in logs or "no configurad" in logs, (
        f"el log de rechazo no distingue falta de configuración: {caplog.text!r}"
    )
    assert "invalid signature" not in logs and "firma inválida" not in logs, (
        "un secreto faltante NO debe logearse como firma inválida (son causas distintas)"
    )


async def test_webhook_invalid_signature_with_secret_present_logs_signature_fault(
    async_client, mock_service_pool, caplog
):
    """4.4 contraste: con secreto configurado, una firma que no matchea se
    loguea como problema de firma, NUNCA como falta de configuración."""
    pool, conn = mock_service_pool
    body = _mp_body("pay-badsig")
    bad_sig = "ts=0,v1=deadbeef"

    with (
        patch("backend.core.database.pool", pool),
        patch("backend.core.config.settings.mercadopago_webhook_secret", SECRET),
        caplog.at_level(logging.WARNING, logger="backend"),
    ):
        resp = await _post_webhook(async_client, body, bad_sig)

    assert resp.status_code == 400
    conn.execute.assert_not_called()
    logs = caplog.text.lower()
    assert "not configured" not in logs and "no configurad" not in logs, (
        f"con secreto presente, el log NO debe decir 'falta de configuración': {caplog.text!r}"
    )


async def test_webhook_rejection_logs_never_leak_secret_or_signature_value(async_client, mock_service_pool, caplog):
    """4.5 TRIANGULATE: ni el secreto configurado ni el valor de la firma
    recibida aparecen en ningún log de rechazo."""
    pool, conn = mock_service_pool
    body = _mp_body("pay-leak-check")
    bad_sig = "ts=0,v1=SHOULD_NOT_LEAK_1234567890abcdef"

    with (
        patch("backend.core.database.pool", pool),
        patch("backend.core.config.settings.mercadopago_webhook_secret", SECRET),
        caplog.at_level(logging.WARNING, logger="backend"),
    ):
        await _post_webhook(async_client, body, bad_sig)

    assert SECRET not in caplog.text
    assert "SHOULD_NOT_LEAK_1234567890abcdef" not in caplog.text


async def test_webhook_direct_notification_traced_as_direct(async_client, mock_service_pool, caplog):
    """4.6: sin el header de relay, el backend traza el origen como directo.

    payment_id deliberadamente sin la subcadena "direct"/"relayed" — evita un
    falso positivo si el id se cuela en el mismo mensaje de log que la traza.
    """
    pool, conn = mock_service_pool
    body = _mp_body("pay-trace-001")
    sig = _make_signature("pay-trace-001")
    conn.fetchrow = AsyncMock(return_value={"id": "existing"})  # camino idempotente, el más simple

    with (
        patch("backend.core.database.pool", pool),
        patch("backend.core.config.settings.mercadopago_webhook_secret", SECRET),
        caplog.at_level(logging.INFO, logger="backend"),
    ):
        resp = await _post_webhook(async_client, body, sig)

    assert resp.status_code == 200
    assert "origin=direct" in caplog.text
    assert "origin=relayed" not in caplog.text


async def test_webhook_relayed_notification_traced_as_relayed(async_client, mock_service_pool, caplog):
    """4.6: con el header x-relay-source, el backend traza el origen como reenviado."""
    pool, conn = mock_service_pool
    body = _mp_body("pay-trace-002")
    sig = _make_signature("pay-trace-002")
    conn.fetchrow = AsyncMock(return_value={"id": "existing"})

    with (
        patch("backend.core.database.pool", pool),
        patch("backend.core.config.settings.mercadopago_webhook_secret", SECRET),
        caplog.at_level(logging.INFO, logger="backend"),
    ):
        resp = await async_client.post(
            "/payments/webhook",
            content=body,
            headers={
                "x-signature": sig,
                "x-request-id": REQUEST_ID,
                "content-type": "application/json",
                "x-relay-source": "legacy-frontend",
            },
        )

    assert resp.status_code == 200
    assert "origin=relayed" in caplog.text
    assert "origin=direct" not in caplog.text


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


# ── v3-api-standards §2.6: envelope estándar {items,total,page,pages} ───────


async def test_list_payment_receipts_envelope(async_client, mock_service_pool):
    pool, conn = mock_service_pool
    conn.fetchval = AsyncMock(return_value="admin")  # require_admin
    conn.fetch = AsyncMock(return_value=[])
    # BillingRepository.list_receipts hace fetchval(count) internamente
    token = make_token({"role": "admin"})

    async def fetchval_side_effect(query, *args):
        if "profiles" in query:
            return "admin"
        return 0  # COUNT(*)

    conn.fetchval = AsyncMock(side_effect=fetchval_side_effect)

    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/payments/receipts",
            headers={"Authorization": f"Bearer {token}"},
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["items"] == []
    assert body["total"] == 0
    assert body["page"] == 0
    assert body["pages"] == 0


async def test_list_payment_receipts_envelope_with_results(async_client, mock_service_pool):
    """TRIANGULATE: con resultados, pages = ceil(total/size)."""
    pool, conn = mock_service_pool
    token = make_token({"role": "admin"})

    async def fetchval_side_effect(query, *args):
        if "profiles" in query:
            return "admin"
        return 120  # COUNT(*)

    conn.fetchval = AsyncMock(side_effect=fetchval_side_effect)
    conn.fetch = AsyncMock(return_value=[])

    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/payments/receipts?page=0&page_size=50",
            headers={"Authorization": f"Bearer {token}"},
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] == 120
    assert body["page"] == 0
    assert body["pages"] == 3


async def test_list_payment_receipts_page_out_of_range_returns_empty_items(async_client, mock_service_pool):
    """2.10: página fuera de rango -> 200 con items vacío, no error."""
    pool, conn = mock_service_pool
    token = make_token({"role": "admin"})

    async def fetchval_side_effect(query, *args):
        if "profiles" in query:
            return "admin"
        return 3

    conn.fetchval = AsyncMock(side_effect=fetchval_side_effect)
    conn.fetch = AsyncMock(return_value=[])

    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/payments/receipts?page=50&page_size=50",
            headers={"Authorization": f"Bearer {token}"},
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["items"] == []
    assert body["total"] == 3
    assert body["page"] == 50


async def test_list_payment_receipts_page_size_over_max_returns_422(async_client, mock_service_pool):
    """2.10: page_size sobre la cota máxima (200) -> 422 problem+json."""
    pool, conn = mock_service_pool
    token = make_token({"role": "admin"})
    conn.fetchval = AsyncMock(return_value="admin")

    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/payments/receipts?page_size=99999",
            headers={"Authorization": f"Bearer {token}"},
        )
    assert resp.status_code == 422
    assert resp.headers["content-type"].startswith("application/problem+json")
    conn.fetch.assert_not_awaited()


# ── fix/service-role-key-env-alias — bug de producción 2026-09-04 ───────────
# Síntoma: "Pasarme a Inicial" en /planes -> 502 "No se pudo resolver el
# email del usuario" (logs de Render: 7x sin el warning
# "[payments] Could not fetch user email for ..." que esta función emite
# cuando la llamada HTTP responde != 200 — es decir, la llamada nunca se
# hizo). Causa raíz: `settings.service_role_key` leía `SERVICE_ROLE_KEY`
# (inexistente en Render) en vez de `SUPABASE_SERVICE_ROLE_KEY` (la real).
# El test de Settings (test_config_service_role_key_alias.py) prueba el
# campo aislado; este prueba el caso CENTRAL: con la variable configurada,
# `_fetch_user_email` debe llegar a hacer la request HTTP — payments.py
# importa el singleton `settings` una sola vez al cargar el módulo, así que
# el fix a nivel Settings no alcanza por sí solo como evidencia end-to-end.
class TestFetchUserEmailServiceRoleKeyAlias:
    async def test_env_var_flows_through_to_http_call_end_to_end(self, monkeypatch):
        """RED (antes del fix): reproduce el bug completo, de punta a punta
        — variable de entorno `SUPABASE_SERVICE_ROLE_KEY` -> `Settings` ->
        singleton `settings` importado por `payments.py` -> `_fetch_user_email`
        hace la llamada HTTP. Antes del fix esto fallaba en silencio
        (`mock_get` nunca invocado, `result is None`) porque el singleton
        leía `SERVICE_ROLE_KEY` (inexistente en Render), no
        `SUPABASE_SERVICE_ROLE_KEY` (la variable real)."""
        from backend.core.config import Settings
        from backend.services import payments as payments_module

        monkeypatch.delenv("SERVICE_ROLE_KEY", raising=False)
        monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "prod-key-e2e")
        monkeypatch.setenv("SUPABASE_URL", "https://proj.supabase.co")

        fresh_settings = Settings(_env_file=None)  # type: ignore[call-arg]
        monkeypatch.setattr(payments_module, "settings", fresh_settings)

        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.json.return_value = {"email": "po@example.com"}

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, return_value=mock_response) as mock_get:
            result = await payments_module._fetch_user_email("some-user-id")

        mock_get.assert_awaited_once()
        assert result == "po@example.com"

    async def test_reaches_http_call_when_service_role_key_configured(self, monkeypatch):
        from backend.services import payments as payments_module

        monkeypatch.setattr(payments_module.settings, "supabase_url", "https://proj.supabase.co")
        monkeypatch.setattr(payments_module.settings, "service_role_key", "real-key")

        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.json.return_value = {"email": "po@example.com"}

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, return_value=mock_response) as mock_get:
            result = await payments_module._fetch_user_email("some-user-id")

        mock_get.assert_awaited_once()
        assert result == "po@example.com"

    async def test_short_circuits_without_http_call_when_service_role_key_empty(self, monkeypatch):
        """TRIANGULATE: sin la key configurada (estado de prod ANTES del
        fix), la función sigue degradando a None sin llamar a la API — el
        comportamiento de fallback no cambia, solo la condición que lo
        dispara pasa a ser la real."""
        from backend.services import payments as payments_module

        monkeypatch.setattr(payments_module.settings, "supabase_url", "https://proj.supabase.co")
        monkeypatch.setattr(payments_module.settings, "service_role_key", "")

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock) as mock_get:
            result = await payments_module._fetch_user_email("some-user-id")

        mock_get.assert_not_awaited()
        assert result is None
