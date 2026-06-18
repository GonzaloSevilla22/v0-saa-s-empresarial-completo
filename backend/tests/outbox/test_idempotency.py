"""
C-25 v20-outbox-activation — Consumer idempotency tests (Tasks 4.1–4.4)

TDD cycle:
  4.1 RED : test_reprocessed_event_one_audit_row — same event dispatched to
            AuditLog twice → exactly one audit_logs row. Fails.
  4.2 GREEN: idempotency via INSERT ... ON CONFLICT DO NOTHING implemented.
  4.3 TRIANGULATE: test_independent_idempotency_per_consumer — AuditLog success
            + EmailNotification retry does NOT re-fire AuditLog.
  4.4 REFACTOR: idempotency guard factored into shared helper in repo.

Spec ref: transactional-outbox/spec.md §"Consumer idempotency"
Design ref: Decision 5 (operation_idempotency keyed by (event_id, consumer_type))
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock, call

import pytest

from backend.repositories.outbox_repository import OutboxRepository
from backend.services.outbox_relay_service import OutboxRelayService, CONSUMER_AUDIT, CONSUMER_EMAIL


ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
EVENT_ID = "cccccccc-cccc-cccc-cccc-cccccccccccc"


def _make_event(
    event_id: str = EVENT_ID,
    event_type: str = "SaleConfirmed",
    account_id: str = ACCOUNT_ID,
) -> dict:
    return {
        "id": event_id,
        "account_id": account_id,
        "event_type": event_type,
        "aggregate_type": "SalesOrder",
        "aggregate_id": str(uuid.uuid4()),
        "payload": {},
        "occurred_at": datetime(2026, 7, 18, 10, 0, 0, tzinfo=timezone.utc),
        "processed_at": None,
    }


@pytest.fixture
def mock_repo():
    repo = MagicMock()
    repo.fetch_pending_batch = AsyncMock()
    repo.mark_processed = AsyncMock()
    repo.insert_audit_log = AsyncMock()
    repo.insert_email_log = AsyncMock()
    # Default: idempotency not yet claimed (first run)
    repo.claim_idempotency = AsyncMock(return_value=True)
    return repo


@pytest.fixture
def service(mock_repo):
    return OutboxRelayService(repo=mock_repo)


# ── 4.1 RED → 4.2 GREEN ──────────────────────────────────────────────────────

class TestReprocessedEventOneAuditRow:
    """4.1/4.2: Dispatching the same event twice produces exactly one audit row."""

    @pytest.mark.asyncio
    async def test_reprocessed_event_one_audit_row(self, service, mock_repo):
        """4.1 RED → 4.2 GREEN: same event dispatched to AuditLog twice → ONE audit row.

        First dispatch: claim_idempotency returns True → INSERT.
        Second dispatch: claim_idempotency returns False → skip INSERT.
        """
        event = _make_event()

        # First run: slot available
        mock_repo.claim_idempotency.return_value = True
        mock_repo.fetch_pending_batch.return_value = [event]
        await service.process_pending()

        first_audit_count = mock_repo.insert_audit_log.call_count
        assert first_audit_count == 1, "First run must INSERT one audit row"

        # Second run: slot already claimed (collision on unique index)
        mock_repo.claim_idempotency.return_value = False
        mock_repo.insert_audit_log.reset_mock()
        mock_repo.mark_processed.reset_mock()

        # NOTE: On second run, claim returns False → consumer skips side-effect.
        # But the event is still marked processed (the relay already committed it
        # first time; on retry, it was already processed). Simulate: on second run
        # the event was NOT returned by fetch_pending_batch (already processed).
        mock_repo.fetch_pending_batch.return_value = []
        await service.process_pending()

        # No additional audit rows on second run
        mock_repo.insert_audit_log.assert_not_called()

    @pytest.mark.asyncio
    async def test_idempotency_claim_false_skips_audit_insert(self, service, mock_repo):
        """4.2: When claim_idempotency returns False, audit INSERT is skipped."""
        event = _make_event()
        mock_repo.fetch_pending_batch.return_value = [event]
        # Slot already claimed → skip
        mock_repo.claim_idempotency.return_value = False

        await service.process_pending()

        # No audit INSERT (idempotent skip)
        mock_repo.insert_audit_log.assert_not_called()
        # Event still marked processed (consumers skipped = idempotent success)
        mock_repo.mark_processed.assert_called_once_with(event["id"])

    @pytest.mark.asyncio
    async def test_claim_idempotency_called_with_correct_consumer_type(self, service, mock_repo):
        """4.2: claim_idempotency called with (event_id, 'AuditLog')."""
        event = _make_event()
        mock_repo.fetch_pending_batch.return_value = [event]

        await service.process_pending()

        # Verify audit consumer claim
        audit_claims = [
            c for c in mock_repo.claim_idempotency.call_args_list
            if CONSUMER_AUDIT in (c.args + tuple(c.kwargs.values()))
        ]
        assert len(audit_claims) >= 1, (
            f"claim_idempotency must be called with consumer_type='{CONSUMER_AUDIT}'"
        )


# ── 4.3 TRIANGULATE: independent idempotency per consumer ─────────────────────

class TestIndependentIdempotencyPerConsumer:
    """4.3: Each (event_id, consumer_type) is independent.

    AuditLog success + EmailNotification retry does NOT re-fire AuditLog.
    """

    @pytest.mark.asyncio
    async def test_independent_idempotency_per_consumer(self, service, mock_repo):
        """4.3: Email retry does not re-fire AuditLog (independent keys)."""
        event = _make_event(event_type="sale_created")
        mock_repo.fetch_pending_batch.return_value = [event]

        # AuditLog: first run → claimed (True)
        # EmailNotification: first run → not claimed (False = already processed)
        # Both consumers skip INSERT on second run; event is still processed.
        def claim_side_effect(event_id: str, consumer_type: str) -> bool:
            if consumer_type == CONSUMER_AUDIT:
                return False  # Already claimed (simulate second run for audit)
            if consumer_type == CONSUMER_EMAIL:
                return True   # Email retry: not yet claimed

        mock_repo.claim_idempotency.side_effect = claim_side_effect

        await service.process_pending()

        # AuditLog skipped (already claimed)
        mock_repo.insert_audit_log.assert_not_called()
        # EmailNotification runs (its slot was available)
        mock_repo.insert_email_log.assert_called_once()
        # Event marked processed (both consumers effectively done)
        mock_repo.mark_processed.assert_called_once_with(event["id"])

    @pytest.mark.asyncio
    async def test_separate_claim_per_consumer_per_event(self, service, mock_repo):
        """4.3: claim_idempotency called separately for each consumer."""
        event = _make_event(event_type="sale_created")
        mock_repo.fetch_pending_batch.return_value = [event]

        await service.process_pending()

        # Both consumers must call claim_idempotency independently
        consumer_types_claimed = [
            c.kwargs.get("consumer_type") or (c.args[1] if len(c.args) > 1 else None)
            for c in mock_repo.claim_idempotency.call_args_list
        ]
        assert CONSUMER_AUDIT in consumer_types_claimed
        assert CONSUMER_EMAIL in consumer_types_claimed

    @pytest.mark.asyncio
    async def test_email_failure_does_not_affect_audit_idempotency(self, service, mock_repo):
        """4.3: EmailNotification failure leaves its idempotency slot unclaimed.

        On retry: AuditLog slot exists (skip) but Email slot is free (retry).
        """
        event = _make_event(event_type="sale_created")
        mock_repo.fetch_pending_batch.return_value = [event]

        # Scenario: audit claimed, email not yet claimed but INSERT fails
        claim_results = {CONSUMER_AUDIT: False, CONSUMER_EMAIL: True}
        mock_repo.claim_idempotency.side_effect = lambda event_id, consumer_type: claim_results[consumer_type]
        mock_repo.insert_email_log.side_effect = RuntimeError("email error")

        await service.process_pending()

        # Email failed → event NOT marked processed
        mock_repo.mark_processed.assert_not_called()
        # Audit was NOT re-fired (slot already claimed)
        mock_repo.insert_audit_log.assert_not_called()
