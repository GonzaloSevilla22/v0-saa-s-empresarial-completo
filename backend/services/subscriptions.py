from __future__ import annotations

import datetime
import decimal
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


def _tier_for_plan_id(plan_id: str | None) -> str | None:
    """Inversa de `_plan_id_for_tier` (H2 hotfix 2026-09-04): dado un
    `preapproval_plan_id` real de MercadoPago, devuelve el tier configurado
    que le corresponde, o None si no coincide con ninguno de los 3 tiers
    pagos configurados (MP_PLAN_ID_INICIAL/AVANZADO/PRO desactualizada, o un
    id de otra cuenta de MP).

    Bug real de prod que esta función corrige: `subscriptions.id =
    fa624f9b-32e5-4b5c-ad0d-fc64e6dc16b1` nació con `plan='pro'` porque el
    código anterior usaba `candidates[0]["plan"] if candidates else "pro"`
    — con 0 candidatas, inventaba 'pro' sin mirar el preapproval_plan_id
    real (que era el de Inicial). Nunca se adivina: si el id no mapea a
    ningún tier, el caller decide qué hacer (no crear la fila / rechazar la
    resolución), pero esta función jamás devuelve un valor no verificado."""
    if not plan_id:
        return None
    return {
        settings.mp_plan_id_inicial: "inicial",
        settings.mp_plan_id_avanzado: "avanzado",
        settings.mp_plan_id_pro: "pro",
    }.get(plan_id)


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

    # H1 hotfix (2026-09-04): public.accounts NO tiene columna updated_at
    # (verificado en prod — columnas reales: id, billing_plan, billing_status,
    # trial_plan, trial_started_at, trial_expires_at, owner_user_id,
    # created_at, plan_expires_at, billing_exempt*, default_payment_terms_days).
    # Setearla explota con 42703 (UndefinedColumn) → 500 sin transacción
    # abierta (get_service_conn), dejando escrituras parciales.
    await conn.execute(
        """
        UPDATE public.accounts
        SET billing_status = 'cancelling', plan_expires_at = $2
        WHERE id = $1
        """,
        account_id,
        plan_expires_at,
    )

    # H4 hotfix (2026-09-04): `$3` (plan_expires_at) casteado a ::timestamptz
    # — vive solo dentro de jsonb_build_object(VARIADIC "any"), mismo patrón
    # que sqlstate 42P18 en `_apply_approved_charge` (ver su docstring).
    await conn.execute(
        """
        INSERT INTO public.billing_events (user_id, event_type, from_plan, to_plan, reason, metadata)
        SELECT owner_user_id, 'subscription_cancelled', billing_plan, billing_plan,
               'mp-real-subscriptions: baja voluntaria del usuario',
               jsonb_build_object('preapproval_id', $2::text, 'plan_expires_at', $3::timestamptz)
        FROM public.accounts WHERE id = $1
        """,
        account_id,
        preapproval_id,
        plan_expires_at,
    )

    # task 7.2: correo de baja, event_type nuevo. Discriminador: preapproval_id
    # (único por suscripción — una cuenta no cancela dos veces LA MISMA).
    await conn.execute(
        """
        INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
        SELECT a.owner_user_id, 'subscription_cancelled', u.email,
               'Tu suscripción fue cancelada — ALIADATA',
               jsonb_build_object('preapproval_id', $2::text, 'plan_expires_at', $3::timestamptz, 'reason', 'user_requested')
        FROM public.accounts a
        JOIN auth.users u ON u.id = a.owner_user_id
        WHERE a.id = $1
        ON CONFLICT DO NOTHING
        """,
        account_id,
        preapproval_id,
        plan_expires_at,
    )

    return SubscriptionCancelOut(ok=True, plan_expires_at=plan_expires_at)


# ── Efecto compartido de una cuota approved (H3 hotfix 2026-09-04) ─────────

async def _apply_approved_charge(
    conn: asyncpg.Connection,
    *,
    account_id: str,
    plan: str,
    preapproval_id: str,
    authorized_payment_id: str,
    mercadopago_payment_id: str | None,
    amount,
    plan_expires_at,
) -> None:
    """ÚNICA definición de los 3 efectos de dinero de una cuota
    `processed`/`approved` ya atribuida a una cuenta: extiende
    `accounts.plan_expires_at`, audita el cobro en `billing_events` y
    encola el correo de renovación. La usan tanto el camino normal
    (`process_subscription_authorized_payment_notification` cuando
    `account_id` ya se conoce de entrada) como el replay al resolver una
    suscripción ambigua (`resolve_ambiguous_subscription`) y el endpoint
    admin de reproceso histórico (`replay_subscription_charges`) — los tres
    caminos deben producir EXACTAMENTE los mismos efectos (reutilización
    antes que repetición, CLAUDE.md; nunca dos copias del mismo efecto de
    dinero).

    Idempotente: `billing_events` tiene un índice único parcial sobre
    `mercadopago_payment_id` (WHERE NOT NULL) y `email_logs` sobre
    `(user_id, event_type, metadata)` — ambos INSERT usan
    `ON CONFLICT DO NOTHING`, así que aplicar la MISMA cuota dos veces
    (p.ej. el endpoint de replay corriendo dos veces) no duplica nada.

    H4 hotfix (2026-09-04): dos bugs de producción reales aislados con
    subscriptions.id fa624f9b-32e5-4b5c-ad0d-fc64e6dc16b1 / pago MP
    176341057469 ($24.900):

    1. El INSERT de `email_logs` de abajo pasaba `amount` (`$5`) y
       `plan_expires_at` (`$6`) SIN cast dentro de
       `jsonb_build_object(VARIADIC "any")` — el ÚNICO lugar donde esos
       parámetros aparecían en toda la sentencia. Postgres no puede inferir
       el tipo de un parámetro que solo se usa en un contexto polimórfico
       ("any"): sqlstate **42P18** ("could not determine data type of
       parameter"), reproducido contra la DB local. `asyncpg_error_handler`
       no tiene ese sqlstate mapeado → 500 genérico sin traceback. Fix:
       cast explícito (`$5::numeric`, `$6::timestamptz`).
    2. Sin transacción: cuando el INSERT de `email_logs` reventaba, el
       UPDATE de `accounts` y el INSERT de `billing_events` de ARRIBA ya
       habían comiteado (autocommit de `get_service_conn`, que entrega una
       conexión sin transacción abierta) — aplicación PARCIAL. Caso real
       verificado: `accounts.plan_expires_at`/`billing_status` y la fila de
       `billing_events` quedaron bien, pero NUNCA se encoló el correo de
       renovación. Fix: las 3 escrituras corren dentro de
       `conn.transaction()` — o las 3, o ninguna.

    `amount` llega de la API de MercadoPago como número JSON (puede
    deserializar como `int` o `float` según lleve decimales) — se normaliza
    acá a `Decimal` (vía `str()`, para no arrastrar el ruido binario de un
    float) antes de bindearlo a las columnas/parámetros `numeric`."""
    if amount is not None and not isinstance(amount, decimal.Decimal):
        amount = decimal.Decimal(str(amount))

    async with conn.transaction():
        await conn.execute(
            """
            UPDATE public.accounts
            SET plan_expires_at = $2, billing_status = 'active'
            WHERE id = $1
            """,
            account_id,
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
            account_id,
            plan,
            preapproval_id,
            authorized_payment_id,
            mercadopago_payment_id,
            amount,
        )
        await conn.execute(
            """
            INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
            SELECT a.owner_user_id, 'subscription_payment_approved', u.email,
                   'Renovamos tu suscripción — ALIADATA',
                   jsonb_build_object(
                       'preapproval_id', $2::text, 'authorized_payment_id', $3::text,
                       'plan', $4::text, 'amount', $5::numeric, 'plan_expires_at', $6::timestamptz
                   )
            FROM public.accounts a
            JOIN auth.users u ON u.id = a.owner_user_id
            WHERE a.id = $1
            ON CONFLICT DO NOTHING
            """,
            account_id,
            preapproval_id,
            authorized_payment_id,
            plan,
            amount,
            plan_expires_at,
        )


# ── Cola de ambiguos (D2bis, task 6.8bis) — resolución manual, admin-only ──

async def resolve_ambiguous_subscription(
    subscription_id: str,
    account_id: str,
    repo: SubscriptionsRepository,
    conn: asyncpg.Connection,
) -> dict:
    """Un admin asigna manualmente la cuenta correcta a una fila
    `ambiguous` (email no matcheó ninguna intención, o matcheó varias).

    H3 hotfix (2026-09-04): el docstring anterior decía "el dinero YA se
    acreditó en billing_events cuando llegó el cobro — esto solo corrige la
    atribución". Eso es FALSO cuando una cuota `processed`/`approved` llega
    ANTES de esta resolución manual — que es el caso NORMAL: MercadoPago
    manda `subscription_preapproval` y `subscription_authorized_payment`
    con segundos de diferencia, y la resolución del admin llega horas
    después. Caso real: subscriptions.id
    fa624f9b-32e5-4b5c-ad0d-fc64e6dc16b1 cobró $24.900 mientras estaba
    'ambiguous' y esos efectos (accounts.plan_expires_at, billing_events,
    email_logs) se perdieron para siempre porque nada los replicaba al
    resolver. Ahora, si `process_subscription_authorized_payment_notification`
    dejó un cobro pendiente guardado en la fila (pending_authorized_payment_id
    + pending_mercadopago_payment_id), se replica acá vía
    `_apply_approved_charge` — la MISMA función que usa el camino normal.

    H2 hotfix (2026-09-04): el `plan` guardado en la fila puede ser
    incorrecto (bug del fallback hardcodeado a 'pro' en
    process_subscription_preapproval_notification con 0 candidatas — caso
    real: subscriptions.id fa624f9b-32e5-4b5c-ad0d-fc64e6dc16b1). El tier
    que se activa en la cuenta SIEMPRE se deriva de `preapproval_plan_id`
    (inverso de `_plan_id_for_tier`), nunca del campo `plan` tal cual. Si
    no mapea a ningún tier configurado, se rechaza con 409 ANTES de tocar
    account_id/status — nunca se asigna un plan adivinado."""
    pending = await repo.find_ambiguous_subscription(subscription_id)
    if pending is None:
        raise HTTPException(
            status_code=404, detail="No hay una suscripción ambigua con ese id (o ya fue resuelta)"
        )

    tier = _tier_for_plan_id(pending["preapproval_plan_id"])
    if tier is None:
        logger.critical(
            "[subscriptions] resolve_ambiguous_subscription %s: preapproval_plan_id %s no "
            "corresponde a ningún tier configurado (MP_PLAN_ID_INICIAL/AVANZADO/PRO) — no se "
            "resuelve para no asignar un plan adivinado.",
            subscription_id, pending["preapproval_plan_id"],
        )
        raise HTTPException(
            status_code=409,
            detail=(
                "El preapproval_plan_id de esta suscripción no corresponde a ningún tier "
                "configurado (MP_PLAN_ID_INICIAL/AVANZADO/PRO). Revisá la configuración antes de "
                "resolver esta fila manualmente."
            ),
        )

    resolved = await repo.resolve_ambiguous_subscription(subscription_id, account_id)
    if resolved is None:
        raise HTTPException(
            status_code=404, detail="No hay una suscripción ambigua con ese id (o ya fue resuelta)"
        )

    if resolved["plan"] != tier:
        # la fila había nacido con un plan incorrecto (bug histórico del
        # fallback hardcodeado a 'pro') — se corrige en el mismo movimiento.
        await repo.correct_subscription_plan(subscription_id, tier)

    # H1 hotfix (2026-09-04): public.accounts no tiene updated_at (ver nota en
    # cancel_subscription).
    await conn.execute(
        """
        UPDATE public.accounts
        SET billing_plan = $2, billing_status = 'active'
        WHERE id = $1
        """,
        account_id,
        tier,
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
        tier,
        subscription_id,
        resolved["preapproval_id"],
    )

    # H3 hotfix (2026-09-04): replay del cobro pendiente (ver docstring de
    # esta función). Si `process_subscription_authorized_payment_notification`
    # guardó un authorized_payment_id mientras la fila no tenía dueño, se
    # replican AHORA los mismos efectos que el camino normal aplica cuando
    # account_id ya se conoce de entrada — vía la MISMA función compartida.
    if pending["pending_authorized_payment_id"]:
        next_payment_date = pending["next_payment_date"]
        plan_expires_at = (next_payment_date + GRACE_PERIOD) if next_payment_date else None
        await _apply_approved_charge(
            conn,
            account_id=account_id,
            plan=tier,
            preapproval_id=resolved["preapproval_id"],
            authorized_payment_id=pending["pending_authorized_payment_id"],
            mercadopago_payment_id=pending["pending_mercadopago_payment_id"],
            amount=pending["amount"],
            plan_expires_at=plan_expires_at,
        )
        await repo.clear_pending_charge(resolved["preapproval_id"])

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
                # H1 hotfix (2026-09-04): public.accounts no tiene updated_at.
                await conn.execute(
                    """
                    UPDATE public.accounts
                    SET billing_plan = $2, billing_status = 'active'
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

        # H2 hotfix (2026-09-04): el tier de la fila ambigua se deriva del
        # preapproval_plan_id REAL de este webhook (inverso de
        # _plan_id_for_tier) — NUNCA se inventa 'pro' como hacía el código
        # anterior con 0 candidatas (caso real: subscriptions.id
        # fa624f9b-32e5-4b5c-ad0d-fc64e6dc16b1 nació 'pro' siendo Inicial).
        # Si el plan id no mapea a ningún tier configurado pero SÍ hay
        # candidatas (multiple_match: todas comparten preapproval_plan_id
        # por construcción de find_pending_intents), su `plan` declarado es
        # la mejor evidencia disponible.
        tier = _tier_for_plan_id(preapproval_plan_id)
        if tier is None and candidates:
            tier = candidates[0]["plan"]

        if tier is None:
            logger.critical(
                "[subscriptions] preapproval %s: preapproval_plan_id %s no corresponde a ningún "
                "tier configurado (MP_PLAN_ID_INICIAL/AVANZADO/PRO) y no hay ninguna intención "
                "candidata que lo declare — NO se crea la fila en subscriptions para no asignar "
                "un plan adivinado. El dinero ya está acreditado en MercadoPago; requiere "
                "revisión manual de la configuración.",
                preapproval_id, preapproval_plan_id,
            )
            return {"ok": True, "unrecognized_plan": True}

        await repo.create_subscription(
            account_id=None,
            preapproval_id=preapproval_id,
            preapproval_plan_id=preapproval_plan_id,
            plan=tier,
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
        # degradar ya. El guard billing_status <> 'cancelling' evita
        # reprocesar (y reenviar el correo) si la notificación se redelivery
        # con una idempotency key distinta por alguna razón.
        plan_expires_at = existing["next_payment_date"] or datetime.datetime.now(datetime.timezone.utc)
        # H1 hotfix (2026-09-04): public.accounts no tiene updated_at.
        status_change = await conn.execute(
            """
            UPDATE public.accounts
            SET billing_status = 'cancelling', plan_expires_at = $2
            WHERE id = $1 AND billing_status <> 'cancelling'
            """,
            existing["account_id"],
            plan_expires_at,
        )
        if int(status_change.rsplit(" ", 1)[-1]) > 0:
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
            # task 7.2: correo de baja — también para la cancelación
            # reportada por MP (impago tras 3 rechazos, o baja hecha desde
            # el propio panel de MP). Mismo event_type que la baja
            # voluntaria (cancel_subscription); el usuario recibe el mismo
            # aviso sin importar el origen.
            # H4 hotfix (2026-09-04): `$3` (plan_expires_at) vive SOLO dentro
            # de jsonb_build_object(VARIADIC "any") — mismo patrón que reventó
            # con sqlstate 42P18 en `_apply_approved_charge` (ver su
            # docstring). Nunca se ejercitó en prod (ninguna baja reportada
            # por MP corrió todavía), pero es el mismo bug latente — casteado
            # acá también.
            await conn.execute(
                """
                INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
                SELECT a.owner_user_id, 'subscription_cancelled', u.email,
                       'Tu suscripción fue cancelada — ALIADATA',
                       jsonb_build_object('preapproval_id', $2::text, 'plan_expires_at', $3::timestamptz, 'reason', 'mercadopago')
                FROM public.accounts a
                JOIN auth.users u ON u.id = a.owner_user_id
                WHERE a.id = $1
                ON CONFLICT DO NOTHING
                """,
                existing["account_id"],
                preapproval_id,
                plan_expires_at,
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

        mercadopago_payment_id = str(payment.get("id")) if payment.get("id") else None
        amount = data.get("transaction_amount")
        has_account = subscription["account_id"] is not None

        # H3 hotfix (2026-09-04): persistir SIEMPRE next_payment_date/
        # last_payment_status/amount — y, mientras la fila TODAVÍA no tiene
        # cuenta asignada ('ambiguous'), también el id del pago MP y el de
        # la cuota — para que resolve_ambiguous_subscription pueda replicar
        # estos mismos efectos más tarde. Caso real: subscriptions.id
        # fa624f9b-32e5-4b5c-ad0d-fc64e6dc16b1 cobró $24.900 mientras
        # ambigua y esos datos se perdieron para siempre porque nada los
        # guardaba junto con el discriminador del pago.
        await repo.update_subscription_status(
            preapproval_id,
            "authorized",
            next_payment_date=next_payment_date,
            retry_state="none",
            last_payment_status="approved",
            amount=amount,
            pending_authorized_payment_id=None if has_account else authorized_payment_id,
            pending_mercadopago_payment_id=None if has_account else mercadopago_payment_id,
        )

        if has_account:
            await _apply_approved_charge(
                conn,
                account_id=subscription["account_id"],
                plan=subscription["plan"],
                preapproval_id=preapproval_id,
                authorized_payment_id=authorized_payment_id,
                mercadopago_payment_id=mercadopago_payment_id,
                amount=amount,
                plan_expires_at=plan_expires_at,
            )
        return {"ok": True, "credited": True}

    # Cobro rechazado (o cualquier estado no-aprobado de una cuota resuelta):
    # avisar, NO tocar plan ni vencimiento (D7 — MercadoPago reintenta solo).
    #
    # H3 hotfix (2026-09-04): a diferencia de la rama approved, acá NO hace
    # falta guardar un "pendiente de replicar" cuando account_id es None —
    # un cobro rechazado no extiende ningún plan (nada que replicar en
    # accounts.plan_expires_at) y el aviso por correo tampoco puede
    # encolarse todavía sin cuenta (no hay a qué owner_user_id/email
    # mandarlo) — resolver la ambigüedad más tarde no cambia eso, así que
    # no hay ningún efecto perdido que un replay pudiera recuperar.
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


# ── Reproceso admin de cobros históricos (H3 hotfix 2026-09-04) ───────────

def _parse_mp_datetime(value: str | None) -> datetime.datetime | None:
    if not value:
        return None
    return datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00"))


async def replay_subscription_charges(
    subscription_id: str,
    repo: SubscriptionsRepository,
    conn: asyncpg.Connection,
) -> dict:
    """POST /payments/subscriptions/{id}/replay-charges (admin-only).

    Reparación puntual para suscripciones cuyas cuotas se cobraron ANTES de
    este fix: cuando una fila nacía 'ambiguous', ninguna cuota
    `processed`/`approved` quedaba registrada para poder reproducirla al
    resolver (ver `_apply_approved_charge` / `resolve_ambiguous_subscription`).
    Caso real: subscriptions.id fa624f9b-32e5-4b5c-ad0d-fc64e6dc16b1 ya fue
    resuelta manualmente ANTES de que existiera este fix — no tiene nada
    guardado en `pending_authorized_payment_id`/`pending_mercadopago_payment_id`
    porque esas columnas no existían todavía cuando se procesó su cobro.

    A diferencia del replay de `resolve_ambiguous_subscription` (que confía
    en lo guardado localmente), este endpoint consulta la API REAL de
    MercadoPago: `GET /preapproval/{id}` (para el estado/next_payment_date
    vigente) y `GET /authorized_payments/search?preapproval_id={id}` (todas
    las cuotas), y aplica `_apply_approved_charge` — la MISMA función que
    usan los otros dos caminos — por CADA cuota `processed`/`approved`,
    tenga o no ya su `billing_event`. Sirve tanto para el caso histórico
    (nada quedó guardado) como para cualquier cuota que este fix no haya
    alcanzado a capturar por otra razón.

    H4 hotfix (2026-09-04): antes de este fix, una cuota con
    `has_billing_event_for_payment` = True se reportaba como `skipped` y
    NUNCA llegaba a llamar a `_apply_approved_charge` — así que una segunda
    corrida del replay sobre la MISMA cuota no podía completar una
    aplicación que había quedado PARCIAL (el caso real que motivó este
    endpoint: `_apply_approved_charge` sin transacción dejó
    `accounts`/`billing_events` escritos pero el `email_logs` de renovación
    nunca se encoló). Ahora se aplica SIEMPRE — los 2 INSERT de
    `_apply_approved_charge` son `ON CONFLICT DO NOTHING` y su UPDATE es
    idempotente, así que reaplicar una cuota ya completa no duplica ni
    corrompe nada — y solo cambia la ETIQUETA con la que se reporta:
    `applied` si el `billing_event` NO existía antes de esta corrida,
    `already_applied` si ya existía (la corrida igual completó cualquier
    escritura que hubiera quedado pendiente, como el correo faltante)."""
    subscription = await repo.find_subscription_by_id(subscription_id)
    if subscription is None:
        raise HTTPException(status_code=404, detail="No existe una suscripción con ese id")
    if subscription["account_id"] is None:
        raise HTTPException(
            status_code=409,
            detail="Esta suscripción todavía no tiene una cuenta asignada — resolvela primero",
        )

    preapproval_id = subscription["preapproval_id"]

    async with httpx.AsyncClient(timeout=10.0) as client:
        preapproval_resp = await client.get(
            f"https://api.mercadopago.com/preapproval/{preapproval_id}",
            headers={"Authorization": f"Bearer {settings.mercadopago_access_token}"},
        )
        if preapproval_resp.status_code != 200:
            logger.error(
                "[subscriptions] replay-charges: MP API error %s al consultar preapproval %s",
                preapproval_resp.status_code, preapproval_id,
            )
            raise HTTPException(status_code=502, detail="No se pudo consultar la suscripción en MercadoPago")
        preapproval_data = preapproval_resp.json()

        payments_resp = await client.get(
            "https://api.mercadopago.com/authorized_payments/search",
            params={"preapproval_id": preapproval_id},
            headers={"Authorization": f"Bearer {settings.mercadopago_access_token}"},
        )
        if payments_resp.status_code != 200:
            logger.error(
                "[subscriptions] replay-charges: MP API error %s al buscar authorized_payments de %s",
                payments_resp.status_code, preapproval_id,
            )
            raise HTTPException(status_code=502, detail="No se pudieron consultar las cuotas en MercadoPago")
        payments_data = payments_resp.json()

    # el shape documentado de /authorized_payments/search es
    # {"paging": {...}, "results": [...]} — defensivo por si alguna vez
    # llega como lista pelada.
    cuotas = payments_data.get("results") if isinstance(payments_data, dict) else payments_data
    cuotas = cuotas or []
    # orden cronológico (id de MP monotónico) — importa porque
    # accounts.plan_expires_at queda con el valor de la ÚLTIMA cuota
    # aplicada; aplicar fuera de orden dejaría un vencimiento viejo pisando
    # uno más nuevo.
    try:
        cuotas = sorted(cuotas, key=lambda c: int(c.get("id")))
    except (TypeError, ValueError):
        pass

    applied: list[str] = []
    already_applied: list[str] = []

    for cuota in cuotas:
        authorized_payment_id = cuota.get("id")
        payment = cuota.get("payment") or {}
        if cuota.get("status") != "processed" or payment.get("status") != "approved":
            continue
        authorized_payment_id = str(authorized_payment_id)

        mercadopago_payment_id = str(payment["id"]) if payment.get("id") else None
        # H4 hotfix: la clasificación se decide ANTES de aplicar (el
        # billing_event existía o no existía cuando arrancó esta corrida) —
        # pero se aplica SIEMPRE, exista o no, para completar cualquier
        # escritura parcial que hubiera quedado pendiente de una corrida
        # anterior interrumpida a mitad (ver docstring de esta función).
        billing_event_existed = bool(
            mercadopago_payment_id and await repo.has_billing_event_for_payment(mercadopago_payment_id)
        )

        next_payment_date = _parse_mp_datetime(cuota.get("next_retry_date") or cuota.get("debit_date"))
        plan_expires_at = (next_payment_date + GRACE_PERIOD) if next_payment_date else None

        await _apply_approved_charge(
            conn,
            account_id=subscription["account_id"],
            plan=subscription["plan"],
            preapproval_id=preapproval_id,
            authorized_payment_id=authorized_payment_id,
            mercadopago_payment_id=mercadopago_payment_id,
            amount=cuota.get("transaction_amount"),
            plan_expires_at=plan_expires_at,
        )
        if billing_event_existed:
            already_applied.append(authorized_payment_id)
        else:
            applied.append(authorized_payment_id)

    # trae el estado/vencimiento LOCAL de subscriptions al día con la verdad
    # vigente de MP, independientemente de si hubo alguna cuota para replicar.
    mp_status = preapproval_data.get("status") if isinstance(preapproval_data, dict) else None
    if mp_status:
        await repo.update_subscription_status(
            preapproval_id,
            mp_status,
            next_payment_date=_parse_mp_datetime(preapproval_data.get("next_payment_date")),
        )

    # cualquier cuota processed/approved encontrada (nueva o ya aplicada)
    # significa que este preapproval ya está cubierto — el marcador de
    # "cobro pendiente de replicar" quedó obsoleto en cualquiera de los 2 casos.
    if applied or already_applied:
        await repo.clear_pending_charge(preapproval_id)

    return {"ok": True, "applied": applied, "already_applied": already_applied}
