from __future__ import annotations

import hashlib
import hmac
import logging

import asyncpg
import httpx
from fastapi import HTTPException

from backend.core.config import settings
from backend.schemas.payments import WebhookResponse

logger = logging.getLogger(__name__)

PLAN_HIERARCHY = ["gratis", "inicial", "avanzado", "pro"]


def verify_mp_signature(
    raw_body: bytes,
    x_signature: str | None,
    x_request_id: str | None,
    secret: str,
) -> bool:
    """Verifica firma HMAC-SHA256 de MercadoPago.

    Template firmado: id:<notification_data_id>;request-id:<x-request-id>;ts:<ts>;
    Paridad exacta con la implementación Web Crypto de Next.js (C-10).
    """
    if not secret or not x_signature or not x_request_id:
        return False

    parts: dict[str, str] = {}
    for part in x_signature.split(","):
        if "=" in part:
            k, v = part.split("=", 1)
            parts[k] = v

    ts = parts.get("ts")
    v1 = parts.get("v1")
    if not ts or not v1:
        return False

    import json as _json

    try:
        body = _json.loads(raw_body)
        notification_id = (body.get("data") or {}).get("id") or ""
    except Exception:
        return False

    signed_template = f"id:{notification_id};request-id:{x_request_id};ts:{ts};"
    computed = hmac.new(
        secret.encode(),
        signed_template.encode(),
        hashlib.sha256,
    ).hexdigest()

    return hmac.compare_digest(computed, v1)


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


async def _fetch_mp_payment(payment_id: str) -> dict:
    """Consulta MercadoPago REST API y retorna los datos del pago."""
    url = f"https://api.mercadopago.com/v1/payments/{payment_id}"
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.get(
            url,
            headers={"Authorization": f"Bearer {settings.mercadopago_access_token}"},
        )
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

    await conn.execute(
        """
        INSERT INTO billing_events
          (user_id, event_type, from_plan, to_plan, reason,
           mercadopago_payment_id, mercadopago_preference_id, amount, metadata)
        VALUES ($1, 'plan_upgraded', $2, $3, 'C-17 mercadopago-payment-approved',
                $4, $5, $6, $7::jsonb)
        """,
        user_id,
        from_plan,
        plan,
        payment_id,
        preference_id,
        amount,
        f'{{"account_id": "{account_id}", "payment_status": "approved"}}',
    )

    recipient_email = await _fetch_user_email(user_id)
    if recipient_email:
        plan_label = plan.capitalize()
        await conn.execute(
            """
            INSERT INTO email_logs (user_id, event_type, recipient, subject, metadata)
            VALUES ($1, 'plan_upgraded', $2, $3, $4::jsonb)
            """,
            user_id,
            recipient_email,
            f"Tu plan {plan_label} está activo — EmprendeSmart",
            f'{{"plan": "{plan}", "amount": {amount}}}',
        )

    logger.info("[payments] Upgraded user %s from %s to %s", user_id, from_plan, plan)
    return WebhookResponse(ok=True)
