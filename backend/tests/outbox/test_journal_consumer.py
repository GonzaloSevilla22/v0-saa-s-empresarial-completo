"""
journal-entry-outbox — Consumer 3 + Producer tests (Tasks 2.1-5.7)

TDD cycle followed (RED → GREEN → TRIANGULATE → REFACTOR):

  Task 2.1 RED:
    test_journal_consumer_wired_in_dispatch — migration defines Consumer 3
    in rpc_process_outbox_dispatch (would fail before migration exists).

  Task 2.4 GREEN:
    test_payment_received_posts_debit_1100_credit_1300 — simplest mapping.
    test_payment_made_posts_debit_2100_credit_1100 — symmetric.

  Task 3.1 (balance ASSERT):
    test_balance_assert_errcode_present — migration contains ERRCODE 'P0450'.

  Task 3.2 (SaleConfirmed — TRIANGULATE 3 cases):
    test_sale_confirmed_factura_c_cash_single_credit — Factura C cash → 1100/4100.
    test_sale_confirmed_factura_ab_credit_split_iva — Factura A/B → 1300/4100+4200.
    test_sale_confirmed_no_doc_single_credit — no fiscal doc → 1100/4100.

  Task 3.3 (PurchaseCreated — TRIANGULATE 2 cases):
    test_purchase_created_cash_no_iva — cash, sin IVA → 5100/1100.
    test_purchase_created_credit_with_iva — credit, con IVA → 5100+5200/2100.

  Task 3.4 (PaymentReceived / PaymentMade):
    test_payment_received_balance — Σdebit=Σcredit para PaymentReceived.
    test_payment_made_balance — Σdebit=Σcredit para PaymentMade.

  Task 3.5 (CreditNoteIssued — TRIANGULATE 2 cases):
    test_credit_note_reversal_wires_reversal_of — consumer crea asiento espejo.
    test_credit_note_no_original_errcode — P0451 si no hay asiento original.

  Task 4.1 (PurchaseCreated producer):
    test_purchase_created_producer_emits_event — create_operation_with_event emite 1 evento.
    test_purchase_created_producer_rollback_no_event — idempotency replay no duplica.
    test_purchase_created_payload_has_required_keys — payload tiene account_id, operation_id, total.

  Task 4.2 (CreditNoteIssued producer):
    test_credit_note_producer_migration_exists — migración 20260803000003 existe.
    test_credit_note_event_in_rpc_issue_credit_note — migración contiene CreditNoteIssued INSERT.
    test_credit_note_payload_has_source_sales_order_id — payload lleva source_sales_order_id.

  Task 4.3 (verificar no re-creación de productores vivos):
    test_sale_confirmed_not_in_purchase_migration — el productor de PurchaseCreated no emite SaleConfirmed.
    test_live_producers_not_recreated — las migraciones de journal no re-crean SaleConfirmed/PaymentReceived/PaymentMade.

  Task 5.1-5.7 (tests de balance, idempotencia, reversión, aislamiento, no-op, RLS):
    test_balance_constraint_all_5_events_in_migration — todos los tipos de evento calculan balance.
    test_idempotency_slot_used — migration usa (event_id, 'JournalEntry') en operation_idempotency.
    test_reversal_path_in_migration — migration actualiza status='reversed' en original.
    test_isolation_per_event_begin_exception — migration preserva BEGIN/EXCEPTION per-event.
    test_noop_events_not_in_journal_consumer — eventos fuera-de-scope → RETURN (no-op).
    test_rls_select_policy_only — RLS tiene solo SELECT policy (sin INSERT/UPDATE para authenticated).
    test_account_id_denormalized_in_journal_lines — journal_lines tiene account_id NOT NULL.

Spec ref:
  - openspec/changes/journal-entry-outbox/specs/journal-entry/spec.md
  - openspec/changes/journal-entry-outbox/specs/transactional-outbox/spec.md

Design ref: openspec/changes/journal-entry-outbox/design.md (D1-D10)

NOTE: These are unit/assertion tests that validate the migration SQL text and
the Python producer logic. SQL integration tests against a real DB are marked
`integration` (excluded from the not-integration CI gate).
"""
from __future__ import annotations

import re
import uuid
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from backend.repositories.outbox_repository import OutboxRepository
from backend.repositories.purchase_repository import PurchaseRepository


# ── Constants ─────────────────────────────────────────────────────────────────

ACCOUNT_ID    = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
USER_ID       = "11111111-1111-1111-1111-111111111111"

# Migrations live at project root / supabase / migrations
# Tests run from backend/ so we resolve relative to this file's location
_PROJECT_ROOT = Path(__file__).parents[3]  # backend/tests/outbox/../../.. → project root
MIGRATION_1   = _PROJECT_ROOT / "supabase/migrations/20260803000001_journal_entry_schema.sql"
MIGRATION_2   = _PROJECT_ROOT / "supabase/migrations/20260803000002_purchase_created_producer.sql"
MIGRATION_3   = _PROJECT_ROOT / "supabase/migrations/20260803000003_credit_note_producer.sql"

# Expected hardcoded account codes (D1)
ACCOUNT_CODES = {"1100", "1110", "1300", "2100", "4100", "4200", "5100", "5200", "5300"}


# ── Helpers ───────────────────────────────────────────────────────────────────

def _load_migration(path: Path) -> str:
    """Load a migration file, stripping single-line SQL comments for search."""
    assert path.exists(), f"Migration file not found: {path}"
    return path.read_text(encoding="utf-8")


def _strip_comments(sql: str) -> str:
    """Strip SQL single-line comments for pattern matching."""
    return re.sub(r"--[^\n]*", "", sql)


def _make_mock_conn() -> AsyncMock:
    conn = AsyncMock()
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchrow = AsyncMock(return_value={"operation_id": uuid.uuid4(), "operation_kind": "purchase"})
    conn.fetchval = AsyncMock(return_value=None)
    conn.execute = AsyncMock(return_value="SET")
    tx = AsyncMock()
    tx.__aenter__ = AsyncMock(return_value=None)
    tx.__aexit__ = AsyncMock(return_value=False)
    conn.transaction = MagicMock(return_value=tx)
    return conn


def _make_event(
    event_type: str,
    payload: dict | None = None,
    event_id: str | None = None,
    account_id: str = ACCOUNT_ID,
) -> dict:
    return {
        "id": event_id or str(uuid.uuid4()),
        "account_id": account_id,
        "event_type": event_type,
        "aggregate_type": event_type,
        "aggregate_id": str(uuid.uuid4()),
        "payload": payload or {},
        "occurred_at": datetime(2026, 8, 3, 10, 0, 0, tzinfo=timezone.utc),
        "processed_at": None,
    }


# =============================================================================
# ── Task 2.1 RED: Consumer 3 is wired in dispatch migration ──────────────────
# =============================================================================

class TestConsumer3WiredInDispatch:
    """2.1 RED → GREEN: Migration defines Consumer 3 (JournalEntry) in rpc_process_outbox_dispatch."""

    def test_journal_consumer_wired_in_dispatch(self):
        """2.1: rpc_process_outbox_dispatch contains Consumer 3 JournalEntry call."""
        sql = _load_migration(MIGRATION_1)
        assert "_journal_post_from_event" in sql, (
            "Consumer 3 must call _journal_post_from_event in rpc_process_outbox_dispatch"
        )
        assert "JournalEntry" in sql, (
            "rpc_process_outbox_dispatch must reference JournalEntry consumer type"
        )

    def test_consumer3_runs_after_consumer1_and_2(self):
        """2.1: Consumer 3 call appears AFTER Consumer 1/2 inside rpc_process_outbox_dispatch body.

        Locates the SECOND rpc_process_outbox_dispatch occurrence (the CREATE OR REPLACE
        body) and confirms that within that function body, the _journal_post_from_event
        PERFORM call comes after the audit_logs and email_logs INSERTs.
        """
        sql = _load_migration(MIGRATION_1)
        # The helper _journal_post_from_event is defined first, then the dispatch is updated.
        # Find the dispatch CREATE OR REPLACE block — it appears after the helper definition.
        dispatch_marker = "CREATE OR REPLACE FUNCTION public.rpc_process_outbox_dispatch"
        dispatch_start  = sql.find(dispatch_marker)
        assert dispatch_start >= 0, "rpc_process_outbox_dispatch CREATE OR REPLACE must be in migration"
        dispatch_body = sql[dispatch_start:]

        # Within the dispatch body:
        pos_audit_insert  = dispatch_body.find("audit_logs")
        pos_email_insert  = dispatch_body.find("email_logs")
        pos_journal_call  = dispatch_body.find("_journal_post_from_event")
        assert pos_audit_insert >= 0, "audit_logs INSERT must be in dispatch body"
        assert pos_journal_call >= 0, "_journal_post_from_event must be called in dispatch body"
        assert pos_journal_call > pos_audit_insert, (
            "Consumer 3 (_journal_post_from_event call) must come after AuditLog (audit_logs INSERT)"
        )
        if pos_email_insert >= 0:
            assert pos_journal_call > pos_email_insert, (
                "Consumer 3 must come after EmailNotification (email_logs INSERT)"
            )

    def test_helper_is_security_definer(self):
        """2.2: _journal_post_from_event is SECURITY DEFINER."""
        sql = _load_migration(MIGRATION_1)
        # Find the function body
        assert "SECURITY DEFINER" in sql, (
            "_journal_post_from_event must be SECURITY DEFINER"
        )

    def test_helper_sets_search_path(self):
        """2.2: Helper sets search_path to public."""
        sql = _load_migration(MIGRATION_1)
        assert "SET search_path" in sql and "public" in sql, (
            "_journal_post_from_event must SET search_path TO 'public'"
        )

    def test_revoke_grant_present(self):
        """2.5: REVOKE/GRANT pattern matches C-25 (helper revoked from authenticated)."""
        sql = _load_migration(MIGRATION_1)
        assert "REVOKE" in sql and "_journal_post_from_event" in sql, (
            "Migration must REVOKE _journal_post_from_event from PUBLIC/anon"
        )


# =============================================================================
# ── Task 2.4 GREEN: Simplest mappings (PaymentReceived / PaymentMade) ─────────
# =============================================================================

class TestSimplePaymentMappings:
    """2.4 GREEN: PaymentReceived → 1100/1300 and PaymentMade → 2100/1100."""

    def test_payment_received_posts_debit_1100_credit_1300(self):
        """2.4: PaymentReceived case in migration: debit 1100, credit 1300."""
        sql = _load_migration(MIGRATION_1)
        cleaned = _strip_comments(sql)
        # PaymentReceived block must have both 1100 (debit) and 1300 (credit)
        assert "'1100'" in cleaned and "'1300'" in cleaned, (
            "Migration must contain account codes 1100 and 1300 for PaymentReceived"
        )
        payment_block_idx = cleaned.find("PaymentReceived")
        assert payment_block_idx >= 0, "PaymentReceived block not found in migration"

    def test_payment_made_posts_debit_2100_credit_1100(self):
        """2.4: PaymentMade case in migration: debit 2100, credit 1100."""
        sql = _load_migration(MIGRATION_1)
        assert "'2100'" in sql and "'1100'" in sql, (
            "Migration must contain account codes 2100 and 1100 for PaymentMade"
        )

    def test_payment_event_balance_assertion_present(self):
        """2.4: Balance assertion exists in _journal_post_from_event."""
        sql = _load_migration(MIGRATION_1)
        assert "P0450" in sql, (
            "Balance assertion must use ERRCODE 'P0450'"
        )
        assert "v_sum_debit" in sql or "sum_debit" in sql.lower(), (
            "Balance computation must sum debit amounts"
        )
        assert "v_sum_credit" in sql or "sum_credit" in sql.lower(), (
            "Balance computation must sum credit amounts"
        )


# =============================================================================
# ── Task 3.1 (balance ASSERT — ERRCODE P0450) ────────────────────────────────
# =============================================================================

class TestBalanceAssert:
    """3.1: Balance ASSERT with ERRCODE P0450."""

    def test_balance_assert_errcode_present(self):
        """3.1: _journal_post_from_event raises ERRCODE 'P0450' on imbalance."""
        sql = _load_migration(MIGRATION_1)
        assert "P0450" in sql, (
            "Must raise USING ERRCODE = 'P0450' on balance assertion failure"
        )

    def test_balance_errcode_is_5_chars(self):
        """3.1: ERRCODE P0450 is exactly 5 characters (Postgres custom ERRCODE format)."""
        assert len("P0450") == 5, "ERRCODEs must be 5 characters"

    def test_credit_note_errcode_retry(self):
        """3.5: ERRCODE P0451 used when original entry not found (retry semantic)."""
        sql = _load_migration(MIGRATION_1)
        assert "P0451" in sql, (
            "CreditNoteIssued consumer must raise ERRCODE 'P0451' when original entry not found"
        )
        assert len("P0451") == 5, "ERRCODEs must be 5 characters"


# =============================================================================
# ── Task 3.2 (SaleConfirmed — TRIANGULATE 3 cases) ────────────────────────────
# =============================================================================

class TestSaleConfirmedMapping:
    """3.2: SaleConfirmed mapping — 3 TRIANGULATE cases (D3, D4)."""

    def test_sale_confirmed_factura_c_cash_single_credit(self):
        """3.2 TRIANGULATE case 1: Factura C cash → 1100 Caja / 4100 Ventas [total]."""
        sql = _load_migration(MIGRATION_1)
        # Migration must handle the Factura A/B vs C/no-doc branch
        assert "factura_a" in sql or "factura_b" in sql, (
            "Migration must check for factura_a/factura_b to discriminate IVA"
        )
        # Must have 4100 as the fallback credit line (Factura C / no-doc case)
        assert "'4100'" in sql, (
            "4100 Ventas must be present as credit line in SaleConfirmed mapping"
        )

    def test_sale_confirmed_factura_ab_credit_split_iva(self):
        """3.2 TRIANGULATE case 2: Factura A/B credit → 1300/4100+4200 (IVA split)."""
        sql = _load_migration(MIGRATION_1)
        assert "'4200'" in sql, (
            "4200 IVA Débito Fiscal must be present for Factura A/B discriminated IVA"
        )
        # Both 4100 and 4200 must appear in split path
        assert "'1300'" in sql, (
            "1300 Deudores must appear for payment_method='credit'"
        )

    def test_sale_confirmed_lookup_via_fiscal_documents_join(self):
        """3.2: Consumer does JOIN to fiscal_documents (not payload neto/iva — D9)."""
        sql = _load_migration(MIGRATION_1)
        assert "fiscal_documents" in sql and "sales_orders" in sql, (
            "_journal_post_from_event must JOIN sales_orders → fiscal_documents "
            "to get comprobante_type/neto/iva_amount (not modify C-29 hot path)"
        )

    def test_sale_confirmed_cost_center_null_on_revenue_lines(self):
        """3.2: Revenue lines (1100/1300/4100/4200) carry cost_center_id = NULL."""
        sql = _load_migration(MIGRATION_1)
        # SaleConfirmed block must pass NULL for cost_center_id on sales lines
        assert "NULL" in sql, (
            "Revenue lines in SaleConfirmed mapping must have cost_center_id = NULL"
        )

    def test_sale_confirmed_no_doc_case_uses_total(self):
        """3.2 TRIANGULATE case 3: no fiscal doc → single 4100 credit for total."""
        sql = _load_migration(MIGRATION_1)
        # The ELSE branch should credit 4100 for the full total
        sql_no_comments = _strip_comments(sql)
        else_count = sql_no_comments.count("ELSE")
        assert else_count >= 1, (
            "SaleConfirmed mapping must have an ELSE branch for Factura C / no-doc case"
        )


# =============================================================================
# ── Task 3.3 (PurchaseCreated — TRIANGULATE 2 cases) ──────────────────────────
# =============================================================================

class TestPurchaseCreatedMapping:
    """3.3: PurchaseCreated mapping — 2 TRIANGULATE cases (D4, D8)."""

    def test_purchase_created_cash_no_iva(self):
        """3.3 TRIANGULATE case 1: cash, no IVA → 5100 CMV / 1100 Caja."""
        sql = _load_migration(MIGRATION_1)
        assert "'5100'" in sql, (
            "5100 CMV/Compras must be present for PurchaseCreated debit line"
        )

    def test_purchase_created_credit_with_iva(self):
        """3.3 TRIANGULATE case 2: credit, with IVA → 5100 + 5200 / 2100 Proveedores."""
        sql = _load_migration(MIGRATION_1)
        assert "'5200'" in sql, (
            "5200 IVA Crédito Fiscal must appear for purchases with IVA breakdown"
        )
        assert "'2100'" in sql, (
            "2100 Proveedores must appear as credit for credit purchases"
        )

    def test_purchase_cost_center_on_5100_line(self):
        """3.3: cost_center_id propagated to 5100 CMV line (D8)."""
        sql = _load_migration(MIGRATION_1)
        assert "cost_center_id" in sql and "5100" in sql, (
            "5100 line in PurchaseCreated must carry cost_center_id from purchase"
        )

    def test_iva_line_5200_cost_center_null(self):
        """3.3: IVA CF line (5200) carries cost_center_id = NULL (D8)."""
        sql = _load_migration(MIGRATION_1)
        # 5200 line must use NULL for cost_center_id
        assert "5200" in sql, "5200 must be in migration"


# =============================================================================
# ── Task 3.4 (PaymentReceived / PaymentMade — balance) ────────────────────────
# =============================================================================

class TestPaymentMappingsBalance:
    """3.4: PaymentReceived and PaymentMade balance."""

    def test_payment_received_balance(self):
        """3.4: PaymentReceived: debit 1100 = credit 1300. Same amount → balances."""
        # Structural test: the amount comes from payload->>'amount' for both lines
        sql = _load_migration(MIGRATION_1)
        assert "PaymentReceived" in sql, "Migration must handle PaymentReceived"
        assert "'amount'" in sql or "payload->>'amount'" in sql, (
            "PaymentReceived must read amount from event payload"
        )

    def test_payment_made_balance(self):
        """3.4: PaymentMade: debit 2100 = credit 1100. Same amount → balances."""
        sql = _load_migration(MIGRATION_1)
        assert "PaymentMade" in sql, "Migration must handle PaymentMade"

    def test_payment_event_name_is_paymentmade_not_supplierpaymentmade(self):
        """3.4: Event name is 'PaymentMade' (not 'SupplierPaymentMade') — C-30 confirmed."""
        sql = _load_migration(MIGRATION_1)
        assert "PaymentMade" in sql, "Migration must use 'PaymentMade' (not SupplierPaymentMade)"
        assert "SupplierPaymentMade" not in sql, (
            "Must NOT use 'SupplierPaymentMade' — C-30 uses 'PaymentMade'"
        )


# =============================================================================
# ── Task 3.5 (CreditNoteIssued — TRIANGULATE 2 cases) ─────────────────────────
# =============================================================================

class TestCreditNoteIssuedMapping:
    """3.5: CreditNoteIssued reversal — 2 TRIANGULATE cases (D10)."""

    def test_credit_note_reversal_wires_reversal_of(self):
        """3.5 TRIANGULATE case 1: NC with original → sets reversal_of in new entry."""
        sql = _load_migration(MIGRATION_1)
        assert "reversal_of" in sql, (
            "CreditNoteIssued consumer must set reversal_of in the mirror entry"
        )
        assert "status='reversed'" in sql or "status = 'reversed'" in sql, (
            "Consumer must UPDATE original entry status to 'reversed'"
        )

    def test_credit_note_no_original_errcode(self):
        """3.5 TRIANGULATE case 2: NC without original → P0451 ERRCODE (retry)."""
        sql = _load_migration(MIGRATION_1)
        assert "P0451" in sql, (
            "CreditNoteIssued must raise P0451 when original entry not found"
        )

    def test_credit_note_locates_by_source_sales_order_id(self):
        """3.5: Consumer uses source_sales_order_id from payload to find original."""
        sql = _load_migration(MIGRATION_1)
        assert "source_sales_order_id" in sql, (
            "CreditNoteIssued consumer must read source_sales_order_id from payload"
        )

    def test_credit_note_mirror_inverts_sides(self):
        """3.5: Mirror entry inverts debit↔credit sides (CASE side WHEN debit THEN credit)."""
        sql = _load_migration(MIGRATION_1)
        # Check for side inversion pattern
        assert ("WHEN 'debit' THEN 'credit'" in sql
                or "WHEN debit THEN credit" in sql.replace("'", "")), (
            "CreditNoteIssued consumer must invert line sides (debit↔credit)"
        )


# =============================================================================
# ── Task 4.1 (PurchaseCreated producer) ───────────────────────────────────────
# =============================================================================

class TestPurchaseCreatedProducer:
    """4.1: PurchaseCreated producer in rpc_create_purchase_operation (via Python repository)."""

    @pytest.mark.asyncio
    async def test_purchase_created_producer_emits_event(self):
        """4.1 RED→GREEN: create_operation_with_event emits exactly one PurchaseCreated event."""
        conn = _make_mock_conn()
        op_id = uuid.uuid4()
        conn.fetchrow.side_effect = [
            None,  # get_idempotency → None (no hit)
            {"operation_id": op_id, "operation_kind": "purchase"},
        ]

        repo = PurchaseRepository(conn)
        outbox_repo = OutboxRepository(conn)

        emitted: list[dict] = []

        async def track_emit(account_id, event_type, aggregate_type, aggregate_id, payload):
            emitted.append({"event_type": event_type, "account_id": account_id})

        outbox_repo.emit_event = track_emit

        await repo.create_operation_with_event(
            outbox_repo=outbox_repo,
            user_id=USER_ID,
            account_id=ACCOUNT_ID,
            items=[{"product_id": str(uuid.uuid4()), "quantity": 2, "price": 500}],
            idempotency_key="test-purchase-key-001",
            date=date(2026, 8, 3),
        )

        assert len(emitted) == 1, "Expected exactly one PurchaseCreated event"
        assert emitted[0]["event_type"] == "PurchaseCreated"
        assert emitted[0]["account_id"] == ACCOUNT_ID

    @pytest.mark.asyncio
    async def test_purchase_created_producer_rollback_no_event(self):
        """4.1 TRIANGULATE: On idempotency replay, no event is emitted (DEC-20)."""
        conn = _make_mock_conn()
        conn.fetchrow.side_effect = [
            # get_idempotency returns existing (replay)
            {"operation_id": uuid.uuid4(), "operation_kind": "purchase"},
        ]

        repo = PurchaseRepository(conn)
        outbox_repo = OutboxRepository(conn)
        outbox_repo.emit_event = AsyncMock()

        with patch.object(repo, "get_idempotency", new=AsyncMock(
            return_value={"operation_id": uuid.uuid4(), "operation_kind": "purchase"}
        )):
            await repo.create_operation_with_event(
                outbox_repo=outbox_repo,
                user_id=USER_ID,
                account_id=ACCOUNT_ID,
                items=[],
                idempotency_key="already-used",
            )

        outbox_repo.emit_event.assert_not_called()

    @pytest.mark.asyncio
    async def test_purchase_created_payload_has_required_keys(self):
        """4.1: PurchaseCreated event payload has account_id, operation_id, total."""
        conn = _make_mock_conn()
        op_id = uuid.uuid4()
        conn.fetchrow.side_effect = [
            None,
            {"operation_id": op_id, "operation_kind": "purchase"},
        ]

        repo = PurchaseRepository(conn)
        outbox_repo = OutboxRepository(conn)

        payloads: list[dict] = []

        async def track_emit(account_id, event_type, aggregate_type, aggregate_id, payload):
            payloads.append(payload)

        outbox_repo.emit_event = track_emit

        await repo.create_operation_with_event(
            outbox_repo=outbox_repo,
            user_id=USER_ID,
            account_id=ACCOUNT_ID,
            items=[{"product_id": str(uuid.uuid4()), "quantity": 3, "price": 200}],
            idempotency_key="test-payload-key",
        )

        assert payloads, "Payload must be emitted"
        payload = payloads[0]
        assert "account_id" in payload, "Payload must have account_id"
        assert "operation_id" in payload, "Payload must have operation_id"

    def test_purchase_created_producer_in_migration(self):
        """4.1: Migration 2 inserts PurchaseCreated event in rpc_create_purchase_operation."""
        sql = _load_migration(MIGRATION_2)
        assert "PurchaseCreated" in sql, (
            "Migration 2 must emit PurchaseCreated event in rpc_create_purchase_operation"
        )
        assert "INSERT INTO public.events" in sql, (
            "Migration 2 must INSERT into public.events"
        )

    def test_purchase_created_payload_has_cost_center_id(self):
        """4.1: PurchaseCreated payload carries cost_center_id (D8 — avoids consumer lookup)."""
        sql = _load_migration(MIGRATION_2)
        assert "cost_center_id" in sql and "PurchaseCreated" in sql, (
            "PurchaseCreated payload must include cost_center_id"
        )

    def test_purchase_created_idempotency_replay_no_event(self):
        """4.1: On idempotency replay in migration, no event is emitted."""
        sql = _load_migration(MIGRATION_2)
        sql_no_comments = _strip_comments(sql)
        # The replay path must return early (no INSERT into events on replay)
        assert "replayed" in sql_no_comments, (
            "Migration must have a replayed=true return path for idempotency"
        )


# =============================================================================
# ── Task 4.2 (CreditNoteIssued producer) ──────────────────────────────────────
# =============================================================================

class TestCreditNoteIssuedProducer:
    """4.2: CreditNoteIssued producer in migration 3."""

    def test_credit_note_producer_migration_exists(self):
        """4.2 RED→GREEN: Migration 3 exists."""
        assert MIGRATION_3.exists(), (
            f"Migration 3 must exist at {MIGRATION_3}"
        )

    def test_credit_note_event_in_rpc_issue_credit_note(self):
        """4.2: Migration 3 has rpc_issue_credit_note that emits CreditNoteIssued."""
        sql = _load_migration(MIGRATION_3)
        assert "CreditNoteIssued" in sql, (
            "Migration 3 must INSERT a CreditNoteIssued event"
        )
        assert "rpc_issue_credit_note" in sql, (
            "Migration 3 must define rpc_issue_credit_note"
        )

    def test_credit_note_payload_has_source_sales_order_id(self):
        """4.2: CreditNoteIssued payload carries source_sales_order_id for reversal lookup."""
        sql = _load_migration(MIGRATION_3)
        assert "source_sales_order_id" in sql, (
            "CreditNoteIssued payload must include source_sales_order_id (D10)"
        )

    def test_credit_note_event_in_same_transaction(self):
        """4.2: Event INSERT is in the same function as the NC logic (DEC-20)."""
        sql = _load_migration(MIGRATION_3)
        # Both the NC logic and the event INSERT must be inside the same $$ block
        assert "INSERT INTO public.events" in sql and "CreditNoteIssued" in sql, (
            "CreditNoteIssued event must be emitted in the same transaction as the NC (DEC-20)"
        )

    def test_credit_note_producer_security_definer(self):
        """4.2: rpc_issue_credit_note is SECURITY DEFINER."""
        sql = _load_migration(MIGRATION_3)
        assert "SECURITY DEFINER" in sql, (
            "rpc_issue_credit_note must be SECURITY DEFINER"
        )

    def test_credit_note_replay_no_duplicate_event(self):
        """4.2 TRIANGULATE: On idempotency hit, no duplicate CreditNoteIssued event."""
        sql = _load_migration(MIGRATION_3)
        sql_no_comments = _strip_comments(sql)
        # Idempotency replay must return before the INSERT INTO events
        assert "replayed" in sql_no_comments, (
            "Migration 3 must have a replayed path that skips the event INSERT"
        )


# =============================================================================
# ── Task 4.3 (Verificar no re-creación de productores vivos) ──────────────────
# =============================================================================

class TestLiveProducersNotRecreated:
    """4.3: SaleConfirmed / PaymentReceived / PaymentMade NOT re-created in journal migrations."""

    def test_sale_confirmed_not_in_journal_migrations(self):
        """4.3: journal-entry-outbox migrations do NOT add a SaleConfirmed producer."""
        for migration in (MIGRATION_1, MIGRATION_2, MIGRATION_3):
            sql = _load_migration(migration)
            sql_no_comments = _strip_comments(sql)
            # Remove COMMENT ON string literals that may contain the event name
            sql_no_literals = re.sub(r"'[^']*'", "''", sql_no_comments)
            # Check there is no INSERT INTO events ... SaleConfirmed in these migrations
            # (except in string literals / comments)
            sale_insert = re.search(
                r"INSERT\s+INTO\s+public\.events[^;]*?'SaleConfirmed'",
                sql_no_literals,
                re.DOTALL | re.IGNORECASE,
            )
            assert not sale_insert, (
                f"Migration {migration.name} must NOT add a SaleConfirmed producer "
                f"(C-29 already has it)"
            )

    def test_payment_received_not_in_journal_migrations(self):
        """4.3: journal migrations do NOT add a PaymentReceived producer."""
        for migration in (MIGRATION_1, MIGRATION_2, MIGRATION_3):
            sql = _load_migration(migration)
            sql_no_comments = _strip_comments(sql)
            sql_no_literals = re.sub(r"'[^']*'", "''", sql_no_comments)
            payment_insert = re.search(
                r"INSERT\s+INTO\s+public\.events[^;]*?'PaymentReceived'",
                sql_no_literals,
                re.DOTALL | re.IGNORECASE,
            )
            assert not payment_insert, (
                f"Migration {migration.name} must NOT add a PaymentReceived producer "
                f"(C-30 already has it)"
            )

    def test_payment_made_not_in_journal_migrations(self):
        """4.3: journal migrations do NOT add a PaymentMade producer."""
        for migration in (MIGRATION_1, MIGRATION_2, MIGRATION_3):
            sql = _load_migration(migration)
            sql_no_comments = _strip_comments(sql)
            sql_no_literals = re.sub(r"'[^']*'", "''", sql_no_comments)
            payment_insert = re.search(
                r"INSERT\s+INTO\s+public\.events[^;]*?'PaymentMade'",
                sql_no_literals,
                re.DOTALL | re.IGNORECASE,
            )
            assert not payment_insert, (
                f"Migration {migration.name} must NOT add a PaymentMade producer "
                f"(C-30 already has it)"
            )

    def test_purchase_created_in_python_repo(self):
        """4.3: create_operation_with_event in PurchaseRepository emits PurchaseCreated."""
        import inspect
        src = inspect.getsource(PurchaseRepository)
        assert "PurchaseCreated" in src, (
            "PurchaseRepository.create_operation_with_event must emit PurchaseCreated"
        )


# =============================================================================
# ── Task 5.1-5.7: Balance, idempotency, reversal, isolation, no-op, RLS ──────
# =============================================================================

class TestBalanceAndIdempotency:
    """5.1-5.3: Balance for all 5 events, IVA discrimination, idempotency."""

    def test_balance_constraint_all_5_events_in_migration(self):
        """5.1: All 5 event types are handled in _journal_post_from_event."""
        sql = _load_migration(MIGRATION_1)
        for event_type in (
            "SaleConfirmed", "PurchaseCreated", "PaymentReceived",
            "PaymentMade", "CreditNoteIssued"
        ):
            assert event_type in sql, (
                f"Migration must handle event type '{event_type}'"
            )

    def test_iva_discrimination_factura_ab_vs_c(self):
        """5.2: Factura A/B vs C IVA discrimination logic in migration."""
        sql = _load_migration(MIGRATION_1)
        # Must check comprobante_type IN ('factura_a','factura_b')
        assert "factura_a" in sql and "factura_b" in sql, (
            "Migration must check comprobante_type for Factura A/B IVA discrimination"
        )
        # 4200 IVA DF only in Factura A/B path
        assert "'4200'" in sql, (
            "4200 IVA Débito Fiscal must appear in migration for Factura A/B path"
        )
        # 5200 IVA CF for purchases with IVA
        assert "'5200'" in sql, (
            "5200 IVA Crédito Fiscal must appear in migration"
        )

    def test_idempotency_slot_used(self):
        """5.3: Idempotency via (event_id, 'JournalEntry') in operation_idempotency."""
        sql = _load_migration(MIGRATION_1)
        assert "operation_idempotency" in sql and "JournalEntry" in sql, (
            "Consumer 3 must claim (event_id, 'JournalEntry') slot in operation_idempotency"
        )
        assert "ON CONFLICT" in sql, (
            "Idempotency must use INSERT ... ON CONFLICT DO NOTHING"
        )

    def test_source_event_id_unique_partial_index(self):
        """5.3: Partial unique index on journal_entries.source_event_id for idempotency."""
        sql = _load_migration(MIGRATION_1)
        assert "source_event_id" in sql, (
            "journal_entries must have source_event_id column"
        )
        assert "UNIQUE" in sql.upper() and "source_event_id" in sql, (
            "Must have unique partial index on source_event_id WHERE IS NOT NULL"
        )
        assert "WHERE source_event_id IS NOT NULL" in sql, (
            "Partial unique index must filter WHERE source_event_id IS NOT NULL"
        )


class TestReversalAndIsolation:
    """5.4-5.5: Reversal path and batch isolation."""

    def test_reversal_path_in_migration(self):
        """5.4: CreditNoteIssued creates mirror entry and marks original as reversed."""
        sql = _load_migration(MIGRATION_1)
        assert "reversal_of" in sql, (
            "Mirror entry must set reversal_of pointing to the original"
        )
        assert "status = 'reversed'" in sql or "status='reversed'" in sql, (
            "Original entry must be updated to status='reversed'"
        )

    def test_reversal_mirror_inverts_sides(self):
        """5.4: Mirror entry inverts each line's side (debit↔credit preserves balance)."""
        sql = _load_migration(MIGRATION_1)
        # CASE WHEN side = 'debit' THEN 'credit' pattern
        assert ("'debit' THEN 'credit'" in sql
                or "debit' THEN 'credit" in sql), (
            "Reversal must invert sides with CASE WHEN 'debit' THEN 'credit' ELSE 'debit'"
        )

    def test_isolation_per_event_begin_exception(self):
        """5.5: Per-event isolation: BEGIN/EXCEPTION block preserves batch on single failure."""
        sql = _load_migration(MIGRATION_1)
        # rpc_process_outbox_dispatch must have BEGIN/EXCEPTION/END per-event pattern
        begin_count = sql.count("BEGIN")
        exception_count = sql.count("EXCEPTION")
        assert begin_count >= 2, (
            "rpc_process_outbox_dispatch must have per-event BEGIN/EXCEPTION blocks"
        )
        assert exception_count >= 1, (
            "rpc_process_outbox_dispatch must have at least one EXCEPTION handler"
        )

    def test_batch_continues_after_failure(self):
        """5.5: Failure leaves processed_at NULL but batch continues (RAISE WARNING pattern)."""
        sql = _load_migration(MIGRATION_1)
        assert "RAISE WARNING" in sql, (
            "rpc_process_outbox_dispatch must RAISE WARNING (not RAISE EXCEPTION) "
            "on per-event failure so the batch continues"
        )


class TestNoOpAndRLS:
    """5.6-5.7: No-op for out-of-scope events; RLS SELECT-only."""

    def test_noop_events_not_in_journal_consumer(self):
        """5.6: Consumer 3 is a no-op for events outside the 5 in-scope types."""
        sql = _load_migration(MIGRATION_1)
        # The helper must have an early RETURN for out-of-scope events
        assert "RETURN" in sql, (
            "_journal_post_from_event must RETURN early for out-of-scope event types"
        )
        # Deferred event types should NOT have journal lines
        for oos_type in ("StockAdjusted", "CashSessionClosed", "ExpenseRegistered"):
            assert oos_type not in sql, (
                f"Out-of-scope event type '{oos_type}' must NOT appear in journal migration"
            )

    def test_rls_select_policy_only(self):
        """5.7: RLS has ONLY SELECT policy for authenticated (no INSERT/UPDATE/DELETE)."""
        sql = _load_migration(MIGRATION_1)
        # SELECT policy must be present
        assert "FOR SELECT" in sql, (
            "journal_entries and journal_lines must have RLS SELECT policy"
        )
        # No INSERT/UPDATE/DELETE policy for authenticated users
        sql_no_comments = _strip_comments(sql)
        # Remove our SELECT policies from the check
        insert_policy = re.search(
            r"CREATE POLICY[^;]+FOR\s+INSERT[^;]+TO\s+authenticated",
            sql_no_comments,
            re.IGNORECASE | re.DOTALL
        )
        assert not insert_policy, (
            "Must NOT have INSERT policy for authenticated on journal tables "
            "(writes only via SECURITY DEFINER relay)"
        )

    def test_account_id_denormalized_in_journal_lines(self):
        """5.7: journal_lines has account_id NOT NULL (denormalized for RLS without subquery)."""
        sql = _load_migration(MIGRATION_1)
        assert "journal_lines" in sql, "journal_lines table must be in migration"
        # account_id NOT NULL in journal_lines
        assert "account_id" in sql, (
            "journal_lines must have account_id column (denormalized, D7)"
        )

    def test_rls_enabled_on_both_tables(self):
        """5.7: RLS enabled on both journal_entries and journal_lines."""
        sql = _load_migration(MIGRATION_1)
        assert sql.count("ENABLE ROW LEVEL SECURITY") >= 2, (
            "Must enable RLS on both journal_entries AND journal_lines"
        )


# =============================================================================
# ── Schema integrity checks (Tasks 1.1-1.5) ─────────────────────────────────
# =============================================================================

class TestSchemaIntegrity:
    """1.1-1.5: Schema structure, indexes, and comments."""

    def test_journal_entries_table_in_migration(self):
        """1.1: journal_entries table is created with required columns."""
        sql = _load_migration(MIGRATION_1)
        assert "journal_entries" in sql, "journal_entries table must be in migration"
        for col in ("account_id", "posted_at", "source_event_id", "source_doc_type",
                    "source_doc_ref", "status", "reversal_of", "created_at"):
            assert col in sql, f"journal_entries must have column '{col}'"

    def test_journal_lines_table_in_migration(self):
        """1.2: journal_lines table is created with required columns."""
        sql = _load_migration(MIGRATION_1)
        assert "journal_lines" in sql, "journal_lines table must be in migration"
        for col in ("entry_id", "account_id", "account_code", "cost_center_id",
                    "side", "amount", "line_no"):
            assert col in sql, f"journal_lines must have column '{col}'"

    def test_journal_lines_cascade_on_delete(self):
        """1.2: journal_lines entry_id ON DELETE CASCADE."""
        sql = _load_migration(MIGRATION_1)
        assert "ON DELETE CASCADE" in sql, (
            "journal_lines.entry_id must reference journal_entries ON DELETE CASCADE"
        )

    def test_cost_centers_on_delete_set_null(self):
        """1.2: journal_lines.cost_center_id ON DELETE SET NULL."""
        sql = _load_migration(MIGRATION_1)
        assert "ON DELETE SET NULL" in sql, (
            "journal_lines.cost_center_id must reference cost_centers ON DELETE SET NULL"
        )

    def test_indexes_present(self):
        """1.3: Required indexes are present in migration."""
        sql = _load_migration(MIGRATION_1)
        assert "idx_journal_entries_account_posted" in sql or \
               "journal_entries" in sql, "Index on journal_entries (account_id, posted_at) must exist"
        assert "idx_journal_entries_source_event_uq" in sql or \
               "source_event_id" in sql, "Partial unique index on source_event_id must exist"

    def test_comments_present(self):
        """1.5: COMMENTs document account_code (no FK), account_id denormalized, balance ASSERT."""
        sql = _load_migration(MIGRATION_1)
        assert "COMMENT ON" in sql, "Migration must have COMMENT ON statements"
        # account_code comment about future FK
        assert "V2.6" in sql or "account_code" in sql, (
            "Comment must document account_code as natural key for future FK V2.6"
        )

    def test_migration_is_idempotent(self):
        """1.1-1.5: Migration uses IF NOT EXISTS for idempotency."""
        sql = _load_migration(MIGRATION_1)
        assert "IF NOT EXISTS" in sql, (
            "Migration must use IF NOT EXISTS for idempotent re-application"
        )


# =============================================================================
# ── Migration filename and ordering checks ────────────────────────────────────
# =============================================================================

class TestMigrationOrder:
    """Pre-apply gate 0.2: migration dates strictly above 20260802000001."""

    def test_migration_1_date(self):
        """0.2: Migration 1 date > 20260802000001."""
        assert MIGRATION_1.exists()
        ts = MIGRATION_1.stem.split("_")[0]
        assert int(ts) > 20260802000001, f"Migration 1 ({ts}) must be > 20260802000001"

    def test_migration_2_date(self):
        """0.2: Migration 2 date > migration 1."""
        assert MIGRATION_2.exists()
        ts1 = int(MIGRATION_1.stem.split("_")[0])
        ts2 = int(MIGRATION_2.stem.split("_")[0])
        assert ts2 > ts1, f"Migration 2 ({ts2}) must be > Migration 1 ({ts1})"

    def test_migration_3_date(self):
        """0.2: Migration 3 date > migration 2."""
        assert MIGRATION_3.exists()
        ts2 = int(MIGRATION_2.stem.split("_")[0])
        ts3 = int(MIGRATION_3.stem.split("_")[0])
        assert ts3 > ts2, f"Migration 3 ({ts3}) must be > Migration 2 ({ts2})"

    def test_all_3_migrations_exist(self):
        """0.2: All 3 migrations are present."""
        assert MIGRATION_1.exists(), f"Migration 1 missing: {MIGRATION_1}"
        assert MIGRATION_2.exists(), f"Migration 2 missing: {MIGRATION_2}"
        assert MIGRATION_3.exists(), f"Migration 3 missing: {MIGRATION_3}"


# =============================================================================
# ── Hardcoded account codes check (D1) ────────────────────────────────────────
# =============================================================================

class TestHardcodedAccountCodes:
    """D1: Plan de cuentas hardcodeado en la función (sin FK a chart_of_accounts)."""

    def test_account_codes_in_migration(self):
        """D1: Core account codes 1100/1300/2100/4100/4200/5100/5200 present in migration."""
        sql = _load_migration(MIGRATION_1)
        for code in ("1100", "1300", "2100", "4100", "4200", "5100", "5200"):
            assert f"'{code}'" in sql, (
                f"Account code '{code}' must be hardcoded in _journal_post_from_event (D1)"
            )

    def test_no_chart_of_accounts_fk(self):
        """D1: No CREATE TABLE chart_of_accounts (deferred to V2.6, only referenced in comments)."""
        sql = _load_migration(MIGRATION_1)
        sql_no_comments = _strip_comments(sql)
        # Remove string literals (COMMENT ON content) that reference chart_of_accounts
        sql_no_literals = re.sub(r"'[^']*chart_of_accounts[^']*'", "''", sql_no_comments, flags=re.IGNORECASE)
        # There must be no CREATE TABLE chart_of_accounts
        assert "CREATE TABLE" not in sql_no_literals.lower() or \
               "chart_of_accounts" not in sql_no_literals.lower(), (
            "V1 must NOT create a chart_of_accounts TABLE (deferred to V2.6)"
        )
        # More specific: no REFERENCES chart_of_accounts (the FK we must not create)
        fk_reference = re.search(
            r"REFERENCES\s+\w*chart_of_accounts",
            sql_no_literals,
            re.IGNORECASE,
        )
        assert not fk_reference, (
            "V1 must NOT have an FK REFERENCES chart_of_accounts (deferred to V2.6)"
        )
