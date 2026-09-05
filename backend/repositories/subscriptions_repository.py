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
        amount=None,
        pending_authorized_payment_id: str | None = None,
        pending_mercadopago_payment_id: str | None = None,
    ) -> bool:
        """H3 hotfix (2026-09-04): suma `amount` +
        `pending_authorized_payment_id`/`pending_mercadopago_payment_id` —
        COALESCE, igual que el resto de los campos, así que un caller que no
        los menciona (p.ej. `cancel_subscription`) nunca pisa con NULL un
        cobro pendiente que otra notificación ya haya dejado guardado. Para
        limpiarlos de verdad (una vez replicados), ver `clear_pending_charge`
        — ahí el NULL sí es la intención explícita."""
        result = await self._conn.execute(
            """
            UPDATE public.subscriptions
            SET status = $2,
                next_payment_date = COALESCE($3, next_payment_date),
                retry_state = COALESCE($4, retry_state),
                last_payment_status = COALESCE($5, last_payment_status),
                amount = COALESCE($6, amount),
                pending_authorized_payment_id = COALESCE($7, pending_authorized_payment_id),
                pending_mercadopago_payment_id = COALESCE($8, pending_mercadopago_payment_id),
                updated_at = now()
            WHERE preapproval_id = $1
            """,
            preapproval_id,
            status,
            next_payment_date,
            retry_state,
            last_payment_status,
            amount,
            pending_authorized_payment_id,
            pending_mercadopago_payment_id,
        )
        return int(result.rsplit(" ", 1)[-1]) > 0

    async def clear_pending_charge(self, preapproval_id: str) -> None:
        """H3 hotfix (2026-09-04): limpia los marcadores de cobro pendiente
        una vez que `resolve_ambiguous_subscription` (o el replay admin) ya
        replicó sus efectos — a diferencia de `update_subscription_status`
        (COALESCE, no destructivo), acá el NULL es la intención explícita:
        "sin cuenta huérfana con dinero sin aplicar esperando"."""
        await self._conn.execute(
            """
            UPDATE public.subscriptions
            SET pending_authorized_payment_id = NULL,
                pending_mercadopago_payment_id = NULL,
                updated_at = now()
            WHERE preapproval_id = $1
            """,
            preapproval_id,
        )

    async def find_subscription_by_id(self, subscription_id: str) -> asyncpg.Record | None:
        """H3 hotfix (2026-09-04): a diferencia de `find_ambiguous_subscription`
        (WHERE status='ambiguous'), el endpoint admin de reproceso histórico
        (`replay_subscription_charges`) necesita encontrar una suscripción YA
        RESUELTA (account_id asignado) — sin filtro de status."""
        return await self._conn.fetchrow(
            """
            SELECT id, account_id, preapproval_id, preapproval_plan_id, plan, status,
                   next_payment_date, amount, currency, retry_state, last_payment_status,
                   pending_authorized_payment_id, pending_mercadopago_payment_id, created_at
            FROM public.subscriptions
            WHERE id = $1
            """,
            subscription_id,
        )

    async def has_billing_event_for_payment(self, mercadopago_payment_id: str) -> bool:
        """H3 hotfix (2026-09-04): `billing_events` tiene un índice único
        parcial sobre `mercadopago_payment_id` (WHERE NOT NULL). H4 hotfix
        (2026-09-04): esta lectura YA NO decide si `replay_subscription_
        charges` aplica la cuota (siempre la aplica, vía `_apply_approved_
        charge` — ON CONFLICT DO NOTHING la hace segura) — solo decide con
        qué ETIQUETA se reporta: `already_applied` si esta lectura da True
        (el billing_event existía ANTES de esta corrida), `applied` si da
        False."""
        row = await self._conn.fetchval(
            "SELECT 1 FROM public.billing_events WHERE mercadopago_payment_id = $1",
            mercadopago_payment_id,
        )
        return row is not None

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
        tier configurado.

        H3 hotfix (2026-09-04): suma next_payment_date/amount/
        pending_authorized_payment_id/pending_mercadopago_payment_id — el
        caller (resolve_ambiguous_subscription) los necesita para replicar
        un cobro que se acreditó mientras la fila no tenía dueño, en la
        MISMA lectura (sin una segunda query)."""
        return await self._conn.fetchrow(
            """
            SELECT id, preapproval_id, preapproval_plan_id, plan, status,
                   next_payment_date, amount, pending_authorized_payment_id,
                   pending_mercadopago_payment_id
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
