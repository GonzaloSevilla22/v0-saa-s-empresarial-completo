"""
mp-real-subscriptions PR4 — migración de productores programados (4.7/6.14)
+ SubscriptionExpiringSoon en _notification_from_event (D11, 8º tipo).

Mismo patrón de test que test_mp_real_subscriptions_migration.py: lee el
.sql como texto, protege los fragmentos DDL clave. El comportamiento real
(gates a-f) corre en CI vía validate-kpis.
"""
from __future__ import annotations

from pathlib import Path

import pytest

MIGRATION_PATH = Path("supabase/migrations/20260830000001_mp_real_subscriptions_producers.sql")


class TestMigrationContent:
    @pytest.fixture(scope="class")
    def sql(self) -> str:
        assert MIGRATION_PATH.exists(), f"migración no encontrada: {MIGRATION_PATH}"
        return MIGRATION_PATH.read_text(encoding="utf-8")

    # ── _notification_from_event — 8º tipo ──────────────────────────────

    def test_notification_from_event_same_signature(self, sql):
        assert "CREATE OR REPLACE FUNCTION public._notification_from_event(" in sql
        assert "p_event public.events" in sql
        assert sql.count("CREATE OR REPLACE FUNCTION public._notification_from_event") == 1

    def test_notification_from_event_admits_subscription_expiring_soon(self, sql):
        assert "'SubscriptionExpiringSoon'" in sql
        idx = sql.index("ELSIF v_event_type = 'SubscriptionExpiringSoon'")
        branch = sql[idx: idx + 200]
        assert "v_target    := 'ADMIN';" in branch
        assert "v_severity  := 'warning';" in branch
        assert "v_branch_id := NULL;" in branch

    def test_notification_from_event_still_admits_payment_failed_non_regression(self, sql):
        """TRIANGULATE — no-regresión: PR2 agregó SubscriptionPaymentFailed,
        este PR no debe perderlo al redefinir la función de nuevo."""
        assert "'SubscriptionPaymentFailed'" in sql

    def test_notification_from_event_revokes_anon_and_authenticated(self, sql):
        idx = sql.index("REVOKE ALL     ON FUNCTION public._notification_from_event")
        block = sql[idx: idx + 400]
        assert "FROM anon" in block
        assert "FROM authenticated" in block

    # ── _produce_plan_expiring_soon (4.7/7.6) ───────────────────────────

    def test_produce_plan_expiring_soon_is_idempotent(self, sql):
        assert "CREATE OR REPLACE FUNCTION public._produce_plan_expiring_soon()" in sql

    def test_produce_plan_expiring_soon_excludes_gratis(self, sql):
        assert "a.billing_plan IN ('inicial', 'avanzado', 'pro')" in sql

    def test_produce_plan_expiring_soon_excludes_exempt(self, sql):
        assert "NOT a.billing_exempt" in sql

    def test_produce_plan_expiring_soon_excludes_active_trial(self, sql):
        assert "a.trial_expires_at > now()" in sql

    def test_produce_plan_expiring_soon_dedup_via_email_conflict(self, sql):
        """D10-adjacent: el dedup real es el ON CONFLICT de email_logs — el
        evento del outbox solo se crea para las filas que el email
        insertó, así que un solo dedup gobierna los dos canales."""
        assert "ON CONFLICT (user_id, event_type, metadata) DO NOTHING" in sql
        assert "JOIN ins_email e ON e.user_id = c.user_id" in sql

    def test_produce_plan_expiring_soon_revokes_anon_and_authenticated(self, sql):
        assert (
            "REVOKE ALL ON FUNCTION public._produce_plan_expiring_soon() FROM PUBLIC, anon, authenticated"
            in sql
        )

    # ── _expire_stale_subscription_intents (6.14) ───────────────────────

    def test_expire_stale_intents_is_idempotent(self, sql):
        assert "CREATE OR REPLACE FUNCTION public._expire_stale_subscription_intents()" in sql

    def test_expire_stale_intents_does_not_delete(self, sql):
        """D2bis: no borra — queda para auditoría."""
        fn_start = sql.index("CREATE OR REPLACE FUNCTION public._expire_stale_subscription_intents()")
        fn_end = sql.index("$fn$;", fn_start)
        body = sql[fn_start:fn_end]
        assert "DELETE FROM public.subscription_intents" not in body
        assert "SET status = 'expired'" in body

    def test_expire_stale_intents_revokes_anon_and_authenticated(self, sql):
        assert (
            "REVOKE ALL ON FUNCTION public._expire_stale_subscription_intents() FROM PUBLIC, anon, authenticated"
            in sql
        )

    # ── Scheduling ────────────────────────────────────────────────────

    def test_both_jobs_scheduled_idempotently(self, sql):
        for job in (
            "mp-subscriptions-plan-expiring-soon-sweep",
            "mp-subscriptions-expire-stale-intents-sweep",
        ):
            assert f"cron.unschedule('{job}')" in sql
            assert f"'{job}'," in sql  # aparece también en el cron.schedule(...)

    # ── Rollback documentado ──────────────────────────────────────────

    def test_rollback_header_documents_all_three_functions(self, sql):
        header_end = sql.index("-- 1. _notification_from_event")
        header = sql[:header_end]
        assert "ROLLBACK" in header
        assert "_produce_plan_expiring_soon" in header
        assert "_expire_stale_subscription_intents" in header
        assert "cron.unschedule" in header

    # ── Gates SQL embebidos ──────────────────────────────────────────

    def test_do_gate_block_present_with_all_six_gates(self, sql):
        assert "DO $gate$" in sql
        assert "END $gate$;" in sql
        for gate_letter in "abcdef":
            assert f"v_gate_{gate_letter} boolean" in sql, f"falta declarar v_gate_{gate_letter}"
