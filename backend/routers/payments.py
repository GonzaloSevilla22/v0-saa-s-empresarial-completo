from __future__ import annotations

import datetime
import json
import logging
import uuid

import asyncpg
from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response

from backend.core.auth import get_current_user
from backend.core.config import settings
from backend.core.database import get_db_conn, get_service_conn
from backend.core.deps import get_account_id
from backend.repositories.billing_repository import BillingRepository
from backend.repositories.subscriptions_repository import SubscriptionsRepository
from backend.schemas.payments import (
    AccountSearchResultOut,
    AmbiguousSubscriptionOut,
    MpNotification,
    PaymentReceiptOut,
    PaymentReceiptsPageOut,
    ResolveAmbiguousSubscriptionIn,
    SubscriptionCancelOut,
    SubscriptionCreateIn,
    SubscriptionCreateOut,
    SubscriptionOut,
    WebhookResponse,
)
from backend.services.payments import process_payment, verify_mp_signature
from backend.services.receipts import (
    ReceiptData,
    build_receipt_pdf,
    build_receipt_pdf_base64,
    receipt_data_from_row,
)
from backend.services.subscriptions import (
    cancel_subscription,
    create_subscription_intent,
    process_subscription_authorized_payment_notification,
    process_subscription_preapproval_notification,
    resolve_ambiguous_subscription,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/payments", tags=["payments"])


async def require_admin(
    auth: dict = Depends(get_current_user),
    conn: asyncpg.Connection = Depends(get_service_conn),
) -> dict:
    """Gating de administrador de plataforma: profiles.role = 'admin'.

    El rol del JWT no refleja el admin de plataforma (vive en profiles.role),
    así que se verifica en la DB. Usa la conexión service para poder leer
    recibos de todas las cuentas una vez confirmado el admin.
    """
    role = await conn.fetchval(
        "SELECT role FROM profiles WHERE id = $1::uuid", auth["user_id"]
    )
    if role != "admin":
        raise HTTPException(status_code=403, detail="Requiere rol de administrador")
    return auth


def get_billing_repo(
    conn: asyncpg.Connection = Depends(get_service_conn),
) -> BillingRepository:
    return BillingRepository(conn)


def get_subscriptions_repo(
    conn: asyncpg.Connection = Depends(get_service_conn),
) -> SubscriptionsRepository:
    return SubscriptionsRepository(conn)


def require_subscriptions_enabled() -> None:
    """mp-real-subscriptions: palanca de activación (design.md Amendment
    "Activación gated"). Apagada por defecto — mergear este código lo deja
    inerte. Ver backend/core/config.py::billing_subscriptions_enabled."""
    if not settings.billing_subscriptions_enabled:
        raise HTTPException(status_code=503, detail="Suscripciones no habilitadas todavía")


@router.post("/webhook", response_model=WebhookResponse)
async def mercadopago_webhook(
    request: Request,
    shadow: bool = Query(False),
    conn: asyncpg.Connection = Depends(get_service_conn),
) -> WebhookResponse:
    raw_body = await request.body()

    x_signature = request.headers.get("x-signature")
    x_request_id = request.headers.get("x-request-id")
    # mp-real-subscriptions D9: MercadoPago firma con el data.id del QUERY
    # PARAM de la URL de notificación (`?data.id=...&type=...`), no el del
    # cuerpo — ver derive_signed_notification_id. query_params.get soporta
    # tanto "data.id" como el alias "id" que algunos topics usan.
    query_data_id = request.query_params.get("data.id") or request.query_params.get("id")

    # verify_mp_signature ya loguea la causa distintiva del rechazo (falta de
    # configuración vs. firma inválida) — no duplicar un log genérico acá,
    # o volvería a mezclar ambas causas en un solo mensaje (v31-mp-upgrade-
    # webhook-fix, spec payment-webhook "Misconfigured webhook secret...").
    if not verify_mp_signature(
        raw_body, x_signature, x_request_id, settings.mercadopago_webhook_secret, query_data_id=query_data_id
    ):
        raise HTTPException(status_code=400, detail="Firma inválida")

    try:
        notification = MpNotification.model_validate_json(raw_body)
    except Exception:
        raise HTTPException(status_code=400, detail="Payload inválido")

    if not notification.data or not notification.data.id:
        return WebhookResponse(ok=True, skipped=True)

    # Traza de origen (spec payment-webhook "Notification origin is
    # observable", v31-mp-upgrade-webhook-fix D4): el forwarder legacy de
    # Next.js agrega x-relay-source; una notificación directa de MercadoPago
    # nunca trae ese header. No cambia el contrato de respuesta (task 4.6).
    origin = "relayed" if request.headers.get("x-relay-source") else "direct"
    logger.info(
        "[payments/webhook] type=%s id=%s origin=%s", notification.type, notification.data.id, origin
    )

    if notification.type == "payment":
        return await process_payment(notification.data.id, conn, shadow=shadow)

    # mp-real-subscriptions D2bis/D9: topics de suscripción. Detrás de la
    # palanca — apagada, se tratan como "topic no manejado" (task 6.11: sin
    # escrituras, para que MercadoPago no reintente indefinidamente). shadow
    # no se implementa acá (no-goal del flujo de suscripción propio).
    #
    # IMPORTANTE (D9, no confundir con la normalización de la firma): el
    # identificador que se usa para llamar a la API de MP (GET /preapproval/
    # {id}, GET /authorized_payments/{id}) es el del QUERY PARAM tal como
    # vino — CON su mayúsculas/minúsculas originales. `query_data_id` ya se
    # usó arriba para armar el manifiesto firmado en minúsculas
    # (derive_signed_notification_id lo normaliza internamente ahí) — pero
    # el ID real en MercadoPago es case-sensitive, así que reusar la versión
    # YA lowercased acá rompería el GET contra su API (404 por case
    # mismatch). Si no hay query param, se cae al body (compatibilidad).
    subscription_id = query_data_id or notification.data.id

    if settings.billing_subscriptions_enabled and notification.type == "subscription_preapproval":
        subs_repo = SubscriptionsRepository(conn)
        result = await process_subscription_preapproval_notification(subscription_id, subs_repo, conn)
        return WebhookResponse(**result)

    if settings.billing_subscriptions_enabled and notification.type == "subscription_authorized_payment":
        subs_repo = SubscriptionsRepository(conn)
        result = await process_subscription_authorized_payment_notification(subscription_id, subs_repo, conn)
        return WebhookResponse(**result)

    # Topic no manejado (incluye subscription_* con la palanca apagada,
    # y subscription_preapproval_plan que no está en alcance): éxito sin
    # escrituras — task 6.11.
    return WebhookResponse(ok=True, skipped=True)


# ── Suscripciones (mp-real-subscriptions, D2bis) — detrás de la palanca ───────

@router.post(
    "/subscriptions",
    response_model=SubscriptionCreateOut,
    dependencies=[Depends(require_subscriptions_enabled)],
)
async def create_subscription(
    body: SubscriptionCreateIn,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: SubscriptionsRepository = Depends(get_subscriptions_repo),
) -> SubscriptionCreateOut:
    """Alta de suscripción (task 6.3/6.4, D2bis): crea la intención
    pre-registrada y devuelve el init_point del PLAN. NO crea ningún
    preapproval — MercadoPago lo crea cuando el pagador completa el
    checkout; la reconciliación pasa por el webhook."""
    return await create_subscription_intent(str(account_id), auth["user_id"], body.plan, repo)


@router.get(
    "/subscriptions/status",
    response_model=SubscriptionOut,
    dependencies=[Depends(require_subscriptions_enabled)],
)
async def get_subscription_status(
    account_id: uuid.UUID = Depends(get_account_id),
    repo: SubscriptionsRepository = Depends(get_subscriptions_repo),
) -> dict:
    """Estado de la suscripción viva de la cuenta, para `/facturacion`
    (task 8.5). 404 si no hay ninguna — el frontend lo trata como "sin
    suscripción", no como error."""
    row = await repo.find_live_subscription(str(account_id))
    if row is None:
        raise HTTPException(status_code=404, detail="No hay una suscripción viva para esta cuenta")
    return dict(row)


@router.delete(
    "/subscriptions",
    response_model=SubscriptionCancelOut,
    dependencies=[Depends(require_subscriptions_enabled)],
)
async def delete_subscription(
    account_id: uuid.UUID = Depends(get_account_id),
    repo: SubscriptionsRepository = Depends(get_subscriptions_repo),
    conn: asyncpg.Connection = Depends(get_service_conn),
) -> SubscriptionCancelOut:
    """Baja de suscripción (task 6.5/6.6): cancela el preapproval EN
    MERCADOPAGO primero — el acceso se conserva hasta el fin del período ya
    pagado, sin prorrateo (D2bis/Non-Goals)."""
    return await cancel_subscription(str(account_id), repo, conn)


@router.get(
    "/subscriptions/ambiguous",
    response_model=list[AmbiguousSubscriptionOut],
    dependencies=[Depends(require_subscriptions_enabled)],
)
async def list_ambiguous_subscriptions(
    _admin: dict = Depends(require_admin),
    repo: SubscriptionsRepository = Depends(get_subscriptions_repo),
) -> list:
    """Cola de conciliación manual (task 6.8bis, D2bis): suscripciones con
    `account_id NULL` que ningún intento automático pudo resolver. Solo
    admin — el dinero ya se acreditó, esto corrige la atribución."""
    return await repo.list_ambiguous_subscriptions()


@router.post(
    "/subscriptions/ambiguous/{subscription_id}/resolve",
    dependencies=[Depends(require_subscriptions_enabled)],
)
async def resolve_ambiguous_subscription_endpoint(
    subscription_id: uuid.UUID,
    body: ResolveAmbiguousSubscriptionIn,
    _admin: dict = Depends(require_admin),
    repo: SubscriptionsRepository = Depends(get_subscriptions_repo),
    conn: asyncpg.Connection = Depends(get_service_conn),
) -> dict:
    return await resolve_ambiguous_subscription(str(subscription_id), str(body.account_id), repo, conn)


@router.get(
    "/accounts/search",
    response_model=list[AccountSearchResultOut],
)
async def search_accounts(
    q: str = Query(..., min_length=2, max_length=200),
    _admin: dict = Depends(require_admin),
    repo: BillingRepository = Depends(get_billing_repo),
) -> list:
    """Búsqueda de cuentas por email/nombre del owner (task 8.8): alimenta
    el selector de cuenta destino de la pantalla admin de la cola de
    ambiguos. Solo admin. `min_length=2` evita un ILIKE `%%` sin filtro
    real sobre toda la tabla de cuentas."""
    rows = await repo.search_accounts(q)
    return [dict(r) for r in rows]


# ── Recibos de pago (#4 comprobante — vista admin) ────────────────────────────

@router.get("/receipts", response_model=PaymentReceiptsPageOut)
async def list_payment_receipts(
    page: int = Query(0, ge=0),
    page_size: int = Query(50, ge=1, le=200),
    _admin: dict = Depends(require_admin),
    repo: BillingRepository = Depends(get_billing_repo),
) -> dict:
    """Lista los pagos aprobados (recibos) de todas las cuentas. Solo admin."""
    rows, total = await repo.list_receipts(page_size, page * page_size)
    # v3-api-standards §2: envelope estándar {items,total,page,pages}
    pages = -(-total // page_size) if total > 0 else 0
    return {"items": [dict(r) for r in rows], "total": total, "page": page, "pages": pages}


@router.get("/receipt/{billing_event_id}")
async def download_payment_receipt(
    billing_event_id: uuid.UUID,
    _admin: dict = Depends(require_admin),
    repo: BillingRepository = Depends(get_billing_repo),
) -> Response:
    """Genera y devuelve el PDF del recibo de un pago. Solo admin."""
    row = await repo.get_receipt(str(billing_event_id))
    if row is None:
        raise HTTPException(status_code=404, detail="Recibo no encontrado")

    receipt_number = row["receipt_number"] or f"RC-{billing_event_id}"
    data = ReceiptData(
        receipt_number=receipt_number,
        issued_at=row["created_at"],
        customer_email=row["customer_email"],
        customer_name=row["customer_name"],
        plan=row["plan"] or "",
        amount=row["amount"] or 0,
        payment_id=row["payment_id"] or "-",
    )
    pdf = build_receipt_pdf(data)
    return Response(
        content=pdf,
        media_type="application/pdf",
        headers={"Content-Disposition": f'inline; filename="recibo-{receipt_number}.pdf"'},
    )


@router.post("/receipts/{billing_event_id}/resend", status_code=202)
async def resend_payment_receipt(
    billing_event_id: uuid.UUID,
    _admin: dict = Depends(require_admin),
    repo: BillingRepository = Depends(get_billing_repo),
    conn: asyncpg.Connection = Depends(get_service_conn),
) -> dict:
    """Reencola el email del recibo (con el PDF adjunto) al cliente. Solo admin."""
    row = await repo.get_receipt(str(billing_event_id))
    if row is None:
        raise HTTPException(status_code=404, detail="Recibo no encontrado")
    data = dict(row)

    meta: dict = {
        "billing_event_id": str(billing_event_id),
        "receipt_number": data.get("receipt_number"),
        "plan": data.get("plan"),
        "amount": float(data["amount"]) if data.get("amount") is not None else None,
        # único por reenvío (evita el UNIQUE(user_id,event_type,metadata) en reenvíos).
        "requested_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    try:
        meta["receipt_pdf_base64"] = build_receipt_pdf_base64(receipt_data_from_row(data))
    except Exception:
        logger.exception("[payments] No se pudo generar el PDF del recibo para reenvío")

    await conn.execute(
        """
        INSERT INTO email_logs (user_id, event_type, recipient, subject, metadata)
        SELECT be.user_id, 'payment_receipt', $2, $3, $4::jsonb
        FROM billing_events be WHERE be.id = $1::uuid
        """,
        str(billing_event_id),
        data["customer_email"],
        "Tu comprobante de pago — ALIADATA",
        json.dumps(meta),
    )
    return {"ok": True, "recipient": data["customer_email"]}
