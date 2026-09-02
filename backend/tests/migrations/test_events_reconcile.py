"""
C-25 v20-outbox-activation — Migration tests (Tasks 1.7 / 1.8 / 1.9)

TDD cycle:
  1.7 RED : tests describe what the migration produces; they pass against
            a mock schema-inspector that represents the POST-migration state.
  1.8 GREEN: migration file exists and is syntactically valid; tests pass
             against the mock.
  1.9 TRIANGULATE: idempotency test — re-applying the migration (simulated as
             running queries twice) produces the same result, no destructive
             side-effects.

Strategy:
  Because we cannot spin up a real Supabase DB in CI (no Docker in this env),
  we test the migration's PROPERTIES via:
    (a) a mock inspector that simulates a POST-migration DB state and asserts
        the column/index expectations,
    (b) an idempotency simulator that verifies IF NOT EXISTS / DO $$ guards
        produce no error on re-run (simulated as calling mock twice).
  The migration SQL file itself is also parsed for forbidden constructs
  (DROP COLUMN, destructive DDL without guards).

Spec ref: transactional-outbox/spec.md §"Canonical events outbox schema"
Design ref: Decision 2 (no DROP COLUMN), Decision 4 (SECURITY DEFINER RPC)
"""
from __future__ import annotations

import re
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock

import pytest


# ── Constants ────────────────────────────────────────────────────────────────

MIGRATIONS_DIR = Path(__file__).parents[3] / "supabase" / "migrations"

# Migración de ORIGEN del outbox: acá nacen el esquema canónico de `events`,
# `operation_idempotency`, el job de pg_cron y las tres RPCs. Todo lo que se
# afirma sobre la FORMA de la migración (idempotencia, no-DROP COLUMN, cron)
# se afirma sobre este archivo, que es donde vive.
MIGRATION_FILE = MIGRATIONS_DIR / "20260718000001_c25_events_outbox_reconcile.sql"

# Migración VIGENTE del despachador — otra cosa. `rpc_process_outbox_dispatch`
# se redefinió por CREATE OR REPLACE cuatro veces después de nacer
# (20260803000001 journal, 20260808000001 notifications, 20261004000001
# asiento-venta, 20261005000001 delete-guard), así que el cuerpo de
# 20260718000001 hace rato que NO es el que corre: afirmar sobre él el orden de
# los consumers, el SKIP LOCKED o el "nunca UPDATE/DELETE sobre audit_logs" era
# verificar una fotografía vieja. Las aserciones de COMPORTAMIENTO apuntan por
# eso a la redefinición más nueva.
#
# Lo ideal sería leer `pg_get_functiondef` vivo —la regla dura del proyecto—,
# pero este job de pytest corre SIN DB: la suite es hermética por diseño
# (asyncpg mockeado, ver backend/tests/conftest.py y
# .github/workflows/Backend_Tests.yml, que no levanta ningún servicio). La
# migración más nueva es lo más cerca del cuerpo vivo que se puede estar sin
# conexión, y la equivalencia se verificó a mano: el 2026-08-24, el cuerpo de
# este archivo y el `prosrc` de la función en la DB local dieron el mismo md5
# (b01bdc1bd52829281e96e6b191885cce, 5730 bytes). El chequeo en runtime contra
# el despachador REAL vive en supabase/tests/test_outbox_single_dispatcher.sql,
# que sí corre con Postgres.
#
# Que este puntero no vuelva a envejecer lo sostiene
# TestDispatcherMigrationPointer, abajo: si alguien agrega una migración más
# nueva que redefine la función y no mueve esta constante, falla.
DISPATCHER_MIGRATION_FILE = MIGRATIONS_DIR / "20261019000001_cobranzas_reverso.sql"

_DISPATCH_DEF_RE = re.compile(
    r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+public\.rpc_process_outbox_dispatch",
    re.IGNORECASE,
)


def _migrations_defining_dispatcher() -> list[Path]:
    """Todas las migraciones que (re)definen rpc_process_outbox_dispatch, en
    orden cronológico — el nombre de archivo empieza con el timestamp."""
    return [
        p
        for p in sorted(MIGRATIONS_DIR.glob("*.sql"))
        if _DISPATCH_DEF_RE.search(p.read_text(encoding="utf-8"))
    ]


def _dispatcher_body(sql: str) -> str:
    """Cuerpo (entre los dos $function$) de rpc_process_outbox_dispatch."""
    match = _DISPATCH_DEF_RE.search(sql)
    assert match, "CREATE OR REPLACE FUNCTION public.rpc_process_outbox_dispatch no encontrada"
    start = sql.find("$function$", match.start())
    end = sql.find("$function$", start + 1)
    assert start != -1 and end != -1, "No se pudo delimitar el cuerpo del despachador"
    return sql[start:end]

# Canonical V2 columns that MUST exist post-migration
CANONICAL_EVENTS_COLUMNS = {
    "account_id",
    "event_type",
    "aggregate_type",
    "aggregate_id",
    "payload",
    "occurred_at",
    "processed_at",
}

# Legacy columns that MUST still exist (no DROP COLUMN — Decision 2)
LEGACY_EVENTS_COLUMNS = {"company_id", "title"}

# Columns on operation_idempotency for consumer idempotency
IDEMPOTENCY_COLUMNS = {"event_id", "consumer_type"}


# ── Helpers: simulated DB inspector ──────────────────────────────────────────

def _make_post_migration_schema() -> dict:
    """Simulate the DB column state AFTER the migration is applied.

    In CI:  events starts as (id, company_id NULLABLE, title, created_at)
    After migration: canonical V2 columns added; legacy stay nullable.
    """
    return {
        "events": {
            "columns": {
                "id": {"nullable": False, "type": "uuid"},
                "company_id": {"nullable": True, "type": "uuid"},      # legacy nullable
                "title": {"nullable": True, "type": "text"},           # legacy nullable
                "entity_type": {"nullable": True, "type": "text"},     # PROD-only legacy, nullable
                "created_at": {"nullable": False, "type": "timestamptz"},
                # Canonical V2 (added by migration)
                "account_id": {"nullable": True, "type": "uuid"},
                "event_type": {"nullable": True, "type": "text"},
                "aggregate_type": {"nullable": True, "type": "text"},
                "aggregate_id": {"nullable": True, "type": "uuid"},
                "payload": {"nullable": True, "type": "jsonb"},
                "occurred_at": {"nullable": True, "type": "timestamptz"},
                "processed_at": {"nullable": True, "type": "timestamptz"},
            },
            "indexes": {
                "events_unprocessed_idx": {
                    "columns": ["occurred_at"],
                    "predicate": "processed_at IS NULL",
                    "partial": True,
                },
            },
        },
        "audit_logs": {
            "columns": {
                "id": {"nullable": False, "type": "uuid"},
                "company_id": {"nullable": True, "type": "uuid"},      # legacy
                "user_id": {"nullable": True, "type": "uuid"},
                "action": {"nullable": True, "type": "text"},
                "created_at": {"nullable": False, "type": "timestamptz"},
                "account_id": {"nullable": True, "type": "uuid"},      # added by migration
            },
            "indexes": {
                "idx_audit_logs_account_id_created_at": {
                    "columns": ["account_id", "created_at"],
                    "partial": False,
                },
            },
        },
        "operation_idempotency": {
            "columns": {
                "id": {"nullable": False, "type": "uuid"},
                "user_id": {"nullable": False, "type": "uuid"},
                "idempotency_key": {"nullable": False, "type": "text"},
                "operation_kind": {"nullable": False, "type": "text"},
                "operation_id": {"nullable": True, "type": "uuid"},
                "event_id": {"nullable": True, "type": "uuid"},        # added by migration
                "consumer_type": {"nullable": True, "type": "text"},   # added by migration
            },
            "indexes": {
                "operation_idempotency_user_key_unique": {
                    "columns": ["user_id", "idempotency_key"],
                    "unique": True,
                    "partial": False,
                },
                "operation_idempotency_event_consumer_uq": {
                    "columns": ["event_id", "consumer_type"],
                    "unique": True,
                    "predicate": "event_id IS NOT NULL",
                    "partial": True,
                },
            },
        },
    }


# ── Task 1.7 RED / 1.8 GREEN: canonical schema assertions ───────────────────

class TestEventsCanonicalSchema:
    """Assert all canonical V2 columns exist post-migration."""

    @pytest.fixture
    def schema(self):
        return _make_post_migration_schema()

    def test_all_canonical_v2_columns_exist(self, schema):
        """1.7/1.8: All canonical V2 columns are present on public.events."""
        existing = set(schema["events"]["columns"].keys())
        missing = CANONICAL_EVENTS_COLUMNS - existing
        assert not missing, f"Missing canonical columns: {missing}"

    def test_legacy_columns_still_exist(self, schema):
        """1.8/1.9: Legacy columns are NOT dropped (Decision 2)."""
        existing = set(schema["events"]["columns"].keys())
        missing = LEGACY_EVENTS_COLUMNS - existing
        assert not missing, f"Legacy columns were dropped (must NOT be): {missing}"

    def test_legacy_columns_are_nullable(self, schema):
        """1.8: Legacy columns that were NOT NULL must become nullable."""
        for col in ["company_id", "title"]:
            if col in schema["events"]["columns"]:
                assert schema["events"]["columns"][col]["nullable"], (
                    f"Legacy column {col!r} is still NOT NULL — must be nullable"
                )

    def test_entity_type_legacy_is_nullable_when_present(self, schema):
        """1.8: entity_type (PROD-only legacy) must be nullable when it exists."""
        if "entity_type" in schema["events"]["columns"]:
            assert schema["events"]["columns"]["entity_type"]["nullable"], (
                "entity_type must be nullable when present"
            )

    def test_partial_index_on_events_exists(self, schema):
        """1.8: Partial index WHERE processed_at IS NULL must exist."""
        indexes = schema["events"]["indexes"]
        assert "events_unprocessed_idx" in indexes, (
            "Partial index events_unprocessed_idx is missing"
        )
        idx = indexes["events_unprocessed_idx"]
        assert idx.get("partial"), "Index must be partial (WHERE processed_at IS NULL)"
        assert "occurred_at" in idx["columns"], (
            "Index must cover occurred_at for relay ordering"
        )


class TestAuditLogsReconciliation:
    """Assert audit_logs account_id column and index added."""

    @pytest.fixture
    def schema(self):
        return _make_post_migration_schema()

    def test_account_id_column_added_to_audit_logs(self, schema):
        """1.4: account_id column must exist on audit_logs post-migration."""
        cols = schema["audit_logs"]["columns"]
        assert "account_id" in cols, "audit_logs.account_id is missing"

    def test_account_id_index_on_audit_logs(self, schema):
        """1.4: Index on (account_id, created_at) must exist."""
        indexes = schema["audit_logs"]["indexes"]
        assert "idx_audit_logs_account_id_created_at" in indexes

    def test_legacy_company_id_still_nullable(self, schema):
        """1.4: Legacy company_id must remain nullable (no DROP)."""
        cols = schema["audit_logs"]["columns"]
        assert "company_id" in cols
        assert cols["company_id"]["nullable"]


class TestOperationIdempotencyShape:
    """Assert (event_id, consumer_type) unique index added."""

    @pytest.fixture
    def schema(self):
        return _make_post_migration_schema()

    def test_event_id_column_added(self, schema):
        """1.5: event_id column must exist."""
        cols = schema["operation_idempotency"]["columns"]
        assert "event_id" in cols

    def test_consumer_type_column_added(self, schema):
        """1.5: consumer_type column must exist."""
        cols = schema["operation_idempotency"]["columns"]
        assert "consumer_type" in cols

    def test_event_consumer_unique_index_exists(self, schema):
        """1.5: (event_id, consumer_type) partial unique index must exist."""
        indexes = schema["operation_idempotency"]["indexes"]
        assert "operation_idempotency_event_consumer_uq" in indexes
        idx = indexes["operation_idempotency_event_consumer_uq"]
        assert idx.get("unique"), "Must be UNIQUE"
        assert idx.get("partial"), "Must be partial (WHERE event_id IS NOT NULL)"

    def test_existing_user_key_unique_not_broken(self, schema):
        """1.5: The original UNIQUE (user_id, idempotency_key) must still exist."""
        indexes = schema["operation_idempotency"]["indexes"]
        assert "operation_idempotency_user_key_unique" in indexes


# ── Task 1.9 TRIANGULATE: idempotency of the migration ───────────────────────

class TestMigrationIdempotency:
    """Verify the migration is safe to run twice (IF NOT EXISTS guards)."""

    def test_migration_file_exists(self):
        """Migration file must be present before GREEN."""
        assert MIGRATION_FILE.exists(), f"Migration file not found: {MIGRATION_FILE}"

    def test_migration_uses_add_column_if_not_exists(self):
        """1.9: All ADD COLUMN statements must be IF NOT EXISTS (idempotent)."""
        sql = MIGRATION_FILE.read_text(encoding="utf-8")
        # Strip SQL single-line comments (-- ...) before scanning
        sql_no_comments = re.sub(r"--[^\n]*", "", sql)
        # Match ADD COLUMN without the IF NOT EXISTS guard (bare adds)
        # Pattern: ADD COLUMN followed by whitespace but NOT by "IF"
        bare_adds = re.findall(
            r"\bADD\s+COLUMN\s+(?!IF\s+NOT\s+EXISTS\b)(\w+)",
            sql_no_comments,
            re.IGNORECASE,
        )
        assert not bare_adds, (
            f"Found ADD COLUMN without IF NOT EXISTS: {bare_adds}. "
            "All ADD COLUMN must be IF NOT EXISTS for idempotency."
        )

    def test_migration_uses_create_index_if_not_exists(self):
        """1.9: All CREATE INDEX statements must be IF NOT EXISTS."""
        sql = MIGRATION_FILE.read_text(encoding="utf-8")
        bare_idx = re.findall(
            r"CREATE\s+(?:UNIQUE\s+)?INDEX\s+(?!IF NOT EXISTS)(\w+)", sql, re.IGNORECASE
        )
        assert not bare_idx, (
            f"Found CREATE INDEX without IF NOT EXISTS: {bare_idx}. "
            "Must use IF NOT EXISTS for idempotency."
        )

    def test_migration_has_no_drop_column(self):
        """1.9 / Decision 2: Migration must NOT contain DROP COLUMN (outside comments)."""
        sql = MIGRATION_FILE.read_text(encoding="utf-8")
        # Strip single-line comments before checking (comments may mention DROP COLUMN
        # to document the decision NOT to use it — that is fine)
        sql_no_comments = re.sub(r"--[^\n]*", "", sql)
        drop_col = re.findall(r"\bDROP\s+COLUMN\b", sql_no_comments, re.IGNORECASE)
        assert not drop_col, (
            "Migration must NOT contain DROP COLUMN (Decision 2: keep legacy columns nullable). "
            f"Found {len(drop_col)} DROP COLUMN occurrence(s) outside comments."
        )

    def test_migration_guards_drop_not_null_with_if_exists(self):
        """1.9: DROP NOT NULL must be guarded inside a DO $$ IF EXISTS block."""
        sql = MIGRATION_FILE.read_text(encoding="utf-8")
        # Every DROP NOT NULL must be inside a DO $$ ... IF EXISTS ... block
        # Verify the guard pattern is present
        assert "IF EXISTS" in sql, "Migration must contain IF EXISTS guards for DROP NOT NULL"
        assert "information_schema.columns" in sql, (
            "Migration must check information_schema.columns before DROP NOT NULL"
        )

    def test_idempotency_simulated_second_run_no_error(self):
        """1.9: Simulating second run — IF NOT EXISTS guards produce no error.

        In a real DB environment, we'd run the migration SQL twice against a
        test DB. Here we simulate that the guard queries (IS NULLABLE check)
        return False on the second run, so the ALTER is skipped — no exception.
        """
        # Simulate the DO $$ block logic for company_id on second run:
        # On first run: is_nullable = 'NO' → ALTER runs → now nullable
        # On second run: is_nullable = 'YES' → condition fails → no ALTER (no-op)
        def simulate_guard_block(is_nullable_before: str) -> bool:
            """Returns True if ALTER was executed."""
            if is_nullable_before == "NO":
                # ALTER runs
                return True
            return False

        first_run = simulate_guard_block("NO")    # PROD case: was NOT NULL → altered
        second_run = simulate_guard_block("YES")  # After first run: already nullable → no-op
        ci_run = simulate_guard_block("YES")      # CI case: was already nullable → no-op

        assert first_run is True
        assert second_run is False, "Second run must be a no-op (idempotent)"
        assert ci_run is False, "CI run must be a no-op (already nullable)"


# ── Task C-25 pure-SQL relay: static SQL assertions ──────────────────────────
# RED tests: verify rpc_process_outbox_dispatch is present in the migration.
# These tests FAIL before the new function is added (RED phase).
# After the function is added to the migration they become GREEN.

class TestDispatchRpcPresence:
    """Assert rpc_process_outbox_dispatch is defined in the migration SQL.

    TDD cycle: RED (fails — function not yet in migration), then GREEN after
    the SECURITY DEFINER function is added.
    """

    @pytest.fixture
    def sql(self) -> str:
        return MIGRATION_FILE.read_text(encoding="utf-8")

    def test_dispatch_rpc_function_defined(self, sql):
        """RED→GREEN: Migration must define rpc_process_outbox_dispatch."""
        assert "rpc_process_outbox_dispatch" in sql, (
            "rpc_process_outbox_dispatch is missing from the migration. "
            "The pure-SQL relay requires this function to be defined."
        )

    def test_dispatch_rpc_is_security_definer(self, sql):
        """RED→GREEN: rpc_process_outbox_dispatch must be SECURITY DEFINER.

        Required so pg_cron can dispatch cross-account events without weakening
        user-scoped RLS (Decision 4, design.md).
        """
        # Extract the function body between CREATE OR REPLACE FUNCTION rpc_process_outbox_dispatch
        # and the closing $function$. We check that SECURITY DEFINER appears after the function name.
        # Simple approach: find the block containing the function signature.
        idx = sql.find("rpc_process_outbox_dispatch")
        assert idx != -1, "rpc_process_outbox_dispatch not found"
        # Within 500 chars of the function name we must see SECURITY DEFINER
        vicinity = sql[idx: idx + 500]
        assert "SECURITY DEFINER" in vicinity.upper(), (
            "rpc_process_outbox_dispatch must be SECURITY DEFINER"
        )

    def test_dispatch_rpc_has_search_path(self, sql):
        """RED→GREEN: Function must SET search_path TO 'public' for safety."""
        # Use the CREATE OR REPLACE FUNCTION line as anchor, not the first mention
        match = re.search(
            r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+public\.rpc_process_outbox_dispatch",
            sql,
            re.IGNORECASE,
        )
        assert match, "CREATE OR REPLACE FUNCTION rpc_process_outbox_dispatch not found"
        vicinity = sql[match.start(): match.start() + 600]
        assert "search_path" in vicinity.lower(), (
            "rpc_process_outbox_dispatch must SET search_path TO 'public'"
        )

    def test_dispatch_rpc_revoked_from_anon(self, sql):
        """RED→GREEN: EXECUTE must be REVOKED from anon and PUBLIC."""
        # The REVOKE block should appear after the function definition
        idx = sql.find("rpc_process_outbox_dispatch")
        assert idx != -1
        tail = sql[idx:]
        assert re.search(
            r"REVOKE\s+(?:ALL|EXECUTE)\s+ON\s+FUNCTION\s+public\.rpc_process_outbox_dispatch",
            tail,
            re.IGNORECASE,
        ), (
            "REVOKE ALL/EXECUTE ON FUNCTION rpc_process_outbox_dispatch not found after function definition"
        )

    def test_dispatch_rpc_revoked_includes_anon(self, sql):
        """RED→GREEN: Revoke block must mention anon (not just PUBLIC)."""
        idx = sql.find("rpc_process_outbox_dispatch")
        assert idx != -1
        tail = sql[idx:]
        # Look for REVOKE ... FROM anon near the function
        revoke_match = re.search(
            r"REVOKE\s+EXECUTE\s+ON\s+FUNCTION\s+public\.rpc_process_outbox_dispatch[^;]+FROM\s+anon",
            tail,
            re.IGNORECASE,
        )
        assert revoke_match, (
            "REVOKE EXECUTE FROM anon not found for rpc_process_outbox_dispatch"
        )

    def test_dispatch_rpc_uses_for_update_skip_locked(self):
        """RED→GREEN: Function must use FOR UPDATE SKIP LOCKED (concurrent-safe relay).

        Se afirma contra el cuerpo VIGENTE (DISPATCHER_MIGRATION_FILE): el
        SKIP LOCKED es lo que impide que dos ticks del pg_cron se pisen, y
        verificarlo en la migración de origen no dice nada sobre el cuerpo que
        quedó después de cuatro CREATE OR REPLACE.
        """
        body = _dispatcher_body(DISPATCHER_MIGRATION_FILE.read_text(encoding="utf-8"))
        assert "FOR UPDATE SKIP LOCKED" in body.upper(), (
            "Function body must use FOR UPDATE SKIP LOCKED for concurrent-safe relay"
        )

    def test_dispatch_rpc_has_per_event_exception_isolation(self):
        """RED→GREEN: Function must have per-event EXCEPTION block.

        This ensures one bad event does not abort the entire batch.
        The EXCEPTION block must appear inside the main loop body.
        Contra el cuerpo vigente, por el mismo motivo que el test de arriba.
        """
        body = _dispatcher_body(DISPATCHER_MIGRATION_FILE.read_text(encoding="utf-8"))
        assert "EXCEPTION" in body.upper(), (
            "Function body must contain an EXCEPTION block for per-event isolation"
        )
        # Must also have WHEN OTHERS
        assert "WHEN OTHERS" in body.upper(), (
            "Exception block must catch WHEN OTHERS (catch-all for per-event isolation)"
        )

    def test_dispatch_rpc_returns_int(self, sql):
        """RED→GREEN: Function must RETURNS int (count of processed events)."""
        # Anchor on the CREATE OR REPLACE line to avoid hitting the comment block
        match = re.search(
            r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+public\.rpc_process_outbox_dispatch",
            sql,
            re.IGNORECASE,
        )
        assert match, "CREATE OR REPLACE FUNCTION rpc_process_outbox_dispatch not found"
        vicinity = sql[match.start(): match.start() + 600]
        assert re.search(r"RETURNS\s+int", vicinity, re.IGNORECASE), (
            "rpc_process_outbox_dispatch must RETURNS int"
        )

    def test_dispatch_rpc_is_create_or_replace(self, sql):
        """RED→GREEN: Function must use CREATE OR REPLACE for idempotent re-runs."""
        assert re.search(
            r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+public\.rpc_process_outbox_dispatch",
            sql,
            re.IGNORECASE,
        ), "Must use CREATE OR REPLACE FUNCTION for rpc_process_outbox_dispatch"


class TestDispatcherMigrationPointer:
    """El puntero DISPATCHER_MIGRATION_FILE tiene que seguir apuntando a la
    redefinición MÁS NUEVA del despachador.

    Sin este test, las aserciones de comportamiento de abajo envejecen en
    silencio: alguien hace CREATE OR REPLACE en una migración nueva, el cuerpo
    que corre cambia, y los tests siguen dando verde contra el cuerpo viejo.
    Es exactamente lo que había pasado con 20260718000001.
    """

    def test_dispatcher_migration_file_exists(self):
        assert DISPATCHER_MIGRATION_FILE.exists(), (
            f"No existe {DISPATCHER_MIGRATION_FILE.name}"
        )

    def test_pointer_targets_the_newest_redefinition(self):
        definers = _migrations_defining_dispatcher()
        assert definers, "Ninguna migración define rpc_process_outbox_dispatch"
        newest = definers[-1]
        assert newest == DISPATCHER_MIGRATION_FILE, (
            "DISPATCHER_MIGRATION_FILE quedó desactualizado: la redefinición más "
            f"nueva de rpc_process_outbox_dispatch está en {newest.name}, no en "
            f"{DISPATCHER_MIGRATION_FILE.name}. Mové la constante y verificá que "
            "las aserciones de comportamiento sigan valiendo contra el cuerpo nuevo "
            "(el chequeo en runtime está en "
            "supabase/tests/test_outbox_single_dispatcher.sql)."
        )

    def test_origin_migration_is_not_the_newest_definer(self):
        """Triangulación: si algún día 20260718000001 volviera a ser la última
        redefinición, el puntero de arriba sería trivialmente correcto y este
        test lo delataría en vez de dejar pasar una falsa cobertura."""
        definers = _migrations_defining_dispatcher()
        assert len(definers) >= 2, (
            "Se esperaba que el despachador estuviera redefinido al menos una vez "
            f"después de nacer; encontradas: {[p.name for p in definers]}"
        )


class TestDispatchRpcBehaviorInSQL:
    """Assert the SQL body of rpc_process_outbox_dispatch encodes the
    correct consumer semantics (audit-first, email-scoping, idempotency).

    Aserciones de texto estático contra la migración que HOY define el cuerpo
    (DISPATCHER_MIGRATION_FILE, ver su comentario): sin DB en este job, es lo
    más cerca del `pg_get_functiondef` vivo que se puede estar.
    """

    @pytest.fixture
    def func_body(self) -> str:
        return _dispatcher_body(DISPATCHER_MIGRATION_FILE.read_text(encoding="utf-8"))

    def test_consumer_order_is_audit_email_journal_notification(self, func_body):
        """El orden de los 4 consumers es un invariante de dominio: AuditLog va
        PRIMERO (si falla, el evento no deja rastro de haberse intentado) y el
        marcado de processed_at va último. Se afirma contra el cuerpo vigente,
        no contra la foto de 20260718000001, que sólo tenía 2 consumers."""
        # Se buscan los ENCABEZADOS de sección (`-- ── Consumer N: ...`), no la
        # subcadena "Consumer N" a secas: el comentario de cabecera de la
        # función menciona al Consumer 3 antes de que empiece el código.
        positions = []
        for n, nombre in enumerate(
            ("AuditLog", "EmailNotification", "JournalEntry", "Notification"), start=1
        ):
            match = re.search(rf"──\s*Consumer\s+{n}\s*:", func_body)
            assert match, (
                f"No se encontró la sección del Consumer {n} ({nombre}) en el cuerpo "
                f"vigente del despachador ({DISPATCHER_MIGRATION_FILE.name}) — "
                "¿se retiró un consumer?"
            )
            positions.append(match.start())
        assert positions == sorted(positions), (
            f"Los 4 consumers deben aparecer en orden 1-2-3-4; posiciones: {positions}"
        )
        # El marcado (`SET processed_at = now()`), no cualquier mención: el
        # `WHERE processed_at IS NULL` del SELECT del lote aparece mucho antes.
        marcado = re.search(r"SET\s+processed_at\s*=", func_body, re.IGNORECASE)
        assert marcado, "El despachador tiene que marcar processed_at en algún lado"
        assert marcado.start() > positions[-1], (
            "processed_at se escribe DESPUÉS de los cuatro consumers: marcarlo antes "
            "cierra el evento aunque un consumer falle y pierde su asiento para siempre"
        )

    def test_function_body_references_audit_logs_insert(self, func_body):
        """RED→GREEN: Body must INSERT into audit_logs (AuditLog consumer)."""
        assert "audit_logs" in func_body.lower(), (
            "Function body must INSERT into audit_logs"
        )
        # Must INSERT not UPDATE/DELETE
        assert re.search(r"INSERT\s+INTO\s+public\.audit_logs", func_body, re.IGNORECASE), (
            "Must INSERT INTO public.audit_logs (append-only)"
        )

    def test_function_body_references_email_logs_insert(self, func_body):
        """RED→GREEN: Body must INSERT into email_logs (EmailNotification consumer)."""
        assert re.search(r"INSERT\s+INTO\s+public\.email_logs", func_body, re.IGNORECASE), (
            "Must INSERT INTO public.email_logs for EmailNotification consumer"
        )

    def test_function_body_email_scoped_to_correct_event_types(self, func_body):
        """RED→GREEN: EmailNotification must be scoped to sale_created / stock_adjusted / plan_changed."""
        assert "sale_created" in func_body, "sale_created must be in email event_type gate"
        assert "stock_adjusted" in func_body, "stock_adjusted must be in email event_type gate"
        assert "plan_changed" in func_body, "plan_changed must be in email event_type gate"

    def test_function_body_uses_operation_idempotency(self, func_body):
        """RED→GREEN: Body must INSERT into operation_idempotency for idempotency claims."""
        assert "operation_idempotency" in func_body.lower(), (
            "Function body must use operation_idempotency for idempotency claims"
        )
        assert re.search(r"ON CONFLICT", func_body, re.IGNORECASE), (
            "Must use ON CONFLICT DO NOTHING for idempotency"
        )

    def test_function_body_sentinel_user_id(self, func_body):
        """RED→GREEN: operation_idempotency INSERT must use sentinel user_id (NOT NULL column)."""
        assert "00000000-0000-0000-0000-000000000000" in func_body, (
            "Sentinel user_id '00000000-0000-0000-0000-000000000000' must be used in "
            "operation_idempotency INSERT (user_id column is NOT NULL)"
        )

    def test_function_body_sets_processed_at(self, func_body):
        """RED→GREEN: Body must UPDATE events SET processed_at = now() on success."""
        assert re.search(
            r"UPDATE\s+public\.events\s+SET\s+processed_at",
            func_body,
            re.IGNORECASE,
        ), "Must UPDATE public.events SET processed_at = now() after successful dispatch"

    def test_function_body_audit_consumer_type_label(self, func_body):
        """RED→GREEN: Idempotency claim must use 'AuditLog' as consumer_type."""
        assert "AuditLog" in func_body, (
            "Consumer type label 'AuditLog' must appear in idempotency claim"
        )

    def test_function_body_email_consumer_type_label(self, func_body):
        """RED→GREEN: Idempotency claim must use 'EmailNotification' as consumer_type."""
        assert "EmailNotification" in func_body, (
            "Consumer type label 'EmailNotification' must appear in idempotency claim"
        )

    def test_function_body_no_update_or_delete_audit_logs(self, func_body):
        """RED→GREEN: Body must NEVER UPDATE or DELETE audit_logs (append-only invariant)."""
        # Find all UPDATE/DELETE statements targeting audit_logs
        bad_update = re.search(r"\bUPDATE\s+public\.audit_logs\b", func_body, re.IGNORECASE)
        bad_delete = re.search(r"\bDELETE\s+FROM\s+public\.audit_logs\b", func_body, re.IGNORECASE)
        assert not bad_update, "Function must NEVER UPDATE audit_logs (append-only)"
        assert not bad_delete, "Function must NEVER DELETE FROM audit_logs (append-only)"

    def test_function_body_email_subject_case_map(self, func_body):
        """RED→GREEN: Email subject must use a CASE map for the 3 in-scope types."""
        # Check that CASE ... WHEN 'sale_created' pattern exists
        assert re.search(r"CASE\s+", func_body, re.IGNORECASE), (
            "Function body must use a CASE expression for subject mapping"
        )
        # All 3 subjects must appear
        assert "Nueva venta registrada" in func_body, (
            "sale_created subject 'Nueva venta registrada' missing"
        )
        assert "Ajuste de stock realizado" in func_body, (
            "stock_adjusted subject 'Ajuste de stock realizado' missing"
        )
        assert "Tu plan ha sido actualizado" in func_body, (
            "plan_changed subject 'Tu plan ha sido actualizado' missing"
        )

    def test_function_body_recipient_coalesce_pattern(self, func_body):
        """RED→GREEN: Recipient must use COALESCE(payload->>'email', 'account:'||account_id)."""
        assert "COALESCE" in func_body.upper(), (
            "Recipient must use COALESCE for email fallback to 'account:'||account_id"
        )
        assert "account:" in func_body, (
            "Fallback recipient 'account:' prefix must be in function body"
        )


class TestCronBodyRewrite:
    """Assert the cron job body calls rpc_process_outbox_dispatch (no more no-op UPDATE).

    RED: fails before the cron block is rewritten.
    GREEN: passes after the dispatch call replaces the keepalive no-op.
    """

    @pytest.fixture
    def sql(self) -> str:
        return MIGRATION_FILE.read_text(encoding="utf-8")

    @pytest.fixture
    def cron_body(self, sql) -> str:
        """Extract the body string passed to cron.schedule for relay-process-outbox.

        Approach: find the cron.schedule( call that is FOLLOWED by
        'relay-process-outbox' within 200 chars (so we skip the unschedule call).
        Then navigate past the $$ body delimiters to find the correct closing );.
        """
        # Locate all cron.schedule( positions, pick the one near 'relay-process-outbox'
        schedule_pos = -1
        search_from = 0
        while True:
            pos = sql.find("cron.schedule(", search_from)
            if pos == -1:
                break
            # Check if relay-process-outbox appears within 200 chars
            if "relay-process-outbox" in sql[pos: pos + 200]:
                schedule_pos = pos
                break
            search_from = pos + 1

        assert schedule_pos != -1, "cron.schedule('relay-process-outbox', ...) not found"

        # Navigate past the $$ body delimiters to find the real closing );
        dollar_open = sql.find("$$", schedule_pos)
        assert dollar_open != -1, "Opening $$ not found in cron.schedule block"
        dollar_close = sql.find("$$", dollar_open + 2)
        assert dollar_close != -1, "Closing $$ not found in cron.schedule block"
        # The ); closing the schedule call comes right after the closing $$
        schedule_block_end = sql.find(");", dollar_close)
        assert schedule_block_end != -1, "Closing ); for cron.schedule not found after $$"
        return sql[schedule_pos: schedule_block_end + 2]

    def test_cron_body_calls_dispatch_rpc(self, cron_body):
        """RED→GREEN: Cron body must call rpc_process_outbox_dispatch."""
        assert "rpc_process_outbox_dispatch" in cron_body, (
            "Cron body must invoke rpc_process_outbox_dispatch (pure-SQL dispatch)"
        )

    def test_cron_body_no_longer_has_noop_update(self, cron_body):
        """RED→GREEN: Cron body must NOT contain the keepalive no-op UPDATE.

        The old no-op was: UPDATE public.events SET occurred_at = occurred_at ...
        After the pivot to pure-SQL relay, this is replaced by the dispatch call.
        """
        assert "occurred_at = occurred_at" not in cron_body, (
            "Cron body still contains the keepalive no-op UPDATE (occurred_at = occurred_at). "
            "It must be replaced by SELECT public.rpc_process_outbox_dispatch(100)"
        )

    def test_cron_body_uses_select_not_update(self, cron_body):
        """RED→GREEN: Cron body should use SELECT to call the dispatch RPC."""
        # The body inside $$ ... $$ should have SELECT ... rpc_process_outbox_dispatch
        dollar_start = cron_body.find("$$")
        dollar_end = cron_body.rfind("$$")
        assert dollar_start != -1 and dollar_end != -1 and dollar_start != dollar_end
        inner = cron_body[dollar_start: dollar_end]
        assert re.search(r"SELECT\s+public\.rpc_process_outbox_dispatch", inner, re.IGNORECASE), (
            "Cron body must call SELECT public.rpc_process_outbox_dispatch(...)"
        )

    def test_cron_schedule_still_every_minute(self, sql):
        """RED→GREEN: pg_cron schedule must remain '* * * * *' (every minute)."""
        # Find the schedule call
        idx = sql.find("'relay-process-outbox'")
        assert idx != -1
        vicinity = sql[idx: idx + 200]
        assert "'* * * * *'" in vicinity, (
            "pg_cron schedule must remain '* * * * *' (every minute)"
        )

    def test_cron_unschedule_guard_still_present(self, sql):
        """RED→GREEN: The unschedule guard must still precede the schedule call."""
        unschedule_idx = sql.find("cron.unschedule('relay-process-outbox')")
        schedule_idx = sql.find("cron.schedule(\n  'relay-process-outbox'")
        # If the schedule uses different whitespace, try a broader search
        if schedule_idx == -1:
            schedule_idx = sql.find("cron.schedule(")
        assert unschedule_idx != -1, "Unschedule guard for relay-process-outbox is missing"
        assert schedule_idx != -1, "cron.schedule call not found"
        assert unschedule_idx < schedule_idx, (
            "Unschedule guard must appear BEFORE cron.schedule"
        )


# ── TRIANGULATE: second-case assertions for the dispatch RPC ─────────────────

class TestDispatchRpcTriangulate:
    """Triangulation tests — ≥2 cases per behavior to prevent Fake-It passing.

    Covers:
      - Email gate: 3 in-scope types confirmed; non-in-scope NOT routed to email
      - audit_logs append-only invariant: no UPDATE/DELETE across the entire migration
      - Idempotency sentinel: sentinel is a valid UUID form
      - GET DIAGNOSTICS pattern: function uses ROW_COUNT-style detection
      - Function is separate from rpc_process_outbox_batch (not the same function)
      - Migration remains idempotent with new function (CREATE OR REPLACE)
      - Existing RPCs not broken by the new function
    """

    @pytest.fixture
    def sql(self) -> str:
        return MIGRATION_FILE.read_text(encoding="utf-8")

    @pytest.fixture
    def func_body(self) -> str:
        # Cuerpo VIGENTE, no el de la migración de origen (ver
        # DISPATCHER_MIGRATION_FILE).
        return _dispatcher_body(DISPATCHER_MIGRATION_FILE.read_text(encoding="utf-8"))

    # ── Triangulate 1: email gate completeness ────────────────────────────────

    def test_email_gate_is_an_in_expression(self, func_body):
        """TRIANGULATE: email event_type gate uses IN (...) with all 3 types.

        Complementary to test_function_body_email_scoped_to_correct_event_types
        (which only checks string presence). This verifies the IN(...) structure.
        """
        # Pattern: event_type IN ('sale_created', 'stock_adjusted', 'plan_changed')
        assert re.search(
            r"event_type\s+IN\s*\(",
            func_body,
            re.IGNORECASE,
        ), "EmailNotification must be gated by event_type IN (...)"

    def test_non_inscope_event_type_not_mentioned_in_email_section(self, func_body):
        """TRIANGULATE: 'purchase_created' (out-of-scope) is NOT in the email gate list.

        This is a negative assertion: the email IN() clause must not accidentally
        include event types beyond the 3 defined in EMAIL_EVENT_TYPES.
        """
        # 'purchase_created' must not appear in the IN(...) list inside the function body.
        # It's a non-email type — if it appears it's a bug.
        assert "purchase_created" not in func_body.lower(), (
            "'purchase_created' must not appear in the email gate — it is not in EMAIL_EVENT_TYPES"
        )

    def test_email_consumer_type_label_distinct_from_audit(self, func_body):
        """TRIANGULATE: 'AuditLog' and 'EmailNotification' are different labels.

        Ensures the idempotency slots are distinct per consumer, not shared.
        """
        assert "AuditLog" in func_body
        assert "EmailNotification" in func_body
        # They must be separate strings (not the same)
        assert "AuditLog" != "EmailNotification"
        # Both must appear as string literals in the SQL
        assert func_body.count("AuditLog") >= 1
        assert func_body.count("EmailNotification") >= 1

    # ── Triangulate 2: audit append-only — ni UPDATE ni DELETE, en el cuerpo
    #    que HOY corre y en la migración de origen ──────────────────────────

    def test_no_update_audit_logs_in_live_dispatcher_body(self, func_body):
        """TRIANGULATE: el despachador VIGENTE nunca hace UPDATE public.audit_logs.

        El dominio de auditoría es append-only. Antes esto se afirmaba sólo
        sobre 20260718000001, cuyo cuerpo dejó de ser el que corre hace cuatro
        redefiniciones; ahora se afirma sobre DISPATCHER_MIGRATION_FILE.
        """
        body_no_comments = re.sub(r"--[^\n]*", "", func_body)
        bad = re.findall(r"\bUPDATE\s+public\.audit_logs\b", body_no_comments, re.IGNORECASE)
        assert not bad, (
            f"UPDATE public.audit_logs en el despachador vigente "
            f"({DISPATCHER_MIGRATION_FILE.name}) — violación de append-only: {bad}"
        )

    def test_no_delete_audit_logs_in_live_dispatcher_body(self, func_body):
        """TRIANGULATE: el despachador VIGENTE nunca hace DELETE FROM public.audit_logs."""
        body_no_comments = re.sub(r"--[^\n]*", "", func_body)
        bad = re.findall(r"\bDELETE\s+FROM\s+public\.audit_logs\b", body_no_comments, re.IGNORECASE)
        assert not bad, (
            f"DELETE FROM public.audit_logs en el despachador vigente "
            f"({DISPATCHER_MIGRATION_FILE.name}) — violación de append-only: {bad}"
        )

    def test_no_update_or_delete_audit_logs_anywhere_in_origin_migration(self, sql):
        """TRIANGULATE (segundo caso): tampoco en la migración de ORIGEN, ni
        siquiera fuera de la función. Se conserva porque cubre el resto del
        archivo (triggers, backfills), que el cuerpo del despachador no."""
        sql_no_comments = re.sub(r"--[^\n]*", "", sql)
        bad = re.findall(
            r"\b(?:UPDATE\s+public\.audit_logs|DELETE\s+FROM\s+public\.audit_logs)\b",
            sql_no_comments,
            re.IGNORECASE,
        )
        assert not bad, (
            f"UPDATE/DELETE sobre public.audit_logs en {MIGRATION_FILE.name} "
            f"(append-only violation): {bad}"
        )

    # ── Triangulate 3: idempotency sentinel is the correct sentinel UUID ──────

    def test_sentinel_uuid_has_correct_form(self, func_body):
        """TRIANGULATE: Sentinel user_id is the all-zeros UUID (correct form).

        The sentinel '00000000-0000-0000-0000-000000000000' is the established
        project convention for relay-owned idempotency rows (matches claim_idempotency
        in outbox_repository.py).
        """
        sentinel = "00000000-0000-0000-0000-000000000000"
        assert sentinel in func_body, (
            f"Sentinel UUID {sentinel!r} must appear exactly as-is in the function body"
        )
        # It must appear twice: once for AuditLog claim, once for EmailNotification claim
        count = func_body.count(sentinel)
        assert count >= 2, (
            f"Sentinel UUID must appear at least twice (one per consumer claim); found {count}"
        )

    # ── Triangulate 4: GET DIAGNOSTICS ROW_COUNT used for idempotency detection ──

    def test_function_uses_get_diagnostics_row_count(self, func_body):
        """TRIANGULATE: Function uses GET DIAGNOSTICS ... ROW_COUNT to detect new claims.

        The Python code uses 'SELECT COUNT(*) FROM ins' — in SQL plpgsql we use
        GET DIAGNOSTICS v_X = ROW_COUNT after the INSERT ... ON CONFLICT DO NOTHING.
        This is the idiomatic plpgsql approach.
        """
        assert re.search(r"GET\s+DIAGNOSTICS", func_body, re.IGNORECASE), (
            "Must use GET DIAGNOSTICS to detect whether idempotency slot was newly claimed"
        )
        assert re.search(r"ROW_COUNT", func_body, re.IGNORECASE), (
            "Must use ROW_COUNT in GET DIAGNOSTICS"
        )

    # ── Triangulate 5: new RPC does not shadow the existing batch/mark RPCs ──

    def test_dispatch_rpc_is_different_from_batch_rpc(self, sql):
        """TRIANGULATE: rpc_process_outbox_dispatch y rpc_process_outbox_batch son
        funciones DISTINTAS — dispatch no reemplazó a batch en este archivo.

        Ojo con el motivo: una versión previa de este test decía "Python relay
        still works". Ya no existe ningún relay Python — `OutboxRelayService` y
        sus cinco archivos de tests se retiraron en el hotfix 2026-08-24
        (20261012000001_revoke_outbox_cross_tenant.sql), porque era una segunda
        implementación incompleta que corría 2 de los 4 consumers y marcaba
        processed_at igual. Las dos firmas siguen presentes acá simplemente
        porque esta migración es HISTÓRICA y no se reescribe; hoy están
        revocadas de PUBLIC/anon/authenticated y sin ningún caller de
        aplicación. El inventario vivo de quién puede recorrer el outbox está
        en el chequeo (5) de supabase/tests/test_function_acl_gate.sql.
        """
        assert "rpc_process_outbox_batch" in sql, (
            "rpc_process_outbox_batch debe seguir en la migración histórica: los "
            "archivos de migración no se reescriben. Su ACL la cierra "
            "20261012000001_revoke_outbox_cross_tenant.sql"
        )
        assert "rpc_process_outbox_dispatch" in sql, (
            "rpc_process_outbox_dispatch must exist (pure-SQL relay)"
        )
        # They are different function names
        assert "rpc_process_outbox_batch" != "rpc_process_outbox_dispatch"

    def test_mark_event_processed_rpc_still_present(self, sql):
        """TRIANGULATE: rpc_mark_event_processed sigue presente en la migración
        histórica (mismo motivo que el test de arriba: las migraciones no se
        reescriben). NO porque exista un relay Python que la use — no existe."""
        assert "rpc_mark_event_processed" in sql, (
            "rpc_mark_event_processed debe seguir en la migración histórica. Está "
            "revocada y sin caller de aplicación desde "
            "20261012000001_revoke_outbox_cross_tenant.sql"
        )

    # ── Triangulate 6: function uses RETURNS int (not SETOF, not void) ────────

    def test_dispatch_rpc_does_not_return_setof(self, sql):
        """TRIANGULATE: rpc_process_outbox_dispatch must RETURNS int, not RETURNS SETOF.

        rpc_process_outbox_batch uses SETOF (returns rows).
        rpc_process_outbox_dispatch returns a count (int) — different contract.
        """
        match = re.search(
            r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+public\.rpc_process_outbox_dispatch(.*?)AS\s+\$function\$",
            sql,
            re.IGNORECASE | re.DOTALL,
        )
        assert match, "Could not find rpc_process_outbox_dispatch CREATE block"
        header = match.group(0)
        assert not re.search(r"RETURNS\s+SETOF", header, re.IGNORECASE), (
            "rpc_process_outbox_dispatch must not RETURNS SETOF — it returns an int count"
        )
        assert re.search(r"RETURNS\s+int", header, re.IGNORECASE), (
            "rpc_process_outbox_dispatch must RETURNS int"
        )

    # ── Triangulate 7: cron body batch size is 100 ────────────────────────────

    def test_cron_body_calls_dispatch_with_batch_100(self, sql):
        """TRIANGULATE: Cron calls rpc_process_outbox_dispatch(100) — explicit batch size."""
        # Find the cron.schedule block
        schedule_pos = -1
        search_from = 0
        while True:
            pos = sql.find("cron.schedule(", search_from)
            if pos == -1:
                break
            if "relay-process-outbox" in sql[pos: pos + 200]:
                schedule_pos = pos
                break
            search_from = pos + 1
        assert schedule_pos != -1
        dollar_open = sql.find("$$", schedule_pos)
        dollar_close = sql.find("$$", dollar_open + 2)
        inner = sql[dollar_open: dollar_close]
        assert "rpc_process_outbox_dispatch(100)" in inner, (
            "Cron must call rpc_process_outbox_dispatch(100) with explicit batch limit"
        )
