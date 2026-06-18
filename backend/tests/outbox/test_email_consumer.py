"""
C-25 v20-outbox-activation — EmailNotification consumer tests (Tasks 5.1–5.5)

TDD cycle:
  5.1 RED : test_email_for_in_scope_type — sale_created/stock_adjusted/plan_changed
            → email_logs INSERT (NOT a direct Resend call). Fails.
  5.2 GREEN: consumer implemented; test passes.
  5.3 TRIANGULATE: test_no_email_for_out_of_scope_type — unrecognized event_type
            → no email_logs row.
  5.4 TRIANGULATE: test_email_failure_keeps_event_unprocessed_but_audit_intact —
            email failure leaves processed_at NULL; retry doesn't duplicate audit.

Spec ref: transactional-outbox/spec.md §"EmailNotification consumer"
Design ref: Decision 3 (DEC-09 path: email_logs INSERT, not Resend direct)
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock

import pytest

from backend.repositories.outbox_repository import OutboxRepository
from backend.services.outbox_relay_service import OutboxRelayService, EMAIL_EVENT_TYPES


ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
EVENT_ID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"


def _make_event(event_type: str, event_id: str = EVENT_ID) -> dict:
    return {
        "id": event_id,
        "account_id": ACCOUNT_ID,
        "event_type": event_type,
        "aggregate_type": "SalesOrder",
        "aggregate_id": str(uuid.uuid4()),
        "payload": {"amount": 100},
        "occurred_at": datetime(2026, 7, 18, 12, 0, 0, tzinfo=timezone.utc),
        "processed_at": None,
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


# ── 5.1 RED → 5.2 GREEN ──────────────────────────────────────────────────────

class TestEmailForInScopeType:
    """5.1/5.2: In-scope event types trigger email_logs INSERT (not Resend direct)."""

    @pytest.mark.parametrize("event_type", sorted(EMAIL_EVENT_TYPES))
    @pytest.mark.asyncio
    async def test_email_for_in_scope_type(self, event_type, service, mock_repo):
        """5.1 RED → 5.2 GREEN: in-scope event type → email_logs INSERT."""
        event = _make_event(event_type=event_type)
        mock_repo.fetch_pending_batch.return_value = [event]

        await service.process_pending()

        # email_logs must be inserted (NOT a Resend API call)
        mock_repo.insert_email_log.assert_called_once()
        # And event must be marked processed
        mock_repo.mark_processed.assert_called_once_with(event["id"])

    @pytest.mark.asyncio
    async def test_email_consumer_does_not_call_resend_directly(self, service, mock_repo):
        """5.2: Email consumer uses email_logs path (DEC-09), no Resend client."""
        event = _make_event(event_type="sale_created")
        mock_repo.fetch_pending_batch.return_value = [event]

        # Verify no direct Resend/HTTP client is invoked
        # The test passes if insert_email_log is called (not a real HTTP call)
        await service.process_pending()

        mock_repo.insert_email_log.assert_called_once()
        # The service must have no resend_client, httpx_client, or direct send method
        assert not hasattr(service, "resend_client"), "Service must not hold a Resend client"
        assert not hasattr(service, "send_email_direct"), "No direct Resend method allowed"

    @pytest.mark.asyncio
    async def test_email_scope_contains_expected_types(self):
        """5.2: The EMAIL_EVENT_TYPES set contains exactly the 3 in-scope types."""
        assert "sale_created" in EMAIL_EVENT_TYPES
        assert "stock_adjusted" in EMAIL_EVENT_TYPES
        assert "plan_changed" in EMAIL_EVENT_TYPES
        # No extra types added (scope cap PA-21)
        assert len(EMAIL_EVENT_TYPES) == 3


# ── 5.3 TRIANGULATE: no email for out-of-scope types ─────────────────────────

class TestNoEmailForOutOfScopeType:
    """5.3: Out-of-scope event types produce no email_logs row."""

    @pytest.mark.parametrize("event_type", [
        "SaleConfirmed",       # sale is 'SaleConfirmed' not 'sale_created' in C-29 producer
        "PurchaseCreated",
        "StockAdjusted",
        "UserRegistered",
        "something_else",
        "PlanUpgraded",        # different from plan_changed
    ])
    @pytest.mark.asyncio
    async def test_no_email_for_out_of_scope_type(self, event_type, service, mock_repo):
        """5.3: Event type not in EMAIL_EVENT_TYPES → no email_logs row."""
        event = _make_event(event_type=event_type)
        mock_repo.fetch_pending_batch.return_value = [event]

        await service.process_pending()

        mock_repo.insert_email_log.assert_not_called()
        # Audit DOES run (mandatory for all events)
        mock_repo.insert_audit_log.assert_called_once()


# ── 5.4 TRIANGULATE: email failure → unprocessed but audit intact ─────────────

class TestEmailFailureKeepsEventUnprocessedAuditIntact:
    """5.4: Email failure leaves processed_at NULL; audit not duplicated on retry."""

    @pytest.mark.asyncio
    async def test_email_failure_keeps_event_unprocessed(self, service, mock_repo):
        """5.4: Email consumer failure → processed_at stays NULL."""
        event = _make_event(event_type="sale_created")
        mock_repo.fetch_pending_batch.return_value = [event]
        mock_repo.insert_email_log.side_effect = RuntimeError("email DB error")

        await service.process_pending()

        mock_repo.mark_processed.assert_not_called()

    @pytest.mark.asyncio
    async def test_email_failure_audit_not_duplicated_on_retry(self, service, mock_repo):
        """5.4: On retry after email failure, AuditLog idempotency prevents duplicate."""
        event = _make_event(event_type="sale_created")
        mock_repo.fetch_pending_batch.return_value = [event]

        # Simulate: audit was already claimed (first run succeeded)
        # Email now succeeds on retry
        from backend.services.outbox_relay_service import CONSUMER_AUDIT, CONSUMER_EMAIL

        def claim_side_effect(event_id: str, consumer_type: str) -> bool:
            if consumer_type == CONSUMER_AUDIT:
                return False  # Already claimed — skip
            return True       # Email not yet claimed

        mock_repo.claim_idempotency.side_effect = claim_side_effect
        # Email succeeds this time
        mock_repo.insert_email_log.side_effect = None

        await service.process_pending()

        # AuditLog NOT re-fired (idempotency)
        mock_repo.insert_audit_log.assert_not_called()
        # Email IS inserted (retry succeeds)
        mock_repo.insert_email_log.assert_called_once()
        # Event marked processed
        mock_repo.mark_processed.assert_called_once_with(event["id"])
