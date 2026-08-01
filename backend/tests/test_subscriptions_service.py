"""
mp-real-subscriptions — servicio de suscripciones (tasks 6.3-6.13). TDD:
RED (comportamiento esperado, mockeado) → GREEN → TRIANGULATE, mismo patrón
de mocking de httpx.AsyncClient que test_payments.py (process_payment).
"""
from __future__ import annotations

import datetime
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi import HTTPException

from backend.services.subscriptions import (
    GRACE_PERIOD,
    cancel_subscription,
    create_subscription_intent,
    process_subscription_authorized_payment_notification,
    process_subscription_preapproval_notification,
    resolve_ambiguous_subscription,
)

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
USER_ID = "uuuuuuuu-uuuu-uuuu-uuuu-uuuuuuuuuuuu"
INTENT_ID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
SUBSCRIPTION_ID = "dddddddd-dddd-dddd-dddd-dddddddddddd"
PREAPPROVAL_ID = "mp-preapproval-XYZ"
PLAN_ID = "mp-plan-abc"


def _mock_repo(**overrides):
    repo = AsyncMock()
    repo.find_live_subscription = AsyncMock(return_value=None)
    repo.create_intent = AsyncMock(
        return_value={
            "id": INTENT_ID,
            "account_id": ACCOUNT_ID,
            "plan": "pro",
            "expires_at": datetime.datetime(2026, 8, 2, tzinfo=datetime.timezone.utc),
        }
    )
    repo.find_pending_intents = AsyncMock(return_value=[])
    repo.find_by_preapproval_id = AsyncMock(return_value=None)
    repo.create_subscription = AsyncMock(return_value={"id": SUBSCRIPTION_ID})
    repo.mark_intent_matched = AsyncMock(return_value=True)
    repo.update_subscription_status = AsyncMock(return_value=True)
    for k, v in overrides.items():
        setattr(repo, k, v)
    return repo


def _mock_conn():
    conn = AsyncMock()
    conn.execute = AsyncMock(return_value="INSERT 0 1")
    conn.fetchrow = AsyncMock(return_value=None)
    return conn


# ── 6.3 RED / 6.4 GREEN — create_subscription_intent ────────────────────────

class TestCreateSubscriptionIntent:
    @pytest.mark.asyncio
    async def test_rejects_invalid_plan(self):
        repo = _mock_repo()
        with pytest.raises(HTTPException) as exc:
            await create_subscription_intent(ACCOUNT_ID, USER_ID, "no-existe", repo)
        assert exc.value.status_code == 400

    @pytest.mark.asyncio
    async def test_rejects_tier_without_configured_plan_id(self):
        repo = _mock_repo()
        with patch("backend.services.subscriptions.settings.mp_plan_id_pro", ""):
            with pytest.raises(HTTPException) as exc:
                await create_subscription_intent(ACCOUNT_ID, USER_ID, "pro", repo)
        assert exc.value.status_code == 400

    @pytest.mark.asyncio
    async def test_rejects_when_live_subscription_exists(self):
        repo = _mock_repo(find_live_subscription=AsyncMock(return_value={"id": SUBSCRIPTION_ID}))
        with patch("backend.services.subscriptions.settings.mp_plan_id_pro", PLAN_ID):
            with pytest.raises(HTTPException) as exc:
                await create_subscription_intent(ACCOUNT_ID, USER_ID, "pro", repo)
        assert exc.value.status_code == 409

    @pytest.mark.asyncio
    async def test_persists_intent_before_returning_init_point(self):
        """RED (6.3): la intención se persiste ANTES de devolver la URL."""
        repo = _mock_repo()
        with (
            patch("backend.services.subscriptions.settings.mp_plan_id_pro", PLAN_ID),
            patch(
                "backend.services.subscriptions._fetch_user_email",
                new_callable=AsyncMock, return_value="buyer@example.com",
            ),
        ):
            result = await create_subscription_intent(ACCOUNT_ID, USER_ID, "pro", repo)

        repo.create_intent.assert_awaited_once()
        assert PLAN_ID in result.init_point
        assert str(result.intent_id) == INTENT_ID

    @pytest.mark.asyncio
    async def test_rejects_when_payer_email_cannot_be_resolved(self):
        repo = _mock_repo()
        with (
            patch("backend.services.subscriptions.settings.mp_plan_id_pro", PLAN_ID),
            patch(
                "backend.services.subscriptions._fetch_user_email",
                new_callable=AsyncMock, return_value=None,
            ),
        ):
            with pytest.raises(HTTPException) as exc:
                await create_subscription_intent(ACCOUNT_ID, USER_ID, "pro", repo)
        assert exc.value.status_code == 502
        repo.create_intent.assert_not_awaited()


# ── 6.5 RED / 6.6 GREEN — cancel_subscription ────────────────────────────

class TestCancelSubscription:
    @pytest.mark.asyncio
    async def test_rejects_when_no_live_subscription(self):
        repo = _mock_repo(find_live_subscription=AsyncMock(return_value=None))
        conn = _mock_conn()
        with pytest.raises(HTTPException) as exc:
            await cancel_subscription(ACCOUNT_ID, repo, conn)
        assert exc.value.status_code == 404

    @pytest.mark.asyncio
    async def test_does_not_touch_local_state_when_mp_cancel_fails(self):
        """RED (6.5): si la cancelación en MP falla, no queda estado local
        inconsistente — ni el repo ni la cuenta se tocan."""
        repo = _mock_repo(
            find_live_subscription=AsyncMock(
                return_value={"preapproval_id": PREAPPROVAL_ID, "next_payment_date": None}
            )
        )
        conn = _mock_conn()
        mp_response = MagicMock()
        mp_response.status_code = 500

        with patch("httpx.AsyncClient.put", new_callable=AsyncMock, return_value=mp_response):
            with pytest.raises(HTTPException) as exc:
                await cancel_subscription(ACCOUNT_ID, repo, conn)

        assert exc.value.status_code == 502
        repo.update_subscription_status.assert_not_awaited()
        conn.execute.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_sets_plan_expires_at_to_paid_period_end(self):
        """GREEN: plan_expires_at = next_payment_date del período YA pagado
        (sin gracia extra — la baja es voluntaria, no un impago)."""
        paid_until = datetime.datetime(2026, 9, 1, tzinfo=datetime.timezone.utc)
        repo = _mock_repo(
            find_live_subscription=AsyncMock(
                return_value={"preapproval_id": PREAPPROVAL_ID, "next_payment_date": paid_until}
            )
        )
        conn = _mock_conn()
        mp_response = MagicMock()
        mp_response.status_code = 200

        with patch("httpx.AsyncClient.put", new_callable=AsyncMock, return_value=mp_response):
            result = await cancel_subscription(ACCOUNT_ID, repo, conn)

        assert result.plan_expires_at == paid_until
        repo.update_subscription_status.assert_awaited_once_with(PREAPPROVAL_ID, "cancelled")


# ── 6.7 RED / 6.8 GREEN — subscription_preapproval ──────────────────────

class TestProcessSubscriptionPreapproval:
    def _mp_get_response(self, status="authorized", payer_email="buyer@example.com"):
        resp = MagicMock()
        resp.status_code = 200
        resp.json.return_value = {
            "status": status,
            "payer_email": payer_email,
            "preapproval_plan_id": PLAN_ID,
        }
        return resp

    @pytest.mark.asyncio
    async def test_redelivery_of_same_notification_is_idempotent(self):
        """TRIANGULATE (6.11-adjacent / D5): redelivery = no-op."""
        repo = _mock_repo()
        conn = _mock_conn()
        conn.execute = AsyncMock(return_value="INSERT 0 0")  # ya reclamado

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, return_value=self._mp_get_response()):
            result = await process_subscription_preapproval_notification(PREAPPROVAL_ID, repo, conn)

        assert result == {"ok": True, "idempotent": True}
        repo.find_by_preapproval_id.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_single_match_activates_plan_and_marks_intent_matched(self):
        """RED (6.7): exactamente 1 candidata → activa el plan de la cuenta
        y marca la intención matched."""
        repo = _mock_repo(
            find_pending_intents=AsyncMock(
                return_value=[{"id": INTENT_ID, "account_id": ACCOUNT_ID, "plan": "pro"}]
            )
        )
        conn = _mock_conn()

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, return_value=self._mp_get_response()):
            result = await process_subscription_preapproval_notification(PREAPPROVAL_ID, repo, conn)

        assert result == {"ok": True, "matched": True}
        repo.create_subscription.assert_awaited_once()
        repo.mark_intent_matched.assert_awaited_once_with(INTENT_ID, SUBSCRIPTION_ID)
        # activó el plan de la cuenta
        update_call = conn.execute.call_args_list[-1]
        assert "billing_plan = $2" in update_call.args[0]
        assert update_call.args[1:] == (ACCOUNT_ID, "pro")

    @pytest.mark.asyncio
    async def test_zero_matches_creates_ambiguous_no_match(self):
        """RED (6.7/D2bis): 0 candidatas → subscriptions.account_id=NULL,
        status='ambiguous', motivo no_match. El dinero no se pierde."""
        repo = _mock_repo(find_pending_intents=AsyncMock(return_value=[]))
        conn = _mock_conn()

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, return_value=self._mp_get_response()):
            result = await process_subscription_preapproval_notification(PREAPPROVAL_ID, repo, conn)

        assert result == {"ok": True, "ambiguous": "no_match"}
        kwargs = repo.create_subscription.call_args.kwargs
        assert kwargs["account_id"] is None
        assert kwargs["status"] == "ambiguous"
        assert kwargs["ambiguous_reason"] == "no_match"

    @pytest.mark.asyncio
    async def test_multiple_matches_creates_ambiguous_multiple_match(self):
        """TRIANGULATE: >1 candidatas → ambiguous, motivo multiple_match,
        sin adivinar cuál es la correcta."""
        repo = _mock_repo(
            find_pending_intents=AsyncMock(
                return_value=[
                    {"id": "i1", "account_id": "acc-1", "plan": "pro"},
                    {"id": "i2", "account_id": "acc-2", "plan": "pro"},
                ]
            )
        )
        conn = _mock_conn()

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, return_value=self._mp_get_response()):
            result = await process_subscription_preapproval_notification(PREAPPROVAL_ID, repo, conn)

        assert result == {"ok": True, "ambiguous": "multiple_match"}
        kwargs = repo.create_subscription.call_args.kwargs
        assert kwargs["ambiguous_reason"] == "multiple_match"

    @pytest.mark.asyncio
    async def test_cancellation_of_known_subscription_triggers_downgrade_wiring(self):
        """D8: cancelación de un preapproval YA vinculado a una cuenta
        programa la degradación (billing_status='cancelling') — reutiliza
        process_cancellations() en el barrido diario, no un segundo camino."""
        repo = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={
                    "account_id": ACCOUNT_ID, "status": "authorized",
                    "next_payment_date": datetime.datetime(2026, 9, 1, tzinfo=datetime.timezone.utc),
                }
            )
        )
        conn = _mock_conn()

        with patch(
            "httpx.AsyncClient.get", new_callable=AsyncMock,
            return_value=self._mp_get_response(status="cancelled"),
        ):
            result = await process_subscription_preapproval_notification(PREAPPROVAL_ID, repo, conn)

        assert result == {"ok": True}
        sqls = [c.args[0] for c in conn.execute.call_args_list]
        assert any("billing_status = 'cancelling'" in s for s in sqls)

    @pytest.mark.asyncio
    async def test_unknown_preapproval_from_mp_is_not_fatal(self):
        """TRIANGULATE (6.7): un preapproval que MP dice no encontrar (404)
        no rompe el webhook."""
        repo = _mock_repo()
        conn = _mock_conn()
        resp_404 = MagicMock()
        resp_404.status_code = 404

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, return_value=resp_404):
            result = await process_subscription_preapproval_notification(PREAPPROVAL_ID, repo, conn)

        assert result == {"ok": True, "skipped": True}


# ── 6.9 RED / 6.10 GREEN — subscription_authorized_payment ──────────────

class TestProcessAuthorizedPayment:
    def _mp_get_response(self, cuota_status="processed", payment_status="approved", **extra):
        resp = MagicMock()
        resp.status_code = 200
        body = {
            "status": cuota_status,
            "preapproval_id": PREAPPROVAL_ID,
            "payment": {"id": "mp-payment-1", "status": payment_status},
            "retry_attempt": extra.get("retry_attempt", 0),
            "next_retry_date": extra.get("next_retry_date"),
            "debit_date": extra.get("debit_date", "2026-09-01T00:00:00Z"),
            "transaction_amount": extra.get("transaction_amount", 34900),
        }
        resp.json.return_value = body
        return resp

    @pytest.mark.asyncio
    async def test_approved_payment_extends_plan_expires_at_with_grace(self):
        """RED (6.9): cobro aprobado extiende plan_expires_at a
        next_payment_date + 10 días de gracia (OQ2) y audita en
        billing_events."""
        repo = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={"account_id": ACCOUNT_ID, "plan": "avanzado", "status": "authorized"}
            )
        )
        conn = _mock_conn()

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, return_value=self._mp_get_response()):
            result = await process_subscription_authorized_payment_notification("ap-1", repo, conn)

        assert result == {"ok": True, "credited": True}
        repo.update_subscription_status.assert_awaited_once()
        args, kwargs = repo.update_subscription_status.call_args
        assert kwargs["retry_state"] == "none"
        assert kwargs["last_payment_status"] == "approved"

        sqls = [c.args[0] for c in conn.execute.call_args_list]
        assert any("plan_expires_at = $2" in s for s in sqls)
        assert any("subscription_payment_approved" in s for s in sqls)

        expected_expiry = datetime.datetime(2026, 9, 1, tzinfo=datetime.timezone.utc) + GRACE_PERIOD
        update_call = next(c for c in conn.execute.call_args_list if "plan_expires_at = $2" in c.args[0])
        assert update_call.args[2] == expected_expiry

    @pytest.mark.asyncio
    async def test_redelivery_of_same_payment_is_idempotent_no_op(self):
        """RED (6.9): redelivery de la misma notificación es no-op."""
        repo = _mock_repo()
        conn = _mock_conn()
        conn.execute = AsyncMock(return_value="INSERT 0 0")

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, return_value=self._mp_get_response()):
            result = await process_subscription_authorized_payment_notification("ap-1", repo, conn)

        assert result == {"ok": True, "idempotent": True}
        repo.find_by_preapproval_id.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_rejected_payment_does_not_touch_plan_or_expiry(self):
        """RED (6.9): cobro rechazado emite el aviso y NO cambia plan ni
        vencimiento."""
        repo = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={"account_id": ACCOUNT_ID, "plan": "avanzado", "status": "authorized"}
            )
        )
        conn = _mock_conn()

        with patch(
            "httpx.AsyncClient.get", new_callable=AsyncMock,
            return_value=self._mp_get_response(payment_status="rejected"),
        ):
            result = await process_subscription_authorized_payment_notification("ap-1", repo, conn)

        assert result == {"ok": True, "payment_failed": True}
        sqls = [c.args[0] for c in conn.execute.call_args_list]
        assert not any("plan_expires_at = $2" in s for s in sqls)
        assert not any("billing_plan" in s for s in sqls)
        assert any("SubscriptionPaymentFailed" in s for s in sqls)

    @pytest.mark.asyncio
    async def test_rejected_payment_email_has_discriminator_in_metadata(self):
        """RED (7.1/D10): el correo de cobro fallido lleva el
        authorized_payment_id como discriminador en metadata — sin esto, un
        2do cobro fallido del mismo mes se traga en silencio por el
        UNIQUE NULLS NOT DISTINCT(user_id, event_type, metadata)."""
        repo = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={"account_id": ACCOUNT_ID, "plan": "avanzado", "status": "authorized"}
            )
        )
        conn = _mock_conn()

        with patch(
            "httpx.AsyncClient.get", new_callable=AsyncMock,
            return_value=self._mp_get_response(payment_status="rejected"),
        ):
            await process_subscription_authorized_payment_notification("ap-first-failure", repo, conn)

        email_call = next(
            c for c in conn.execute.call_args_list if "email_logs" in c.args[0]
        )
        assert "ap-first-failure" in email_call.args

    @pytest.mark.asyncio
    async def test_two_distinct_failures_produce_distinct_discriminators(self):
        """TRIANGULATE (D10): dos cobros fallidos DISTINTOS generan
        discriminadores DISTINTOS en metadata (authorized_payment_id
        difiere) — la garantía de que el 2do aviso no se pierde."""
        repo = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={"account_id": ACCOUNT_ID, "plan": "avanzado", "status": "authorized"}
            )
        )
        conn1, conn2 = _mock_conn(), _mock_conn()

        with patch(
            "httpx.AsyncClient.get", new_callable=AsyncMock,
            return_value=self._mp_get_response(payment_status="rejected"),
        ):
            await process_subscription_authorized_payment_notification("ap-failure-1", repo, conn1)
            await process_subscription_authorized_payment_notification("ap-failure-2", repo, conn2)

        email_call_1 = next(c for c in conn1.execute.call_args_list if "email_logs" in c.args[0])
        email_call_2 = next(c for c in conn2.execute.call_args_list if "email_logs" in c.args[0])
        assert "ap-failure-1" in email_call_1.args
        assert "ap-failure-2" in email_call_2.args
        assert email_call_1.args != email_call_2.args

    @pytest.mark.asyncio
    async def test_scheduled_cuota_is_a_no_op(self):
        """TRIANGULATE (6.11-adjacent): una cuota todavía scheduled (no
        resuelta) no escribe nada."""
        repo = _mock_repo()
        conn = _mock_conn()

        with patch(
            "httpx.AsyncClient.get", new_callable=AsyncMock,
            return_value=self._mp_get_response(cuota_status="scheduled"),
        ):
            result = await process_subscription_authorized_payment_notification("ap-1", repo, conn)

        assert result == {"ok": True, "scheduled": True}
        repo.find_by_preapproval_id.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_unknown_preapproval_is_not_fatal_authorized_payment(self):
        """TRIANGULATE: un authorized_payment de un preapproval que no
        tenemos registrado no es fatal."""
        repo = _mock_repo(find_by_preapproval_id=AsyncMock(return_value=None))
        conn = _mock_conn()

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, return_value=self._mp_get_response()):
            result = await process_subscription_authorized_payment_notification("ap-1", repo, conn)

        assert result == {"ok": True, "unknown_subscription": True}


# ── 6.8bis — resolve_ambiguous_subscription (cola de conciliación manual) ──

class TestResolveAmbiguousSubscription:
    @pytest.mark.asyncio
    async def test_404_when_nothing_to_resolve(self):
        repo = _mock_repo(resolve_ambiguous_subscription=AsyncMock(return_value=None))
        conn = _mock_conn()

        with pytest.raises(HTTPException) as exc:
            await resolve_ambiguous_subscription(SUBSCRIPTION_ID, ACCOUNT_ID, repo, conn)
        assert exc.value.status_code == 404

    @pytest.mark.asyncio
    async def test_activates_plan_and_audits_billing_event(self):
        """GREEN: al resolver, activa el plan de la cuenta recién asignada
        y audita en billing_events (distinguible de un match automático)."""
        repo = _mock_repo(
            resolve_ambiguous_subscription=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "account_id": ACCOUNT_ID,
                    "preapproval_id": PREAPPROVAL_ID, "plan": "avanzado", "status": "authorized",
                }
            )
        )
        conn = _mock_conn()

        result = await resolve_ambiguous_subscription(SUBSCRIPTION_ID, ACCOUNT_ID, repo, conn)

        assert result == {"ok": True}
        sqls = [c.args[0] for c in conn.execute.call_args_list]
        assert any("billing_plan = $2" in s for s in sqls)
        assert any("subscription_ambiguous_resolved" in s for s in sqls)
