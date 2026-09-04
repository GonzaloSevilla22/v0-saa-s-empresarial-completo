from __future__ import annotations

import asyncpg

from backend.repositories.base import BaseRepository

# mp-real-subscriptions (D2bis/D4): repositorio de `subscriptions` +
# `subscription_intents`. JWT-passthrough para las lecturas del propio
# usuario (find_live_subscription al alta); las escrituras del ciclo de
# vida (webhook, reconciliación) usan la conexión de servicio del router de
# pagos — igual patrón que el resto de payments.py.


class SubscriptionsRepository(BaseRepository):
    # ── subscription_intents ────────────────────────────────────────────

    async def create_intent(
        self,
        account_id: str,
        payer_email: str,
        plan: str,
        preapproval_plan_id: str,
    ) -> asyncpg.Record:
        return await self._conn.fetchrow(
            """
            INSERT INTO public.subscription_intents
                (account_id, payer_email, plan, preapproval_plan_id)
            VALUES ($1, $2, $3, $4)
            RETURNING id, account_id, payer_email, plan, preapproval_plan_id,
                      status, expires_at, created_at
            """,
            account_id,
            payer_email.strip().lower(),
            plan,
            preapproval_plan_id,
        )

    async def find_pending_intents(
        self, payer_email: str, preapproval_plan_id: str
    ) -> list[asyncpg.Record]:
        """Candidatas para reconciliar una notificación subscription_preapproval
        (D2bis): pending, no vencidas, mismo email normalizado y mismo plan."""
        return await self._conn.fetch(
            """
            SELECT id, account_id, payer_email, plan, preapproval_plan_id, status, expires_at
            FROM public.subscription_intents
            WHERE payer_email = $1
              AND preapproval_plan_id = $2
              AND status = 'pending'
              AND expires_at > now()
            ORDER BY created_at ASC
            """,
            payer_email.strip().lower(),
            preapproval_plan_id,
        )

    async def mark_intent_matched(self, intent_id: str, subscription_id: str) -> bool:
        status = await self._conn.execute(
            """
            UPDATE public.subscription_intents
            SET status = 'matched', matched_subscription_id = $2, matched_at = now(), updated_at = now()
            WHERE id = $1 AND status = 'pending'
            """,
            intent_id,
            subscription_id,
        )
        return int(status.rsplit(" ", 1)[-1]) > 0

    # NOTA (task 6.14, superseded en PR4): el barrido de intenciones
    # `pending` vencidas → `expired` se implementó como función SQL
    # `public._expire_stale_subscription_intents()` programada por pg_cron
    # (migración `20260830000002`) — mismo patrón que `expire_trials()` /
    # `_sweep_plan_limit_exceeded()`, en vez de un método de repositorio sin
    # llamador. Ver esa migración para la lógica real.

    # ── subscriptions ─────────────────────────────────────────────────────

    async def find_live_subscription(self, account_id: str) -> asyncpg.Record | None:
        return await self._conn.fetchrow(
            """
            SELECT id, account_id, preapproval_id, preapproval_plan_id, plan, status,
                   next_payment_date, amount, currency, retry_state, created_at
            FROM public.subscriptions
            WHERE account_id = $1 AND status IN ('pending', 'authorized')
            """,
            account_id,
        )

    async def find_by_preapproval_id(self, preapproval_id: str) -> asyncpg.Record | None:
        return await self._conn.fetchrow(
            """
            SELECT id, account_id, preapproval_id, preapproval_plan_id, plan, status,
                   ambiguous_reason, next_payment_date, amount, currency, retry_state,
                   last_payment_status, created_at
            FROM public.subscriptions
            WHERE preapproval_id = $1
            """,
            preapproval_id,
        )

    async def create_subscription(
        self,
        *,
        account_id: str | None,
        preapproval_id: str,
        preapproval_plan_id: str,
        plan: str,
        status: str,
        ambiguous_reason: str | None = None,
        next_payment_date=None,
        amount=None,
        currency: str = "ARS",
        external_reference: str | None = None,
    ) -> asyncpg.Record:
        return await self._conn.fetchrow(
            """
            INSERT INTO public.subscriptions
                (account_id, preapproval_id, preapproval_plan_id, plan, status,
                 ambiguous_reason, next_payment_date, amount, currency, external_reference)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
            ON CONFLICT (preapproval_id) DO NOTHING
            RETURNING id, account_id, preapproval_id, preapproval_plan_id, plan, status,
                      ambiguous_reason, next_payment_date, amount, currency, created_at
            """,
            account_id,
            preapproval_id,
            preapproval_plan_id,
            plan,
            status,
            ambiguous_reason,
            next_payment_date,
            amount,
            currency,
            external_reference,
        )

    async def update_subscription_status(
        self,
        preapproval_id: str,
        status: str,
        *,
        next_payment_date=None,
        retry_state: str | None = None,
        last_payment_status: str | None = None,
    ) -> bool:
        result = await self._conn.execute(
            """
            UPDATE public.subscriptions
            SET status = $2,
                next_payment_date = COALESCE($3, next_payment_date),
                retry_state = COALESCE($4, retry_state),
                last_payment_status = COALESCE($5, last_payment_status),
                updated_at = now()
            WHERE preapproval_id = $1
            """,
            preapproval_id,
            status,
            next_payment_date,
            retry_state,
            last_payment_status,
        )
        return int(result.rsplit(" ", 1)[-1]) > 0

    async def list_ambiguous_subscriptions(self) -> list[asyncpg.Record]:
        return await self._conn.fetch(
            """
            SELECT id, preapproval_id, preapproval_plan_id, plan, ambiguous_reason,
                   amount, currency, created_at
            FROM public.subscriptions
            WHERE status = 'ambiguous' AND account_id IS NULL
            ORDER BY created_at ASC
            """
        )

    async def resolve_ambiguous_subscription(
        self, subscription_id: str, account_id: str, resolved_status: str = "authorized"
    ) -> asyncpg.Record | None:
        """Resolución manual (task 6.8bis): asigna account_id a una fila
        ambigua. Solo afecta filas que sigan status='ambiguous' — no
        reasigna una que ya se resolvió (evita doble asignación). Devuelve
        la fila actualizada (para poder activar el plan de la cuenta) o
        None si no había nada que resolver.

        H2 hotfix (2026-09-04): RETURNING suma preapproval_plan_id — el
        caller lo necesita para derivar el tier REAL (nunca confiar en el
        `plan` guardado tal cual: podía haber nacido con el fallback
        hardcodeado a 'pro')."""
        return await self._conn.fetchrow(
            """
            UPDATE public.subscriptions
            SET account_id = $2, status = $3, ambiguous_reason = NULL, updated_at = now()
            WHERE id = $1 AND status = 'ambiguous'
            RETURNING id, account_id, preapproval_id, preapproval_plan_id, plan, status
            """,
            subscription_id,
            account_id,
            resolved_status,
        )

    async def find_ambiguous_subscription(self, subscription_id: str) -> asyncpg.Record | None:
        """H2 hotfix (2026-09-04): lookup de solo lectura, PREVIO a
        resolver — permite derivar y validar el tier real (desde
        preapproval_plan_id) antes de tocar account_id/status, para no
        dejar la fila a medio resolver si el plan id no mapea a ningún
        tier configurado."""
        return await self._conn.fetchrow(
            """
            SELECT id, preapproval_id, preapproval_plan_id, plan, status
            FROM public.subscriptions
            WHERE id = $1 AND status = 'ambiguous'
            """,
            subscription_id,
        )

    async def correct_subscription_plan(self, subscription_id: str, plan: str) -> bool:
        """H2 hotfix (2026-09-04): corrige subscriptions.plan de una fila
        que había nacido con un tier equivocado (bug del fallback
        hardcodeado a 'pro' en 0-candidatas) una vez que
        resolve_ambiguous_subscription deriva el tier real."""
        result = await self._conn.execute(
            """
            UPDATE public.subscriptions
            SET plan = $2, updated_at = now()
            WHERE id = $1
            """,
            subscription_id,
            plan,
        )
        return int(result.rsplit(" ", 1)[-1]) > 0
