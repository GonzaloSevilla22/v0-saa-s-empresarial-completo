"""
mp-real-subscriptions §4/§5 — migración de esquema (subscriptions,
subscription_intents, operation_idempotency.operation_kind,
_notification_from_event, get_effective_plan).

Patrón de test (mismo que test_v3_api_standards_migration.py /
test_c3_bank_reconciliation.py::TestMigrationContent): lee el .sql como
texto y verifica presencia de los fragmentos DDL clave. No ejecuta contra
una DB real — el comportamiento real (los 14 gates SQL, estructurales a-g +
de comportamiento h-n) corre dentro de la propia migración vía DO $gate$
cuando CI aplica el archivo contra una base real (job validate-kpis). Este
archivo es la red de seguridad estática: protege contra una edición futura
que rompa un fragmento sin que nadie note que el gate SQL correspondiente
dejó de poder pasar.
"""
from __future__ import annotations

from pathlib import Path

import pytest

MIGRATION_PATH = Path("supabase/migrations/20260829000001_mp_real_subscriptions_schema.sql")


class TestMigrationContent:
    @pytest.fixture(scope="class")
    def sql(self) -> str:
        assert MIGRATION_PATH.exists(), f"migración no encontrada: {MIGRATION_PATH}"
        return MIGRATION_PATH.read_text(encoding="utf-8")

    # ── Tablas (D4/D2bis) ────────────────────────────────────────────────

    def test_subscriptions_table_is_idempotent(self, sql):
        assert "CREATE TABLE IF NOT EXISTS public.subscriptions" in sql

    def test_subscription_intents_table_is_idempotent(self, sql):
        assert "CREATE TABLE IF NOT EXISTS public.subscription_intents" in sql

    def test_subscriptions_account_id_is_nullable(self, sql):
        """D2bis: una fila 'ambiguous' nace sin dueño conocido. account_id
        NO debe llevar NOT NULL en subscriptions (a diferencia de
        subscription_intents, donde SÍ es NOT NULL — quien inicia el alta
        siempre se conoce)."""
        table_start = sql.index("CREATE TABLE IF NOT EXISTS public.subscriptions (")
        table_end = sql.index(");", table_start)
        table_body = sql[table_start:table_end]
        account_id_line = next(
            line for line in table_body.splitlines() if line.strip().startswith("account_id")
        )
        assert "NOT NULL" not in account_id_line, (
            f"subscriptions.account_id debe ser nullable (D2bis): {account_id_line!r}"
        )

    def test_subscription_intents_account_id_is_not_null(self, sql):
        table_start = sql.index("CREATE TABLE IF NOT EXISTS public.subscription_intents (")
        table_end = sql.index(");", table_start)
        table_body = sql[table_start:table_end]
        account_id_line = next(
            line for line in table_body.splitlines() if line.strip().startswith("account_id")
        )
        assert "NOT NULL" in account_id_line

    def test_subscription_intents_payer_email_normalized_check(self, sql):
        """D2bis: defensa en profundidad — el email se normaliza también a
        nivel de DB, no solo en el backend."""
        assert "payer_email = lower(trim(payer_email))" in sql

    # ── Índice único parcial (D4) ────────────────────────────────────────

    def test_partial_unique_index_one_live_subscription_per_account(self, sql):
        assert "CREATE UNIQUE INDEX IF NOT EXISTS idx_subscriptions_one_live_per_account" in sql
        assert "WHERE status IN ('pending', 'authorized') AND account_id IS NOT NULL" in sql

    # ── RLS (D4) ──────────────────────────────────────────────────────────

    def test_rls_enabled_on_both_tables(self, sql):
        assert "ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY" in sql
        assert "ALTER TABLE public.subscription_intents ENABLE ROW LEVEL SECURITY" in sql

    def test_no_write_policies_for_authenticated(self, sql):
        """D4: deliberadamente SIN policies de INSERT/UPDATE/DELETE — el
        estado lo escribe solo el backend. Si alguien agrega una policy de
        escritura sin querer, este test debe fallar."""
        for verb in ("FOR INSERT", "FOR UPDATE", "FOR DELETE"):
            assert verb not in sql, (
                f"se encontró una policy '{verb}' — subscriptions/subscription_intents "
                "son SELECT-only por diseño (D4)"
            )
        assert sql.count("FOR SELECT") == 2

    # ── operation_idempotency.operation_kind (D5, lección C3) ──────────────

    def test_operation_kind_check_is_idempotent_drop_if_exists(self, sql):
        assert "DROP CONSTRAINT IF EXISTS operation_idempotency_operation_kind_check" in sql
        assert "ADD CONSTRAINT operation_idempotency_operation_kind_check" in sql

    def test_operation_kind_check_preserves_all_nine_previous_kinds(self, sql):
        """TRIANGULATE — regresión del incidente C3: el DROP+ADD debe
        reproducir la UNIÓN vigente en prod, leída con MCP el 2026-08-01
        sobre gxdhpxvdjjkmxhdkkwyb (9 valores) o el db push rompe 23514
        contra filas existentes (CI no lo atrapa: su DB nace vacía)."""
        for kind in (
            "'sale'", "'purchase'", "'payment_received'", "'payment_made'",
            "'supplier_charge'", "'bank_movement'", "'event_consumer'",
            "'bank_statement_import'", "'cash_session_close'",
        ):
            assert kind in sql, f"falta {kind} en el CHECK de operation_kind (lección C3)"

    def test_operation_kind_check_admits_subscription_webhook(self, sql):
        assert "'subscription_webhook'" in sql

    # ── _notification_from_event (D11) ──────────────────────────────────

    def test_notification_from_event_same_signature(self, sql):
        """El dispatcher rpc_process_outbox_dispatch no se toca — la firma
        de _notification_from_event debe seguir siendo (public.events)."""
        assert "CREATE OR REPLACE FUNCTION public._notification_from_event(" in sql
        assert "p_event public.events" in sql
        assert sql.count("CREATE OR REPLACE FUNCTION public._notification_from_event") == 1

    def test_notification_from_event_admits_subscription_payment_failed(self, sql):
        assert "'SubscriptionPaymentFailed'" in sql
        # target ADMIN, severity warning, sin branch_id — mismo patrón que PlanLimitExceeded
        idx = sql.index("ELSIF v_event_type = 'SubscriptionPaymentFailed'")
        branch = sql[idx: idx + 200]
        assert "v_target    := 'ADMIN';" in branch
        assert "v_severity  := 'warning';" in branch
        assert "v_branch_id := NULL;" in branch

    def test_notification_from_event_revokes_anon_and_authenticated(self, sql):
        """Gate ACL: REVOKE explícito de anon Y authenticated, no solo
        FROM PUBLIC (gotcha confirmado PR #337)."""
        idx = sql.index("REVOKE ALL     ON FUNCTION public._notification_from_event")
        block = sql[idx: idx + 400]
        assert "FROM anon" in block
        assert "FROM authenticated" in block

    # ── get_effective_plan (D6 — el paso delicado) ──────────────────────

    def test_get_effective_plan_same_single_argument_signature(self, sql):
        """Lección 42725/C3: agregar un parámetro crearía un overload. La
        firma debe seguir siendo (p_account_id uuid) — un solo argumento.
        El cuerpo (excluyendo el header, que trae el rollback textual como
        comentario con su propia copia de esta línea) debe tener EXACTAMENTE
        una definición real."""
        header_end = sql.index("-- 1. public.subscriptions")
        body = sql[header_end:]
        assert "CREATE OR REPLACE FUNCTION public.get_effective_plan(p_account_id uuid)" in body
        assert body.count("CREATE OR REPLACE FUNCTION public.get_effective_plan") == 1
        # ninguna firma con 2 argumentos (ej. agregar p_as_of) se coló
        assert "get_effective_plan(p_account_id uuid, " not in sql

    def test_get_effective_plan_null_does_not_degrade(self, sql):
        """D6: plan_expires_at NULL conserva el plan pago (semántica
        permisiva, OQ1 resuelta (b))."""
        assert "v_account.plan_expires_at IS NULL OR v_account.plan_expires_at > now()" in sql

    def test_get_effective_plan_revoke_and_grant_reaffirmed(self, sql):
        assert (
            "REVOKE ALL ON FUNCTION public.get_effective_plan(uuid) FROM PUBLIC, anon, authenticated"
            in sql
        )
        assert (
            "GRANT EXECUTE ON FUNCTION public.get_effective_plan(uuid) TO supabase_auth_admin, service_role"
            in sql
        )

    def test_get_effective_plan_precedence_order_preserved(self, sql):
        """TRIANGULATE — no-regresión: exención antes que trial, trial antes
        que billing_plan, en ese orden textual dentro de la función REAL
        (D1 billing-pro-trial, intacto). Ancla después del header —
        `.index()` encontraría primero la copia comentada del rollback
        textual, que también contiene estos fragmentos en el mismo orden."""
        header_end = sql.index("-- 1. public.subscriptions")
        fn_start = sql.index("CREATE OR REPLACE FUNCTION public.get_effective_plan", header_end)
        fn_end = sql.index("REVOKE ALL ON FUNCTION public.get_effective_plan", fn_start)
        body = sql[fn_start:fn_end]
        exempt_idx = body.index("billing_exempt")
        trial_idx = body.index("trial_plan IS NOT NULL")
        billing_plan_idx = body.index("billing_plan IN")
        assert exempt_idx < trial_idx < billing_plan_idx

    # ── Rollback documentado (task 4.10) ─────────────────────────────────

    def test_rollback_header_documents_get_effective_plan_restoration(self, sql):
        header_end = sql.index("-- 1. public.subscriptions")
        header = sql[:header_end]
        assert "ROLLBACK" in header
        assert "get_effective_plan" in header
        assert "DROP TABLE IF EXISTS public.subscription_intents" in header
        assert "DROP TABLE IF EXISTS public.subscriptions" in header

    # ── Gates SQL embebidos ──────────────────────────────────────────────

    def test_do_gate_block_present_with_all_fourteen_gates(self, sql):
        assert "DO $gate$" in sql
        assert "END $gate$;" in sql
        for gate_letter in "abcdefghijklmn":
            assert f"v_gate_{gate_letter} boolean" in sql, f"falta declarar v_gate_{gate_letter}"
