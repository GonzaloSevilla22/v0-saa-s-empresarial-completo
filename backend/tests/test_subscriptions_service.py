"""
mp-real-subscriptions — servicio de suscripciones (tasks 6.3-6.13). TDD:
RED (comportamiento esperado, mockeado) → GREEN → TRIANGULATE, mismo patrón
de mocking de httpx.AsyncClient que test_payments.py (process_payment).
"""
from __future__ import annotations

import datetime
import decimal
import json
import re
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi import HTTPException

from backend.services.subscriptions import (
    GRACE_PERIOD,
    _apply_approved_charge,
    _claim_subscription_webhook_idempotency,
    _tier_for_plan_id,
    cancel_subscription,
    create_subscription_intent,
    discard_ambiguous_subscription,
    list_recent_subscriptions,
    process_subscription_authorized_payment_notification,
    process_subscription_preapproval_notification,
    replay_subscription_charges,
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
    # item B (2), residuo (a) de mp-real-subscriptions — match determinístico
    # por external_reference, ver TestProcessSubscriptionPreapproval.
    repo.find_pending_intent_by_id = AsyncMock(return_value=None)
    repo.find_by_preapproval_id = AsyncMock(return_value=None)
    repo.create_subscription = AsyncMock(return_value={"id": SUBSCRIPTION_ID})
    repo.mark_intent_matched = AsyncMock(return_value=True)
    repo.update_subscription_status = AsyncMock(return_value=True)
    repo.find_ambiguous_subscription = AsyncMock(return_value=None)
    repo.correct_subscription_plan = AsyncMock(return_value=True)
    # H3 hotfix (2026-09-04) — replay de cobros perdidos en filas ambiguas.
    repo.clear_pending_charge = AsyncMock(return_value=None)
    repo.find_subscription_by_id = AsyncMock(return_value=None)
    repo.has_billing_event_for_payment = AsyncMock(return_value=False)
    # Descartar (residuo (b)) + resurrección tras descarte + recientes (c).
    repo.discard_ambiguous_subscription = AsyncMock(return_value=None)
    repo.reopen_as_ambiguous = AsyncMock(return_value=True)
    repo.list_recent_subscriptions = AsyncMock(return_value=[])
    for k, v in overrides.items():
        setattr(repo, k, v)
    return repo


class _NullAsyncTransaction:
    """H4 hotfix (2026-09-04): stub de `conn.transaction()` para los tests
    con mocks — `_apply_approved_charge` ahora envuelve sus 3 escrituras en
    `async with conn.transaction():` (el bug real: sin transacción, un 500 a
    mitad de las 3 escrituras dejaba estado parcial en prod). Un `AsyncMock()`
    plano no sirve acá: `conn.transaction()` en un AsyncMock devuelve un
    coroutine, no un context manager async (`TypeError: 'coroutine' object
    does not support the asynchronous context manager protocol`)."""
    async def __aenter__(self):
        return None

    async def __aexit__(self, exc_type, exc, tb):
        return False


def _mock_conn():
    conn = AsyncMock()
    conn.execute = AsyncMock(return_value="INSERT 0 1")
    conn.fetchrow = AsyncMock(return_value=None)
    conn.transaction = MagicMock(return_value=_NullAsyncTransaction())
    # `is_in_transaction()` es SÍNCRONO en asyncpg — con el AsyncMock por
    # defecto devolvería una coroutine (siempre truthy), y la guarda de
    # `_claim_subscription_webhook_idempotency` quedaría sin probar.
    conn.is_in_transaction = MagicMock(return_value=True)
    return conn


class _RecordingTransaction:
    """fix(billing) 2026-10-13: stub de `conn.transaction()` que deja traza
    de cuándo se abre y cómo se cierra cada transacción — para fijar que el
    reclamo de idempotencia de un webhook corre ADENTRO de la misma
    transacción que sus efectos (y que un fallo la deshace entera)."""

    def __init__(self, events: list[str]):
        self._events = events

    async def __aenter__(self):
        self._events.append("begin")

    async def __aexit__(self, exc_type, exc, tb):
        self._events.append("rollback" if exc_type else "commit")
        return False


def _recording_conn(fail_on: str | None = None):
    """Conexión mock que registra, en orden, las transacciones y las
    escrituras hechas con `conn.execute` ("claim" = la marca de
    idempotencia, "write" = cualquier otra). `fail_on`: fragmento de SQL
    cuya escritura revienta."""
    conn = _mock_conn()
    events: list[str] = []

    async def _execute(sql: str, *args: object) -> str:
        if fail_on and fail_on in sql:
            raise RuntimeError("simulated failure after the idempotency claim")
        events.append("claim" if "operation_idempotency" in sql else "write")
        return "INSERT 0 1"

    conn.execute = AsyncMock(side_effect=_execute)
    conn.transaction = MagicMock(side_effect=lambda: _RecordingTransaction(events))
    return conn, events


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

    @pytest.mark.asyncio
    async def test_claim_outside_a_transaction_is_refused(self):
        """fix(billing) 2026-10-13 — la lección del caso real, hecha
        estructural: la marca de idempotencia jamás se escribe fuera de la
        transacción de los efectos. `get_service_conn` entrega la conexión
        en autocommit; reclamar ahí deja la marca comiteada aunque el
        handler reviente después, y MercadoPago recibe `idempotent` en cada
        reintento. Un caller que olvide abrir la transacción falla acá, en
        el primer test que lo ejercite, en vez de perder una notificación
        en producción."""
        conn = _mock_conn()
        conn.is_in_transaction = MagicMock(return_value=False)

        with pytest.raises(RuntimeError, match="transacción"):
            await _claim_subscription_webhook_idempotency(conn, "some-key")

        conn.execute.assert_not_awaited()


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
    async def test_init_point_carries_intent_id_as_external_reference(self):
        """RED (item B (2), residuo (a)): la URL de checkout lleva
        external_reference=<intent_id> además del plan — la reconciliación
        del preapproval la usa para un match determinístico."""
        repo = _mock_repo()
        with (
            patch("backend.services.subscriptions.settings.mp_plan_id_pro", PLAN_ID),
            patch(
                "backend.services.subscriptions._fetch_user_email",
                new_callable=AsyncMock, return_value="buyer@example.com",
            ),
        ):
            result = await create_subscription_intent(ACCOUNT_ID, USER_ID, "pro", repo)

        assert f"preapproval_plan_id={PLAN_ID}" in result.init_point
        assert f"external_reference={INTENT_ID}" in result.init_point

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
    def _mp_get_response(
        self, status="authorized", payer_email="buyer@example.com", external_reference=None
    ):
        resp = MagicMock()
        resp.status_code = 200
        resp.json.return_value = {
            "status": status,
            "payer_email": payer_email,
            "preapproval_plan_id": PLAN_ID,
            "external_reference": external_reference,
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

    # ── item B (2), residuo (a) de mp-real-subscriptions ───────────────────
    # external_reference viaja en el checkout (create_subscription_intent) y
    # debe resolver la atribución ANTES que el camino por email — el email
    # que MercadoPago reporta puede no coincidir con el de la cuenta que iba
    # a suscribirse (caso real: Daniel).

    @pytest.mark.asyncio
    async def test_external_reference_matches_deterministically_before_email(self):
        """RED: con external_reference válido, ni siquiera se consulta el
        camino por email — la referencia matchea directo, aunque el email
        del pagador no coincida con ninguna intención."""
        repo = _mock_repo(
            find_pending_intent_by_id=AsyncMock(
                return_value={"id": INTENT_ID, "account_id": ACCOUNT_ID, "plan": "pro"}
            ),
            find_pending_intents=AsyncMock(
                return_value=[{"id": "otra-intencion", "account_id": "acc-ajena", "plan": "pro"}]
            ),
        )
        conn = _mock_conn()

        with patch(
            "httpx.AsyncClient.get",
            new_callable=AsyncMock,
            return_value=self._mp_get_response(
                payer_email="email-distinto@example.com", external_reference=INTENT_ID
            ),
        ):
            result = await process_subscription_preapproval_notification(PREAPPROVAL_ID, repo, conn)

        assert result == {"ok": True, "matched": True}
        repo.find_pending_intent_by_id.assert_awaited_once_with(INTENT_ID, PLAN_ID)
        repo.find_pending_intents.assert_not_awaited()
        repo.mark_intent_matched.assert_awaited_once_with(INTENT_ID, SUBSCRIPTION_ID)
        create_kwargs = repo.create_subscription.call_args.kwargs
        assert create_kwargs["account_id"] == ACCOUNT_ID
        assert create_kwargs["external_reference"] == INTENT_ID

    @pytest.mark.asyncio
    async def test_expired_or_foreign_external_reference_falls_back_to_email(self):
        """TRIANGULATE: external_reference sintácticamente válido pero sin
        intención pendiente que lo respalde (vencida, o de otro plan) — cae
        al camino por email exactamente como antes de esta capacidad."""
        repo = _mock_repo(
            find_pending_intent_by_id=AsyncMock(return_value=None),
            find_pending_intents=AsyncMock(
                return_value=[{"id": INTENT_ID, "account_id": ACCOUNT_ID, "plan": "pro"}]
            ),
        )
        conn = _mock_conn()

        with patch(
            "httpx.AsyncClient.get",
            new_callable=AsyncMock,
            return_value=self._mp_get_response(external_reference=SUBSCRIPTION_ID),
        ):
            result = await process_subscription_preapproval_notification(PREAPPROVAL_ID, repo, conn)

        assert result == {"ok": True, "matched": True}
        repo.find_pending_intents.assert_awaited_once()
        repo.mark_intent_matched.assert_awaited_once_with(INTENT_ID, SUBSCRIPTION_ID)

    @pytest.mark.asyncio
    async def test_external_reference_and_email_pointing_to_same_intent_is_a_single_match(self):
        """TRIANGULATE: si external_reference Y el email identifican la
        MISMA intención, el match determinístico gana y el camino por email
        ni se consulta — un solo match, no dos."""
        repo = _mock_repo(
            find_pending_intent_by_id=AsyncMock(
                return_value={"id": INTENT_ID, "account_id": ACCOUNT_ID, "plan": "pro"}
            ),
        )
        conn = _mock_conn()

        with patch(
            "httpx.AsyncClient.get",
            new_callable=AsyncMock,
            return_value=self._mp_get_response(external_reference=INTENT_ID),
        ):
            result = await process_subscription_preapproval_notification(PREAPPROVAL_ID, repo, conn)

        assert result == {"ok": True, "matched": True}
        repo.find_pending_intents.assert_not_awaited()
        repo.create_subscription.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_non_uuid_external_reference_falls_back_to_email_without_erroring(self):
        """TRIANGULATE: un external_reference que no es un uuid válido
        (checkout previo a esta capacidad, o valor corrupto) no revienta —
        simplemente cae al camino por email."""
        repo = _mock_repo(
            find_pending_intents=AsyncMock(
                return_value=[{"id": INTENT_ID, "account_id": ACCOUNT_ID, "plan": "pro"}]
            ),
        )
        conn = _mock_conn()

        with patch(
            "httpx.AsyncClient.get",
            new_callable=AsyncMock,
            return_value=self._mp_get_response(external_reference="no-es-un-uuid"),
        ):
            result = await process_subscription_preapproval_notification(PREAPPROVAL_ID, repo, conn)

        assert result == {"ok": True, "matched": True}
        repo.find_pending_intent_by_id.assert_not_awaited()
        repo.find_pending_intents.assert_awaited_once()

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

    @pytest.mark.asyncio
    async def test_zero_matches_persists_external_reference_on_ambiguous_row(self):
        """RED (F3, revisor adversarial tanda6): 0 candidatas + external_
        reference presente — la fila ambigua TAMBIÉN debe persistir la
        referencia externa (spec subscription-lifecycle: "se persiste
        coincida o no con una intención"). Antes de este fix, solo la rama
        matcheada la pasaba — justo la fila que más la necesita (cola de
        conciliación manual) era la que perdía la única pista
        determinística disponible."""
        repo = _mock_repo(find_pending_intents=AsyncMock(return_value=[]))
        conn = _mock_conn()

        with (
            patch("backend.services.subscriptions.settings.mp_plan_id_pro", PLAN_ID),
            patch(
                "httpx.AsyncClient.get", new_callable=AsyncMock,
                return_value=self._mp_get_response(external_reference=INTENT_ID),
            ),
        ):
            result = await process_subscription_preapproval_notification(PREAPPROVAL_ID, repo, conn)

        assert result == {"ok": True, "ambiguous": "no_match"}
        create_kwargs = repo.create_subscription.call_args.kwargs
        assert create_kwargs["external_reference"] == INTENT_ID

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

    # ── fix(billing) 2026-10-13 — idempotencia a prueba de fallos ─────────
    # Este topic comparte `_claim_subscription_webhook_idempotency` con el de
    # cuotas y tenía el mismo defecto: la marca se comiteaba antes de los
    # efectos, así que un fallo a mitad de una cancelación dejaba la cuenta
    # en `cancelling` sin auditoría ni correo y el reintento de MercadoPago
    # no completaba nada.

    def _known_subscription_repo(self):
        return _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={
                    "account_id": ACCOUNT_ID, "status": "authorized",
                    "next_payment_date": datetime.datetime(2026, 9, 1, tzinfo=datetime.timezone.utc),
                }
            )
        )

    @pytest.mark.asyncio
    async def test_claim_and_effects_share_one_transaction(self):
        conn, events = _recording_conn()

        with patch(
            "httpx.AsyncClient.get", new_callable=AsyncMock,
            return_value=self._mp_get_response(status="cancelled"),
        ):
            await process_subscription_preapproval_notification(
                PREAPPROVAL_ID, self._known_subscription_repo(), conn
            )

        # accounts + billing_events + email_logs, todas después del reclamo
        # y dentro de la única transacción del handler.
        assert events == ["begin", "claim", "write", "write", "write", "commit"]

    @pytest.mark.asyncio
    async def test_failure_after_the_claim_rolls_back_the_claim_too(self):
        conn, events = _recording_conn(fail_on="INSERT INTO public.email_logs")

        with patch(
            "httpx.AsyncClient.get", new_callable=AsyncMock,
            return_value=self._mp_get_response(status="cancelled"),
        ):
            with pytest.raises(RuntimeError, match="simulated failure"):
                await process_subscription_preapproval_notification(
                    PREAPPROVAL_ID, self._known_subscription_repo(), conn
                )

        assert events == ["begin", "claim", "write", "write", "rollback"]

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

    # ── Descartar (residuo (b)) — resurrección tras el descarte ──────────
    # Una fila descartada (discard_ambiguous_subscription) queda
    # status='cancelled', account_id=NULL. Si MercadoPago vuelve a
    # notificar el MISMO preapproval con un estado "vivo", el código NO
    # debe dejarla con status=<nuevo> y account_id TODAVÍA NULL (fila
    # inconsistente e invisible para list_ambiguous_subscriptions).

    @pytest.mark.asyncio
    async def test_discarded_row_notified_as_authorized_reopens_as_ambiguous(self):
        """RED: MP notifica el preapproval como 'authorized' después de
        haber sido descartado — vuelve a la cola de ambiguos en vez de
        resucitar sin cuenta asignada."""
        repo = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={
                    "account_id": None, "status": "cancelled", "ambiguous_reason": None,
                    "next_payment_date": None,
                }
            )
        )
        conn = _mock_conn()

        with patch(
            "httpx.AsyncClient.get", new_callable=AsyncMock,
            return_value=self._mp_get_response(status="authorized"),
        ):
            result = await process_subscription_preapproval_notification(PREAPPROVAL_ID, repo, conn)

        assert result == {"ok": True, "ambiguous": "no_match"}
        repo.reopen_as_ambiguous.assert_awaited_once_with(PREAPPROVAL_ID, "no_match")
        repo.update_subscription_status.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_discarded_row_notified_as_pending_also_reopens(self):
        """TRIANGULATE: cualquier estado "vivo" (no solo 'authorized')
        dispara la reapertura — 'pending' también."""
        repo = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={
                    "account_id": None, "status": "cancelled", "ambiguous_reason": None,
                    "next_payment_date": None,
                }
            )
        )
        conn = _mock_conn()

        with patch(
            "httpx.AsyncClient.get", new_callable=AsyncMock,
            return_value=self._mp_get_response(status="pending"),
        ):
            result = await process_subscription_preapproval_notification(PREAPPROVAL_ID, repo, conn)

        assert result == {"ok": True, "ambiguous": "no_match"}
        repo.reopen_as_ambiguous.assert_awaited_once_with(PREAPPROVAL_ID, "no_match")

    @pytest.mark.asyncio
    async def test_discarded_row_notified_cancelled_again_stays_discarded(self):
        """TRIANGULATE: si MP repite la MISMA cancelación (status sigue
        'cancelled'), no hay nada que reabrir — solo se actualiza el
        status (no-op de hecho), sin tocar reopen_as_ambiguous."""
        repo = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={
                    "account_id": None, "status": "cancelled", "ambiguous_reason": None,
                    "next_payment_date": None,
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
        repo.reopen_as_ambiguous.assert_not_awaited()
        repo.update_subscription_status.assert_awaited_once_with(PREAPPROVAL_ID, "cancelled")

    @pytest.mark.asyncio
    async def test_ambiguous_row_still_pending_resolution_does_not_reopen(self):
        """TRIANGULATE: una fila que sigue genuinamente 'ambiguous'
        (nunca descartada) no pasa por el camino de reapertura — ese guard
        es específico de status=='cancelled' con account_id NULL."""
        repo = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={
                    "account_id": None, "status": "ambiguous", "ambiguous_reason": "no_match",
                    "next_payment_date": None,
                }
            )
        )
        conn = _mock_conn()

        with patch(
            "httpx.AsyncClient.get", new_callable=AsyncMock,
            return_value=self._mp_get_response(status="authorized"),
        ):
            await process_subscription_preapproval_notification(PREAPPROVAL_ID, repo, conn)

        repo.reopen_as_ambiguous.assert_not_awaited()


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

    def _mp_preapproval_response(self, next_payment_date="2026-10-01T00:00:00Z", status_code=200):
        """`GET /preapproval/{id}` — segunda consulta a MercadoPago de una
        cuota aprobada: de acá sale el siguiente ciclo."""
        resp = MagicMock()
        resp.status_code = status_code
        resp.json.return_value = {"status": "authorized", "next_payment_date": next_payment_date}
        return resp

    @pytest.mark.asyncio
    async def test_approved_payment_extends_plan_expires_at_with_grace(self):
        """RED (6.9): cobro aprobado extiende plan_expires_at a
        next_payment_date + 10 días de gracia (OQ2) y audita en
        billing_events.

        fix(billing) 2026-10-13: ese `next_payment_date` es el del
        PREAPPROVAL (siguiente ciclo), no el `debit_date` de la cuota recién
        cobrada — con el débito, una cuota del 01-09 dejaba el plan
        venciendo el 11-09 en vez de cubrir hasta el 01-10 + gracia."""
        repo = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={"account_id": ACCOUNT_ID, "plan": "avanzado", "status": "authorized"}
            )
        )
        conn = _mock_conn()
        responses = [
            self._mp_get_response(debit_date="2026-09-01T00:00:00Z"),
            self._mp_preapproval_response(next_payment_date="2026-10-01T00:00:00Z"),
        ]

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, side_effect=responses):
            result = await process_subscription_authorized_payment_notification("ap-1", repo, conn)

        assert result == {"ok": True, "credited": True}
        repo.update_subscription_status.assert_awaited_once()
        args, kwargs = repo.update_subscription_status.call_args
        assert kwargs["retry_state"] == "none"
        assert kwargs["last_payment_status"] == "approved"

        sqls = [c.args[0] for c in conn.execute.call_args_list]
        assert any("subscription_payment_approved" in s for s in sqls)

        next_cycle = datetime.datetime(2026, 10, 1, tzinfo=datetime.timezone.utc)
        update_call = next(c for c in conn.execute.call_args_list if "SET plan_expires_at" in c.args[0])
        assert update_call.args[2] == next_cycle + GRACE_PERIOD

    @pytest.mark.asyncio
    @pytest.mark.parametrize(
        "subscription",
        [
            {"account_id": ACCOUNT_ID, "plan": "inicial", "status": "authorized"},
            {"account_id": None, "plan": "inicial", "status": "ambiguous"},
        ],
        ids=["con_cuenta", "ambigua"],
    )
    async def test_repo_receives_a_datetime_never_the_mercadopago_string(self, subscription):
        """Bug real (cuota 7032577415, 2026-10-04): al repositorio le llegaba
        el texto de MercadoPago tal cual y asyncpg lo rechazaba con
        `DataError` al bindearlo a `timestamptz` — en las DOS ramas. Este
        test usa las fechas con la forma real (offset `-04:00` y
        milisegundos): la suite de mocks anterior asserteaba el string y por
        eso no vio el bug."""
        repo = _mock_repo(find_by_preapproval_id=AsyncMock(return_value=subscription))
        conn = _mock_conn()
        responses = [
            self._mp_get_response(debit_date="2026-10-04T17:02:30.000-04:00", transaction_amount=24900),
            self._mp_preapproval_response(next_payment_date="2026-11-04T16:54:19.000-04:00"),
        ]

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, side_effect=responses):
            await process_subscription_authorized_payment_notification("7032577415", repo, conn)

        next_payment_date = repo.update_subscription_status.call_args.kwargs["next_payment_date"]
        assert isinstance(next_payment_date, datetime.datetime)
        assert next_payment_date == datetime.datetime(2026, 11, 4, 20, 54, 19, tzinfo=datetime.timezone.utc)

    @pytest.mark.asyncio
    async def test_expiry_of_the_real_october_cuota_is_next_cycle_plus_grace(self):
        """TRIANGULATE (defecto 2): cuota debitada el 04-10 con siguiente
        ciclo el 04-11 → el plan vence el 14-11 (ciclo + gracia), no el
        14-10 (débito + gracia)."""
        repo = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={"account_id": ACCOUNT_ID, "plan": "inicial", "status": "authorized"}
            )
        )
        conn = _mock_conn()
        responses = [
            self._mp_get_response(debit_date="2026-10-04T17:02:30.000-04:00", transaction_amount=24900),
            self._mp_preapproval_response(next_payment_date="2026-11-04T16:54:19.000-04:00"),
        ]

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, side_effect=responses):
            await process_subscription_authorized_payment_notification("7032577415", repo, conn)

        update_call = next(c for c in conn.execute.call_args_list if "SET plan_expires_at" in c.args[0])
        assert update_call.args[2] == datetime.datetime(2026, 11, 14, 20, 54, 19, tzinfo=datetime.timezone.utc)

    @pytest.mark.asyncio
    async def test_preapproval_without_next_payment_date_does_not_derive_expiry_from_the_debit(self):
        """Si MercadoPago no informa el siguiente ciclo, no se inventa uno a
        partir del débito: el repositorio y `_apply_approved_charge` reciben
        None (y ambos conservan la fecha que ya había, vía COALESCE)."""
        repo = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={"account_id": ACCOUNT_ID, "plan": "inicial", "status": "authorized"}
            )
        )
        conn = _mock_conn()
        responses = [
            self._mp_get_response(debit_date="2026-10-04T17:02:30.000-04:00"),
            self._mp_preapproval_response(next_payment_date=None),
        ]

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, side_effect=responses):
            result = await process_subscription_authorized_payment_notification("ap-1", repo, conn)

        assert result == {"ok": True, "credited": True}
        assert repo.update_subscription_status.call_args.kwargs["next_payment_date"] is None
        update_call = next(c for c in conn.execute.call_args_list if "SET plan_expires_at" in c.args[0])
        assert update_call.args[2] is None
        assert any("subscription_payment_approved" in c.args[0] for c in conn.execute.call_args_list)

    @pytest.mark.asyncio
    async def test_preapproval_lookup_failure_raises_502_without_claiming_anything(self):
        """Un error de MercadoPago al consultar el preapproval corta con 502
        ANTES de reclamar la idempotencia y de cualquier escritura: la
        notificación queda intacta para el reintento de MercadoPago."""
        repo = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={"account_id": ACCOUNT_ID, "plan": "inicial", "status": "authorized"}
            )
        )
        conn = _mock_conn()
        responses = [self._mp_get_response(), self._mp_preapproval_response(status_code=500)]

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, side_effect=responses):
            with pytest.raises(HTTPException) as exc:
                await process_subscription_authorized_payment_notification("ap-1", repo, conn)

        assert exc.value.status_code == 502
        conn.execute.assert_not_awaited()
        conn.transaction.assert_not_called()
        repo.update_subscription_status.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_claim_and_effects_share_one_transaction(self):
        """El agravante estructural del bug real: la marca de idempotencia
        se insertaba ANTES de los efectos, en autocommit, y quedaba
        comiteada aunque el handler reventara. Ahora el reclamo es la
        primera escritura de la MISMA transacción que los efectos."""
        repo = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={"account_id": ACCOUNT_ID, "plan": "inicial", "status": "authorized"}
            )
        )
        conn, events = _recording_conn()
        responses = [self._mp_get_response(), self._mp_preapproval_response()]

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, side_effect=responses):
            await process_subscription_authorized_payment_notification("ap-1", repo, conn)

        assert events[:2] == ["begin", "claim"]
        assert events[-1] == "commit"
        assert events.count("begin") == events.count("commit")
        assert "rollback" not in events
        assert events.count("write") == 3  # accounts + billing_events + email_logs

    @pytest.mark.asyncio
    async def test_failure_after_the_claim_rolls_back_the_claim_too(self):
        """TRIANGULATE: si una escritura posterior al reclamo falla, la
        transacción que contiene la marca se cierra con rollback — nunca con
        commit — y el error se propaga (500 → MercadoPago reintenta)."""
        repo = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={"account_id": ACCOUNT_ID, "plan": "inicial", "status": "authorized"}
            )
        )
        conn, events = _recording_conn(fail_on="INSERT INTO public.email_logs")
        responses = [self._mp_get_response(), self._mp_preapproval_response()]

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, side_effect=responses):
            with pytest.raises(RuntimeError, match="simulated failure"):
                await process_subscription_authorized_payment_notification("ap-1", repo, conn)

        assert events[:2] == ["begin", "claim"]
        assert events[-1] == "rollback"
        assert "commit" not in events

    @pytest.mark.asyncio
    async def test_next_cycle_not_after_the_debit_is_logged(self, caplog):
        """Si el preapproval todavía informa un `next_payment_date` que no
        es posterior al débito de la cuota recién cobrada, MercadoPago no
        avanzó el ciclo: se aplica igual lo que informa, pero queda un
        aviso — el vencimiento quedó corto y hay que correr el replay."""
        repo = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={"account_id": ACCOUNT_ID, "plan": "inicial", "status": "authorized"}
            )
        )
        conn = _mock_conn()
        responses = [
            self._mp_get_response(debit_date="2026-10-04T17:02:30.000-04:00"),
            self._mp_preapproval_response(next_payment_date="2026-10-04T16:54:19.000-04:00"),
        ]

        with caplog.at_level("WARNING", logger="backend.services.subscriptions"):
            with patch("httpx.AsyncClient.get", new_callable=AsyncMock, side_effect=responses):
                await process_subscription_authorized_payment_notification("ap-1", repo, conn)

        stale = [r for r in caplog.records if "no es posterior al débito" in r.getMessage()]
        assert len(stale) == 1
        assert PREAPPROVAL_ID in stale[0].getMessage()

    @pytest.mark.asyncio
    async def test_advanced_next_cycle_is_not_logged_as_stale(self, caplog):
        """TRIANGULATE: el caso normal (siguiente ciclo posterior al débito)
        no deja ningún aviso."""
        repo = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={"account_id": ACCOUNT_ID, "plan": "inicial", "status": "authorized"}
            )
        )
        conn = _mock_conn()
        responses = [
            self._mp_get_response(debit_date="2026-10-04T17:02:30.000-04:00"),
            self._mp_preapproval_response(next_payment_date="2026-11-04T16:54:19.000-04:00"),
        ]

        with caplog.at_level("WARNING", logger="backend.services.subscriptions"):
            with patch("httpx.AsyncClient.get", new_callable=AsyncMock, side_effect=responses):
                await process_subscription_authorized_payment_notification("ap-1", repo, conn)

        assert not [r for r in caplog.records if "no es posterior al débito" in r.getMessage()]

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
        ) as mp_get:
            result = await process_subscription_authorized_payment_notification("ap-1", repo, conn)

        assert result == {"ok": True, "payment_failed": True}
        sqls = [c.args[0] for c in conn.execute.call_args_list]
        assert not any("plan_expires_at" in s for s in sqls)
        assert not any("billing_plan" in s for s in sqls)
        assert any("SubscriptionPaymentFailed" in s for s in sqls)
        # un cobro rechazado no extiende nada: no hace falta el siguiente
        # ciclo, así que no se consulta el preapproval.
        assert mp_get.await_count == 1

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

    # ── H3 hotfix (2026-09-04) — no perder el cobro cuando account_id es NULL ──
    # Caso real de prod: subscriptions.id fa624f9b-32e5-4b5c-ad0d-fc64e6dc16b1
    # cobró $24.900 (authorized_payment 7031580844, pago MP 176341057469)
    # mientras estaba 'ambiguous' — el docstring viejo de
    # resolve_ambiguous_subscription decía "el dinero YA se acreditó en
    # billing_events" pero eso es FALSO cuando la cuota llega ANTES de la
    # resolución manual (el caso normal: MP manda preapproval y cuota con
    # segundos de diferencia, la resolución del admin llega horas después).

    @pytest.mark.asyncio
    async def test_approved_payment_with_null_account_persists_pending_charge(self):
        """RED (TDD a): con account_id=None, el UPDATE debe guardar
        next_payment_date/last_payment_status/amount y el id del pago MP +
        el id de la cuota — todo lo que resolve_ambiguous_subscription
        necesitará más tarde para replicar los efectos. Ningún efecto de
        dinero (accounts/billing_events/email_logs) se aplica todavía: no
        hay cuenta a la que aplicarlo."""
        repo = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={"account_id": None, "plan": "inicial", "status": "ambiguous"}
            )
        )
        conn = _mock_conn()

        with patch(
            "httpx.AsyncClient.get", new_callable=AsyncMock,
            return_value=self._mp_get_response(
                transaction_amount=24900, debit_date="2026-10-01T00:00:00Z",
            ),
        ):
            result = await process_subscription_authorized_payment_notification("7031580844", repo, conn)

        assert result == {"ok": True, "credited": True}
        repo.update_subscription_status.assert_awaited_once()
        _, kwargs = repo.update_subscription_status.call_args
        assert kwargs["retry_state"] == "none"
        assert kwargs["last_payment_status"] == "approved"
        assert kwargs["amount"] == 24900
        assert kwargs["pending_authorized_payment_id"] == "7031580844"
        assert kwargs["pending_mercadopago_payment_id"] == "mp-payment-1"

        # sin cuenta conocida no hay ningún efecto de dinero que aplicar
        # todavía — el único conn.execute es el claim de idempotencia
        # (_claim_subscription_webhook_idempotency), nunca accounts/
        # billing_events/email_logs.
        assert conn.execute.await_count == 1
        sqls = [c.args[0] for c in conn.execute.call_args_list]
        assert not any("plan_expires_at" in s for s in sqls)
        assert not any("billing_events" in s for s in sqls)
        assert not any("email_logs" in s for s in sqls)

    @pytest.mark.asyncio
    async def test_approved_payment_with_known_account_does_not_set_pending_fields(self):
        """TRIANGULATE (TDD a): cuando account_id YA se conoce (camino
        normal), no hace falta dejar marcadores de "pendiente" — el efecto
        se aplica de inmediato vía _apply_approved_charge."""
        repo = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={"account_id": ACCOUNT_ID, "plan": "avanzado", "status": "authorized"}
            )
        )
        conn = _mock_conn()

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, return_value=self._mp_get_response()):
            await process_subscription_authorized_payment_notification("ap-1", repo, conn)

        _, kwargs = repo.update_subscription_status.call_args
        assert kwargs["pending_authorized_payment_id"] is None
        assert kwargs["pending_mercadopago_payment_id"] is None

    # ── F2 (revisor adversarial tanda6) — no forzar 'authorized' sin cuenta ──
    # Antes de este fix, una cuota approved forzaba status='authorized' con
    # account_id NULL incluso sobre una fila YA DESCARTADA (status=
    # 'cancelled', ambiguous_reason=NULL) — el CHECK
    # (status='ambiguous')=(ambiguous_reason IS NOT NULL) lo permitía en
    # silencio (false=false) y la fila quedaba invisible/huérfana con
    # dinero cobrado. Mismo invariante que el guard de resurrección del
    # topic subscription_preapproval.

    @pytest.mark.asyncio
    async def test_discarded_row_receiving_approved_charge_returns_to_ambiguous_not_authorized(self):
        """RED (F2): una fila DESCARTADA (status='cancelled', account_id
        NULL) que recibe una cuota approved NO debe resucitar con
        status='authorized' — vuelve a la cola de ambiguos (mismo guard que
        reopen_as_ambiguous usa para el topic subscription_preapproval) con
        el cobro pendiente guardado para que resolve_ambiguous_subscription
        lo replique más tarde."""
        repo = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={"account_id": None, "plan": "inicial", "status": "cancelled"}
            )
        )
        conn = _mock_conn()

        with patch(
            "httpx.AsyncClient.get", new_callable=AsyncMock,
            return_value=self._mp_get_response(
                transaction_amount=24900, debit_date="2026-10-01T00:00:00Z",
            ),
        ):
            result = await process_subscription_authorized_payment_notification("7031580844", repo, conn)

        assert result == {"ok": True, "credited": True}
        repo.reopen_as_ambiguous.assert_awaited_once_with(PREAPPROVAL_ID, "no_match")
        repo.update_subscription_status.assert_awaited_once()
        args, kwargs = repo.update_subscription_status.call_args
        assert args[1] == "ambiguous"
        assert kwargs["pending_authorized_payment_id"] == "7031580844"
        assert kwargs["pending_mercadopago_payment_id"] == "mp-payment-1"
        assert kwargs["last_payment_status"] == "approved"
        # sin cuenta, ningún efecto de dinero se aplica todavía.
        sqls = [c.args[0] for c in conn.execute.call_args_list]
        assert not any("billing_events" in s for s in sqls)

    @pytest.mark.asyncio
    async def test_still_ambiguous_row_receiving_approved_charge_stays_ambiguous(self):
        """TRIANGULATE (F2): una fila TODAVÍA ambigua (nunca descartada)
        que recibe una cuota approved sigue 'ambiguous' con el cobro
        pendiente guardado — comportamiento existente (H3) intacto, ahora
        con el status explícito en vez de forzar 'authorized' sin cuenta."""
        repo = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={"account_id": None, "plan": "inicial", "status": "ambiguous"}
            )
        )
        conn = _mock_conn()

        with patch(
            "httpx.AsyncClient.get", new_callable=AsyncMock,
            return_value=self._mp_get_response(
                transaction_amount=24900, debit_date="2026-10-01T00:00:00Z",
            ),
        ):
            result = await process_subscription_authorized_payment_notification("7031580844", repo, conn)

        assert result == {"ok": True, "credited": True}
        repo.reopen_as_ambiguous.assert_awaited_once_with(PREAPPROVAL_ID, "no_match")
        args, kwargs = repo.update_subscription_status.call_args
        assert args[1] == "ambiguous"
        assert kwargs["pending_authorized_payment_id"] == "7031580844"

    @pytest.mark.asyncio
    async def test_account_row_receiving_approved_charge_stays_authorized(self):
        """TRIANGULATE (F2): con cuenta asignada, el comportamiento no
        cambia — status='authorized', sin reopen_as_ambiguous ni
        pending_*."""
        repo = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={"account_id": ACCOUNT_ID, "plan": "avanzado", "status": "authorized"}
            )
        )
        conn = _mock_conn()

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, return_value=self._mp_get_response()):
            await process_subscription_authorized_payment_notification("ap-1", repo, conn)

        repo.reopen_as_ambiguous.assert_not_awaited()
        args, kwargs = repo.update_subscription_status.call_args
        assert args[1] == "authorized"
        assert kwargs["pending_authorized_payment_id"] is None


# ── H3 hotfix (2026-09-04) — camino compartido para efectos de una cuota ──

class TestApplyApprovedChargeParity:
    @pytest.mark.asyncio
    async def test_normal_path_and_resolve_path_call_the_same_shared_function(self):
        """RED/TDD (d), test de paridad: tanto el camino normal (webhook con
        account_id ya conocido) como el replay al resolver una suscripción
        ambigua deben invocar `_apply_approved_charge` — la ÚNICA definición
        de los efectos de dinero de una cuota aprobada (reutilización antes
        que repetición, CLAUDE.md). Si algún camino reimplementa el efecto
        por su cuenta en vez de llamar a la función compartida, este test lo
        atrapa."""
        from backend.services import subscriptions as subs_module

        # camino normal: account_id ya conocido de entrada
        repo1 = _mock_repo(
            find_by_preapproval_id=AsyncMock(
                return_value={"account_id": ACCOUNT_ID, "plan": "avanzado", "status": "authorized"}
            )
        )
        conn1 = _mock_conn()
        mp_response = MagicMock()
        mp_response.status_code = 200
        mp_response.json.return_value = {
            "status": "processed", "preapproval_id": PREAPPROVAL_ID,
            "payment": {"id": "mp-payment-1", "status": "approved"},
            "retry_attempt": 0, "debit_date": "2026-08-01T00:00:00Z",
            "transaction_amount": 34900,
        }
        # fix(billing) 2026-10-13: el vencimiento del camino normal sale del
        # siguiente ciclo del preapproval — el mismo dato que el camino de
        # resolución lee de `subscriptions.next_payment_date`.
        mp_preapproval = MagicMock()
        mp_preapproval.status_code = 200
        mp_preapproval.json.return_value = {"status": "authorized", "next_payment_date": "2026-09-01T00:00:00Z"}
        with (
            patch.object(subs_module, "_apply_approved_charge", new_callable=AsyncMock) as mock_apply,
            patch("httpx.AsyncClient.get", new_callable=AsyncMock, side_effect=[mp_response, mp_preapproval]),
        ):
            await process_subscription_authorized_payment_notification("ap-1", repo1, conn1)
        mock_apply.assert_awaited_once()
        normal_kwargs = mock_apply.call_args.kwargs

        # camino de resolución: account_id recién asignado, cobro pendiente
        # guardado en la fila (H3) por una notificación anterior.
        repo2 = _mock_repo(
            find_ambiguous_subscription=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "preapproval_id": PREAPPROVAL_ID,
                    "preapproval_plan_id": PLAN_ID, "plan": "avanzado", "status": "ambiguous",
                    "next_payment_date": datetime.datetime(2026, 9, 1, tzinfo=datetime.timezone.utc),
                    "amount": 34900, "pending_authorized_payment_id": "ap-1",
                    "pending_mercadopago_payment_id": "mp-payment-1",
                }
            ),
            resolve_ambiguous_subscription=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "account_id": ACCOUNT_ID,
                    "preapproval_id": PREAPPROVAL_ID, "plan": "avanzado", "status": "authorized",
                }
            ),
        )
        conn2 = _mock_conn()
        with (
            patch.object(subs_module, "_apply_approved_charge", new_callable=AsyncMock) as mock_apply2,
            patch("backend.services.subscriptions.settings.mp_plan_id_avanzado", PLAN_ID),
        ):
            await resolve_ambiguous_subscription(SUBSCRIPTION_ID, ACCOUNT_ID, repo2, conn2)
        mock_apply2.assert_awaited_once()
        resolve_kwargs = mock_apply2.call_args.kwargs

        assert normal_kwargs["account_id"] == resolve_kwargs["account_id"] == ACCOUNT_ID
        assert normal_kwargs["plan"] == resolve_kwargs["plan"] == "avanzado"
        assert normal_kwargs["preapproval_id"] == resolve_kwargs["preapproval_id"] == PREAPPROVAL_ID
        assert normal_kwargs["authorized_payment_id"] == resolve_kwargs["authorized_payment_id"] == "ap-1"
        assert normal_kwargs["mercadopago_payment_id"] == resolve_kwargs["mercadopago_payment_id"] == "mp-payment-1"
        assert normal_kwargs["amount"] == resolve_kwargs["amount"] == 34900
        assert normal_kwargs["plan_expires_at"] == resolve_kwargs["plan_expires_at"]
        assert normal_kwargs["plan_expires_at"] == (
            datetime.datetime(2026, 9, 1, tzinfo=datetime.timezone.utc) + GRACE_PERIOD
        )

        # limpia el marcador de pendiente una vez replicado
        repo2.clear_pending_charge.assert_awaited_once_with(PREAPPROVAL_ID)


# ── H4 hotfix (2026-09-04) — atomicidad + normalización de `amount` ────────
# Caso real: subscriptions.id fa624f9b-32e5-4b5c-ad0d-fc64e6dc16b1, pago MP
# 176341057469 ($24.900). `_apply_approved_charge` reventaba con sqlstate
# 42P18 ("could not determine data type of parameter") en el INSERT de
# email_logs — `amount`/`plan_expires_at` viajaban SIN cast dentro de
# jsonb_build_object(VARIADIC "any"), el único lugar de la sentencia donde
# aparecían. Sin transacción (get_service_conn entrega autocommit), eso dejó
# accounts/billing_events escritos pero el correo de renovación nunca se
# encoló — aplicación PARCIAL, verificada con SELECT contra prod.

class TestApplyApprovedChargeAtomicityAndAmountNormalization:
    @pytest.mark.asyncio
    async def test_wraps_the_three_writes_in_a_transaction(self):
        """GREEN: las 3 escrituras (UPDATE accounts, INSERT billing_events,
        INSERT email_logs) corren dentro de `async with conn.transaction()`
        — o las 3, o ninguna."""
        conn = _mock_conn()
        await _apply_approved_charge(
            conn,
            account_id=ACCOUNT_ID,
            plan="inicial",
            preapproval_id=PREAPPROVAL_ID,
            authorized_payment_id="ap-1",
            mercadopago_payment_id="mp-1",
            amount=24900,
            plan_expires_at=datetime.datetime(2026, 10, 1, tzinfo=datetime.timezone.utc),
        )
        conn.transaction.assert_called_once()
        assert conn.execute.await_count == 3

    @pytest.mark.asyncio
    async def test_normalizes_float_amount_to_decimal_via_str(self):
        """RED/GREEN: MercadoPago manda `transaction_amount` como número
        JSON — si trae decimales, Python's json lo deserializa como
        `float`. Se normaliza vía `Decimal(str(...))` (no `Decimal(float)`
        directo, que arrastraría el ruido binario del float) antes de
        bindearlo a una columna `numeric`."""
        conn = _mock_conn()
        await _apply_approved_charge(
            conn,
            account_id=ACCOUNT_ID,
            plan="inicial",
            preapproval_id=PREAPPROVAL_ID,
            authorized_payment_id="ap-1",
            mercadopago_payment_id="mp-1",
            amount=24900.5,
            plan_expires_at=None,
        )
        billing_event_call = next(
            c for c in conn.execute.call_args_list if "subscription_payment_approved" in c.args[0]
        )
        amount_arg = billing_event_call.args[-1]
        assert isinstance(amount_arg, decimal.Decimal)
        assert amount_arg == decimal.Decimal("24900.5")

    @pytest.mark.asyncio
    async def test_normalizes_int_amount_to_decimal(self):
        """TRIANGULATE: un `int` (caso real: 24900, sin decimales) también
        se normaliza a Decimal — no solo el caso float."""
        conn = _mock_conn()
        await _apply_approved_charge(
            conn,
            account_id=ACCOUNT_ID,
            plan="inicial",
            preapproval_id=PREAPPROVAL_ID,
            authorized_payment_id="ap-1",
            mercadopago_payment_id="mp-1",
            amount=24900,
            plan_expires_at=None,
        )
        billing_event_call = next(
            c for c in conn.execute.call_args_list if "subscription_payment_approved" in c.args[0]
        )
        amount_arg = billing_event_call.args[-1]
        assert isinstance(amount_arg, decimal.Decimal)
        assert amount_arg == decimal.Decimal("24900")

    @pytest.mark.asyncio
    async def test_none_amount_stays_none(self):
        """TRIANGULATE: un amount ausente no explota (Decimal(str(None))
        rompería) — se deja pasar tal cual."""
        conn = _mock_conn()
        await _apply_approved_charge(
            conn,
            account_id=ACCOUNT_ID,
            plan="inicial",
            preapproval_id=PREAPPROVAL_ID,
            authorized_payment_id="ap-1",
            mercadopago_payment_id="mp-1",
            amount=None,
            plan_expires_at=None,
        )
        billing_event_call = next(
            c for c in conn.execute.call_args_list if "subscription_payment_approved" in c.args[0]
        )
        assert billing_event_call.args[-1] is None

    @pytest.mark.asyncio
    async def test_already_decimal_amount_is_left_untouched(self):
        """TRIANGULATE: `resolve_ambiguous_subscription` pasa `pending["amount"]`,
        que ya viene de una columna `numeric` leída por asyncpg (siempre
        `Decimal`, nunca int/float) — no debe re-envolverse ni perder
        precisión."""
        conn = _mock_conn()
        original = decimal.Decimal("24900.50")
        await _apply_approved_charge(
            conn,
            account_id=ACCOUNT_ID,
            plan="inicial",
            preapproval_id=PREAPPROVAL_ID,
            authorized_payment_id="ap-1",
            mercadopago_payment_id="mp-1",
            amount=original,
            plan_expires_at=None,
        )
        billing_event_call = next(
            c for c in conn.execute.call_args_list if "subscription_payment_approved" in c.args[0]
        )
        assert billing_event_call.args[-1] is original


# ── fix(billing) 2026-10-13 — contrato de las sentencias de una cuota ──────
# Candados de texto sobre el SQL (los mocks no ejecutan Postgres): el
# comportamiento real lo prueba
# test_subscriptions_webhook_handlers_integration.py, que no corre en CI.
# Estos fijan, en la suite que SÍ corre, las dos cláusulas de las que
# depende.

class TestApplyApprovedChargeStatements:
    async def _statements(self, plan_expires_at=None) -> dict[str, str]:
        conn = _mock_conn()
        await _apply_approved_charge(
            conn,
            account_id=ACCOUNT_ID,
            plan="inicial",
            preapproval_id=PREAPPROVAL_ID,
            authorized_payment_id="7032577415",
            mercadopago_payment_id="182393490148",
            amount=24900,
            plan_expires_at=plan_expires_at,
        )
        sqls = [c.args[0] for c in conn.execute.call_args_list]
        return {
            "accounts": next(s for s in sqls if "UPDATE public.accounts" in s),
            "email": next(s for s in sqls if "INSERT INTO public.email_logs" in s),
        }

    @pytest.mark.asyncio
    async def test_missing_expiry_never_erases_the_account_expiry(self):
        """Sin siguiente ciclo, `plan_expires_at` llega None. Escribirlo tal
        cual lo dejaría NULL — "sin vencimiento" para `get_effective_plan`:
        una cuenta paga para siempre. La sentencia conserva el valor
        previo."""
        statements = await self._statements(plan_expires_at=None)
        assert "plan_expires_at = COALESCE($2, plan_expires_at)" in statements["accounts"]

    @pytest.mark.asyncio
    async def test_renewal_email_is_deduplicated_per_cuota(self):
        """El correo se encola una vez por cuota (`authorized_payment_id`),
        no una vez por metadata: la metadata incluye `plan_expires_at`, y el
        replay reaplica cuotas viejas con el vencimiento del ciclo vigente —
        deduplicar por la metadata completa mandaba un segundo correo de
        renovación por el mismo cobro."""
        statements = await self._statements()
        email_sql = " ".join(statements["email"].split())
        assert "AND NOT EXISTS ( SELECT 1 FROM public.email_logs sent" in email_sql
        assert "sent.event_type = 'subscription_payment_approved'" in email_sql
        assert "sent.metadata ->> 'authorized_payment_id' = $3::text" in email_sql


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
                    "next_payment_date": None, "amount": None,
                    "pending_authorized_payment_id": None, "pending_mercadopago_payment_id": None,
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
        # sin cobro pendiente guardado — nada que replicar (H3)
        repo.clear_pending_charge.assert_not_awaited()

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
                    "next_payment_date": None, "amount": None,
                    "pending_authorized_payment_id": None, "pending_mercadopago_payment_id": None,
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
                    "next_payment_date": None, "amount": None,
                    "pending_authorized_payment_id": None, "pending_mercadopago_payment_id": None,
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

    # ── H3 hotfix (2026-09-04) — replay del cobro pendiente al resolver ────
    # Caso real: fa624f9b-32e5-4b5c-ad0d-fc64e6dc16b1 cobró $24.900 mientras
    # ambigua y ese dinero nunca se reflejó en accounts.plan_expires_at ni en
    # billing_events/email_logs al resolverla — el docstring viejo asumía
    # que el dinero "YA se acreditó en billing_events", falso en este caso.

    @pytest.mark.asyncio
    async def test_resolve_replays_pending_charge_extends_expiry_and_audits(self):
        """RED (TDD b): si la fila ambigua tiene un cobro pendiente
        guardado (H3), resolver debe extender accounts.plan_expires_at
        (next_payment_date + GRACE_PERIOD), auditar en billing_events y
        encolar el correo de renovación — los MISMOS tres efectos que el
        camino normal, ADEMÁS de los de subscription_ambiguous_resolved."""
        next_payment_date = datetime.datetime(2026, 10, 1, tzinfo=datetime.timezone.utc)
        repo = _mock_repo(
            find_ambiguous_subscription=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "preapproval_id": PREAPPROVAL_ID,
                    "preapproval_plan_id": PLAN_ID, "plan": "inicial", "status": "ambiguous",
                    "next_payment_date": next_payment_date, "amount": 24900,
                    "pending_authorized_payment_id": "7031580844",
                    "pending_mercadopago_payment_id": "176341057469",
                }
            ),
            resolve_ambiguous_subscription=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "account_id": ACCOUNT_ID,
                    "preapproval_id": PREAPPROVAL_ID, "plan": "inicial", "status": "authorized",
                }
            ),
        )
        conn = _mock_conn()

        with patch("backend.services.subscriptions.settings.mp_plan_id_inicial", PLAN_ID):
            result = await resolve_ambiguous_subscription(SUBSCRIPTION_ID, ACCOUNT_ID, repo, conn)

        assert result == {"ok": True}
        sqls = [c.args[0] for c in conn.execute.call_args_list]
        assert any("subscription_payment_approved" in s for s in sqls)
        assert any("subscription_ambiguous_resolved" in s for s in sqls)

        expiry_call = next(c for c in conn.execute.call_args_list if "SET plan_expires_at" in c.args[0])
        assert expiry_call.args[2] == next_payment_date + GRACE_PERIOD

        billing_event_call = next(
            c for c in conn.execute.call_args_list if "subscription_payment_approved" in c.args[0]
        )
        assert "7031580844" in billing_event_call.args
        assert "176341057469" in billing_event_call.args

        email_call = next(
            c for c in conn.execute.call_args_list
            if "email_logs" in c.args[0] and "subscription_payment_approved" in c.args[0]
        )
        assert "7031580844" in email_call.args

        repo.clear_pending_charge.assert_awaited_once_with(PREAPPROVAL_ID)

    @pytest.mark.asyncio
    async def test_resolve_without_pending_charge_does_not_replay_anything(self):
        """TRIANGULATE (TDD b): una fila ambigua SIN cobro pendiente (nunca
        llegó ninguna cuota mientras estaba sin dueño) no dispara ningún
        efecto de dinero extra — solo lo de subscription_ambiguous_resolved,
        exactamente igual que antes de este hotfix."""
        repo = _mock_repo(
            find_ambiguous_subscription=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "preapproval_id": PREAPPROVAL_ID,
                    "preapproval_plan_id": PLAN_ID, "plan": "avanzado", "status": "ambiguous",
                    "next_payment_date": None, "amount": None,
                    "pending_authorized_payment_id": None, "pending_mercadopago_payment_id": None,
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
        assert not any("subscription_payment_approved" in s for s in sqls)
        repo.clear_pending_charge.assert_not_awaited()


# ── H3 hotfix (2026-09-04) — POST /payments/subscriptions/{id}/replay-charges ──
# Reparación puntual para el caso ya resuelto ANTES de este fix (fa624f9b-...):
# nada quedó guardado en la fila, así que hace falta reconstruir desde MP.

class TestReplaySubscriptionCharges:
    def _mp_preapproval_response(self, next_payment_date="2026-11-01T00:00:00Z", status="authorized"):
        resp = MagicMock()
        resp.status_code = 200
        resp.json.return_value = {"status": status, "next_payment_date": next_payment_date}
        return resp

    def _mp_search_response(self, results):
        resp = MagicMock()
        resp.status_code = 200
        resp.json.return_value = {"results": results}
        return resp

    def _cuota(self, authorized_payment_id, mp_payment_id, amount=24900, debit_date="2026-09-01T00:00:00Z"):
        return {
            "id": authorized_payment_id,
            "status": "processed",
            "payment": {"id": mp_payment_id, "status": "approved"},
            "transaction_amount": amount,
            "debit_date": debit_date,
        }

    @pytest.mark.asyncio
    async def test_404_when_subscription_does_not_exist(self):
        repo = _mock_repo(find_subscription_by_id=AsyncMock(return_value=None))
        conn = _mock_conn()

        with pytest.raises(HTTPException) as exc:
            await replay_subscription_charges(SUBSCRIPTION_ID, repo, conn)
        assert exc.value.status_code == 404

    @pytest.mark.asyncio
    async def test_409_when_subscription_still_has_no_account(self):
        """No tiene sentido reproducir cobros contra una cuenta que todavía
        no existe — hay que resolver la ambigüedad primero."""
        repo = _mock_repo(
            find_subscription_by_id=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "account_id": None, "preapproval_id": PREAPPROVAL_ID,
                    "plan": "inicial",
                }
            )
        )
        conn = _mock_conn()

        with pytest.raises(HTTPException) as exc:
            await replay_subscription_charges(SUBSCRIPTION_ID, repo, conn)
        assert exc.value.status_code == 409

    @pytest.mark.asyncio
    async def test_applies_unapplied_approved_cuota_from_mp(self):
        """RED (TDD c): reconstruye desde la API real de MP — busca TODAS
        las cuotas del preapproval, y aplica _apply_approved_charge para la
        que todavía no tiene billing_event. Caso real: fa624f9b-...,
        cuota 7031580844 / pago MP 176341057469 / $24.900."""
        repo = _mock_repo(
            find_subscription_by_id=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "account_id": ACCOUNT_ID, "preapproval_id": PREAPPROVAL_ID,
                    "plan": "inicial",
                }
            ),
            has_billing_event_for_payment=AsyncMock(return_value=False),
        )
        conn = _mock_conn()

        responses = [
            self._mp_preapproval_response(),
            self._mp_search_response([self._cuota("7031580844", "176341057469")]),
        ]
        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, side_effect=responses):
            result = await replay_subscription_charges(SUBSCRIPTION_ID, repo, conn)

        assert result["applied"] == ["7031580844"]
        assert result["already_applied"] == []
        sqls = [c.args[0] for c in conn.execute.call_args_list]
        assert any("subscription_payment_approved" in s for s in sqls)
        billing_event_call = next(c for c in conn.execute.call_args_list if "subscription_payment_approved" in c.args[0])
        assert "176341057469" in billing_event_call.args

    @pytest.mark.asyncio
    async def test_second_run_completes_partial_state_reports_already_applied(self):
        """H4 hotfix (2026-09-04) — RED (TDD b): antes de este fix, correr el
        replay una segunda vez sobre una cuota que YA tiene billing_event la
        reportaba como `skipped` y NUNCA volvía a llamar a
        `_apply_approved_charge` — así que si la primera corrida había
        quedado PARCIAL (el caso real: accounts/billing_events escritos,
        pero el email_logs de renovación nunca se encoló porque
        `_apply_approved_charge` reventaba con 42P18 a mitad de camino), una
        segunda corrida NO podía completarla. Ahora SIEMPRE se reaplica
        (idempotente vía ON CONFLICT DO NOTHING) y se reporta como
        `already_applied`, no `applied` — pero SÍ vuelve a ejecutar las 3
        escrituras, incluida la del email."""
        repo = _mock_repo(
            find_subscription_by_id=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "account_id": ACCOUNT_ID, "preapproval_id": PREAPPROVAL_ID,
                    "plan": "inicial",
                }
            ),
            has_billing_event_for_payment=AsyncMock(return_value=True),
        )
        conn = _mock_conn()

        responses = [
            self._mp_preapproval_response(),
            self._mp_search_response([self._cuota("7031580844", "176341057469")]),
        ]
        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, side_effect=responses):
            result = await replay_subscription_charges(SUBSCRIPTION_ID, repo, conn)

        assert result["applied"] == []
        assert result["already_applied"] == ["7031580844"]
        sqls = [c.args[0] for c in conn.execute.call_args_list]
        assert any("subscription_payment_approved" in s for s in sqls)
        assert any("INSERT INTO public.email_logs" in s for s in sqls)
        repo.clear_pending_charge.assert_awaited_once_with(PREAPPROVAL_ID)

    @pytest.mark.asyncio
    async def test_ignores_cuotas_that_are_not_processed_approved(self):
        """TRIANGULATE (TDD c): una cuota scheduled/recycling o con pago
        rechazado no se aplica — solo processed+approved mueve dinero."""
        repo = _mock_repo(
            find_subscription_by_id=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "account_id": ACCOUNT_ID, "preapproval_id": PREAPPROVAL_ID,
                    "plan": "inicial",
                }
            )
        )
        conn = _mock_conn()

        pending_cuota = {"id": "future-1", "status": "scheduled", "payment": {}}
        rejected_cuota = {"id": "rej-1", "status": "processed", "payment": {"id": "mp-2", "status": "rejected"}}
        responses = [
            self._mp_preapproval_response(),
            self._mp_search_response([pending_cuota, rejected_cuota]),
        ]
        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, side_effect=responses):
            result = await replay_subscription_charges(SUBSCRIPTION_ID, repo, conn)

        assert result["applied"] == []
        assert result["already_applied"] == []

    @pytest.mark.asyncio
    async def test_mp_error_on_preapproval_lookup_raises_502(self):
        repo = _mock_repo(
            find_subscription_by_id=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "account_id": ACCOUNT_ID, "preapproval_id": PREAPPROVAL_ID,
                    "plan": "inicial",
                }
            )
        )
        conn = _mock_conn()
        error_resp = MagicMock()
        error_resp.status_code = 500

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, return_value=error_resp):
            with pytest.raises(HTTPException) as exc:
                await replay_subscription_charges(SUBSCRIPTION_ID, repo, conn)
        assert exc.value.status_code == 502

    @pytest.mark.asyncio
    async def test_mp_error_on_authorized_payments_search_raises_502(self):
        """TRIANGULATE (TDD c): la PRIMERA llamada (preapproval) puede
        salir bien y la SEGUNDA (búsqueda de cuotas) fallar — también debe
        cortar con 502, sin aplicar nada."""
        repo = _mock_repo(
            find_subscription_by_id=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "account_id": ACCOUNT_ID, "preapproval_id": PREAPPROVAL_ID,
                    "plan": "inicial",
                }
            )
        )
        conn = _mock_conn()
        error_resp = MagicMock()
        error_resp.status_code = 500
        responses = [self._mp_preapproval_response(), error_resp]

        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, side_effect=responses):
            with pytest.raises(HTTPException) as exc:
                await replay_subscription_charges(SUBSCRIPTION_ID, repo, conn)
        assert exc.value.status_code == 502
        conn.execute.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_expiry_comes_from_the_preapproval_next_cycle_not_from_each_cuota(self):
        """fix(billing) 2026-10-13 (defecto 2): el replay calculaba el
        vencimiento por cuota (`debit_date` + gracia), así que reproducir la
        cuota del 01-09 dejaba el plan venciendo el 11-09. Mismo criterio
        que el webhook: siguiente ciclo del preapproval + gracia, para
        todas las cuotas."""
        repo = _mock_repo(
            find_subscription_by_id=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "account_id": ACCOUNT_ID, "preapproval_id": PREAPPROVAL_ID,
                    "plan": "inicial",
                }
            )
        )
        conn = _mock_conn()
        responses = [
            self._mp_preapproval_response(next_payment_date="2026-11-04T16:54:19.000-04:00"),
            self._mp_search_response([
                self._cuota("7031580844", "176341057469", debit_date="2026-09-04T16:54:19.000-04:00"),
                self._cuota("7032577415", "182393490148", debit_date="2026-10-04T17:02:30.000-04:00"),
            ]),
        ]
        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, side_effect=responses):
            result = await replay_subscription_charges(SUBSCRIPTION_ID, repo, conn)

        assert result["applied"] == ["7031580844", "7032577415"]
        next_cycle = datetime.datetime(2026, 11, 4, 20, 54, 19, tzinfo=datetime.timezone.utc)
        expiry_calls = [c for c in conn.execute.call_args_list if "SET plan_expires_at" in c.args[0]]
        assert [c.args[2] for c in expiry_calls] == [next_cycle + GRACE_PERIOD] * 2
        assert repo.update_subscription_status.call_args.kwargs["next_payment_date"] == next_cycle

    @pytest.mark.asyncio
    async def test_applies_cuota_without_next_payment_date_leaves_expiry_untouched(self):
        """TRIANGULATE: si el preapproval no informa siguiente ciclo, la
        cuota approved igual se aplica — el vencimiento queda sin extender
        (None → COALESCE conserva el que la cuenta tenía), mismo
        comportamiento que el camino normal cuando next_payment_date
        falta. Tampoco se deriva del `debit_date` de la cuota."""
        repo = _mock_repo(
            find_subscription_by_id=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "account_id": ACCOUNT_ID, "preapproval_id": PREAPPROVAL_ID,
                    "plan": "inicial",
                }
            )
        )
        conn = _mock_conn()
        responses = [
            self._mp_preapproval_response(next_payment_date=None),
            self._mp_search_response([self._cuota("7031580844", "176341057469")]),
        ]
        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, side_effect=responses):
            result = await replay_subscription_charges(SUBSCRIPTION_ID, repo, conn)

        assert result["applied"] == ["7031580844"]
        expiry_call = next(c for c in conn.execute.call_args_list if "SET plan_expires_at" in c.args[0])
        assert "plan_expires_at = COALESCE($2, plan_expires_at)" in expiry_call.args[0]
        assert expiry_call.args[2] is None

    # ── item B (3), residuo (d) de mp-real-subscriptions ───────────────────
    # El replay sincroniza last_payment_status con el estado de la ÚLTIMA
    # cuota (por fecha) — visible después en /facturacion.

    @pytest.mark.asyncio
    async def test_syncs_last_payment_status_approved_from_latest_cuota(self):
        """RED: la última cuota (por fecha/id) está processed+approved →
        last_payment_status='approved'."""
        repo = _mock_repo(
            find_subscription_by_id=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "account_id": ACCOUNT_ID, "preapproval_id": PREAPPROVAL_ID,
                    "plan": "inicial",
                }
            )
        )
        conn = _mock_conn()
        responses = [
            self._mp_preapproval_response(),
            self._mp_search_response([
                self._cuota("7031580844", "176341057469", debit_date="2026-08-01T00:00:00Z"),
                self._cuota("7031580900", "176341057999", debit_date="2026-09-01T00:00:00Z"),
            ]),
        ]
        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, side_effect=responses):
            await replay_subscription_charges(SUBSCRIPTION_ID, repo, conn)

        repo.update_subscription_status.assert_awaited_once()
        kwargs = repo.update_subscription_status.call_args.kwargs
        assert kwargs["last_payment_status"] == "approved"

    @pytest.mark.asyncio
    async def test_syncs_last_payment_status_from_rejected_latest_cuota(self):
        """TRIANGULATE: si la ÚLTIMA cuota (por fecha) no está aprobada, se
        guarda el status del pago (con reserva en el de la cuota) — misma
        regla que el webhook de cuotas, nunca 'approved' inventado."""
        repo = _mock_repo(
            find_subscription_by_id=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "account_id": ACCOUNT_ID, "preapproval_id": PREAPPROVAL_ID,
                    "plan": "inicial",
                }
            )
        )
        conn = _mock_conn()
        rejected_cuota = {
            "id": "7031580999", "status": "processed",
            "payment": {"id": "mp-rejected", "status": "rejected"},
            "transaction_amount": 24900, "debit_date": "2026-09-01T00:00:00Z",
        }
        responses = [
            self._mp_preapproval_response(),
            self._mp_search_response([
                self._cuota("7031580844", "176341057469", debit_date="2026-08-01T00:00:00Z"),
                rejected_cuota,
            ]),
        ]
        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, side_effect=responses):
            await replay_subscription_charges(SUBSCRIPTION_ID, repo, conn)

        kwargs = repo.update_subscription_status.call_args.kwargs
        assert kwargs["last_payment_status"] == "rejected"

    @pytest.mark.asyncio
    async def test_last_payment_status_ignores_trailing_scheduled_cuota(self):
        """RED (F1, revisor adversarial tanda6): una cuota `scheduled`
        (cobro futuro, todavía no ocurrido) al final de la lista (orden por
        id ascendente) NO debe pisar el último cobro REAL ('approved') —
        scheduled no representa ningún intento de cobro. Antes de este fix,
        [approved, scheduled] dejaba last_payment_status='scheduled' sobre
        un 'approved' correcto."""
        repo = _mock_repo(
            find_subscription_by_id=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "account_id": ACCOUNT_ID, "preapproval_id": PREAPPROVAL_ID,
                    "plan": "inicial",
                }
            )
        )
        conn = _mock_conn()
        scheduled_cuota = {
            "id": "7031580900", "status": "scheduled", "payment": {},
            "transaction_amount": 24900, "debit_date": "2026-10-01T00:00:00Z",
        }
        responses = [
            self._mp_preapproval_response(),
            self._mp_search_response([
                self._cuota("7031580844", "176341057469", debit_date="2026-09-01T00:00:00Z"),
                scheduled_cuota,
            ]),
        ]
        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, side_effect=responses):
            await replay_subscription_charges(SUBSCRIPTION_ID, repo, conn)

        kwargs = repo.update_subscription_status.call_args.kwargs
        assert kwargs["last_payment_status"] == "approved"

    @pytest.mark.asyncio
    async def test_syncs_last_payment_status_none_when_no_cuotas(self):
        """TRIANGULATE: sin ninguna cuota no hay nada que derivar —
        update_subscription_status recibe None y su propio COALESCE evita
        pisar un valor previo."""
        repo = _mock_repo(
            find_subscription_by_id=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "account_id": ACCOUNT_ID, "preapproval_id": PREAPPROVAL_ID,
                    "plan": "inicial",
                }
            )
        )
        conn = _mock_conn()
        responses = [self._mp_preapproval_response(), self._mp_search_response([])]
        with patch("httpx.AsyncClient.get", new_callable=AsyncMock, side_effect=responses):
            await replay_subscription_charges(SUBSCRIPTION_ID, repo, conn)

        kwargs = repo.update_subscription_status.call_args.kwargs
        assert kwargs["last_payment_status"] is None


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


# ── Descartar (residuo (b) de mp-real-subscriptions) — admin-only ──────────

ADMIN_USER_ID = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"


class TestDiscardAmbiguousSubscription:
    @pytest.mark.asyncio
    async def test_404_when_nothing_to_discard(self):
        """RED: sin fila ambigua sin cuenta que descartar → 404, NUNCA
        toca audit_logs (default de _mock_repo: None)."""
        repo = _mock_repo()
        conn = _mock_conn()

        with pytest.raises(HTTPException) as exc:
            await discard_ambiguous_subscription(SUBSCRIPTION_ID, ADMIN_USER_ID, None, repo, conn)
        assert exc.value.status_code == 404
        conn.execute.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_discards_and_audits_without_touching_accounts_or_billing_events(self):
        """GREEN: descartar audita en audit_logs — y NUNCA en accounts ni
        billing_events (a diferencia de resolve_ambiguous_subscription:
        esto no asigna ninguna cuenta ni activa ningún plan)."""
        repo = _mock_repo(
            discard_ambiguous_subscription=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "preapproval_id": PREAPPROVAL_ID,
                    "preapproval_plan_id": PLAN_ID, "plan": "pro", "amount": None,
                    "pending_authorized_payment_id": None, "pending_mercadopago_payment_id": None,
                    "ambiguous_reason_before": "no_match",
                }
            ),
        )
        conn = _mock_conn()

        result = await discard_ambiguous_subscription(
            SUBSCRIPTION_ID, ADMIN_USER_ID, "cuenta cancelada en MP", repo, conn
        )

        assert result == {"id": SUBSCRIPTION_ID, "status": "cancelled"}
        conn.execute.assert_awaited_once()
        sql, *args = conn.execute.call_args.args
        assert "INSERT INTO public.audit_logs" in sql
        assert "subscription.ambiguous_discarded" in sql
        assert ADMIN_USER_ID in args
        assert SUBSCRIPTION_ID in args
        # nunca toca accounts ni billing_events
        assert "accounts" not in sql
        assert "billing_events" not in sql

    @pytest.mark.asyncio
    async def test_audit_metadata_includes_reason_and_previous_ambiguous_reason(self):
        """TRIANGULATE: el motivo del admin Y el ambiguous_reason previo
        (capturado por el repo antes del UPDATE) viajan en el jsonb de
        auditoría — ambos se pierden si no se guardan acá."""
        repo = _mock_repo(
            discard_ambiguous_subscription=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "preapproval_id": PREAPPROVAL_ID,
                    "preapproval_plan_id": PLAN_ID, "plan": "pro", "amount": decimal.Decimal("4999.00"),
                    "pending_authorized_payment_id": None, "pending_mercadopago_payment_id": None,
                    "ambiguous_reason_before": "multiple_match",
                }
            ),
        )
        conn = _mock_conn()

        await discard_ambiguous_subscription(SUBSCRIPTION_ID, ADMIN_USER_ID, "duplicado", repo, conn)

        metadata_arg = conn.execute.call_args.args[-1]
        metadata = json.loads(metadata_arg)
        assert metadata["reason"] == "duplicado"
        assert metadata["ambiguous_reason_before"] == "multiple_match"
        assert metadata["preapproval_id"] == PREAPPROVAL_ID
        assert metadata["amount"] == 4999.00

    @pytest.mark.asyncio
    async def test_reason_none_is_accepted(self):
        """TRIANGULATE: el motivo es opcional — None no rompe el INSERT."""
        repo = _mock_repo(
            discard_ambiguous_subscription=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "preapproval_id": PREAPPROVAL_ID,
                    "preapproval_plan_id": PLAN_ID, "plan": "pro", "amount": None,
                    "pending_authorized_payment_id": None, "pending_mercadopago_payment_id": None,
                    "ambiguous_reason_before": "no_match",
                }
            ),
        )
        conn = _mock_conn()

        result = await discard_ambiguous_subscription(SUBSCRIPTION_ID, ADMIN_USER_ID, None, repo, conn)

        assert result == {"id": SUBSCRIPTION_ID, "status": "cancelled"}
        metadata = json.loads(conn.execute.call_args.args[-1])
        assert metadata["reason"] is None

    @pytest.mark.asyncio
    async def test_failure_in_audit_insert_propagates_and_is_wrapped_in_a_transaction(self):
        """RED (F4, revisor adversarial tanda6): si el INSERT de audit_logs
        revienta, el error se propaga (no se traga en un 500 silencioso
        dejando el UPDATE de descarte ya comiteado) Y las dos escrituras
        corren dentro de la MISMA transacción — así el UPDATE se revierte
        en vez de quedar aplicado sin ninguna traza de quién lo hizo."""
        repo = _mock_repo(
            discard_ambiguous_subscription=AsyncMock(
                return_value={
                    "id": SUBSCRIPTION_ID, "preapproval_id": PREAPPROVAL_ID,
                    "preapproval_plan_id": PLAN_ID, "plan": "pro", "amount": None,
                    "pending_authorized_payment_id": None, "pending_mercadopago_payment_id": None,
                    "ambiguous_reason_before": "no_match",
                }
            ),
        )
        conn = _mock_conn()
        conn.execute = AsyncMock(side_effect=RuntimeError("boom"))

        with pytest.raises(RuntimeError, match="boom"):
            await discard_ambiguous_subscription(SUBSCRIPTION_ID, ADMIN_USER_ID, "motivo", repo, conn)

        conn.transaction.assert_called_once()


# ── "Suscripciones recientes" (residuo (c)) ─────────────────────────────────

class TestListRecentSubscriptions:
    @pytest.mark.asyncio
    async def test_converts_records_to_dicts_at_the_boundary(self):
        """RED: mismo patrón que list_ambiguous_subscriptions/search_accounts
        — convierte a dict en el borde del servicio (asyncpg.Record no
        soporta getattr(), que es lo que usa un modelo Pydantic
        from_attributes=True cuando el valor no es un dict/Mapping)."""
        repo = _mock_repo(
            list_recent_subscriptions=AsyncMock(
                return_value=[
                    {"id": SUBSCRIPTION_ID, "plan": "pro", "status": "authorized"},
                ]
            )
        )

        result = await list_recent_subscriptions(20, repo)

        assert result == [{"id": SUBSCRIPTION_ID, "plan": "pro", "status": "authorized"}]
        repo.list_recent_subscriptions.assert_awaited_once_with(20)

    @pytest.mark.asyncio
    async def test_empty_list_stays_empty(self):
        """TRIANGULATE: sin filas, devuelve []."""
        repo = _mock_repo(list_recent_subscriptions=AsyncMock(return_value=[]))

        result = await list_recent_subscriptions(20, repo)

        assert result == []
