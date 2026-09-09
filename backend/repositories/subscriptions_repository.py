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

    async def find_pending_intent_by_id(
        self, intent_id: str, preapproval_plan_id: str
    ) -> asyncpg.Record | None:
        """Match determinístico por `external_reference` (item B (2),
        residuo (a) de mp-real-subscriptions): mismo criterio que
        `find_pending_intents` (pending, mismo plan, no vencida) pero por
        id de la intención en vez de payer_email — se prueba PRIMERO en
        `process_subscription_preapproval_notification`, porque
        MercadoPago puede devolver un email de pagador distinto del login
        (caso real: Daniel)."""
        return await self._conn.fetchrow(
            """
            SELECT id, account_id, payer_email, plan, preapproval_plan_id, status, expires_at
            FROM public.subscription_intents
            WHERE id = $1
              AND preapproval_plan_id = $2
              AND status = 'pending'
              AND expires_at > now()
            """,
            intent_id,
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
                   next_payment_date, amount, currency, retry_state, last_payment_status,
                   created_at
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

    # ── Cola de ambiguos — Descartar (residuo (b) de mp-real-subscriptions,
    #    ver CHANGES.md "Hotfixes post-archive #511-#517") ─────────────────

    async def discard_ambiguous_subscription(self, subscription_id: str) -> asyncpg.Record | None:
        """Descarta una fila `ambiguous` sin cuenta legítima que la
        reclame (caso real: subscriptions.id
        caeaa3a1-42b2-44bf-b938-ce20452160ff, preapproval Pro cancelado en
        MercadoPago). A diferencia de `resolve_ambiguous_subscription`
        (asigna una cuenta y activa un plan), descartar SOLO saca la fila
        de la cola visible: `status='cancelled'`, `account_id` se queda
        NULL, `ambiguous_reason` se limpia (mismo shape que cualquier otra
        fila `cancelled` — la CHECK `(status='ambiguous') = (ambiguous_
        reason IS NOT NULL)` sigue satisfecha).

        Solo afecta filas que sigan `status='ambiguous' AND account_id IS
        NULL` — no reasigna/reescribe una fila que ya se resolvió o que ya
        se descartó (evita una carrera con `resolve_ambiguous_subscription`
        corriendo al mismo tiempo). El `ambiguous_reason` PREVIO se captura
        en la misma sentencia (CTE `prev`) para la traza de auditoría —
        después del UPDATE ya es NULL.

        F5 fix (revisor adversarial tanda6): el predicado se re-assertea en
        el WHERE del UPDATE (no solo en la CTE `prev`) — antes de este fix,
        `prev` se evaluaba contra el snapshot del inicio de la sentencia
        pero el WHERE del UPDATE solo comparaba por `id`, así que un
        `resolve_ambiguous_subscription` concurrente que commiteara justo
        entre medio dejaba pasar el descarte igual sobre la fila YA
        resuelta (Postgres espera el lock y re-evalúa el UPDATE sobre la
        versión nueva, que sigue cumpliendo `s.id = prev.id`). Repetir el
        predicado en el WHERE del UPDATE sí se re-evalúa después del lock:
        la carrera perdedora devuelve RETURNING vacío → 404, como promete
        el docstring."""
        return await self._conn.fetchrow(
            """
            WITH prev AS (
                SELECT id, ambiguous_reason AS ambiguous_reason_before
                FROM public.subscriptions
                WHERE id = $1 AND status = 'ambiguous' AND account_id IS NULL
            )
            UPDATE public.subscriptions s
            SET status = 'cancelled', ambiguous_reason = NULL, updated_at = now()
            FROM prev
            WHERE s.id = prev.id AND s.status = 'ambiguous' AND s.account_id IS NULL
            RETURNING s.id, s.preapproval_id, s.preapproval_plan_id, s.plan, s.amount,
                      s.pending_authorized_payment_id, s.pending_mercadopago_payment_id,
                      prev.ambiguous_reason_before
            """,
            subscription_id,
        )

    async def reopen_as_ambiguous(self, preapproval_id: str, reason: str) -> bool:
        """Devuelve a la cola de ambiguos una fila `account_id IS NULL` que
        había sido sacada de la cola (p.ej. por `discard_ambiguous_
        subscription`, status='cancelled') pero de la que MercadoPago
        volvió a notificar un estado "vivo" (no cancelado) para el MISMO
        preapproval — evita que la fila quede con `status='authorized'`/
        `'pending'` y ningún `account_id` (fila inconsistente e invisible:
        `list_ambiguous_subscriptions` solo lista `status='ambiguous'`).

        Solo toca filas sin cuenta asignada — una fila ya resuelta
        (`account_id` no NULL) nunca se reabre por acá."""
        result = await self._conn.execute(
            """
            UPDATE public.subscriptions
            SET status = 'ambiguous', ambiguous_reason = $2, updated_at = now()
            WHERE preapproval_id = $1 AND account_id IS NULL
            """,
            preapproval_id,
            reason,
        )
        return int(result.rsplit(" ", 1)[-1]) > 0

    # ── "Suscripciones recientes" (residuo (c) — botón Replicar cuotas) ────

    async def list_recent_subscriptions(self, limit: int) -> list[asyncpg.Record]:
        """Suscripciones NO ambiguas (con o sin cuenta — una fila
        descartada sigue siendo `status='cancelled'` con `account_id`
        NULL, y aparece acá para que quede visible que se descartó), más
        recientes primero. Alimenta la sección "Suscripciones recientes"
        del panel admin (`GET /payments/subscriptions/recent`), de donde
        sale la acción "Replicar cuotas" (`replay_subscription_charges`).

        `account_name` se resuelve igual que `search_accounts`
        (BillingRepository): `accounts` no tiene nombre de negocio propio,
        se deriva del owner vía `auth.users`/`profiles`."""
        return await self._conn.fetch(
            """
            SELECT s.id, s.plan, s.status, s.account_id,
                   COALESCE(p.business_name, p.name, u.email) AS account_name,
                   s.next_payment_date, s.last_payment_status, s.retry_state,
                   s.updated_at
            FROM public.subscriptions s
            LEFT JOIN public.accounts a ON a.id = s.account_id
            LEFT JOIN auth.users u ON u.id = a.owner_user_id
            LEFT JOIN profiles p ON p.id = a.owner_user_id
            WHERE s.status <> 'ambiguous'
            ORDER BY s.updated_at DESC
            LIMIT $1
            """,
            limit,
        )
