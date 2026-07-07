"""
v3-api-standards §4 — migración gobernada del CHECK de operation_idempotency
para agregar el operation_kind 'cash_session_close' (Lección C3).

Patrón de test (mismo que test_c3_bank_reconciliation.py::TestMigrationContent):
lee el .sql como texto y verifica presencia de los fragmentos DDL clave. No
ejecuta contra una DB real (CI no tiene los datos de prod) — la regla dura
es que el DROP+ADD reproduzca la UNIÓN completa vigente en prod, verificada
con pg_get_constraintdef ANTES de escribir el archivo (ya hecho en el propose
y re-verificado en el apply: gxdhpxvdjjkmxhdkkwyb devuelve exactamente los
8 kinds previos).
"""
from __future__ import annotations

from pathlib import Path

import pytest

MIGRATION_PATH = Path("supabase/migrations/20260815000001_v3_api_standards.sql")


class TestOperationKindCheckMigration:
    @pytest.fixture(scope="class")
    def sql(self) -> str:
        assert MIGRATION_PATH.exists(), f"migración no encontrada: {MIGRATION_PATH}"
        return MIGRATION_PATH.read_text(encoding="utf-8")

    def test_migration_is_idempotent_drop_if_exists(self, sql):
        """4.1: DROP CONSTRAINT IF EXISTS + ADD CONSTRAINT (recreable en cada reset)."""
        assert "DROP CONSTRAINT IF EXISTS operation_idempotency_operation_kind_check" in sql
        assert "ADD CONSTRAINT operation_idempotency_operation_kind_check" in sql

    def test_check_admits_cash_session_close(self, sql):
        """4.1/4.2: el nuevo kind está en la unión del CHECK recreado."""
        assert "'cash_session_close'" in sql

    def test_check_preserves_all_eight_previous_kinds(self, sql):
        """4.2 TRIANGULATE: regresión del incidente C3 — el DROP+ADD debe
        reproducir la UNIÓN vigente en prod (verificada con pg_get_constraintdef
        el 2026-07-07 sobre gxdhpxvdjjkmxhdkkwyb) o el db push rompe 23514
        contra filas existentes (CI no lo atrapa: su DB nace vacía)."""
        for kind in (
            "'sale'",
            "'purchase'",
            "'payment_received'",
            "'payment_made'",
            "'supplier_charge'",
            "'bank_movement'",
            "'event_consumer'",
            "'bank_statement_import'",
            "'cash_session_close'",
        ):
            assert kind in sql, f"falta {kind} en el CHECK de operation_kind"

    def test_migration_file_is_idempotent_pattern_for_reruns(self, sql):
        """4.2: aplicar dos veces el mismo archivo no debe romper — DROP IF EXISTS
        + ADD sin IF NOT EXISTS es el patrón estándar del proyecto para
        recrear CHECKs (ver bank-reconciliation C3); se verifica que no haya
        un CREATE TABLE sin IF NOT EXISTS que rompería el re-run."""
        # No debe haber CREATE TABLE sin guard — esta migración no crea tablas
        # nuevas, solo recrea un CHECK existente.
        assert "CREATE TABLE public.operation_idempotency" not in sql

    def test_drops_old_two_arg_overload_before_recreating_function(self, sql):
        """Regresión CI (2026-07-07): agregar p_idempotency_key con CREATE OR
        REPLACE no reemplaza rpc_close_cash_session(uuid,numeric) — Postgres
        resuelve funciones por (nombre, tipos de args), así que queda un
        segundo overload. El COMMENT ON FUNCTION posterior sin firma
        explícita se vuelve ambiguo (42725: 'function name ... is not
        unique'), como reprodujo el job validate-kpis. El fix es un DROP
        FUNCTION IF EXISTS del overload viejo de 2 argumentos ANTES del
        CREATE OR REPLACE de 3, para dejar un único overload vigente."""
        assert "DROP FUNCTION IF EXISTS public.rpc_close_cash_session(uuid, numeric)" in sql
        drop_idx = sql.index("DROP FUNCTION IF EXISTS public.rpc_close_cash_session")
        create_idx = sql.index("CREATE OR REPLACE FUNCTION public.rpc_close_cash_session")
        assert drop_idx < create_idx, "el DROP del overload viejo debe ir ANTES del CREATE OR REPLACE"

    def test_comment_on_function_is_unambiguous_single_overload(self, sql):
        """TRIANGULATE: tras el DROP, solo debe quedar UNA definición de
        CREATE FUNCTION para rpc_close_cash_session en el archivo (evita que
        alguien reintroduzca el overload viejo sin querer)."""
        assert sql.count("CREATE OR REPLACE FUNCTION public.rpc_close_cash_session") == 1
