"""
C-25 v20-outbox-activation — E2E outbox acceptance tests (Tasks 7.1–7.3)

TDD cycle:
  7.1 RED→GREEN: test_sale_created_to_audit_log — SaleConfirmed event (from
            C-29 path, via fixture insert) processed by relay yields an audit_logs entry.
  7.2 test_event_processed_twice_is_idempotent — relay run twice over the same
            event → exactly one audit_logs row.
  7.3 test_relay_raises_leaves_processed_at_null — force a consumer exception
            → events.processed_at stays NULL, retried next run.

These tests simulate the full outbox flow using mocked repositories.

Spec ref: transactional-outbox/spec.md (all requirements)
Design ref: all 5 decisions
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from backend.repositories.outbox_repository import OutboxRepository
from backend.services.outbox_relay_service import OutboxRelayService


ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"


def _make_sale_confirmed_event(event_id: str | None = None) -> dict:
    """Simulate a SaleConfirmed event as emitted by C-29's rpc_confirm_sales_order."""
    return {
        "id": event_id or str(uuid.uuid4()),
        "account_id": ACCOUNT_ID,
        "event_type": "SaleConfirmed",
        "aggregate_type": "SalesOrder",
        "aggregate_id": str(uuid.uuid4()),
        "payload": {
            "account_id": ACCOUNT_ID,
            "branch_id": str(uuid.uuid4()),
            "sales_order_id": str(uuid.uuid4()),
            "total": 5000.0,
            "occurred_at": "2026-07-18T12:00:00Z",
        },
        "occurred_at": datetime(2026, 7, 18, 12, 0, 0, tzinfo=timezone.utc),
        "processed_at": None,
    }


def _make_mock_repo():
    repo = MagicMock()
    repo.fetch_pending_batch = AsyncMock()
    repo.mark_processed = AsyncMock()
    repo.insert_audit_log = AsyncMock()
    repo.insert_email_log = AsyncMock()
    repo.claim_idempotency = AsyncMock(return_value=True)
    return repo


# ── 7.1 RED→GREEN ─────────────────────────────────────────────────────────────

class TestSaleCreatedToAuditLog:
    """7.1: SaleConfirmed event processed by relay yields an audit_logs entry."""

    @pytest.mark.asyncio
    async def test_sale_created_to_audit_log(self):
        """7.1: SaleConfirmed (from C-29 producer) → relay → audit_logs row."""
        repo = _make_mock_repo()
        event = _make_sale_confirmed_event()
        repo.fetch_pending_batch.return_value = [event]

        service = OutboxRelayService(repo=repo)
        processed = await service.process_pending()

        # Audit log must be written
        repo.insert_audit_log.assert_called_once()
        # Event must be marked processed
        repo.mark_processed.assert_called_once_with(event["id"])
        # Return count is 1
        assert processed == 1

    @pytest.mark.asyncio
    async def test_relay_end_to_end_multiple_events(self):
        """7.1: Relay processes a batch of mixed event types end-to-end."""
        repo = _make_mock_repo()
        events = [
            _make_sale_confirmed_event(),
            {**_make_sale_confirmed_event(), "event_type": "PurchaseCreated",
             "id": str(uuid.uuid4())},
            {**_make_sale_confirmed_event(), "event_type": "sale_created",
             "id": str(uuid.uuid4())},
        ]
        repo.fetch_pending_batch.return_value = events

        service = OutboxRelayService(repo=repo)
        processed = await service.process_pending()

        assert processed == 3
        # 3 audit logs (one per event)
        assert repo.insert_audit_log.call_count == 3
        # 1 email log (only sale_created is in EMAIL_EVENT_TYPES)
        assert repo.insert_email_log.call_count == 1
        # All 3 marked processed
        assert repo.mark_processed.call_count == 3


# ── 7.2 Idempotency E2E ───────────────────────────────────────────────────────

class TestEventProcessedTwiceIsIdempotent:
    """7.2: Relay run twice over the same event → exactly one audit_logs row."""

    @pytest.mark.asyncio
    async def test_event_processed_twice_is_idempotent(self):
        """7.2: Same event dispatched twice → exactly 1 audit_logs row."""
        repo = _make_mock_repo()
        event = _make_sale_confirmed_event()
        service = OutboxRelayService(repo=repo)

        # First run: slots available, event pending
        repo.fetch_pending_batch.return_value = [event]
        repo.claim_idempotency.return_value = True
        await service.process_pending()

        first_audit_count = repo.insert_audit_log.call_count
        assert first_audit_count == 1

        # Second run: slots already claimed (event would not be pending in real DB,
        # but simulate idempotency guard preventing double INSERT)
        repo.fetch_pending_batch.return_value = [event]
        repo.claim_idempotency.return_value = False  # already claimed
        repo.insert_audit_log.reset_mock()
        repo.mark_processed.reset_mock()

        await service.process_pending()

        # No additional audit rows
        repo.insert_audit_log.assert_not_called()
        # Event still "marked processed" (idempotent — already processed)
        repo.mark_processed.assert_called_once_with(event["id"])

    @pytest.mark.asyncio
    async def test_concurrent_relay_runs_do_not_double_process(self):
        """7.2: Two concurrent relay runs — SKIP LOCKED prevents overlap.

        The repository simulates SKIP LOCKED by returning an empty batch
        for the second concurrent run (the event is locked by the first).
        """
        repo1 = _make_mock_repo()
        repo2 = _make_mock_repo()
        event = _make_sale_confirmed_event()

        # Run 1 claims the event
        repo1.fetch_pending_batch.return_value = [event]
        # Run 2 finds nothing (event is locked by run 1 via SKIP LOCKED)
        repo2.fetch_pending_batch.return_value = []

        service1 = OutboxRelayService(repo=repo1)
        service2 = OutboxRelayService(repo=repo2)

        # Both runs execute concurrently (simulated sequentially)
        processed1 = await service1.process_pending()
        processed2 = await service2.process_pending()

        # Only run 1 processed the event
        assert processed1 == 1
        assert processed2 == 0
        repo1.insert_audit_log.assert_called_once()
        repo2.insert_audit_log.assert_not_called()


# ── 7.3 Failure leaves processed_at NULL ──────────────────────────────────────

class TestRelayRaisesLeavesProcessedAtNull:
    """7.3: Consumer exception → events.processed_at stays NULL, retried next run."""

    @pytest.mark.asyncio
    async def test_relay_raises_leaves_processed_at_null(self):
        """7.3: Consumer exception → processed_at stays NULL."""
        repo = _make_mock_repo()
        event = _make_sale_confirmed_event()
        repo.fetch_pending_batch.return_value = [event]
        # Force audit consumer failure
        repo.insert_audit_log.side_effect = RuntimeError("DB unavailable")

        service = OutboxRelayService(repo=repo)
        processed = await service.process_pending()

        # processed_at must NOT be set
        repo.mark_processed.assert_not_called()
        assert processed == 0

    @pytest.mark.asyncio
    async def test_relay_retries_on_next_run(self):
        """7.3: After failure on run 1, event is retried on run 2."""
        repo = _make_mock_repo()
        event = _make_sale_confirmed_event()
        service = OutboxRelayService(repo=repo)

        # Run 1: audit fails
        repo.fetch_pending_batch.return_value = [event]
        repo.insert_audit_log.side_effect = [RuntimeError("temporary failure"), None]

        await service.process_pending()
        repo.mark_processed.assert_not_called()

        # Run 2: audit succeeds (side_effect consumed the error on first call)
        repo.insert_audit_log.side_effect = None  # succeeds now
        repo.fetch_pending_batch.return_value = [event]  # event still pending

        processed = await service.process_pending()

        # Now processed
        repo.mark_processed.assert_called_once_with(event["id"])
        assert processed == 1

    @pytest.mark.asyncio
    async def test_email_failure_event_retried_without_audit_duplicate(self):
        """7.3 + 5.4: Email failure → retry run does not double-fire AuditLog."""
        from backend.services.outbox_relay_service import CONSUMER_AUDIT, CONSUMER_EMAIL

        repo = _make_mock_repo()
        event = {**_make_sale_confirmed_event(), "event_type": "sale_created"}
        service = OutboxRelayService(repo=repo)

        # Run 1: audit OK, email fails
        call_count = {"audit_claim": 0, "email_claim": 0}

        def claim_side_effect_run1(event_id, consumer_type):
            if consumer_type == CONSUMER_AUDIT:
                call_count["audit_claim"] += 1
                return True   # audit not yet claimed
            return True  # email not yet claimed

        repo.claim_idempotency.side_effect = claim_side_effect_run1
        repo.fetch_pending_batch.return_value = [event]
        repo.insert_email_log.side_effect = RuntimeError("email error")

        await service.process_pending()
        repo.mark_processed.assert_not_called()  # email failed

        # Run 2: audit already claimed, email now succeeds
        def claim_side_effect_run2(event_id, consumer_type):
            if consumer_type == CONSUMER_AUDIT:
                return False  # already claimed → skip
            return True   # email retry

        repo.claim_idempotency.side_effect = claim_side_effect_run2
        repo.fetch_pending_batch.return_value = [event]
        repo.insert_audit_log.reset_mock()
        repo.insert_email_log.reset_mock()  # reset call count too
        repo.insert_email_log.side_effect = None  # no longer raises
        repo.mark_processed.reset_mock()

        processed = await service.process_pending()

        # Audit NOT re-fired (idempotent)
        repo.insert_audit_log.assert_not_called()
        # Email succeeds (called once in run 2)
        repo.insert_email_log.assert_called_once()
        # Event marked processed
        assert processed == 1
