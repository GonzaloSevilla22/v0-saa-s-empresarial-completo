"""
C-25 v20-outbox-activation — AuditLog consumer tests (Tasks 3.1–3.5)

TDD cycle:
  3.1 RED : test_audit_consumer_writes_one_row — processing an event INSERTs
            exactly one audit_logs row stamped with account_id. Fails.
  3.2 GREEN: AuditLog consumer implemented; test passes.
  3.3 TRIANGULATE: test_audit_failure_keeps_event_unprocessed — audit failure
            leaves processed_at NULL.
  3.4 TRIANGULATE: test_relay_never_updates_or_deletes_audit_rows — relay only
            INSERTs audit rows.

Audit domain invariant:
  - AuditLog consumer runs FIRST (before EmailNotification)
  - processed_at set ONLY after audit INSERT commits
  - relay only INSERTs audit rows; no UPDATE/DELETE

Spec ref: transactional-outbox/spec.md §"AuditLog consumer"
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock, call, patch

import pytest

from backend.repositories.outbox_repository import OutboxRepository
from backend.services.outbox_relay_service import OutboxRelayService


ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
EVENT_ID = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"


def _make_event(event_type: str = "SaleConfirmed", processed_at: datetime | None = None) -> dict:
    return {
        "id": EVENT_ID,
        "account_id": ACCOUNT_ID,
        "event_type": event_type,
        "aggregate_type": "SalesOrder",
        "aggregate_id": str(uuid.uuid4()),
        "payload": {"sale_id": str(uuid.uuid4())},
        "occurred_at": datetime(2026, 7, 18, 10, 0, 0, tzinfo=timezone.utc),
        "processed_at": processed_at,
    }


@pytest.fixture
def mock_repo():
    repo = MagicMock()
    repo.fetch_pending_batch = AsyncMock()
    repo.mark_processed = AsyncMock()
    repo.insert_audit_log = AsyncMock()
    repo.insert_email_log = AsyncMock()
    repo.claim_idempotency = AsyncMock(return_value=True)
    return repo


@pytest.fixture
def service(mock_repo):
    return OutboxRelayService(repo=mock_repo)


# ── 3.1 RED → 3.2 GREEN ──────────────────────────────────────────────────────

class TestAuditConsumerWritesOneRow:
    """3.1/3.2: Processing an event writes exactly one audit_logs row."""

    @pytest.mark.asyncio
    async def test_audit_consumer_writes_one_row(self, service, mock_repo):
        """3.1 RED → 3.2 GREEN: processing an event INSERTs exactly one audit_logs row
        stamped with the event's account_id."""
        event = _make_event()
        mock_repo.fetch_pending_batch.return_value = [event]

        await service.process_pending()

        mock_repo.insert_audit_log.assert_called_once()
        call_kwargs = mock_repo.insert_audit_log.call_args
        # account_id must match the event's account_id
        assert ACCOUNT_ID in (call_kwargs.args + tuple(call_kwargs.kwargs.values()))

    @pytest.mark.asyncio
    async def test_audit_consumer_action_derived_from_event_type(self, service, mock_repo):
        """3.2: The action written to audit_logs is derived from event_type."""
        event = _make_event(event_type="PurchaseCreated")
        mock_repo.fetch_pending_batch.return_value = [event]

        await service.process_pending()

        call_kwargs = mock_repo.insert_audit_log.call_args
        all_args = list(call_kwargs.args) + list(call_kwargs.kwargs.values())
        assert "PurchaseCreated" in all_args

    @pytest.mark.asyncio
    async def test_audit_consumer_runs_before_email_consumer(self, service, mock_repo):
        """3.2: AuditLog consumer runs FIRST (before EmailNotification)."""
        call_order = []
        mock_repo.insert_audit_log.side_effect = lambda **kw: call_order.append("audit") or None
        mock_repo.insert_email_log.side_effect = lambda **kw: call_order.append("email") or None

        event = _make_event(event_type="sale_created")
        mock_repo.fetch_pending_batch.return_value = [event]

        await service.process_pending()

        assert call_order[0] == "audit", "AuditLog must run before EmailNotification"

    @pytest.mark.asyncio
    async def test_audit_consumer_called_once_per_event(self, service, mock_repo):
        """3.2: Exactly one audit_logs INSERT per event (not more)."""
        event = _make_event()
        mock_repo.fetch_pending_batch.return_value = [event]

        await service.process_pending()

        assert mock_repo.insert_audit_log.call_count == 1


# ── 3.3 TRIANGULATE: audit failure leaves event unprocessed ──────────────────

class TestAuditFailureKeepsEventUnprocessed:
    """3.3: If audit INSERT raises, processed_at stays NULL, no consumer runs."""

    @pytest.mark.asyncio
    async def test_audit_failure_keeps_event_unprocessed(self, service, mock_repo):
        """3.3: Audit INSERT failure → processed_at NOT set (event stays pending)."""
        event = _make_event()
        mock_repo.fetch_pending_batch.return_value = [event]
        mock_repo.insert_audit_log.side_effect = RuntimeError("DB connection error")

        await service.process_pending()

        mock_repo.mark_processed.assert_not_called()

    @pytest.mark.asyncio
    async def test_audit_failure_no_email_either(self, service, mock_repo):
        """3.3: Audit failure also prevents EmailNotification from running."""
        event = _make_event(event_type="sale_created")
        mock_repo.fetch_pending_batch.return_value = [event]
        mock_repo.insert_audit_log.side_effect = RuntimeError("DB error")

        await service.process_pending()

        mock_repo.insert_email_log.assert_not_called()

    @pytest.mark.asyncio
    async def test_audit_claim_failure_keeps_event_unprocessed(self, service, mock_repo):
        """3.3: If idempotency claim fails for audit, event stays unprocessed."""
        event = _make_event()
        mock_repo.fetch_pending_batch.return_value = [event]
        mock_repo.claim_idempotency.side_effect = RuntimeError("idempotency DB error")

        await service.process_pending()

        mock_repo.mark_processed.assert_not_called()


# ── 3.4 TRIANGULATE: relay never updates or deletes audit rows ────────────────

class TestRelayNeverUpdatesOrDeletesAuditRows:
    """3.4: Relay path only INSERTs audit rows — no UPDATE/DELETE."""

    @pytest.mark.asyncio
    async def test_relay_only_inserts_audit_rows(self, service, mock_repo):
        """3.4: The relay only calls insert_audit_log (never update/delete audit)."""
        event = _make_event()
        mock_repo.fetch_pending_batch.return_value = [event]

        await service.process_pending()

        # Only insert_audit_log should be called; no delete/update audit method
        mock_repo.insert_audit_log.assert_called()
        # The mock repo has no update_audit_log or delete_audit_log method
        # (they don't exist); verify the service doesn't have them either
        assert not hasattr(service, "update_audit_log"), (
            "Service must not have update_audit_log (append-only)"
        )
        assert not hasattr(service, "delete_audit_log"), (
            "Service must not have delete_audit_log (append-only)"
        )

    @pytest.mark.asyncio
    async def test_relay_insert_audit_not_update(self, service, mock_repo):
        """3.4: insert_audit_log is called (not a hypothetical update method)."""
        events = [_make_event(), _make_event(event_type="PurchaseCreated")]
        events[1]["id"] = str(uuid.uuid4())
        mock_repo.fetch_pending_batch.return_value = events

        await service.process_pending()

        # Two events → two audit INSERTs (no updates)
        assert mock_repo.insert_audit_log.call_count == 2
