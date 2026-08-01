from __future__ import annotations

import datetime
import hashlib
import hmac
import json
import logging

import asyncpg
import httpx
from fastapi import HTTPException

from backend.core.config import settings
from backend.schemas.payments import WebhookResponse
from backend.services.receipts import ReceiptData, build_receipt_pdf_base64

logger = logging.getLogger(__name__)

PLAN_HIERARCHY = ["gratis", "inicial", "avanzado", "pro"]


def derive_signed_notification_id(raw_body: bytes, query_data_id: str | None) -> str | None:
    """Deriva el `data.id` que MercadoPago usó para firmar el manifiesto (D9).

    MercadoPago firma con el `data.id` tal como aparece en el **query param**
    de la URL de notificación, no el del cuerpo, y lo pasa a minúsculas antes
    de firmar (los IDs de `preapproval`/suscripción son alfanuméricos; bajar
    a minúsculas un ID de pago, que es numérico, no lo altera — de ahí que la
    derivación previa, solo desde el cuerpo y sin normalizar, funcionara
    "por casualidad" para pagos y rompiera para suscripciones).

    El cuerpo se usa únicamente como respaldo cuando no hay query param
    (compatibilidad hacia atrás). Devuelve `None` si no se pudo derivar
    ningún id de ninguna de las dos fuentes — caso distinguible de "id vacío"
    para el log de rechazo.
    """
    if query_data_id:
        return query_data_id.lower()

    try:
        body = json.loads(raw_body)
    except Exception:
        return None

    notification_id = (body.get("data") or {}).get("id")
    if not notification_id:
        return None
    return str(notification_id).lower()


def verify_mp_signature(
    raw_body: bytes,
    x_signature: str | None,
    x_request_id: str | None,
    secret: str,
    query_data_id: str | None = None,
) -> bool:
    """Verifica firma HMAC-SHA256 de MercadoPago.

    Template firmado: id:<notification_data_id>;request-id:<x-request-id>;ts:<ts>;
    Paridad exacta con la implementación Web Crypto de Next.js (C-10).

    v31-mp-upgrade-webhook-fix (D del spec payment-webhook, "Misconfigured
    webhook secret fails closed and is diagnosable"): un secreto faltante y
    una firma forjada dan el mismo resultado (False) pero son causas
    DISTINTAS — la primera es un error de configuración propio, la segunda es
    un intento de request ilegítimo (o el síntoma exacto de H-02 si el
    secreto de Render no coincide con el del panel de MP). El log distingue
    ambas ramas explícitamente. Nunca se loguea el secreto configurado ni el
    valor de x_signature recibido — solo la causa del rechazo.

    `query_data_id` (mp-real-subscriptions D9): el `data.id` tal como viene
    del query param de la URL de notificación. Es la fuente de verdad para
    el manifiesto firmado — ver `derive_signed_notification_id`. Opcional
    por compatibilidad hacia atrás (cae al cuerpo si se omite).
    """
    if not secret:
        logger.warning("[payments] Webhook rejected — MERCADOPAGO_WEBHOOK_SECRET is not configured")
        return False

    if not x_signature or not x_request_id:
        logger.warning("[payments] Webhook rejected — missing x-signature or x-request-id header")
        return False

    parts: dict[str, str] = {}
    for part in x_signature.split(","):
        if "=" in part:
            k, v = part.split("=", 1)
            parts[k] = v

    ts = parts.get("ts")
    v1 = parts.get("v1")
    if not ts or not v1:
        logger.warning("[payments] Webhook rejected — malformed x-signature header")
        return False

    notification_id = derive_signed_notification_id(raw_body, query_data_id)
    if notification_id is None:
        logger.warning("[payments] Webhook rejected — malformed payload, cannot build signed template")
        return False

    signed_template = f"id:{notification_id};request-id:{x_request_id};ts:{ts};"
    computed = hmac.new(
        secret.encode(),
        signed_template.encode(),
        hashlib.sha256,
    ).hexdigest()

    is_valid = hmac.compare_digest(computed, v1)
    if not is_valid:
        logger.warning("[payments] Webhook rejected — invalid signature")
    return is_valid


async def _fetch_user_email(user_id: str) -> str | None:
    """Obtiene el email del usuario via Supabase Admin REST API."""
    if not settings.supabase_url or not settings.service_role_key:
        return None
    url = f"{settings.supabase_url.rstrip('/')}/auth/v1/admin/users/{user_id}"
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.get(
            url,
            headers={
                "Authorization": f"Bearer {settings.service_role_key}",
                "apikey": settings.service_role_key,
            },
        )
    if resp.status_code != 200:
        logger.warning("[payments] Could not fetch user email for %s: %s", user_id, resp.status_code)
        return None
    return resp.json().get("email")


async def _fetch_mp_payment(payment_id: str) -> dict | None:
    """Consulta MercadoPago REST API y retorna los datos del pago.

    Retorna None si el pago no existe (404) — ocurre con IDs de test como "123456".
    """
    url = f"https://api.mercadopago.com/v1/payments/{payment_id}"
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.get(
            url,
            headers={"Authorization": f"Bearer {settings.mercadopago_access_token}"},
        )
    if resp.status_code == 404:
        logger.info("[payments] Payment %s not found in MP API (test ID or already deleted)", payment_id)
        return None
    if resp.status_code != 200:
        logger.error("[payments] MP API error %s for payment %s", resp.status_code, payment_id)
        raise HTTPException(status_code=502, detail="Error al consultar MercadoPago")
    return resp.json()


async def process_payment(
    payment_id: str,
    conn: asyncpg.Connection,
    shadow: bool = False,
) -> WebhookResponse:
    """Procesa una notificación de pago aprobado de MercadoPago.

    En shadow=True ejecuta toda la lógica pero no escribe en la DB.
    """
    # Idempotency check
    existing = await conn.fetchrow(
        "SELECT id FROM billing_events WHERE mercadopago_payment_id = $1",
        payment_id,
    )
    if existing:
        logger.info("[payments] Duplicate payment_id — idempotent skip: %s", payment_id)
        return WebhookResponse(ok=True, idempotent=True)

    payment_data = await _fetch_mp_payment(payment_id)

    if payment_data is None:
        return WebhookResponse(ok=True, skipped=True)

    if payment_data.get("status") != "approved":
        return WebhookResponse(ok=True, status=payment_data.get("status"))

    external_ref = payment_data.get("external_reference") or ""
    parts = external_ref.split("::")
    if len(parts) != 2 or not parts[0] or parts[1] not in PLAN_HIERARCHY:
        logger.error("[payments] Invalid external_reference: %s", external_ref)
        raise HTTPException(status_code=400, detail="external_reference inválido")

    user_id, plan = parts[0], parts[1]
    amount = payment_data.get("transaction_amount") or 0
    preference_id = payment_data.get("preference_id")

    member_row = await conn.fetchrow(
        """
        SELECT am.account_id, a.billing_plan
        FROM account_members am
        JOIN accounts a ON a.id = am.account_id
        WHERE am.user_id = $1
        """,
        user_id,
    )
    if not member_row:
        logger.error("[payments] No account found for user: %s", user_id)
        raise HTTPException(status_code=404, detail="Cuenta no encontrada")

    account_id = member_row["account_id"]
    from_plan = member_row["billing_plan"] or "gratis"

    if shadow:
        logger.info(
            "[payments] shadow=True — would upgrade user %s from %s to %s",
            user_id,
            from_plan,
            plan,
        )
        return WebhookResponse(ok=True, shadow=True)

    await conn.execute(
        """
        UPDATE accounts
        SET billing_plan = $1, billing_status = 'active', plan_expires_at = NULL
        WHERE id = $2
        """,
        plan,
        account_id,
    )

    event_row = await conn.fetchrow(
        """
        INSERT INTO billing_events
          (user_id, event_type, from_plan, to_plan, reason,
           mercadopago_payment_id, mercadopago_preference_id, amount, metadata)
        VALUES ($1, 'plan_upgraded', $2, $3, 'C-17 mercadopago-payment-approved',
                $4, $5, $6, $7::jsonb)
        RETURNING id, receipt_number
        """,
        user_id,
        from_plan,
        plan,
        payment_id,
        preference_id,
        amount,
        json.dumps({"account_id": str(account_id), "payment_status": "approved"}),
    )
    billing_event_id = str(event_row["id"]) if event_row else None
    receipt_number = event_row["receipt_number"] if event_row else None

    recipient_email = await _fetch_user_email(user_id)
    if recipient_email:
        plan_label = plan.capitalize()
        email_meta: dict = {
            "plan": plan,
            "amount": float(amount) if amount is not None else None,
            "activated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "billing_event_id": billing_event_id,
            "receipt_number": receipt_number,
        }
        # Recibo en PDF adjunto (best-effort: nunca romper el webhook por esto).
        try:
            email_meta["receipt_pdf_base64"] = build_receipt_pdf_base64(
                ReceiptData(
                    receipt_number=receipt_number or f"RC-{billing_event_id}",
                    issued_at=datetime.datetime.now(datetime.timezone.utc),
                    customer_email=recipient_email,
                    plan=plan,
                    amount=amount or 0,
                    payment_id=payment_id,
                )
            )
        except Exception:
            logger.exception("[payments] No se pudo generar el PDF del recibo; se envía sin adjunto")

        await conn.execute(
            """
            INSERT INTO email_logs (user_id, event_type, recipient, subject, metadata)
            VALUES ($1, 'plan_upgraded', $2, $3, $4::jsonb)
            """,
            user_id,
            recipient_email,
            f"Tu plan {plan_label} está activo — ALIADATA",
            json.dumps(email_meta),
        )

    logger.info("[payments] Upgraded user %s from %s to %s", user_id, from_plan, plan)
    return WebhookResponse(ok=True)
