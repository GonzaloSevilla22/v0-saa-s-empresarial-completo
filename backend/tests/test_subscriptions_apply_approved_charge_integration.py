"""
H4 hotfix (2026-09-04) — test de integración contra la DB local real
(Supabase local stack, `supabase start`). Marcado `@pytest.mark.integration`:
excluido del gate de CI (`pytest backend/tests -m "not integration"`,
Backend_Tests.yml) — correr a mano con `-m integration` cuando el stack local
esté levantado.

Por qué hace falta un test de integración además de los mocks: el bug real
(sqlstate 42P18, "could not determine data type of parameter") solo lo
detecta Postgres analizando la sentencia — un mock de `conn.execute` nunca lo
habría atrapado (de hecho, no lo atrapó: la suite de mocks estaba en verde
mientras el bug vivía en producción). Este test ejercita
`_apply_approved_charge` de punta a punta contra un Postgres real:

1. Reproduce el caso real (fa624f9b-.../176341057469/$24.900): las 3 filas
   quedan escritas — `accounts.plan_expires_at`/`billing_status`,
   `billing_events`, `email_logs`.
2. Prueba la atomicidad (H4, la segunda mitad del fix): si la 3ª escritura
   falla, las 2 anteriores NO quedan escritas — antes de este fix sí
   quedaban (aplicación parcial verificada en prod).
"""
from __future__ import annotations

import datetime
import decimal
import json
import os
import uuid

import asyncpg
import pytest

from backend.services.subscriptions import _apply_approved_charge

DSN = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@127.0.0.1:54322/postgres")


class _RaiseOnNthExecute:
    """Envuelve una conexión asyncpg real y hace que la N-ésima llamada a
    `execute()` reviente con un error arbitrario — para probar que
    `async with conn.transaction():` realmente deshace lo anterior cuando
    una escritura posterior falla. `transaction()`/`fetchval()` se delegan
    sin cambios a la conexión real."""

    def __init__(self, conn: asyncpg.Connection, raise_at: int):
        self._conn = conn
        self._raise_at = raise_at
        self._count = 0

    def transaction(self):
        return self._conn.transaction()

    async def execute(self, *args, **kwargs):
        self._count += 1
        if self._count == self._raise_at:
            raise RuntimeError("simulated failure — atomicity test (H4)")
        return await self._conn.execute(*args, **kwargs)

    async def fetchval(self, *args, **kwargs):
        return await self._conn.fetchval(*args, **kwargs)


async def _make_account(conn: asyncpg.Connection) -> tuple[uuid.UUID, uuid.UUID, str]:
    """Siembra un auth.users + public.accounts mínimos — email_logs hace
    JOIN auth.users, así que hace falta un usuario real, no solo la cuenta."""
    user_id = uuid.uuid4()
    account_id = uuid.uuid4()
    email = f"h4-hotfix-test-{user_id}@test.local"
    await conn.execute(
        """
        INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
        VALUES ($1, 'authenticated', 'authenticated', $2, now(), now(), '{}'::jsonb)
        """,
        user_id, email,
    )
    await conn.execute(
        """
        INSERT INTO public.accounts (id, owner_user_id, billing_plan, billing_status)
        VALUES ($1, $2, 'inicial', 'trialing')
        """,
        account_id, user_id,
    )
    return account_id, user_id, email


async def _cleanup(conn: asyncpg.Connection, account_id: uuid.UUID, user_id: uuid.UUID) -> None:
    """Limpia TODO lo que `auth.users` dispara automáticamente al insertar
    (handle_new_user crea, además de la cuenta que sembramos a mano, su
    propia `accounts`/`account_members`/`branches` — mismo patrón de
    limpieza que 20260903000001_fix_email_logs_null_collision.sql).

    `session_replication_role = replica` (alcance transaccional, `SET
    LOCAL`) desactiva los triggers para este borrado — sin esto, el borrado
    físico de `branches` lo rechaza incondicionalmente
    `trg_guard_branch_decommission` (sucursal-guard-vaciado-auditoria,
    2026-08-25); mismo patrón ya usado en los gates SQL del repo (41 usos
    documentados) para limpiar fixtures de test."""
    async with conn.transaction():
        await conn.execute("SET LOCAL session_replication_role = replica")
        await conn.execute("DELETE FROM public.email_logs WHERE user_id = $1", user_id)
        await conn.execute("DELETE FROM public.billing_events WHERE user_id = $1", user_id)
        await conn.execute(
            """
            DELETE FROM public.branch_stock WHERE branch_id IN (
                SELECT id FROM public.branches WHERE account_id IN (
                    SELECT id FROM public.accounts WHERE owner_user_id = $1 OR id = $2))
            """,
            user_id, account_id,
        )
        await conn.execute(
            """
            DELETE FROM public.cashboxes WHERE branch_id IN (
                SELECT id FROM public.branches WHERE account_id IN (
                    SELECT id FROM public.accounts WHERE owner_user_id = $1 OR id = $2))
            """,
            user_id, account_id,
        )
        await conn.execute(
            """
            DELETE FROM public.branches WHERE account_id IN (
                SELECT id FROM public.accounts WHERE owner_user_id = $1 OR id = $2)
            """,
            user_id, account_id,
        )
        await conn.execute("DELETE FROM public.account_members WHERE user_id = $1", user_id)
        await conn.execute(
            "DELETE FROM public.accounts WHERE owner_user_id = $1 OR id = $2", user_id, account_id,
        )
        await conn.execute("DELETE FROM public.profiles WHERE id = $1", user_id)
        await conn.execute("DELETE FROM auth.users WHERE id = $1", user_id)


@pytest.mark.integration
@pytest.mark.asyncio
class TestApplyApprovedChargeIntegration:
    async def test_writes_all_three_rows_real_case_shape(self):
        """GREEN: reproduce el caso real (montos/ids con la misma FORMA que
        fa624f9b-32e5-4b5c-ad0d-fc64e6dc16b1/176341057469/$24.900) contra
        Postgres real — antes del fix esto reventaba con 42P18 en el 3er
        INSERT."""
        conn = await asyncpg.connect(DSN)
        account_id, user_id, email = await _make_account(conn)
        preapproval_id = f"mp-preapproval-{uuid.uuid4()}"
        authorized_payment_id = "7031580844"
        mercadopago_payment_id = "176341057469"
        plan_expires_at = datetime.datetime(2026, 10, 14, 20, 54, 19, tzinfo=datetime.timezone.utc)
        try:
            await _apply_approved_charge(
                conn,
                account_id=str(account_id),
                plan="inicial",
                preapproval_id=preapproval_id,
                authorized_payment_id=authorized_payment_id,
                mercadopago_payment_id=mercadopago_payment_id,
                amount=24900,  # tal como llega de MP para este caso real (sin decimales)
                plan_expires_at=plan_expires_at,
            )

            account_row = await conn.fetchrow(
                "SELECT plan_expires_at, billing_status FROM public.accounts WHERE id = $1",
                account_id,
            )
            assert account_row["billing_status"] == "active"
            assert account_row["plan_expires_at"] == plan_expires_at

            billing_event = await conn.fetchrow(
                """
                SELECT event_type, mercadopago_payment_id, amount, metadata
                FROM public.billing_events
                WHERE user_id = $1 AND event_type = 'subscription_payment_approved'
                """,
                user_id,
            )
            assert billing_event is not None
            assert billing_event["mercadopago_payment_id"] == mercadopago_payment_id
            assert billing_event["amount"] == decimal.Decimal("24900")
            # asyncpg devuelve jsonb como str crudo por default (sin codec
            # jsonb configurado) — json.loads() para inspeccionar el objeto.
            billing_metadata = json.loads(billing_event["metadata"])
            assert billing_metadata["authorized_payment_id"] == authorized_payment_id

            email_log = await conn.fetchrow(
                """
                SELECT event_type, recipient, metadata
                FROM public.email_logs
                WHERE user_id = $1 AND event_type = 'subscription_payment_approved'
                """,
                user_id,
            )
            assert email_log is not None
            assert email_log["recipient"] == email
            email_metadata = json.loads(email_log["metadata"])
            assert email_metadata["authorized_payment_id"] == authorized_payment_id
            assert email_metadata["plan"] == "inicial"
        finally:
            await _cleanup(conn, account_id, user_id)
            await conn.close()

    async def test_third_write_failing_rolls_back_the_first_two(self):
        """H4 — RED antes del fix / GREEN ahora: si la 3ra escritura
        (email_logs) falla, la transacción deshace TAMBIÉN la 1ra
        (accounts) y la 2da (billing_events). Antes de envolver las 3
        escrituras en `conn.transaction()`, esto NO pasaba — es exactamente
        la aplicación parcial que se midió en prod para
        fa624f9b-32e5-4b5c-ad0d-fc64e6dc16b1 (accounts/billing_events
        escritos, email_logs faltante)."""
        conn = await asyncpg.connect(DSN)
        account_id, user_id, email = await _make_account(conn)
        preapproval_id = f"mp-preapproval-{uuid.uuid4()}"
        mercadopago_payment_id = f"mp-payment-{uuid.uuid4()}"
        wrapped = _RaiseOnNthExecute(conn, raise_at=3)  # 3ra = INSERT email_logs
        try:
            with pytest.raises(RuntimeError, match="simulated failure"):
                await _apply_approved_charge(
                    wrapped,
                    account_id=str(account_id),
                    plan="inicial",
                    preapproval_id=preapproval_id,
                    authorized_payment_id="ap-atomicity-1",
                    mercadopago_payment_id=mercadopago_payment_id,
                    amount=24900,
                    plan_expires_at=datetime.datetime(2026, 10, 1, tzinfo=datetime.timezone.utc),
                )

            # las 2 escrituras ANTERIORES a la que falló deben haberse
            # deshecho junto con ella — ninguna quedó comiteada suelta.
            account_row = await conn.fetchrow(
                "SELECT plan_expires_at, billing_status FROM public.accounts WHERE id = $1",
                account_id,
            )
            assert account_row["billing_status"] == "trialing"  # el valor ORIGINAL, sin tocar
            assert account_row["plan_expires_at"] is None

            billing_event = await conn.fetchval(
                "SELECT count(*) FROM public.billing_events WHERE user_id = $1",
                user_id,
            )
            assert billing_event == 0

            # filtrado por event_type: `handle_new_user` (trigger de
            # auth.users) siembra sus PROPIAS filas de email_logs para todo
            # usuario nuevo ('welcome' + 'new_user_admin_notice', ambas con
            # este mismo user_id) — no son parte de lo que
            # _apply_approved_charge debería haber escrito, así que un
            # `count(*)` sin filtrar por event_type daría un falso negativo
            # (2, no 0) y ocultaría que el rollback SÍ funcionó.
            email_log = await conn.fetchval(
                """
                SELECT count(*) FROM public.email_logs
                WHERE user_id = $1 AND event_type = 'subscription_payment_approved'
                """,
                user_id,
            )
            assert email_log == 0
        finally:
            await _cleanup(conn, account_id, user_id)
            await conn.close()
