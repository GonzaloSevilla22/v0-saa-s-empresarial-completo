"""
mp-cuota-acreditacion-resiliente — integración contra el Postgres local
(`supabase start`). Marcado `@pytest.mark.integration`: corre en el tier de
integración de `KPI_Validation.yml`.

Caso real que lo motivó (prod, 2026-11-04): MercadoPago cobró la cuota de
noviembre ($24.900, pago 187789722328) de la suscripción
fa624f9b-32e5-4b5c-ad0d-fc64e6dc16b1 y NUNCA notificó la cuota `processed`;
la notificación `payment` del mismo cobro se ignoró por diseño. El plan quedó
a diez días de vencer con el mes pagado hasta que el PO corrió "Replicar
cuotas" a mano.

Acá se prueba contra filas reales:

1. La selección del barrido (D4): por el período pagado de la cuenta
   (`accounts.plan_expires_at`), dentro de la ventana, excluyendo lo que no
   corresponde — y nunca por `subscriptions.next_payment_date`.
2. El barrido de punta a punta: acredita la cuota no notificada y la
   suscripción deja de ser seleccionada.
3. El acelerador del webhook `payment` (D6, task 4.6): acredita la cuota y
   la notificación tardía de la misma cuota no duplica nada.

Las fechas son RELATIVAS a `now()` (el barrido compara contra `now()`), no
las de noviembre: el test tiene que dar lo mismo cualquier día que corra.
"""
from __future__ import annotations

import datetime
import uuid
from unittest.mock import patch

import asyncpg
import pytest

from backend.repositories.subscriptions_repository import SubscriptionsRepository
from backend.services.payments import process_payment
from backend.services.subscriptions import (
    GRACE_PERIOD,
    RECONCILE_LOOKBACK,
    process_subscription_authorized_payment_notification,
    reconcile_due_subscriptions,
)
from backend.tests.integration_db import connect
from backend.tests.test_subscriptions_apply_approved_charge_integration import (
    _cleanup,
    _make_account,
)
from backend.tests.test_subscriptions_webhook_handlers_integration import (
    PLAN_ID_INICIAL,
    _cleanup_subscription,
    _mp_api,
    _unique_mp_id,
)

UTC = datetime.timezone.utc


def _mp_date(value: datetime.datetime) -> str:
    """Formato real de MercadoPago: offset -04:00 y milisegundos."""
    local = value.astimezone(datetime.timezone(datetime.timedelta(hours=-4)))
    return local.isoformat(timespec="milliseconds")


async def _seed(
    conn: asyncpg.Connection,
    *,
    plan_expires_at: datetime.datetime | None,
    status: str = "authorized",
    with_account: bool = True,
) -> dict:
    """Una cuenta (con su vencimiento) + una suscripción. `with_account=False`
    deja la suscripción ambigua, sin cuenta."""
    preapproval_id = f"mp-preapproval-{uuid.uuid4().hex}"
    account_id = user_id = None
    if with_account:
        account_id, user_id, _email = await _make_account(conn)
        await conn.execute(
            "UPDATE public.accounts SET billing_status = 'active', plan_expires_at = $2 WHERE id = $1",
            account_id, plan_expires_at,
        )
    ambiguous = status == "ambiguous"
    subscription_id = await conn.fetchval(
        """
        INSERT INTO public.subscriptions
            (account_id, preapproval_id, preapproval_plan_id, plan, status, ambiguous_reason, retry_state)
        VALUES ($1, $2, $3, 'inicial', $4, $5, 'none')
        RETURNING id
        """,
        account_id, preapproval_id, PLAN_ID_INICIAL, status, "no_match" if ambiguous else None,
    )
    return {
        "subscription_id": subscription_id,
        "preapproval_id": preapproval_id,
        "account_id": account_id,
        "user_id": user_id,
    }


async def _teardown(conn: asyncpg.Connection, seeds: list[dict], idem_keys: list[str] | None = None) -> None:
    for seed in seeds:
        await _cleanup_subscription(conn, seed["preapproval_id"], idem_keys or [])
        if seed["account_id"] is not None:
            await _cleanup(conn, seed["account_id"], seed["user_id"])


async def _now(conn: asyncpg.Connection) -> datetime.datetime:
    return await conn.fetchval("SELECT now()")


@pytest.mark.integration
@pytest.mark.asyncio
class TestDueSubscriptionSelection:
    async def test_window_exclusions_and_order_against_real_rows(self):
        """3.1: entran sólo las autorizadas con cuenta cuyo período pagado
        vence dentro de la gracia y no hace más de 30 días; ordenadas por
        vencimiento. Quedan afuera: vencimiento lejano, vencimiento fuera de
        la ventana, cancelada, sin vencimiento y ambigua sin cuenta."""
        conn = await connect()
        now = await _now(conn)
        seeds: dict[str, dict] = {}
        try:
            seeds["due_soon"] = await _seed(conn, plan_expires_at=now + datetime.timedelta(days=5))
            seeds["due_overdue"] = await _seed(conn, plan_expires_at=now - datetime.timedelta(days=29))
            seeds["not_yet"] = await _seed(conn, plan_expires_at=now + datetime.timedelta(days=11))
            seeds["too_old"] = await _seed(conn, plan_expires_at=now - datetime.timedelta(days=31))
            seeds["cancelled"] = await _seed(conn, plan_expires_at=now, status="cancelled")
            seeds["no_expiry"] = await _seed(conn, plan_expires_at=None)
            seeds["ambiguous"] = await _seed(conn, plan_expires_at=None, status="ambiguous", with_account=False)

            rows = await SubscriptionsRepository(conn).find_subscriptions_due_for_reconciliation(
                grace=GRACE_PERIOD, lookback=RECONCILE_LOOKBACK, limit=1000
            )
            ours = {s["preapproval_id"]: name for name, s in seeds.items()}
            selected = [ours[r["preapproval_id"]] for r in rows if r["preapproval_id"] in ours]

            assert selected == ["due_overdue", "due_soon"]
            picked = next(r for r in rows if r["preapproval_id"] == seeds["due_soon"]["preapproval_id"])
            assert str(picked["account_id"]) == str(seeds["due_soon"]["account_id"])
            assert picked["plan"] == "inicial"
        finally:
            await _teardown(conn, list(seeds.values()))
            await conn.close()

    async def test_limit_bounds_one_run(self):
        """TRIANGULATE: el `LIMIT` acota una corrida (con 2 elegibles y
        `limit=1` vuelve una sola fila)."""
        conn = await connect()
        now = await _now(conn)
        seeds: list[dict] = []
        try:
            seeds.append(await _seed(conn, plan_expires_at=now - datetime.timedelta(days=1)))
            seeds.append(await _seed(conn, plan_expires_at=now - datetime.timedelta(days=2)))
            rows = await SubscriptionsRepository(conn).find_subscriptions_due_for_reconciliation(
                grace=GRACE_PERIOD, lookback=RECONCILE_LOOKBACK, limit=1
            )
            assert len(rows) == 1
        finally:
            await _teardown(conn, seeds)
            await conn.close()


def _routes_for(preapproval_id: str, next_cycle: datetime.datetime, cuota_id: int, payment_id: int,
                cuota_status: str = "processed") -> dict[str, dict[str, object]]:
    cuota = {
        "id": cuota_id,
        "type": "recurring",
        "status": cuota_status,
        "preapproval_id": preapproval_id,
        "debit_date": _mp_date(next_cycle - datetime.timedelta(days=30)),
        "transaction_amount": 24900,
        "currency_id": "ARS",
        "payment": {"id": payment_id, "status": "approved"} if cuota_status == "processed" else {},
    }
    return {
        f"/preapproval/{preapproval_id}": {
            "id": preapproval_id,
            "status": "authorized",
            "preapproval_plan_id": PLAN_ID_INICIAL,
            "next_payment_date": _mp_date(next_cycle),
        },
        "/authorized_payments/search": {"paging": {"total": 1}, "results": [cuota]},
        f"/authorized_payments/{cuota_id}": cuota,
    }


async def _credited(conn: asyncpg.Connection, user_id: uuid.UUID) -> tuple[int, int]:
    billing = await conn.fetchval(
        "SELECT count(*) FROM public.billing_events WHERE user_id = $1 AND event_type = 'subscription_payment_approved'",
        user_id,
    )
    emails = await conn.fetchval(
        "SELECT count(*) FROM public.email_logs WHERE user_id = $1 AND event_type = 'subscription_payment_approved'",
        user_id,
    )
    return billing, emails


@pytest.mark.integration
@pytest.mark.asyncio
class TestSweepEndToEnd:
    async def test_unnotified_processed_cuota_is_credited_and_leaves_the_sweep(self):
        """Escenario "Cuota procesada sin notificación se acredita en el
        barrido siguiente": el período pagado pasa al siguiente ciclo +
        gracia, queda UN cobro auditado y UN correo, y la suscripción deja de
        ser seleccionada."""
        conn = await connect()
        now = await _now(conn)
        seed = await _seed(conn, plan_expires_at=now + datetime.timedelta(days=5))
        next_cycle = (now + datetime.timedelta(days=25)).replace(microsecond=0)
        cuota_id, payment_id = _unique_mp_id(), _unique_mp_id()
        routes = _routes_for(seed["preapproval_id"], next_cycle, cuota_id, payment_id)
        repo = SubscriptionsRepository(conn)
        try:
            # Sólo la suscripción sembrada: el resto de la base local queda
            # fuera del barrido de este test.
            original = repo.find_subscriptions_due_for_reconciliation

            async def _only_ours(**kwargs):
                rows = await original(grace=kwargs["grace"], lookback=kwargs["lookback"], limit=1000)
                return [r for r in rows if r["preapproval_id"] == seed["preapproval_id"]]

            repo.find_subscriptions_due_for_reconciliation = _only_ours
            with (
                patch("backend.services.subscriptions.settings.billing_subscriptions_enabled", True),
                patch("httpx.AsyncClient.get", new=_mp_api(routes)),
            ):
                summary = await reconcile_due_subscriptions(repo, conn)
                again = await reconcile_due_subscriptions(repo, conn)

            assert summary == {"ok": True, "checked": 1, "applied": [str(cuota_id)], "errors": 0}
            assert again == {"ok": True, "checked": 0, "applied": [], "errors": 0}
            expiry = await conn.fetchval(
                "SELECT plan_expires_at FROM public.accounts WHERE id = $1", seed["account_id"]
            )
            assert expiry == next_cycle + GRACE_PERIOD
            assert await _credited(conn, seed["user_id"]) == (1, 1)
        finally:
            await _teardown(conn, [seed])
            await conn.close()

    async def test_cuota_still_scheduled_credits_nothing_and_stays_selected(self):
        """Escenario "Cuota todavía no procesada no acredita nada": ni
        vencimiento, ni cobro, y la suscripción vuelve a ser elegible."""
        conn = await connect()
        now = await _now(conn)
        original_expiry = (now + datetime.timedelta(days=5)).replace(microsecond=0)
        seed = await _seed(conn, plan_expires_at=original_expiry)
        next_cycle = (now + datetime.timedelta(days=25)).replace(microsecond=0)
        routes = _routes_for(seed["preapproval_id"], next_cycle, _unique_mp_id(), _unique_mp_id(),
                             cuota_status="scheduled")
        repo = SubscriptionsRepository(conn)
        try:
            with patch("httpx.AsyncClient.get", new=_mp_api(routes)):
                from backend.services.subscriptions import reconcile_preapproval_charges

                result = await reconcile_preapproval_charges(
                    {"account_id": seed["account_id"], "preapproval_id": seed["preapproval_id"], "plan": "inicial"},
                    repo, conn,
                )
            assert result == {"applied": [], "already_applied": []}
            expiry = await conn.fetchval(
                "SELECT plan_expires_at FROM public.accounts WHERE id = $1", seed["account_id"]
            )
            assert expiry == original_expiry
            assert await _credited(conn, seed["user_id"]) == (0, 0)
            rows = await repo.find_subscriptions_due_for_reconciliation(
                grace=GRACE_PERIOD, lookback=RECONCILE_LOOKBACK, limit=1000
            )
            assert seed["preapproval_id"] in {r["preapproval_id"] for r in rows}
        finally:
            await _teardown(conn, [seed])
            await conn.close()


@pytest.mark.integration
@pytest.mark.asyncio
class TestPaymentWebhookAccelerator:
    async def test_payment_with_preapproval_credits_and_late_cuota_is_a_no_op(self):
        """4.6 (D6): la notificación `payment` del cobro con
        `metadata.preapproval_id` acredita la cuota; la notificación tardía
        `processed/approved` de la MISMA cuota no agrega un cobro, ni un
        correo, ni vuelve a mover el vencimiento."""
        conn = await connect()
        now = await _now(conn)
        seed = await _seed(conn, plan_expires_at=now + datetime.timedelta(days=5))
        next_cycle = (now + datetime.timedelta(days=25)).replace(microsecond=0)
        cuota_id, payment_id = _unique_mp_id(), _unique_mp_id()
        routes = _routes_for(seed["preapproval_id"], next_cycle, cuota_id, payment_id)
        routes[f"/v1/payments/{payment_id}"] = {
            "id": payment_id,
            "status": "approved",
            "external_reference": None,
            "operation_type": "recurring_payment",
            "metadata": {"preapproval_id": seed["preapproval_id"]},
            "transaction_amount": 24900,
        }
        idem_key = f"authorized_payment:{cuota_id}:processed:approved"
        repo = SubscriptionsRepository(conn)
        try:
            with (
                patch("backend.services.payments.settings.billing_subscriptions_enabled", True),
                patch("httpx.AsyncClient.get", new=_mp_api(routes)),
            ):
                response = await process_payment(str(payment_id), conn, subscriptions_repo=repo)
                assert response.reconciled == "subscription_charge"
                assert response.ignored is None
                expiry_after_payment = await conn.fetchval(
                    "SELECT plan_expires_at FROM public.accounts WHERE id = $1", seed["account_id"]
                )

                late = await process_subscription_authorized_payment_notification(str(cuota_id), repo, conn)

            assert late["ok"] is True
            assert expiry_after_payment == next_cycle + GRACE_PERIOD
            assert await conn.fetchval(
                "SELECT plan_expires_at FROM public.accounts WHERE id = $1", seed["account_id"]
            ) == expiry_after_payment
            assert await _credited(conn, seed["user_id"]) == (1, 1)
        finally:
            await _teardown(conn, [seed], [idem_key])
            await conn.close()
