"""
mp-real-subscriptions — servicio de suscripciones (tasks 6.3-6.13). TDD:
RED (comportamiento esperado, mockeado) → GREEN → TRIANGULATE, mismo patrón
de mocking de httpx.AsyncClient que test_payments.py (process_payment).
"""
from __future__ import annotations

import datetime
import re
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi import HTTPException

from backend.services.subscriptions import (
    GRACE_PERIOD,
    _claim_subscription_webhook_idempotency,
    _tier_for_plan_id,
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
    repo.find_ambiguous_subscription = AsyncMock(return_value=None)
    repo.correct_subscription_plan = AsyncMock(return_value=True)
    for k, v in overrides.items():
        setattr(repo, k, v)
    return repo


def _mock_conn():
    conn = AsyncMock()
    conn.execute = AsyncMock(return_value="INSERT 0 1")
    conn.fetchrow = AsyncMock(return_value=None)
    return conn


# ── HOTFIX subscription-webhook-idempotency-contract (2026-09-04) ───────────
# _claim_subscription_webhook_idempotency: la sentencia que moria con 23514
# (-> 422) antes de 20261027000001 porque insertaba sin operation_id y el
# CHECK operation_idempotency_operation_id_contract solo eximia a
# 'event_consumer'. Este mock no puede reproducir el CHECK real de Postgres
# (esa garantia es supabase/tests/test_subscription_webhook_idempotency.sql,
# corrido contra una DB real) - lo que si fija aca es el CONTRATO del lado
# Python: la sentencia se ejecuta, con que forma, y que hace con el resultado.

class TestClaimSubscriptionWebhookIdempotency:
    @pytest.mark.asyncio
    async def test_claim_inserts_without_operation_id_for_operation_kind_subscription_webhook(self):
        """La forma exacta que depende de la exencion de la migracion: sin
        operation_id, operation_kind='subscription_webhook'. Si alguien
        agrega operation_id aca sin necesidad, o cambia el kind, este test
        lo marca (documenta la dependencia con el CHECK, no la reemplaza)."""
        conn = _mock_conn()
        conn.execute = AsyncMock(return_value="INSERT 0 1")

        claimed = await _claim_subscription_webhook_idempotency(conn, "some-key")

        assert claimed is True
        conn.execute.assert_awaited_once()
        sql, key = conn.execute.call_args.args
        assert "INSERT INTO public.operation_idempotency" in sql
        assert "operation_kind" in sql
        assert "'subscription_webhook'" in sql
        # \b evita el falso positivo de "operation_idempotency" (el nombre
        # de la tabla contiene "operation_id" como substring literal).
        # operation_id (la COLUMNA) nunca se setea — esa es justo la fila
        # que el CHECK debe eximir.
        assert not re.search(r"\boperation_id\b", sql)
        assert key == "some-key"

    @pytest.mark.asyncio
    async def test_claim_returns_false_on_conflict_redelivery(self):
        """ON CONFLICT DO NOTHING → 'INSERT 0 0' → redelivery, no procesar
        de nuevo."""
        conn = _mock_conn()
        conn.execute = AsyncMock(return_value="INSERT 0 0")

        claimed = await _claim_subscription_webhook_idempotency(conn, "some-key")

        assert claimed is False


# ── H2 hotfix (2026-09-04) RED/GREEN/TRIANGULATE — _tier_for_plan_id ────────
# Bug real de prod: subscriptions.id = fa624f9b-32e5-4b5c-ad0d-fc64e6dc16b1
# nació con plan='pro' (fallback hardcodeado) cuando su preapproval_plan_id
# era el de Inicial ($24.900, MP_PLAN_ID_INICIAL). _tier_for_plan_id es la
# inversa pura de _plan_id_for_tier — se testea directo, sin mocks de red.

class TestTierForPlanId:
    @pytest.mark.parametrize(
        "setting_name,expected_tier",
        [
            ("mp_plan_id_inicial", "inicial"),
            ("mp_plan_id_avanzado", "avanzado"),
            ("mp_plan_id_pro", "pro"),
        ],
    )
    def test_maps_each_configured_tier(self, setting_name, expected_tier):
        with patch(f"backend.services.subscriptions.settings.{setting_name}", PLAN_ID):
            assert _tier_for_plan_id(PLAN_ID) == expected_tier

    def test_unrecognized_plan_id_returns_none(self):
        """No debe inventar ningún tier — un id que no corresponde a
        ninguno de los 3 configurados devuelve None, nunca 'pro'."""
        assert _tier_for_plan_id("plan-id-que-no-existe") is None

    def test_empty_plan_id_returns_none(self):
        assert _tier_for_plan_id("") is None


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
    async def test_duplicate_same_tier_blocks_before_persisting_anything(self):
        """qa-integral-modulos (G14 task 14.2, OQ-2/D8 — H20): el alta
        duplicada del MISMO tier con suscripción viva se corta con 409 ANTES
        de persistir la intención (el guard ya existía en
        create_subscription_intent; este test lo fija como contrato: nada
        queda escrito y el detail explica el conflicto)."""
        repo = _mock_repo(
            find_live_subscription=AsyncMock(
                return_value={"id": SUBSCRIPTION_ID, "plan": "pro", "status": "authorized"}
            )
        )
        with patch("backend.services.subscriptions.settings.mp_plan_id_pro", PLAN_ID):
            with pytest.raises(HTTPException) as exc:
                await create_subscription_intent(ACCOUNT_ID, USER_ID, "pro", repo)

        assert exc.value.status_code == 409
        assert "suscripción viva" in exc.value.detail
        repo.create_intent.assert_not_awaited()

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
        status='ambiguous', motivo no_match. El dinero no se pierde. El tier
        se deriva del preapproval_plan_id real (H2 hotfix 2026-09-04)."""
        repo = _mock_repo(find_pending_intents=AsyncMock(return_value=[]))
        conn = _mock_conn()

        with (
            patch("backend.services.subscriptions.settings.mp_plan_id_pro", PLAN_ID),
            patch("httpx.AsyncClient.get", new_callable=AsyncMock, return_value=self._mp_get_response()),
        ):
            result = await process_subscription_preapproval_notification(PREAPPROVAL_ID, repo, conn)

        assert result == {"ok": True, "ambiguous": "no_match"}
        kwargs = repo.create_subscription.call_args.kwargs
        assert kwargs["account_id"] is None
        assert kwargs["status"] == "ambiguous"
        assert kwargs["ambiguous_reason"] == "no_match"
        assert kwargs["plan"] == "pro"

    # ── H2 hotfix (2026-09-04) ────────────────────────────────────────────
    # Caso real de prod: subscriptions.id = fa624f9b-32e5-4b5c-ad0d-fc64e6dc16b1
    # nació con plan='pro' (candidates[0]["plan"] if candidates else "pro",
    # con 0 candidatas) cuando el preapproval_plan_id real era el de Inicial.
    # El tier ahora se deriva SIEMPRE de preapproval_plan_id, nunca se
    # inventa 'pro'.

    @pytest.mark.asyncio
    @pytest.mark.parametrize(
        "setting_name,expected_tier",
        [
            ("mp_plan_id_inicial", "inicial"),
            ("mp_plan_id_avanzado", "avanzado"),
            ("mp_plan_id_pro", "pro"),
        ],
    )
    async def test_zero_matches_derives_tier_from_preapproval_plan_id(self, setting_name, expected_tier):
        """RED/TRIANGULATE (H2): 0 candidatas, cualquiera de los 3 tiers
        configurados — la fila ambigua nace con el tier REAL del
        preapproval_plan_id, no con un fallback hardcodeado."""
        repo = _mock_repo(find_pending_intents=AsyncMock(return_value=[]))
        conn = _mock_conn()

        with (
            patch(f"backend.services.subscriptions.settings.{setting_name}", PLAN_ID),
            patch("httpx.AsyncClient.get", new_callable=AsyncMock, return_value=self._mp_get_response()),
        ):
            result = await process_subscription_preapproval_notification(PREAPPROVAL_ID, repo, conn)

        assert result == {"ok": True, "ambiguous": "no_match"}
        assert repo.create_subscription.call_args.kwargs["plan"] == expected_tier

    @pytest.mark.asyncio
    async def test_zero_matches_with_unrecognized_plan_id_does_not_guess(self):
        """RED (H2): si preapproval_plan_id no corresponde a NINGÚN tier
        configurado (los 3 MP_PLAN_ID_* quedan en su default "" de test) y
        no hay candidatas que lo declaren, NO se crea la fila — nunca se
        adivina 'pro'. Queda solo el log crítico para revisión manual."""
        repo = _mock_repo(find_pending_intents=AsyncMock(return_value=[]))
        conn = _mock_conn()

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, return_value=self._mp_get_response()):
            result = await process_subscription_preapproval_notification(PREAPPROVAL_ID, repo, conn)

        assert result == {"ok": True, "unrecognized_plan": True}
        repo.create_subscription.assert_not_awaited()

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
        # H2 hotfix: preapproval_plan_id (PLAN_ID) no está configurado en
        # ningún MP_PLAN_ID_* de test — sin evidencia propia, cae al plan
        # declarado por la primera candidata (todas comparten
        # preapproval_plan_id por construcción de find_pending_intents).
        assert kwargs["plan"] == "pro"

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
        """find_ambiguous_subscription no encuentra nada → 404 ANTES de
        tocar account_id/status (default de _mock_repo: None)."""
        repo = _mock_repo()
        conn = _mock_conn()

        with pytest.raises(HTTPException) as exc:
            await resolve_ambiguous_subscription(SUBSCRIPTION_ID, ACCOUNT_ID, repo, conn)
        assert exc.value.status_code == 404
        repo.resolve_ambiguous_subscription.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_activates_plan_and_audits_billing_event(self):
        """GREEN: al resolver, activa el plan de la cuenta recién asignada
        (derivado de preapproval_plan_id) y audita en billing_events
        (distinguible de un match automático)."""
        repo = _mock_repo(
            find_ambiguous_subscription=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "preapproval_id": PREAPPROVAL_ID,
                    "preapproval_plan_id": PLAN_ID, "plan": "avanzado", "status": "ambiguous",
                }
            ),
            resolve_ambiguous_subscription=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "account_id": ACCOUNT_ID,
                    "preapproval_id": PREAPPROVAL_ID, "plan": "avanzado", "status": "authorized",
                }
            ),
        )
        conn = _mock_conn()

        with patch("backend.services.subscriptions.settings.mp_plan_id_avanzado", PLAN_ID):
            result = await resolve_ambiguous_subscription(SUBSCRIPTION_ID, ACCOUNT_ID, repo, conn)

        assert result == {"ok": True}
        sqls = [c.args[0] for c in conn.execute.call_args_list]
        assert any("billing_plan = $2" in s for s in sqls)
        assert any("subscription_ambiguous_resolved" in s for s in sqls)
        # el plan guardado ya coincidía con el derivado — sin corrección
        repo.correct_subscription_plan.assert_not_awaited()

    # ── H2 hotfix (2026-09-04) ────────────────────────────────────────────
    # Caso real de prod: la fila fa624f9b nació con plan='pro' pero su
    # preapproval_plan_id es el de Inicial. resolve_ambiguous_subscription
    # NUNCA debe confiar en el `plan` guardado tal cual — deriva el tier
    # real de preapproval_plan_id y corrige la fila si divergía.

    @pytest.mark.asyncio
    async def test_derives_tier_from_preapproval_plan_id_and_corrects_stale_plan(self):
        """RED (H2): fila histórica nacida 'pro' por el bug del fallback,
        cuyo preapproval_plan_id real es el de Inicial — resolver debe
        activar 'inicial' en la cuenta y corregir subscriptions.plan."""
        repo = _mock_repo(
            find_ambiguous_subscription=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "preapproval_id": PREAPPROVAL_ID,
                    "preapproval_plan_id": PLAN_ID, "plan": "pro", "status": "ambiguous",
                }
            ),
            resolve_ambiguous_subscription=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "account_id": ACCOUNT_ID,
                    "preapproval_id": PREAPPROVAL_ID, "plan": "pro", "status": "authorized",
                }
            ),
        )
        conn = _mock_conn()

        with patch("backend.services.subscriptions.settings.mp_plan_id_inicial", PLAN_ID):
            result = await resolve_ambiguous_subscription(SUBSCRIPTION_ID, ACCOUNT_ID, repo, conn)

        assert result == {"ok": True}
        repo.correct_subscription_plan.assert_awaited_once_with(SUBSCRIPTION_ID, "inicial")

        update_call = next(c for c in conn.execute.call_args_list if "billing_plan = $2" in c.args[0])
        assert update_call.args[1:] == (ACCOUNT_ID, "inicial")

        billing_event_call = next(
            c for c in conn.execute.call_args_list if "subscription_ambiguous_resolved" in c.args[0]
        )
        assert "inicial" in billing_event_call.args

    @pytest.mark.asyncio
    @pytest.mark.parametrize(
        "setting_name,expected_tier",
        [
            ("mp_plan_id_inicial", "inicial"),
            ("mp_plan_id_avanzado", "avanzado"),
            ("mp_plan_id_pro", "pro"),
        ],
    )
    async def test_resolves_each_configured_tier(self, setting_name, expected_tier):
        """TRIANGULATE (H2): los 3 tiers configurados se derivan y activan
        correctamente, no solo 'inicial'."""
        repo = _mock_repo(
            find_ambiguous_subscription=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "preapproval_id": PREAPPROVAL_ID,
                    "preapproval_plan_id": PLAN_ID, "plan": "pro", "status": "ambiguous",
                }
            ),
            resolve_ambiguous_subscription=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "account_id": ACCOUNT_ID,
                    "preapproval_id": PREAPPROVAL_ID, "plan": "pro", "status": "authorized",
                }
            ),
        )
        conn = _mock_conn()

        with patch(f"backend.services.subscriptions.settings.{setting_name}", PLAN_ID):
            result = await resolve_ambiguous_subscription(SUBSCRIPTION_ID, ACCOUNT_ID, repo, conn)

        assert result == {"ok": True}
        update_call = next(c for c in conn.execute.call_args_list if "billing_plan = $2" in c.args[0])
        assert update_call.args[1:] == (ACCOUNT_ID, expected_tier)

    @pytest.mark.asyncio
    async def test_rejects_when_plan_id_unrecognized(self):
        """RED (H2): si preapproval_plan_id no mapea a ningún tier
        configurado, no se resuelve — 409 explícito, sin tocar account_id
        ni billing_plan (nunca se asigna un plan adivinado)."""
        repo = _mock_repo(
            find_ambiguous_subscription=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "preapproval_id": PREAPPROVAL_ID,
                    "preapproval_plan_id": "plan-id-que-no-existe", "plan": "pro", "status": "ambiguous",
                }
            )
        )
        conn = _mock_conn()

        with pytest.raises(HTTPException) as exc:
            await resolve_ambiguous_subscription(SUBSCRIPTION_ID, ACCOUNT_ID, repo, conn)

        assert exc.value.status_code in (409, 422)
        repo.resolve_ambiguous_subscription.assert_not_awaited()
        conn.execute.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_404_when_resolve_races_away_after_find(self):
        """TRIANGULATE (H2): find_ambiguous_subscription encuentra la fila
        y el tier deriva bien, pero otro admin la resuelve primero — el
        UPDATE con WHERE status='ambiguous' no afecta filas y
        resolve_ambiguous_subscription devuelve None. 404, sin tocar la
        cuenta (no se corrige ni se activa nada sobre una carrera)."""
        repo = _mock_repo(
            find_ambiguous_subscription=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "preapproval_id": PREAPPROVAL_ID,
                    "preapproval_plan_id": PLAN_ID, "plan": "pro", "status": "ambiguous",
                }
            ),
            resolve_ambiguous_subscription=AsyncMock(return_value=None),
        )
        conn = _mock_conn()

        with patch("backend.services.subscriptions.settings.mp_plan_id_pro", PLAN_ID):
            with pytest.raises(HTTPException) as exc:
                await resolve_ambiguous_subscription(SUBSCRIPTION_ID, ACCOUNT_ID, repo, conn)

        assert exc.value.status_code == 404
        conn.execute.assert_not_awaited()


# ── 7.2 RED / GREEN — correos encolados (renovación / baja) ──────────────

class TestSubscriptionEmailsEnqueued:
    @pytest.mark.asyncio
    async def test_cancel_subscription_enqueues_cancellation_email(self):
        """RED (7.2): la baja voluntaria encola un correo
        subscription_cancelled con preapproval_id como discriminador."""
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
            await cancel_subscription(ACCOUNT_ID, repo, conn)

        email_call = next(c for c in conn.execute.call_args_list if "email_logs" in c.args[0])
        assert "'subscription_cancelled'" in email_call.args[0]
        assert PREAPPROVAL_ID in email_call.args

    @pytest.mark.asyncio
    async def test_approved_payment_enqueues_renewal_email(self):
        """RED (7.2): un cobro aprobado encola un correo
        subscription_payment_approved con authorized_payment_id como
        discriminador (distinto cada mes, nunca colisiona)."""
        repo = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={"account_id": ACCOUNT_ID, "plan": "avanzado", "status": "authorized"}
            )
        )
        conn = _mock_conn()
        mp_response = MagicMock()
        mp_response.status_code = 200
        mp_response.json.return_value = {
            "status": "processed",
            "preapproval_id": PREAPPROVAL_ID,
            "payment": {"id": "mp-payment-1", "status": "approved"},
            "retry_attempt": 0,
            "debit_date": "2026-09-01T00:00:00Z",
            "transaction_amount": 34900,
        }

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, return_value=mp_response):
            await process_subscription_authorized_payment_notification("ap-renewal-1", repo, conn)

        email_call = next(c for c in conn.execute.call_args_list if "email_logs" in c.args[0])
        assert "'subscription_payment_approved'" in email_call.args[0]
        assert "ap-renewal-1" in email_call.args

    @pytest.mark.asyncio
    async def test_mp_side_cancellation_enqueues_email_only_once(self):
        """TRIANGULATE (7.2): la cancelación reportada por MP encola el
        correo, pero SOLO en la transición real (guard billing_status <>
        'cancelling') — una redelivery no debe reenviar el aviso."""
        repo = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={
                    "account_id": ACCOUNT_ID, "status": "authorized",
                    "next_payment_date": datetime.datetime(2026, 9, 1, tzinfo=datetime.timezone.utc),
                }
            )
        )
        conn = _mock_conn()
        conn.execute = AsyncMock(return_value="UPDATE 0")  # ya estaba 'cancelling' — no-op
        mp_response = MagicMock()
        mp_response.status_code = 200
        mp_response.json.return_value = {
            "status": "cancelled", "payer_email": "buyer@example.com", "preapproval_plan_id": PLAN_ID,
        }

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, return_value=mp_response):
            await process_subscription_preapproval_notification(PREAPPROVAL_ID, repo, conn)

        sqls = [c.args[0] for c in conn.execute.call_args_list]
        assert not any("email_logs" in s for s in sqls)
