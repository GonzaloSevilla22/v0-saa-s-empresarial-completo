"""
mp-real-subscriptions — SubscriptionsRepository TDD tests (task 6.1 RED /
6.2 GREEN). Mismo patrón que test_client_address_repository.py: asyncpg
mockeado, se verifica el SQL vía call_args y el comportamiento vía el valor
de retorno. No toca una DB real.
"""
from __future__ import annotations

from unittest.mock import AsyncMock

import pytest

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
SUBSCRIPTION_ID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
INTENT_ID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
PREAPPROVAL_ID = "mp-preapproval-XYZ123"
PLAN_ID = "mp-plan-abc"


@pytest.fixture
def subs_repo():
    from backend.repositories.subscriptions_repository import SubscriptionsRepository

    conn = AsyncMock()
    return SubscriptionsRepository(conn), conn


# ── subscription_intents ────────────────────────────────────────────────────

class TestCreateIntent:
    @pytest.mark.asyncio
    async def test_create_intent_normalizes_email(self, subs_repo):
        """RED (6.1): el email se normaliza (lower/trim) antes de insertar —
        defensa en profundidad, la DB también lo exige via CHECK."""
        repo, conn = subs_repo
        conn.fetchrow = AsyncMock(return_value={"id": INTENT_ID})

        await repo.create_intent(ACCOUNT_ID, "  Buyer@Example.COM  ", "pro", PLAN_ID)

        args = conn.fetchrow.call_args.args
        assert args[2] == "buyer@example.com"

    @pytest.mark.asyncio
    async def test_create_intent_inserts_into_subscription_intents(self, subs_repo):
        repo, conn = subs_repo
        conn.fetchrow = AsyncMock(return_value={"id": INTENT_ID})

        await repo.create_intent(ACCOUNT_ID, "buyer@example.com", "pro", PLAN_ID)

        sql = conn.fetchrow.call_args.args[0]
        assert "INSERT INTO public.subscription_intents" in sql


class TestFindPendingIntents:
    @pytest.mark.asyncio
    async def test_finds_by_email_and_plan_pending_not_expired(self, subs_repo):
        """RED (6.1): la reconciliación busca por (payer_email,
        preapproval_plan_id, status=pending, expires_at > now())."""
        repo, conn = subs_repo
        conn.fetch = AsyncMock(return_value=[{"id": INTENT_ID, "account_id": ACCOUNT_ID}])

        result = await repo.find_pending_intents("buyer@example.com", PLAN_ID)

        assert len(result) == 1
        sql = conn.fetch.call_args.args[0]
        assert "status = 'pending'" in sql
        assert "expires_at > now()" in sql

    @pytest.mark.asyncio
    async def test_find_pending_intents_normalizes_email_arg(self, subs_repo):
        repo, conn = subs_repo
        conn.fetch = AsyncMock(return_value=[])

        await repo.find_pending_intents("  Buyer@Example.COM  ", PLAN_ID)

        args = conn.fetch.call_args.args
        assert args[1] == "buyer@example.com"


class TestMarkIntentMatched:
    @pytest.mark.asyncio
    async def test_mark_matched_only_touches_pending_rows(self, subs_repo):
        repo, conn = subs_repo
        conn.execute = AsyncMock(return_value="UPDATE 1")

        result = await repo.mark_intent_matched(INTENT_ID, SUBSCRIPTION_ID)

        assert result is True
        sql = conn.execute.call_args.args[0]
        assert "status = 'pending'" in sql

    @pytest.mark.asyncio
    async def test_mark_matched_returns_false_when_no_row_affected(self, subs_repo):
        """TRIANGULATE: una intención ya matcheada (o inexistente) no
        afecta filas — el caller debe poder distinguir éxito de no-op."""
        repo, conn = subs_repo
        conn.execute = AsyncMock(return_value="UPDATE 0")

        result = await repo.mark_intent_matched(INTENT_ID, SUBSCRIPTION_ID)

        assert result is False


# ── subscriptions ─────────────────────────────────────────────────────────

class TestFindLiveSubscription:
    @pytest.mark.asyncio
    async def test_filters_by_pending_or_authorized(self, subs_repo):
        repo, conn = subs_repo
        conn.fetchrow = AsyncMock(return_value=None)

        result = await repo.find_live_subscription(ACCOUNT_ID)

        assert result is None
        sql = conn.fetchrow.call_args.args[0]
        assert "status IN ('pending', 'authorized')" in sql


class TestCreateSubscription:
    @pytest.mark.asyncio
    async def test_create_subscription_ambiguous_has_no_account_id(self, subs_repo):
        """RED (6.7 fundamento): una fila ambigua nace con account_id=None."""
        repo, conn = subs_repo
        conn.fetchrow = AsyncMock(return_value={"id": SUBSCRIPTION_ID, "account_id": None})

        await repo.create_subscription(
            account_id=None,
            preapproval_id=PREAPPROVAL_ID,
            preapproval_plan_id=PLAN_ID,
            plan="pro",
            status="ambiguous",
            ambiguous_reason="no_match",
        )

        args = conn.fetchrow.call_args.args
        assert args[1] is None  # account_id
        assert args[6] == "no_match"  # ambiguous_reason

    @pytest.mark.asyncio
    async def test_create_subscription_is_idempotent_on_conflict(self, subs_repo):
        """TRIANGULATE: redelivery de la misma notificación no debe crear
        una segunda fila para el mismo preapproval_id — ON CONFLICT DO
        NOTHING sobre el UNIQUE de preapproval_id."""
        repo, conn = subs_repo
        conn.fetchrow = AsyncMock(return_value={"id": SUBSCRIPTION_ID})

        await repo.create_subscription(
            account_id=ACCOUNT_ID,
            preapproval_id=PREAPPROVAL_ID,
            preapproval_plan_id=PLAN_ID,
            plan="pro",
            status="authorized",
        )

        sql = conn.fetchrow.call_args.args[0]
        assert "ON CONFLICT (preapproval_id) DO NOTHING" in sql


class TestUpdateSubscriptionStatus:
    @pytest.mark.asyncio
    async def test_update_status_by_preapproval_id(self, subs_repo):
        repo, conn = subs_repo
        conn.execute = AsyncMock(return_value="UPDATE 1")

        result = await repo.update_subscription_status(PREAPPROVAL_ID, "cancelled")

        assert result is True
        sql = conn.execute.call_args.args[0]
        assert "WHERE preapproval_id = $1" in sql


class TestAmbiguousQueue:
    @pytest.mark.asyncio
    async def test_list_ambiguous_filters_null_account_id(self, subs_repo):
        repo, conn = subs_repo
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_ambiguous_subscriptions()

        sql = conn.fetch.call_args.args[0]
        assert "status = 'ambiguous' AND account_id IS NULL" in sql

    @pytest.mark.asyncio
    async def test_resolve_ambiguous_only_touches_still_ambiguous_rows(self, subs_repo):
        """TRIANGULATE: no reasigna una fila que ya se resolvió (evita doble
        asignación por dos admins resolviendo al mismo tiempo) — devuelve
        None cuando no había nada `ambiguous` que resolver."""
        repo, conn = subs_repo
        conn.fetchrow = AsyncMock(
            return_value={"id": SUBSCRIPTION_ID, "account_id": ACCOUNT_ID, "plan": "pro", "status": "authorized"}
        )

        result = await repo.resolve_ambiguous_subscription(SUBSCRIPTION_ID, ACCOUNT_ID)

        assert result is not None
        sql = conn.fetchrow.call_args.args[0]
        assert "WHERE id = $1 AND status = 'ambiguous'" in sql

    @pytest.mark.asyncio
    async def test_resolve_ambiguous_returns_none_when_already_resolved(self, subs_repo):
        repo, conn = subs_repo
        conn.fetchrow = AsyncMock(return_value=None)

        result = await repo.resolve_ambiguous_subscription(SUBSCRIPTION_ID, ACCOUNT_ID)

        assert result is None

    @pytest.mark.asyncio
    async def test_resolve_ambiguous_returns_preapproval_plan_id(self, subs_repo):
        """H2 hotfix (2026-09-04): el caller necesita preapproval_plan_id
        de la fila resuelta para derivar el tier real (nunca confiar en el
        `plan` guardado tal cual)."""
        repo, conn = subs_repo
        conn.fetchrow = AsyncMock(
            return_value={
                "id": SUBSCRIPTION_ID, "account_id": ACCOUNT_ID,
                "preapproval_id": PREAPPROVAL_ID, "preapproval_plan_id": PLAN_ID,
                "plan": "pro", "status": "authorized",
            }
        )

        result = await repo.resolve_ambiguous_subscription(SUBSCRIPTION_ID, ACCOUNT_ID)

        assert result["preapproval_plan_id"] == PLAN_ID
        sql = conn.fetchrow.call_args.args[0]
        assert "preapproval_plan_id" in sql


class TestFindAmbiguousSubscription:
    @pytest.mark.asyncio
    async def test_finds_by_id_only_when_still_ambiguous(self, subs_repo):
        """H2 hotfix: lookup PREVIO a resolver — permite derivar y validar
        el tier ANTES de tocar account_id/status, para no dejar la fila a
        medio resolver si el preapproval_plan_id no mapea a ningún tier."""
        repo, conn = subs_repo
        conn.fetchrow = AsyncMock(
            return_value={
                "id": SUBSCRIPTION_ID, "preapproval_id": PREAPPROVAL_ID,
                "preapproval_plan_id": PLAN_ID, "plan": "pro", "status": "ambiguous",
            }
        )

        result = await repo.find_ambiguous_subscription(SUBSCRIPTION_ID)

        assert result["preapproval_plan_id"] == PLAN_ID
        sql = conn.fetchrow.call_args.args[0]
        assert "WHERE id = $1 AND status = 'ambiguous'" in sql

    @pytest.mark.asyncio
    async def test_returns_none_when_not_ambiguous_or_missing(self, subs_repo):
        repo, conn = subs_repo
        conn.fetchrow = AsyncMock(return_value=None)

        result = await repo.find_ambiguous_subscription(SUBSCRIPTION_ID)

        assert result is None


class TestCorrectSubscriptionPlan:
    @pytest.mark.asyncio
    async def test_updates_plan_by_id(self, subs_repo):
        """H2 hotfix: corrige subscriptions.plan de una fila que había
        nacido con el tier equivocado (bug del fallback hardcodeado a
        'pro') una vez que se deriva el tier real."""
        repo, conn = subs_repo
        conn.execute = AsyncMock(return_value="UPDATE 1")

        await repo.correct_subscription_plan(SUBSCRIPTION_ID, "inicial")

        sql, *args = conn.execute.call_args.args
        assert "UPDATE public.subscriptions" in sql
        assert "SET plan = $2" in sql
        assert "WHERE id = $1" in sql
        assert args == [SUBSCRIPTION_ID, "inicial"]
