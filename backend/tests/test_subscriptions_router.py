"""
mp-real-subscriptions — wiring del router (task 6.0/6.4/6.6, palanca
billing_subscriptions_enabled). Mismo patrón que los tests de
/payments/receipts en test_payments.py: async_client + mock_service_pool +
patch de settings. La lógica de negocio ya está testeada en
test_subscriptions_service.py — acá solo se verifica el WIRING (rutas,
gating de la palanca, códigos de status).
"""
from __future__ import annotations

import datetime
import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from backend.schemas.payments import SubscriptionCancelOut, SubscriptionCreateOut
from backend.tests.conftest import make_token

SECRET = "test-webhook-secret"
REQUEST_ID = "req-sub-1"


@pytest.fixture
def mock_service_pool():
    pool = MagicMock()
    conn = AsyncMock()
    pool.acquire.return_value.__aenter__ = AsyncMock(return_value=conn)
    pool.acquire.return_value.__aexit__ = AsyncMock(return_value=False)
    conn.fetchrow = AsyncMock(return_value=None)
    conn.execute = AsyncMock(return_value="OK")
    return pool, conn


# ── task 6.0 — palanca apagada por defecto ────────────────────────────────

class TestFeatureFlagGating:
    async def test_create_subscription_503_when_flag_off(self, async_client, mock_service_pool):
        pool, conn = mock_service_pool
        token = make_token()
        with (
            patch("backend.core.database.pool", pool),
            patch("backend.core.config.settings.billing_subscriptions_enabled", False),
        ):
            resp = await async_client.post(
                "/payments/subscriptions",
                json={"plan": "pro"},
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 503

    async def test_delete_subscription_503_when_flag_off(self, async_client, mock_service_pool):
        pool, conn = mock_service_pool
        token = make_token()
        with (
            patch("backend.core.database.pool", pool),
            patch("backend.core.config.settings.billing_subscriptions_enabled", False),
        ):
            resp = await async_client.delete(
                "/payments/subscriptions",
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 503


# ── task 6.4 — alta ─────────────────────────────────────────────────────

class TestCreateSubscriptionEndpoint:
    async def test_create_subscription_ok_when_flag_on(self, async_client, mock_service_pool):
        pool, conn = mock_service_pool
        token = make_token()
        fake_result = SubscriptionCreateOut(
            init_point="https://www.mercadopago.com.ar/subscriptions/checkout?preapproval_plan_id=plan-1",
            intent_id="cccccccc-cccc-cccc-cccc-cccccccccccc",
            plan="pro",
            expires_at=datetime.datetime(2026, 8, 2, tzinfo=datetime.timezone.utc),
        )
        with (
            patch("backend.core.database.pool", pool),
            patch("backend.core.config.settings.billing_subscriptions_enabled", True),
            patch(
                "backend.routers.payments.create_subscription_intent",
                new_callable=AsyncMock, return_value=fake_result,
            ),
        ):
            resp = await async_client.post(
                "/payments/subscriptions",
                json={"plan": "pro"},
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 200
        assert resp.json()["plan"] == "pro"
        assert "plan-1" in resp.json()["init_point"]


# ── task 6.6 — baja ─────────────────────────────────────────────────────

class TestDeleteSubscriptionEndpoint:
    async def test_delete_subscription_ok_when_flag_on(self, async_client, mock_service_pool):
        pool, conn = mock_service_pool
        token = make_token()
        fake_result = SubscriptionCancelOut(
            ok=True, plan_expires_at=datetime.datetime(2026, 9, 1, tzinfo=datetime.timezone.utc)
        )
        with (
            patch("backend.core.database.pool", pool),
            patch("backend.core.config.settings.billing_subscriptions_enabled", True),
            patch(
                "backend.routers.payments.cancel_subscription",
                new_callable=AsyncMock, return_value=fake_result,
            ),
        ):
            resp = await async_client.delete(
                "/payments/subscriptions",
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 200
        assert resp.json()["ok"] is True


# ── webhook dispatch — subscription_* topics ─────────────────────────────

def _sub_notification_body(notif_type: str, data_id: str) -> bytes:
    return json.dumps({"type": notif_type, "data": {"id": data_id}}).encode()


def _sig_for(data_id: str, request_id: str = REQUEST_ID) -> str:
    import hashlib
    import hmac
    import time

    ts = str(int(time.time()))
    template = f"id:{data_id};request-id:{request_id};ts:{ts};"
    digest = hmac.new(SECRET.encode(), template.encode(), hashlib.sha256).hexdigest()
    return f"ts={ts},v1={digest}"


class TestWebhookSubscriptionDispatch:
    async def test_subscription_preapproval_skipped_when_flag_off(self, async_client, mock_service_pool):
        """TRIANGULATE (6.11): con la palanca apagada, el topic de
        suscripción se trata como no manejado — sin escrituras."""
        pool, conn = mock_service_pool
        data_id = "MPPreapprovalABC"
        sig = _sig_for(data_id.lower())
        with (
            patch("backend.core.database.pool", pool),
            patch("backend.core.config.settings.mercadopago_webhook_secret", SECRET),
            patch("backend.core.config.settings.billing_subscriptions_enabled", False),
            patch(
                "backend.routers.payments.process_subscription_preapproval_notification",
                new_callable=AsyncMock,
            ) as mock_process,
        ):
            resp = await async_client.post(
                f"/payments/webhook?data.id={data_id}",
                content=_sub_notification_body("subscription_preapproval", data_id),
                headers={
                    "x-signature": sig, "x-request-id": REQUEST_ID, "content-type": "application/json",
                },
            )
        assert resp.status_code == 200
        assert resp.json()["skipped"] is True
        mock_process.assert_not_awaited()

    async def test_subscription_preapproval_dispatched_when_flag_on(self, async_client, mock_service_pool):
        """RED (6.8): con la palanca encendida, el topic
        subscription_preapproval se procesa de verdad."""
        pool, conn = mock_service_pool
        data_id = "MPPreapprovalABC"
        sig = _sig_for(data_id.lower())
        with (
            patch("backend.core.database.pool", pool),
            patch("backend.core.config.settings.mercadopago_webhook_secret", SECRET),
            patch("backend.core.config.settings.billing_subscriptions_enabled", True),
            patch(
                "backend.routers.payments.process_subscription_preapproval_notification",
                new_callable=AsyncMock, return_value={"ok": True, "matched": True},
            ) as mock_process,
        ):
            resp = await async_client.post(
                f"/payments/webhook?data.id={data_id}",
                content=_sub_notification_body("subscription_preapproval", data_id),
                headers={
                    "x-signature": sig, "x-request-id": REQUEST_ID, "content-type": "application/json",
                },
            )
        assert resp.status_code == 200
        assert resp.json()["ok"] is True
        mock_process.assert_awaited_once()
        # El id pasado al SERVICIO (para llamar a la API real de MP) viene
        # del query param con su case ORIGINAL — la normalización a
        # minúsculas de D9 es SOLO para el manifiesto de la firma HMAC, un
        # ID real de MP es case-sensitive y lowercasearlo acá rompería el
        # GET /preapproval/{id} contra la API real (404 por case mismatch).
        assert mock_process.call_args.args[0] == data_id

    async def test_subscription_authorized_payment_dispatched_when_flag_on(self, async_client, mock_service_pool):
        pool, conn = mock_service_pool
        data_id = "MPAuthPayment999"
        sig = _sig_for(data_id.lower())
        with (
            patch("backend.core.database.pool", pool),
            patch("backend.core.config.settings.mercadopago_webhook_secret", SECRET),
            patch("backend.core.config.settings.billing_subscriptions_enabled", True),
            patch(
                "backend.routers.payments.process_subscription_authorized_payment_notification",
                new_callable=AsyncMock, return_value={"ok": True, "credited": True},
            ) as mock_process,
        ):
            resp = await async_client.post(
                f"/payments/webhook?data.id={data_id}",
                content=_sub_notification_body("subscription_authorized_payment", data_id),
                headers={
                    "x-signature": sig, "x-request-id": REQUEST_ID, "content-type": "application/json",
                },
            )
        assert resp.status_code == 200
        assert resp.json()["ok"] is True
        mock_process.assert_awaited_once()

    async def test_subscription_id_case_preserved_even_when_body_id_differs(self, async_client, mock_service_pool):
        """TRIANGULATE — regresión atrapada durante el desarrollo de este
        PR: el id pasado al servicio debe ser el del QUERY PARAM con su case
        ORIGINAL, nunca la versión lowercased usada para el manifiesto de
        firma, y nunca el del body si el query param está presente (D9: el
        query param es la fuente de verdad)."""
        pool, conn = mock_service_pool
        query_id = "MiXeDCaseID789"
        body_id = "otro-id-distinto-en-el-body"
        sig = _sig_for(query_id.lower())
        with (
            patch("backend.core.database.pool", pool),
            patch("backend.core.config.settings.mercadopago_webhook_secret", SECRET),
            patch("backend.core.config.settings.billing_subscriptions_enabled", True),
            patch(
                "backend.routers.payments.process_subscription_preapproval_notification",
                new_callable=AsyncMock, return_value={"ok": True},
            ) as mock_process,
        ):
            resp = await async_client.post(
                f"/payments/webhook?data.id={query_id}",
                content=_sub_notification_body("subscription_preapproval", body_id),
                headers={
                    "x-signature": sig, "x-request-id": REQUEST_ID, "content-type": "application/json",
                },
            )
        assert resp.status_code == 200
        mock_process.assert_awaited_once_with(query_id, mock_process.call_args.args[1], mock_process.call_args.args[2])

    async def test_payment_topic_still_works_non_regression(self, async_client, mock_service_pool):
        """TRIANGULATE — no-regresión: el topic `payment` (el único que
        existía antes de este change) sigue andando exactamente igual."""
        pool, conn = mock_service_pool
        conn.fetchrow = AsyncMock(return_value={"id": "be-1"})  # idempotency hit
        data_id = "163134506523"
        sig = _sig_for(data_id)
        with (
            patch("backend.core.database.pool", pool),
            patch("backend.core.config.settings.mercadopago_webhook_secret", SECRET),
        ):
            resp = await async_client.post(
                f"/payments/webhook?data.id={data_id}",
                content=_sub_notification_body("payment", data_id),
                headers={
                    "x-signature": sig, "x-request-id": REQUEST_ID, "content-type": "application/json",
                },
            )
        assert resp.status_code == 200
        assert resp.json()["idempotent"] is True


# ── task 6.8bis — cola de ambiguos, admin-only ───────────────────────────

class TestAmbiguousQueueEndpoints:
    async def test_list_ambiguous_requires_admin(self, async_client, mock_service_pool):
        pool, conn = mock_service_pool
        conn.fetchval = AsyncMock(return_value="user")  # no admin
        token = make_token({"role": "user"})
        with (
            patch("backend.core.database.pool", pool),
            patch("backend.core.config.settings.billing_subscriptions_enabled", True),
        ):
            resp = await async_client.get(
                "/payments/subscriptions/ambiguous",
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 403

    async def test_resolve_ambiguous_requires_admin(self, async_client, mock_service_pool):
        pool, conn = mock_service_pool
        conn.fetchval = AsyncMock(return_value="user")
        token = make_token({"role": "user"})
        with (
            patch("backend.core.database.pool", pool),
            patch("backend.core.config.settings.billing_subscriptions_enabled", True),
        ):
            resp = await async_client.post(
                "/payments/subscriptions/ambiguous/cccccccc-cccc-cccc-cccc-cccccccccccc/resolve",
                json={"account_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"},
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 403

    async def test_resolve_ambiguous_admin_ok(self, async_client, mock_service_pool):
        pool, conn = mock_service_pool
        conn.fetchval = AsyncMock(return_value="admin")
        token = make_token({"role": "user"})
        with (
            patch("backend.core.database.pool", pool),
            patch("backend.core.config.settings.billing_subscriptions_enabled", True),
            patch(
                "backend.routers.payments.resolve_ambiguous_subscription",
                new_callable=AsyncMock, return_value={"ok": True},
            ),
        ):
            resp = await async_client.post(
                "/payments/subscriptions/ambiguous/cccccccc-cccc-cccc-cccc-cccccccccccc/resolve",
                json={"account_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"},
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 200
        assert resp.json()["ok"] is True


# ── task 8.8 — GET /payments/accounts/search (selector de la cola) ───────

class TestAccountSearchEndpoint:
    async def test_requires_admin(self, async_client, mock_service_pool):
        pool, conn = mock_service_pool
        conn.fetchval = AsyncMock(return_value="user")
        token = make_token({"role": "user"})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/payments/accounts/search?q=buyer",
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 403

    async def test_admin_ok_returns_matches(self, async_client, mock_service_pool):
        pool, conn = mock_service_pool
        conn.fetchval = AsyncMock(return_value="admin")
        conn.fetch = AsyncMock(
            return_value=[
                {
                    "account_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                    "owner_email": "buyer@example.com",
                    "owner_name": "Buyer Test",
                    "billing_plan": "pro",
                }
            ]
        )
        token = make_token({"role": "user"})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/payments/accounts/search?q=buyer",
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 200
        body = resp.json()
        assert len(body) == 1
        assert body[0]["owner_email"] == "buyer@example.com"
        assert body[0]["billing_plan"] == "pro"

    async def test_empty_query_returns_422(self, async_client, mock_service_pool):
        """TRIANGULATE: min_length=2 rechaza un query vacío/muy corto antes
        de tocar la DB — evita un ILIKE `%%` sin filtro real."""
        pool, conn = mock_service_pool
        conn.fetchval = AsyncMock(return_value="admin")
        token = make_token({"role": "user"})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/payments/accounts/search?q=a",
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 422

    async def test_no_matches_returns_empty_list(self, async_client, mock_service_pool):
        pool, conn = mock_service_pool
        conn.fetchval = AsyncMock(return_value="admin")
        conn.fetch = AsyncMock(return_value=[])
        token = make_token({"role": "user"})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/payments/accounts/search?q=nadie-tiene-este-email",
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 200
        assert resp.json() == []


# ── task 8.5 — GET /payments/subscriptions/status ────────────────────────

class TestSubscriptionStatusEndpoint:
    async def test_503_when_flag_off(self, async_client, mock_service_pool):
        pool, conn = mock_service_pool
        token = make_token()
        with (
            patch("backend.core.database.pool", pool),
            patch("backend.core.config.settings.billing_subscriptions_enabled", False),
        ):
            resp = await async_client.get(
                "/payments/subscriptions/status",
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 503

    async def test_404_when_no_live_subscription(self, async_client, mock_service_pool):
        pool, conn = mock_service_pool
        conn.fetchrow = AsyncMock(return_value=None)
        token = make_token()
        with (
            patch("backend.core.database.pool", pool),
            patch("backend.core.config.settings.billing_subscriptions_enabled", True),
        ):
            resp = await async_client.get(
                "/payments/subscriptions/status",
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 404

    async def test_200_with_live_subscription(self, async_client, mock_service_pool):
        pool, conn = mock_service_pool
        conn.fetchrow = AsyncMock(
            return_value={
                "id": "dddddddd-dddd-dddd-dddd-dddddddddddd",
                "account_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                "preapproval_id": "mp-preapproval-1",
                "preapproval_plan_id": "mp-plan-1",
                "plan": "avanzado",
                "status": "authorized",
                "next_payment_date": datetime.datetime(2026, 9, 1, tzinfo=datetime.timezone.utc),
                "amount": None,
                "currency": "ARS",
                "retry_state": "none",
                "created_at": datetime.datetime(2026, 8, 1, tzinfo=datetime.timezone.utc),
            }
        )
        token = make_token()
        with (
            patch("backend.core.database.pool", pool),
            patch("backend.core.config.settings.billing_subscriptions_enabled", True),
        ):
            resp = await async_client.get(
                "/payments/subscriptions/status",
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 200
        body = resp.json()
        assert body["plan"] == "avanzado"
        assert body["status"] == "authorized"
        assert body["retry_state"] == "none"
