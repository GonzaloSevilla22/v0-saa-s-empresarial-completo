"""
fix(billing) 2026-10-13 — tests de integración de los handlers REALES de los
topics de suscripción de MercadoPago contra la DB local (Supabase local stack,
`supabase start`). Marcados `@pytest.mark.integration`: excluidos del gate de
CI (`pytest backend/tests -m "not integration"`) — correr a mano con
`-m integration` cuando el stack local esté levantado.

Por qué existen: hasta este fix ningún test ejecutaba
`process_subscription_authorized_payment_notification` contra un Postgres
real. La suite de mocks asserteaba que al repositorio le llegaba el string de
MercadoPago TAL CUAL, y la integración existente sólo cubría
`_apply_approved_charge`. Ese hueco dejó pasar dos bugs que sólo Postgres
detecta:

1. `next_payment_date` viajaba como `str` (`"2026-10-04T17:02:30.000-04:00"`)
   a una columna `timestamptz` → `asyncpg.DataError` → HTTP 500.
2. La marca de idempotencia se insertaba ANTES de los efectos y sobre una
   conexión en autocommit: quedaba comiteada aunque el handler reventara, así
   que los reintentos de MercadoPago recibían `idempotent` (200) sin aplicar
   nada. La notificación se perdía para siempre.

Caso real (prod, 2026-10-04 21:02 UTC): cuota 7032577415 de $24.900 de la
suscripción fa624f9b-32e5-4b5c-ad0d-fc64e6dc16b1 — cobrada y acreditada en
MercadoPago, sin `billing_event`, sin correo y con `subscriptions.updated_at`
congelado en 2026-09-05.

Los ids de cada test son únicos (no los reales) para que las marcas de
idempotencia y el índice único de `billing_events.mercadopago_payment_id` no
choquen entre corridas; lo que se conserva del caso real es la FORMA del
payload (offset `-04:00`, milisegundos, `next_retry_date` nulo, monto entero).
"""
from __future__ import annotations

import datetime
import decimal
import uuid
from unittest.mock import patch

import asyncpg
import pytest

from backend.repositories.subscriptions_repository import SubscriptionsRepository
from backend.services.subscriptions import (
    GRACE_PERIOD,
    _apply_approved_charge,
    _claim_subscription_webhook_idempotency,
    process_subscription_authorized_payment_notification,
    process_subscription_preapproval_notification,
    replay_subscription_charges,
)
from backend.tests.test_subscriptions_apply_approved_charge_integration import (
    DSN,
    _cleanup,
    _make_account,
)

UTC = datetime.timezone.utc
PLAN_ID_INICIAL = "024813393f994f819327459602d1f8a1"

# Estado de la suscripción ANTES de la cuota de octubre, tal como estaba en
# prod: el ciclo vigente vencía el 04-10 y el plan el 14-10 (ciclo + gracia).
SEEDED_NEXT_PAYMENT_DATE = datetime.datetime(2026, 10, 4, 20, 54, 19, tzinfo=UTC)
SEEDED_PLAN_EXPIRES_AT = datetime.datetime(2026, 10, 14, 20, 54, 19, tzinfo=UTC)
SEEDED_UPDATED_AT = datetime.datetime(2026, 9, 5, 1, 12, 56, tzinfo=UTC)

# Lo que MercadoPago informa DESPUÉS de cobrar la cuota de octubre: el
# siguiente ciclo es el 04-11. Mismo formato que `debit_date` (offset -04:00
# y milisegundos).
MP_NEXT_PAYMENT_DATE = "2026-11-04T16:54:19.000-04:00"
NEXT_CYCLE = datetime.datetime(2026, 11, 4, 20, 54, 19, tzinfo=UTC)


class _MpResponse:
    def __init__(self, payload: dict[str, object], status_code: int = 200):
        self._payload = payload
        self.status_code = status_code

    def json(self) -> dict[str, object]:
        return self._payload


def _mp_api(routes: dict[str, dict[str, object]]):
    """Doble de `httpx.AsyncClient.get`: responde por sufijo de URL con el
    payload que MercadoPago devolvería, y 404 para cualquier otra ruta."""

    async def _get(self, url: str, **kwargs: object) -> _MpResponse:
        for suffix, payload in routes.items():
            if url.endswith(suffix):
                return _MpResponse(payload)
        return _MpResponse({}, status_code=404)

    return _get


def _unique_mp_id() -> int:
    """MercadoPago manda los ids de cuota y de pago como enteros JSON."""
    return 10**11 + uuid.uuid4().int % 10**11


def _cuota_payload(authorized_payment_id: int, preapproval_id: str, payment_id: int) -> dict[str, object]:
    """Forma real de `GET /authorized_payments/7032577415` (los campos que
    lee el handler)."""
    return {
        "id": authorized_payment_id,
        "type": "recurring",
        "status": "processed",
        "preapproval_id": preapproval_id,
        "debit_date": "2026-10-04T17:02:30.000-04:00",
        "next_retry_date": None,
        "retry_attempt": 1,
        "transaction_amount": 24900,
        "currency_id": "ARS",
        "payment": {"id": payment_id, "status": "approved", "status_detail": "accredited"},
    }


def _preapproval_payload(
    preapproval_id: str,
    *,
    status: str = "authorized",
    next_payment_date: str | None = MP_NEXT_PAYMENT_DATE,
) -> dict[str, object]:
    """`GET /preapproval/{id}` — los campos que leen los handlers, con los
    valores que MercadoPago informaba para el caso real después del cobro
    (`next_payment_date` 2026-11-04, `charged_quantity` 2)."""
    return {
        "id": preapproval_id,
        "status": status,
        "payer_email": "pagador@test.local",
        "preapproval_plan_id": PLAN_ID_INICIAL,
        "external_reference": None,
        "next_payment_date": next_payment_date,
        "summarized": {"charged_quantity": 2},
    }


class _RaiseOnMatchingExecute:
    """Envuelve una conexión asyncpg real y hace reventar el `execute()` cuya
    sentencia contenga `fragment` — simula un fallo DESPUÉS de reclamar la
    idempotencia. Mismo molde que `_RaiseOnNthExecute` (H4), pero por
    contenido de la sentencia en vez de por posición: el handler intercala
    escrituras propias con las del repositorio, y contar llamadas ataría el
    test a ese orden. `transaction()` se delega a la conexión real."""

    def __init__(self, conn: asyncpg.Connection, fragment: str):
        self._conn = conn
        self._fragment = fragment

    def transaction(self):
        return self._conn.transaction()

    def is_in_transaction(self) -> bool:
        return self._conn.is_in_transaction()

    async def execute(self, query: str, *args: object) -> str:
        if self._fragment in query:
            raise RuntimeError("simulated failure after the idempotency claim")
        return await self._conn.execute(query, *args)


async def _make_active_account(conn: asyncpg.Connection) -> tuple[uuid.UUID, uuid.UUID, str]:
    account_id, user_id, email = await _make_account(conn)
    await conn.execute(
        "UPDATE public.accounts SET billing_status = 'active', plan_expires_at = $2 WHERE id = $1",
        account_id, SEEDED_PLAN_EXPIRES_AT,
    )
    return account_id, user_id, email


async def _make_subscription(
    conn: asyncpg.Connection,
    *,
    account_id: uuid.UUID | None,
    preapproval_id: str,
    status: str = "authorized",
    ambiguous_reason: str | None = None,
) -> None:
    await conn.execute(
        """
        INSERT INTO public.subscriptions
            (account_id, preapproval_id, preapproval_plan_id, plan, status, ambiguous_reason,
             next_payment_date, retry_state, created_at, updated_at)
        VALUES ($1, $2, $3, 'inicial', $4, $5, $6, 'none', '2026-09-04 21:47:03+00', $7)
        """,
        account_id, preapproval_id, PLAN_ID_INICIAL, status, ambiguous_reason,
        SEEDED_NEXT_PAYMENT_DATE, SEEDED_UPDATED_AT,
    )


async def _cleanup_subscription(conn: asyncpg.Connection, preapproval_id: str, idem_keys: list[str]) -> None:
    await conn.execute(
        """
        DELETE FROM public.operation_idempotency
        WHERE operation_kind = 'subscription_webhook' AND idempotency_key = ANY($1::text[])
        """,
        idem_keys,
    )
    await conn.execute("DELETE FROM public.subscriptions WHERE preapproval_id = $1", preapproval_id)


async def _idempotency_claimed(conn: asyncpg.Connection, key: str) -> bool:
    return bool(
        await conn.fetchval(
            """
            SELECT count(*) FROM public.operation_idempotency
            WHERE operation_kind = 'subscription_webhook' AND idempotency_key = $1
            """,
            key,
        )
    )


async def _subscription_row(conn: asyncpg.Connection, preapproval_id: str) -> asyncpg.Record:
    return await conn.fetchrow(
        """
        SELECT status, next_payment_date, last_payment_status, retry_state, amount, updated_at,
               pending_authorized_payment_id, pending_mercadopago_payment_id
        FROM public.subscriptions WHERE preapproval_id = $1
        """,
        preapproval_id,
    )


async def _count_events(conn: asyncpg.Connection, table: str, user_id: uuid.UUID, event_type: str) -> int:
    assert table in ("billing_events", "email_logs")
    return await conn.fetchval(
        f"SELECT count(*) FROM public.{table} WHERE user_id = $1 AND event_type = $2",
        user_id, event_type,
    )


@pytest.mark.integration
@pytest.mark.asyncio
class TestAuthorizedPaymentWebhookIntegration:
    async def test_real_october_cuota_shape_is_applied_end_to_end(self):
        """RED con el código previo al fix: `asyncpg.DataError` (el string de
        MercadoPago bindeado a `subscriptions.next_payment_date`). GREEN: la
        cuota queda aplicada entera y el plan vence en el SIGUIENTE ciclo +
        gracia (04-11 + 10 d = 14-11), no en el débito de esta cuota + gracia
        (que lo dejaría venciendo el mismo 14-10 que ya tenía)."""
        conn = await asyncpg.connect(DSN)
        account_id, user_id, email = await _make_active_account(conn)
        preapproval_id = f"mp-preapproval-{uuid.uuid4().hex}"
        cuota_id, payment_id = _unique_mp_id(), _unique_mp_id()
        idem_key = f"authorized_payment:{cuota_id}:processed:approved"
        await _make_subscription(conn, account_id=account_id, preapproval_id=preapproval_id)
        mp_api = _mp_api(
            {
                f"/authorized_payments/{cuota_id}": _cuota_payload(cuota_id, preapproval_id, payment_id),
                f"/preapproval/{preapproval_id}": _preapproval_payload(preapproval_id),
            }
        )
        try:
            with patch("httpx.AsyncClient.get", new=mp_api):
                result = await process_subscription_authorized_payment_notification(
                    str(cuota_id), SubscriptionsRepository(conn), conn
                )

            assert result == {"ok": True, "credited": True}

            subscription = await _subscription_row(conn, preapproval_id)
            assert subscription["status"] == "authorized"
            assert subscription["last_payment_status"] == "approved"
            assert subscription["retry_state"] == "none"
            assert subscription["amount"] == decimal.Decimal("24900")
            assert subscription["next_payment_date"] == NEXT_CYCLE
            assert subscription["updated_at"] > SEEDED_UPDATED_AT
            assert subscription["pending_authorized_payment_id"] is None

            billing_event = await conn.fetchrow(
                """
                SELECT mercadopago_payment_id, amount, to_plan FROM public.billing_events
                WHERE user_id = $1 AND event_type = 'subscription_payment_approved'
                """,
                user_id,
            )
            assert billing_event is not None
            assert billing_event["mercadopago_payment_id"] == str(payment_id)
            assert billing_event["amount"] == decimal.Decimal("24900")
            assert billing_event["to_plan"] == "inicial"

            email_log = await conn.fetchrow(
                """
                SELECT recipient FROM public.email_logs
                WHERE user_id = $1 AND event_type = 'subscription_payment_approved'
                """,
                user_id,
            )
            assert email_log is not None
            assert email_log["recipient"] == email

            account = await conn.fetchrow(
                "SELECT plan_expires_at, billing_status FROM public.accounts WHERE id = $1", account_id
            )
            assert account["billing_status"] == "active"
            assert account["plan_expires_at"] == NEXT_CYCLE + GRACE_PERIOD
            assert account["plan_expires_at"] == datetime.datetime(2026, 11, 14, 20, 54, 19, tzinfo=UTC)

            assert await _idempotency_claimed(conn, idem_key)
        finally:
            await _cleanup_subscription(conn, preapproval_id, [idem_key])
            await _cleanup(conn, account_id, user_id)
            await conn.close()

    async def test_ambiguous_row_persists_the_pending_charge(self):
        """La rama sin cuenta (`account_id IS NULL`) bindeaba el mismo string:
        mismo `DataError`. Sin cuenta no hay efecto de dinero que aplicar
        todavía — el cobro queda guardado en la fila para que
        `resolve_ambiguous_subscription` lo replique, con el siguiente ciclo
        como `next_payment_date` (de ahí sale el vencimiento al resolver)."""
        conn = await asyncpg.connect(DSN)
        preapproval_id = f"mp-preapproval-{uuid.uuid4().hex}"
        cuota_id, payment_id = _unique_mp_id(), _unique_mp_id()
        idem_key = f"authorized_payment:{cuota_id}:processed:approved"
        await _make_subscription(
            conn, account_id=None, preapproval_id=preapproval_id,
            status="ambiguous", ambiguous_reason="no_match",
        )
        mp_api = _mp_api(
            {
                f"/authorized_payments/{cuota_id}": _cuota_payload(cuota_id, preapproval_id, payment_id),
                f"/preapproval/{preapproval_id}": _preapproval_payload(preapproval_id),
            }
        )
        try:
            with patch("httpx.AsyncClient.get", new=mp_api):
                result = await process_subscription_authorized_payment_notification(
                    str(cuota_id), SubscriptionsRepository(conn), conn
                )

            assert result == {"ok": True, "credited": True}

            subscription = await _subscription_row(conn, preapproval_id)
            assert subscription["status"] == "ambiguous"
            assert subscription["last_payment_status"] == "approved"
            assert subscription["amount"] == decimal.Decimal("24900")
            assert subscription["next_payment_date"] == NEXT_CYCLE
            assert subscription["pending_authorized_payment_id"] == str(cuota_id)
            assert subscription["pending_mercadopago_payment_id"] == str(payment_id)

            credited = await conn.fetchval(
                "SELECT count(*) FROM public.billing_events WHERE mercadopago_payment_id = $1",
                str(payment_id),
            )
            assert credited == 0
            assert await _idempotency_claimed(conn, idem_key)
        finally:
            await _cleanup_subscription(conn, preapproval_id, [idem_key])
            await conn.close()

    async def test_failure_after_the_claim_does_not_burn_the_notification(self):
        """El agravante estructural. Un fallo después de reclamar la
        idempotencia (acá: el INSERT del correo) NO puede dejar la marca
        comiteada — si queda, el reintento de MercadoPago recibe
        `idempotent` y el cobro se pierde. Tampoco puede dejar la fila de
        `subscriptions` a medio actualizar. El segundo intento SÍ aplica."""
        conn = await asyncpg.connect(DSN)
        account_id, user_id, _ = await _make_active_account(conn)
        preapproval_id = f"mp-preapproval-{uuid.uuid4().hex}"
        cuota_id, payment_id = _unique_mp_id(), _unique_mp_id()
        idem_key = f"authorized_payment:{cuota_id}:processed:approved"
        await _make_subscription(conn, account_id=account_id, preapproval_id=preapproval_id)
        mp_api = _mp_api(
            {
                f"/authorized_payments/{cuota_id}": _cuota_payload(cuota_id, preapproval_id, payment_id),
                f"/preapproval/{preapproval_id}": _preapproval_payload(preapproval_id),
            }
        )
        failing = _RaiseOnMatchingExecute(conn, "INSERT INTO public.email_logs")
        try:
            with patch("httpx.AsyncClient.get", new=mp_api):
                with pytest.raises(RuntimeError, match="simulated failure"):
                    await process_subscription_authorized_payment_notification(
                        str(cuota_id), SubscriptionsRepository(conn), failing
                    )

                # nada quedó comiteado: ni la marca, ni la fila, ni el dinero.
                assert not await _idempotency_claimed(conn, idem_key)
                subscription = await _subscription_row(conn, preapproval_id)
                assert subscription["last_payment_status"] is None
                assert subscription["next_payment_date"] == SEEDED_NEXT_PAYMENT_DATE
                assert subscription["updated_at"] == SEEDED_UPDATED_AT
                assert await _count_events(conn, "billing_events", user_id, "subscription_payment_approved") == 0
                account = await conn.fetchrow(
                    "SELECT plan_expires_at FROM public.accounts WHERE id = $1", account_id
                )
                assert account["plan_expires_at"] == SEEDED_PLAN_EXPIRES_AT

                # el reintento de MercadoPago encuentra la notificación intacta.
                retry = await process_subscription_authorized_payment_notification(
                    str(cuota_id), SubscriptionsRepository(conn), conn
                )

            assert retry == {"ok": True, "credited": True}
            assert await _idempotency_claimed(conn, idem_key)
            assert await _count_events(conn, "billing_events", user_id, "subscription_payment_approved") == 1
            assert await _count_events(conn, "email_logs", user_id, "subscription_payment_approved") == 1
            subscription = await _subscription_row(conn, preapproval_id)
            assert subscription["last_payment_status"] == "approved"
            assert subscription["next_payment_date"] == NEXT_CYCLE
        finally:
            await _cleanup_subscription(conn, preapproval_id, [idem_key])
            await _cleanup(conn, account_id, user_id)
            await conn.close()

    async def test_redelivery_after_success_is_a_no_op(self):
        """Triangulación de la idempotencia: mover la marca adentro de la
        transacción no puede debilitarla. Una vez aplicada la cuota, la
        redelivery devuelve `idempotent` y no duplica recibo ni correo."""
        conn = await asyncpg.connect(DSN)
        account_id, user_id, _ = await _make_active_account(conn)
        preapproval_id = f"mp-preapproval-{uuid.uuid4().hex}"
        cuota_id, payment_id = _unique_mp_id(), _unique_mp_id()
        idem_key = f"authorized_payment:{cuota_id}:processed:approved"
        await _make_subscription(conn, account_id=account_id, preapproval_id=preapproval_id)
        mp_api = _mp_api(
            {
                f"/authorized_payments/{cuota_id}": _cuota_payload(cuota_id, preapproval_id, payment_id),
                f"/preapproval/{preapproval_id}": _preapproval_payload(preapproval_id),
            }
        )
        try:
            with patch("httpx.AsyncClient.get", new=mp_api):
                first = await process_subscription_authorized_payment_notification(
                    str(cuota_id), SubscriptionsRepository(conn), conn
                )
                applied_at = (await _subscription_row(conn, preapproval_id))["updated_at"]
                second = await process_subscription_authorized_payment_notification(
                    str(cuota_id), SubscriptionsRepository(conn), conn
                )

            assert first == {"ok": True, "credited": True}
            assert second == {"ok": True, "idempotent": True}
            assert await _count_events(conn, "billing_events", user_id, "subscription_payment_approved") == 1
            assert await _count_events(conn, "email_logs", user_id, "subscription_payment_approved") == 1
            assert (await _subscription_row(conn, preapproval_id))["updated_at"] == applied_at
        finally:
            await _cleanup_subscription(conn, preapproval_id, [idem_key])
            await _cleanup(conn, account_id, user_id)
            await conn.close()

    async def test_preapproval_without_next_payment_date_does_not_touch_the_expiry(self):
        """Si MercadoPago no informa el siguiente ciclo, la cuota se registra
        igual (recibo + correo) pero el vencimiento NO se extiende: ni se
        calcula desde el débito de esta cuota, ni se borra (un
        `plan_expires_at` nulo significa "sin vencimiento" para
        `get_effective_plan`). La cuenta y la suscripción conservan las
        fechas que tenían."""
        conn = await asyncpg.connect(DSN)
        account_id, user_id, _ = await _make_active_account(conn)
        preapproval_id = f"mp-preapproval-{uuid.uuid4().hex}"
        cuota_id, payment_id = _unique_mp_id(), _unique_mp_id()
        idem_key = f"authorized_payment:{cuota_id}:processed:approved"
        await _make_subscription(conn, account_id=account_id, preapproval_id=preapproval_id)
        mp_api = _mp_api(
            {
                f"/authorized_payments/{cuota_id}": _cuota_payload(cuota_id, preapproval_id, payment_id),
                f"/preapproval/{preapproval_id}": _preapproval_payload(preapproval_id, next_payment_date=None),
            }
        )
        try:
            with patch("httpx.AsyncClient.get", new=mp_api):
                result = await process_subscription_authorized_payment_notification(
                    str(cuota_id), SubscriptionsRepository(conn), conn
                )

            assert result == {"ok": True, "credited": True}
            subscription = await _subscription_row(conn, preapproval_id)
            assert subscription["last_payment_status"] == "approved"
            assert subscription["next_payment_date"] == SEEDED_NEXT_PAYMENT_DATE
            assert await _count_events(conn, "billing_events", user_id, "subscription_payment_approved") == 1
            assert await _count_events(conn, "email_logs", user_id, "subscription_payment_approved") == 1
            account = await conn.fetchrow(
                "SELECT plan_expires_at, billing_status FROM public.accounts WHERE id = $1", account_id
            )
            assert account["billing_status"] == "active"
            assert account["plan_expires_at"] == SEEDED_PLAN_EXPIRES_AT
        finally:
            await _cleanup_subscription(conn, preapproval_id, [idem_key])
            await _cleanup(conn, account_id, user_id)
            await conn.close()


@pytest.mark.integration
@pytest.mark.asyncio
class TestReplaySubscriptionChargesIntegration:
    async def test_replay_repairs_the_lost_cuota_without_resending_the_previous_one(self):
        """La reparación del caso real: la cuota de septiembre ya estaba
        aplicada (recibo + correo, con el vencimiento de aquel momento) y la
        de octubre se perdió. El replay admin aplica la de octubre y deja las
        fechas en el siguiente ciclo.

        RED antes del fix: el correo de renovación se deduplicaba por la
        metadata COMPLETA, que incluye `plan_expires_at`. Con el vencimiento
        tomado del siguiente ciclo vigente, la cuota de septiembre se
        reaplicaba con una fecha distinta a la original y el cliente recibía
        un segundo "Renovamos tu suscripción" por un cobro viejo — en cada
        replay posterior a un cambio de ciclo."""
        conn = await asyncpg.connect(DSN)
        account_id, user_id, _ = await _make_active_account(conn)
        preapproval_id = f"mp-preapproval-{uuid.uuid4().hex}"
        september_id = _unique_mp_id()
        october_id = september_id + 1
        september_payment, october_payment = _unique_mp_id(), _unique_mp_id()
        await _make_subscription(conn, account_id=account_id, preapproval_id=preapproval_id)
        subscription_id = await conn.fetchval(
            "SELECT id FROM public.subscriptions WHERE preapproval_id = $1", preapproval_id
        )
        await _apply_approved_charge(
            conn,
            account_id=str(account_id),
            plan="inicial",
            preapproval_id=preapproval_id,
            authorized_payment_id=str(september_id),
            mercadopago_payment_id=str(september_payment),
            amount=24900,
            plan_expires_at=SEEDED_PLAN_EXPIRES_AT,
        )
        september_cuota = _cuota_payload(september_id, preapproval_id, september_payment)
        september_cuota["debit_date"] = "2026-09-04T16:54:19.000-04:00"
        mp_api = _mp_api(
            {
                f"/preapproval/{preapproval_id}": _preapproval_payload(preapproval_id),
                "/authorized_payments/search": {
                    "paging": {"total": 2},
                    "results": [september_cuota, _cuota_payload(october_id, preapproval_id, october_payment)],
                },
            }
        )
        try:
            with patch("httpx.AsyncClient.get", new=mp_api):
                first = await replay_subscription_charges(
                    str(subscription_id), SubscriptionsRepository(conn), conn
                )
                second = await replay_subscription_charges(
                    str(subscription_id), SubscriptionsRepository(conn), conn
                )

            assert first == {"ok": True, "applied": [str(october_id)], "already_applied": [str(september_id)]}
            assert second == {
                "ok": True, "applied": [], "already_applied": [str(september_id), str(october_id)],
            }
            # un recibo y un correo por cuota — ni uno más, corra las veces que corra.
            assert await _count_events(conn, "billing_events", user_id, "subscription_payment_approved") == 2
            assert await _count_events(conn, "email_logs", user_id, "subscription_payment_approved") == 2

            account = await conn.fetchrow(
                "SELECT plan_expires_at, billing_status FROM public.accounts WHERE id = $1", account_id
            )
            assert account["billing_status"] == "active"
            assert account["plan_expires_at"] == NEXT_CYCLE + GRACE_PERIOD
            subscription = await _subscription_row(conn, preapproval_id)
            assert subscription["next_payment_date"] == NEXT_CYCLE
            assert subscription["last_payment_status"] == "approved"
        finally:
            await _cleanup_subscription(conn, preapproval_id, [])
            await _cleanup(conn, account_id, user_id)
            await conn.close()


@pytest.mark.integration
@pytest.mark.asyncio
class TestIdempotencyClaimIntegration:
    async def test_claim_on_an_autocommit_connection_is_refused_and_writes_nothing(self):
        """La conexión que entrega `get_service_conn` está en autocommit: es
        exactamente la condición en la que la marca quedaba comiteada antes
        que los efectos. Contra una conexión real sin transacción abierta el
        reclamo se niega y no inserta nada."""
        conn = await asyncpg.connect(DSN)
        idem_key = f"authorized_payment:{_unique_mp_id()}:processed:approved"
        try:
            with pytest.raises(RuntimeError, match="transacción"):
                await _claim_subscription_webhook_idempotency(conn, idem_key)
            assert not await _idempotency_claimed(conn, idem_key)

            async with conn.transaction():
                assert await _claim_subscription_webhook_idempotency(conn, idem_key) is True
            assert await _idempotency_claimed(conn, idem_key)
        finally:
            await conn.execute(
                "DELETE FROM public.operation_idempotency WHERE idempotency_key = $1", idem_key
            )
            await conn.close()


@pytest.mark.integration
@pytest.mark.asyncio
class TestPreapprovalWebhookIntegration:
    async def test_failure_after_the_claim_does_not_burn_the_cancellation(self):
        """El topic `subscription_preapproval` comparte el reclamo de
        idempotencia y tenía el mismo defecto. Caso: MercadoPago avisa que la
        suscripción se canceló y el handler falla a mitad de camino. Antes
        quedaban comiteadas la marca, la fila `cancelled` y la cuenta en
        `cancelling`, sin auditoría ni correo, y el reintento no completaba
        nada. Ahora no queda nada escrito y el reintento aplica todo."""
        conn = await asyncpg.connect(DSN)
        account_id, user_id, _ = await _make_active_account(conn)
        preapproval_id = f"mp-preapproval-{uuid.uuid4().hex}"
        idem_key = f"preapproval:{preapproval_id}:cancelled"
        await _make_subscription(conn, account_id=account_id, preapproval_id=preapproval_id)
        mp_api = _mp_api(
            {f"/preapproval/{preapproval_id}": _preapproval_payload(preapproval_id, status="cancelled")}
        )
        failing = _RaiseOnMatchingExecute(conn, "INSERT INTO public.email_logs")
        try:
            with patch("httpx.AsyncClient.get", new=mp_api):
                with pytest.raises(RuntimeError, match="simulated failure"):
                    await process_subscription_preapproval_notification(
                        preapproval_id, SubscriptionsRepository(conn), failing
                    )

                assert not await _idempotency_claimed(conn, idem_key)
                assert (await _subscription_row(conn, preapproval_id))["status"] == "authorized"
                account = await conn.fetchrow(
                    "SELECT billing_status FROM public.accounts WHERE id = $1", account_id
                )
                assert account["billing_status"] == "active"
                assert await _count_events(conn, "billing_events", user_id, "subscription_cancelled") == 0

                retry = await process_subscription_preapproval_notification(
                    preapproval_id, SubscriptionsRepository(conn), conn
                )

            assert retry == {"ok": True}
            assert await _idempotency_claimed(conn, idem_key)
            assert (await _subscription_row(conn, preapproval_id))["status"] == "cancelled"
            account = await conn.fetchrow(
                "SELECT billing_status, plan_expires_at FROM public.accounts WHERE id = $1", account_id
            )
            assert account["billing_status"] == "cancelling"
            assert account["plan_expires_at"] == SEEDED_NEXT_PAYMENT_DATE
            assert await _count_events(conn, "billing_events", user_id, "subscription_cancelled") == 1
            assert await _count_events(conn, "email_logs", user_id, "subscription_cancelled") == 1
        finally:
            await _cleanup_subscription(conn, preapproval_id, [idem_key])
            await _cleanup(conn, account_id, user_id)
            await conn.close()
