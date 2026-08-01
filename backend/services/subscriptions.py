from __future__ import annotations

import datetime
import logging

import asyncpg
import httpx
from fastapi import HTTPException

from backend.core.config import settings
from backend.repositories.subscriptions_repository import SubscriptionsRepository
from backend.schemas.payments import (
    SubscriptionCancelOut,
    SubscriptionCreateOut,
)
from backend.services.payments import _fetch_user_email

logger = logging.getLogger(__name__)

# mp-real-subscriptions D6/OQ2: gracia entre next_payment_date y
# plan_expires_at — 10 días, igual a la ventana de reintentos de
# MercadoPago (hasta 4 intentos en 10 días). Decisión firmada del PO
# (tasks.md 1.3).
GRACE_PERIOD = datetime.timedelta(days=10)

PAID_PLANS = ("inicial", "avanzado", "pro")

# ── D2bis: el init_point de un preapproval_plan es determinístico a partir
# de su id — verificado en sandbox 2026-08-01 (task 2.2). Nunca se llama a
# la API de MP para obtenerlo: es una URL construida.
_MP_PLAN_CHECKOUT_URL = "https://www.mercadopago.com.ar/subscriptions/checkout?preapproval_plan_id={plan_id}"


def _plan_id_for_tier(plan: str) -> str | None:
    return {
        "inicial": settings.mp_plan_id_inicial,
        "avanzado": settings.mp_plan_id_avanzado,
        "pro": settings.mp_plan_id_pro,
    }.get(plan) or None


async def _claim_subscription_webhook_idempotency(conn: asyncpg.Connection, key: str) -> bool:
    """Reclama un slot de idempotencia para el procesamiento de una
    notificación de suscripción (D5, kind 'subscription_webhook'). Devuelve
    True si es la PRIMERA vez que se ve esta key (procesar), False si ya
    estaba reclamada (no-op — redelivery)."""
    status = await conn.execute(
        """
        INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind)
        VALUES ('00000000-0000-0000-0000-000000000000'::uuid, $1, 'subscription_webhook')
        ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING
        """,
        key,
    )
    return int(status.rsplit(" ", 1)[-1]) > 0


# ── Alta (D2bis) ──────────────────────────────────────────────────────────

async def create_subscription_intent(
    account_id: str,
    user_id: str,
    plan: str,
    repo: SubscriptionsRepository,
) -> SubscriptionCreateOut:
    """POST /payments/subscriptions (task 6.3/6.4).

    NO crea ningún `preapproval` — D2 está refutado (400/500 en sandbox sin
    card_token_id, ver design.md Amendment). Crea una intención
    pre-registrada y devuelve el init_point del PLAN (determinístico); MP
    crea el preapproval real cuando el pagador completa el checkout, y la
    reconciliación pasa por `process_subscription_preapproval_notification`.
    """
    if plan not in PAID_PLANS:
        raise HTTPException(status_code=400, detail=f"Plan inválido: {plan!r}")

    plan_id = _plan_id_for_tier(plan)
    if not plan_id:
        logger.error("[subscriptions] Tier %s sin preapproval_plan configurado", plan)
        raise HTTPException(
            status_code=400,
            detail=f"El plan {plan!r} no tiene un preapproval_plan de MercadoPago configurado todavía",
        )

    existing = await repo.find_live_subscription(account_id)
    if existing:
        raise HTTPException(status_code=409, detail="Ya existe una suscripción viva para esta cuenta")

    payer_email = await _fetch_user_email(user_id)
    if not payer_email:
        logger.error("[subscriptions] No se pudo resolver el email del usuario %s", user_id)
        raise HTTPException(status_code=502, detail="No se pudo resolver el email del usuario")

    # Persiste ANTES de devolver la URL de autorización (task 6.3) — si el
    # usuario nunca completa el checkout, la intención simplemente vence
    # (D2bis, ventana 24h) sin haber comprometido nada más.
    row = await repo.create_intent(account_id, payer_email, plan, plan_id)

    return SubscriptionCreateOut(
        init_point=_MP_PLAN_CHECKOUT_URL.format(plan_id=plan_id),
        intent_id=row["id"],
        plan=plan,
        expires_at=row["expires_at"],
    )


# ── Baja ──────────────────────────────────────────────────────────────────

async def cancel_subscription(
    account_id: str,
    repo: SubscriptionsRepository,
    conn: asyncpg.Connection,
) -> SubscriptionCancelOut:
    """DELETE /payments/subscriptions (task 6.5/6.6).

    Cancela el preapproval EN MERCADOPAGO primero — si esa llamada falla,
    no se toca ningún estado local (task 6.5: "si la cancelación en MP
    falla, no deja estado local inconsistente"). El acceso se conserva
    hasta el fin del período YA PAGADO (next_payment_date), no se corta al
    instante — D8/D2bis, sin prorrateo.
    """
    subscription = await repo.find_live_subscription(account_id)
    if not subscription:
        raise HTTPException(status_code=404, detail="No hay una suscripción viva para cancelar")

    preapproval_id = subscription["preapproval_id"]

    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.put(
            f"https://api.mercadopago.com/preapproval/{preapproval_id}",
            headers={"Authorization": f"Bearer {settings.mercadopago_access_token}"},
            json={"status": "cancelled"},
        )

    if resp.status_code not in (200, 201):
        logger.error(
            "[subscriptions] Cancelación en MP falló para %s: HTTP %s", preapproval_id, resp.status_code
        )
        raise HTTPException(status_code=502, detail="No se pudo cancelar la suscripción en MercadoPago")

    plan_expires_at = subscription["next_payment_date"]  # fin del período YA pagado, sin gracia extra

    await repo.update_subscription_status(preapproval_id, "cancelled")

    await conn.execute(
        """
        UPDATE public.accounts
        SET billing_status = 'cancelling', plan_expires_at = $2, updated_at = now()
        WHERE id = $1
        """,
        account_id,
        plan_expires_at,
    )

    await conn.execute(
        """
        INSERT INTO public.billing_events (user_id, event_type, from_plan, to_plan, reason, metadata)
        SELECT owner_user_id, 'subscription_cancelled', billing_plan, billing_plan,
               'mp-real-subscriptions: baja voluntaria del usuario',
               jsonb_build_object('preapproval_id', $2::text, 'plan_expires_at', $3)
        FROM public.accounts WHERE id = $1
        """,
        account_id,
        preapproval_id,
        plan_expires_at,
    )

    return SubscriptionCancelOut(ok=True, plan_expires_at=plan_expires_at)


# ── Cola de ambiguos (D2bis, task 6.8bis) — resolución manual, admin-only ──

async def resolve_ambiguous_subscription(
    subscription_id: str,
    account_id: str,
    repo: SubscriptionsRepository,
    conn: asyncpg.Connection,
) -> dict:
    """Un admin asigna manualmente la cuenta correcta a una fila
    `ambiguous` (email no matcheó ninguna intención, o matcheó varias). El
    dinero YA se acreditó en billing_events cuando llegó el cobro — esto
    solo corrige la atribución."""
    resolved = await repo.resolve_ambiguous_subscription(subscription_id, account_id)
    if resolved is None:
        raise HTTPException(
            status_code=404, detail="No hay una suscripción ambigua con ese id (o ya fue resuelta)"
        )

    await conn.execute(
        """
        UPDATE public.accounts
        SET billing_plan = $2, billing_status = 'active', updated_at = now()
        WHERE id = $1
        """,
        account_id,
        resolved["plan"],
    )
    await conn.execute(
        """
        INSERT INTO public.billing_events (user_id, event_type, to_plan, reason, metadata)
        SELECT owner_user_id, 'subscription_ambiguous_resolved', $2,
               'mp-real-subscriptions: resolución manual de la cola de ambiguos',
               jsonb_build_object('subscription_id', $3::text, 'preapproval_id', $4::text)
        FROM public.accounts WHERE id = $1
        """,
        account_id,
        resolved["plan"],
        subscription_id,
        resolved["preapproval_id"],
    )

    return {"ok": True}


# ── Webhook: subscription_preapproval (autorización/cancelación) ──────────

async def process_subscription_preapproval_notification(
    preapproval_id: str,
    repo: SubscriptionsRepository,
    conn: asyncpg.Connection,
) -> dict:
    """Topic `subscription_preapproval` (task 6.7/6.8)."""
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.get(
            f"https://api.mercadopago.com/preapproval/{preapproval_id}",
            headers={"Authorization": f"Bearer {settings.mercadopago_access_token}"},
        )
    if resp.status_code == 404:
        logger.info("[subscriptions] preapproval %s no existe en MP (id de test o ya borrado)", preapproval_id)
        return {"ok": True, "skipped": True}
    if resp.status_code != 200:
        logger.error("[subscriptions] MP API error %s para preapproval %s", resp.status_code, preapproval_id)
        raise HTTPException(status_code=502, detail="Error al consultar MercadoPago")

    data = resp.json()
    status = data.get("status")
    payer_email = (data.get("payer_email") or "").strip().lower()
    preapproval_plan_id = data.get("preapproval_plan_id") or ""

    idem_key = f"preapproval:{preapproval_id}:{status}"
    if not await _claim_subscription_webhook_idempotency(conn, idem_key):
        return {"ok": True, "idempotent": True}

    existing = await repo.find_by_preapproval_id(preapproval_id)

    if existing is None:
        # Primera vez que vemos este preapproval — reconciliación D2bis.
        candidates = await repo.find_pending_intents(payer_email, preapproval_plan_id)

        if len(candidates) == 1:
            intent = candidates[0]
            sub = await repo.create_subscription(
                account_id=intent["account_id"],
                preapproval_id=preapproval_id,
                preapproval_plan_id=preapproval_plan_id,
                plan=intent["plan"],
                status=status,
            )
            if sub:
                await repo.mark_intent_matched(intent["id"], sub["id"])
            if status == "authorized":
                await conn.execute(
                    """
                    UPDATE public.accounts
                    SET billing_plan = $2, billing_status = 'active', updated_at = now()
                    WHERE id = $1
                    """,
                    intent["account_id"],
                    intent["plan"],
                )
            return {"ok": True, "matched": True}

        reason = "multiple_match" if len(candidates) > 1 else "no_match"
        logger.warning(
            "[subscriptions] preapproval %s sin match automático (%s, %d candidatas)",
            preapproval_id, reason, len(candidates),
        )
        await repo.create_subscription(
            account_id=None,
            preapproval_id=preapproval_id,
            preapproval_plan_id=preapproval_plan_id,
            plan=candidates[0]["plan"] if candidates else "pro",
            status="ambiguous",
            ambiguous_reason=reason,
        )
        return {"ok": True, "ambiguous": reason}

    # Ya existe la fila (reconciliada o ambigua previamente) — solo estado.
    await repo.update_subscription_status(preapproval_id, status)

    if status == "cancelled" and existing["account_id"] is not None:
        # D8: reutiliza process_cancellations() — la cuenta entra al mismo
        # barrido que ya está en producción. plan_expires_at real: si había
        # next_payment_date usarlo, si no (cancelación sin cobro previo)
        # degradar ya.
        plan_expires_at = existing["next_payment_date"] or datetime.datetime.now(datetime.timezone.utc)
        await conn.execute(
            """
            UPDATE public.accounts
            SET billing_status = 'cancelling', plan_expires_at = $2, updated_at = now()
            WHERE id = $1 AND billing_status <> 'cancelling'
            """,
            existing["account_id"],
            plan_expires_at,
        )
        await conn.execute(
            """
            INSERT INTO public.billing_events (user_id, event_type, from_plan, to_plan, reason, metadata)
            SELECT owner_user_id, 'subscription_cancelled', billing_plan, billing_plan,
                   'mp-real-subscriptions: cancelación reportada por MercadoPago (baja o impago)',
                   jsonb_build_object('preapproval_id', $2::text)
            FROM public.accounts WHERE id = $1
            """,
            existing["account_id"],
            preapproval_id,
        )

    return {"ok": True}


# ── Webhook: subscription_authorized_payment (cobro mensual) ──────────────

async def process_subscription_authorized_payment_notification(
    authorized_payment_id: str,
    repo: SubscriptionsRepository,
    conn: asyncpg.Connection,
) -> dict:
    """Topic `subscription_authorized_payment` (task 6.9/6.10)."""
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.get(
            f"https://api.mercadopago.com/authorized_payments/{authorized_payment_id}",
            headers={"Authorization": f"Bearer {settings.mercadopago_access_token}"},
        )
    if resp.status_code == 404:
        return {"ok": True, "skipped": True}
    if resp.status_code != 200:
        logger.error(
            "[subscriptions] MP API error %s para authorized_payment %s",
            resp.status_code, authorized_payment_id,
        )
        raise HTTPException(status_code=502, detail="Error al consultar MercadoPago")

    data = resp.json()
    cuota_status = data.get("status")  # scheduled | processed | recycling | cancelled
    preapproval_id = data.get("preapproval_id")
    payment = data.get("payment") or {}
    payment_status = payment.get("status")
    retry_attempt = data.get("retry_attempt")

    idem_key = f"authorized_payment:{authorized_payment_id}:{cuota_status}:{payment_status}"
    if not await _claim_subscription_webhook_idempotency(conn, idem_key):
        return {"ok": True, "idempotent": True}

    if cuota_status == "scheduled":
        return {"ok": True, "scheduled": True}

    subscription = await repo.find_by_preapproval_id(preapproval_id) if preapproval_id else None
    if subscription is None:
        logger.warning(
            "[subscriptions] authorized_payment %s referencia un preapproval desconocido (%s)",
            authorized_payment_id, preapproval_id,
        )
        return {"ok": True, "unknown_subscription": True}

    if cuota_status == "processed" and payment_status == "approved":
        next_payment_date = data.get("next_retry_date") or data.get("debit_date")
        plan_expires_at = None
        if next_payment_date:
            parsed = datetime.datetime.fromisoformat(str(next_payment_date).replace("Z", "+00:00"))
            plan_expires_at = parsed + GRACE_PERIOD

        await repo.update_subscription_status(
            preapproval_id,
            "authorized",
            next_payment_date=next_payment_date,
            retry_state="none",
            last_payment_status="approved",
        )

        if subscription["account_id"] is not None:
            await conn.execute(
                """
                UPDATE public.accounts
                SET plan_expires_at = $2, billing_status = 'active', updated_at = now()
                WHERE id = $1
                """,
                subscription["account_id"],
                plan_expires_at,
            )
            await conn.execute(
                """
                INSERT INTO public.billing_events
                    (user_id, event_type, to_plan, reason, metadata, mercadopago_payment_id, amount)
                SELECT owner_user_id, 'subscription_payment_approved', $2, 'mp-real-subscriptions: cobro mensual',
                       jsonb_build_object('preapproval_id', $3::text, 'authorized_payment_id', $4::text),
                       $5, $6
                FROM public.accounts WHERE id = $1
                ON CONFLICT DO NOTHING
                """,
                subscription["account_id"],
                subscription["plan"],
                preapproval_id,
                authorized_payment_id,
                str(payment.get("id")) if payment.get("id") else None,
                data.get("transaction_amount"),
            )
        return {"ok": True, "credited": True}

    # Cobro rechazado (o cualquier estado no-aprobado de una cuota resuelta):
    # avisar, NO tocar plan ni vencimiento (D7 — MercadoPago reintenta solo).
    await repo.update_subscription_status(
        preapproval_id,
        subscription["status"],
        retry_state="retrying",
        last_payment_status=payment_status or cuota_status,
    )

    if subscription["account_id"] is not None:
        await conn.execute(
            """
            INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
            VALUES ($1, 'SubscriptionPaymentFailed', 'Subscription', $1,
                    jsonb_build_object(
                        'preapproval_id', $2::text, 'authorized_payment_id', $3::text,
                        'retry_attempt', $4::int, 'plan', $5::text
                    ),
                    now())
            """,
            subscription["account_id"],
            preapproval_id,
            authorized_payment_id,
            retry_attempt,
            subscription["plan"],
        )
        # D10: discriminador (authorized_payment_id) obligatorio en metadata —
        # sin esto, un 2do cobro rechazado del mismo mes se traga en
        # silencio por el UNIQUE NULLS NOT DISTINCT(user_id,event_type,metadata).
        await conn.execute(
            """
            INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
            SELECT a.owner_user_id, 'subscription_payment_failed', u.email,
                   'No pudimos procesar tu pago — ALIADATA',
                   jsonb_build_object('preapproval_id', $2::text, 'authorized_payment_id', $3::text)
            FROM public.accounts a
            JOIN auth.users u ON u.id = a.owner_user_id
            WHERE a.id = $1
            ON CONFLICT DO NOTHING
            """,
            subscription["account_id"],
            preapproval_id,
            authorized_payment_id,
        )

    return {"ok": True, "payment_failed": True}
