"""
C-25 v20-outbox-activation — Relay select tests (Tasks 2.1 / 2.2 / 2.3 / 2.4)

TDD cycle:
  2.1 RED : relay claims only processed_at IS NULL rows, ordered by occurred_at,
            using FOR UPDATE SKIP LOCKED — fails with no relay.
  2.2 GREEN: outbox_repository.py + outbox_relay_service.py pass these tests.
  2.4 TRIANGULATE: batch with mix of processed + unprocessed + locked rows.

Spec ref: transactional-outbox/spec.md §"Outbox relay dispatch"
Design ref: Decision 1 (pg_cron + backend), Decision 4 (SECURITY DEFINER, no service_role)
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock, call, patch

import pytest

from backend.repositories.outbox_repository import OutboxRepository
from backend.services.outbox_relay_service import OutboxRelayService


ACCOUNT_A = str(uuid.uuid4())
ACCOUNT_B = str(uuid.uuid4())


def _make_event(
    event_id: str | None = None,
    event_type: str = "SaleConfirmed",
    account_id: str = ACCOUNT_A,
    occurred_at: datetime | None = None,
    processed_at: datetime | None = None,
) -> dict:
    return {
        "id": event_id or str(uuid.uuid4()),
        "account_id": account_id,
        "event_type": event_type,
        "aggregate_type": "SalesOrder",
        "aggregate_id": str(uuid.uuid4()),
        "payload": {"some": "data"},
        "occurred_at": occurred_at or datetime(2026, 7, 18, 10, 0, 0, tzinfo=timezone.utc),
        "processed_at": processed_at,
    }


# ── 2.1 RED → 2.2 GREEN: repository calls rpc_process_outbox_batch ───────────

class TestOutboxRepository:
    """Repository layer: calls rpc_process_outbox_batch via JWT-passthrough conn."""

    @pytest.fixture
    def mock_conn(self):
        conn = AsyncMock()
        conn.fetch = AsyncMock(return_value=[])
        conn.execute = AsyncMock(return_value="UPDATE 1")
        return conn

    @pytest.fixture
    def repo(self, mock_conn):
        return OutboxRepository(mock_conn)

    @pytest.mark.asyncio
    async def test_fetch_pending_calls_rpc(self, repo, mock_conn):
        """2.1/2.2: fetch_pending_batch calls rpc_process_outbox_batch(batch_limit)."""
        event = _make_event()
        mock_conn.fetch.return_value = [event]

        result = await repo.fetch_pending_batch(batch_limit=100)

        mock_conn.fetch.assert_called_once()
        call_args = mock_conn.fetch.call_args
        sql = call_args[0][0]
        # Must call the SECURITY DEFINER RPC
        assert "rpc_process_outbox_batch" in sql
        assert result == [event]

    @pytest.mark.asyncio
    async def test_fetch_pending_default_batch_100(self, repo, mock_conn):
        """2.2: Default batch size is 100 (mirrors C-27 pattern)."""
        mock_conn.fetch.return_value = []
        await repo.fetch_pending_batch()
        call_args = mock_conn.fetch.call_args
        # 100 should be passed as the batch limit
        assert 100 in call_args[0][1:] or 100 == call_args[1].get("batch_limit", None) or \
               any(100 == a for a in call_args[0][1:])

    @pytest.mark.asyncio
    async def test_mark_processed_calls_rpc(self, repo, mock_conn):
        """2.2: mark_processed calls rpc_mark_event_processed with the event id."""
        event_id = str(uuid.uuid4())
        mock_conn.execute.return_value = "UPDATE 1"

        await repo.mark_processed(event_id)

        mock_conn.execute.assert_called_once()
        call_args = mock_conn.execute.call_args
        sql = call_args[0][0]
        assert "rpc_mark_event_processed" in sql

    @pytest.mark.asyncio
    async def test_insert_audit_log_row(self, repo, mock_conn):
        """2.2: insert_audit_log inserts into audit_logs."""
        event = _make_event()
        mock_conn.execute.return_value = "INSERT 0 1"

        await repo.insert_audit_log(
            event_id=event["id"],
            account_id=event["account_id"],
            action=event["event_type"],
        )

        mock_conn.execute.assert_called_once()
        sql = mock_conn.execute.call_args[0][0]
        assert "audit_logs" in sql.lower()

    @pytest.mark.asyncio
    async def test_insert_email_log_row(self, repo, mock_conn):
        """2.2: insert_email_log inserts into email_logs."""
        event = _make_event(event_type="sale_created")
        mock_conn.execute.return_value = "INSERT 0 1"

        await repo.insert_email_log(
            account_id=event["account_id"],
            event_type=event["event_type"],
            recipient="test@example.com",
            subject="Sale created",
            metadata={"event_id": event["id"]},
        )

        mock_conn.execute.assert_called_once()
        sql = mock_conn.execute.call_args[0][0]
        assert "email_logs" in sql.lower()

    @pytest.mark.asyncio
    async def test_claim_idempotency_slot(self, repo, mock_conn):
        """2.2: claim_idempotency inserts with ON CONFLICT DO NOTHING."""
        mock_conn.fetchval = AsyncMock(return_value=True)

        claimed = await repo.claim_idempotency(
            event_id=str(uuid.uuid4()),
            consumer_type="AuditLog",
        )

        mock_conn.fetchval.assert_called_once()
        sql = mock_conn.fetchval.call_args[0][0]
        assert "operation_idempotency" in sql.lower()
        assert "ON CONFLICT" in sql


# ── 2.3 GREEN: relay service dispatch loop ───────────────────────────────────

class TestOutboxRelayService:
    """Service layer: dispatch loop, consumer routing, processed_at semantics."""

    @pytest.fixture
    def mock_repo(self):
        repo = MagicMock()
        repo.fetch_pending_batch = AsyncMock(return_value=[])
        repo.mark_processed = AsyncMock()
        repo.insert_audit_log = AsyncMock()
        repo.insert_email_log = AsyncMock()
        repo.claim_idempotency = AsyncMock(return_value=True)
        return repo

    @pytest.fixture
    def service(self, mock_repo):
        return OutboxRelayService(repo=mock_repo)

    @pytest.mark.asyncio
    async def test_relay_processes_pending_events(self, service, mock_repo):
        """2.3: relay dispatch processes events returned by the repository."""
        event = _make_event(event_type="SaleConfirmed")
        mock_repo.fetch_pending_batch.return_value = [event]

        await service.process_pending()

        mock_repo.fetch_pending_batch.assert_called_once()
        # Audit log must be written for any event
        mock_repo.insert_audit_log.assert_called_once()

    @pytest.mark.asyncio
    async def test_relay_marks_processed_after_consumers_succeed(self, service, mock_repo):
        """2.3: processed_at is set ONLY after all consumers succeed."""
        event = _make_event(event_type="SaleConfirmed")
        mock_repo.fetch_pending_batch.return_value = [event]

        await service.process_pending()

        mock_repo.mark_processed.assert_called_once_with(event["id"])

    @pytest.mark.asyncio
    async def test_relay_marks_processed_at_only_after_audit_commits(self, service, mock_repo):
        """2.3 / Audit domain: processed_at is NOT set if audit fails."""
        event = _make_event(event_type="SaleConfirmed")
        mock_repo.fetch_pending_batch.return_value = [event]
        mock_repo.insert_audit_log.side_effect = RuntimeError("audit DB error")

        await service.process_pending()

        # processed_at must NOT be set when audit fails
        mock_repo.mark_processed.assert_not_called()

    @pytest.mark.asyncio
    async def test_consumer_failure_leaves_event_unprocessed(self, service, mock_repo):
        """Spec: consumer failure → processed_at stays NULL, event retried next run."""
        event = _make_event(event_type="SaleConfirmed")
        mock_repo.fetch_pending_batch.return_value = [event]
        mock_repo.insert_audit_log.side_effect = Exception("failure")

        await service.process_pending()

        mock_repo.mark_processed.assert_not_called()

    # ── 2.4 TRIANGULATE: mixed batch (processed + unprocessed + locked) ────────

    @pytest.mark.asyncio
    async def test_relay_only_gets_pending_events(self, service, mock_repo):
        """2.4: The RPC returns only pending rows (processed_at IS NULL + unlocked).

        The SKIP LOCKED + WHERE is enforced in SQL; here we verify the service
        processes exactly what the repo returns (never second-guesses).
        """
        # Repo returns only 2 unprocessed events (the SQL would have filtered the rest)
        ev1 = _make_event(event_type="SaleConfirmed")
        ev2 = _make_event(event_type="PurchaseCreated")
        mock_repo.fetch_pending_batch.return_value = [ev1, ev2]

        await service.process_pending()

        # Both must be processed
        assert mock_repo.insert_audit_log.call_count == 2
        assert mock_repo.mark_processed.call_count == 2

    @pytest.mark.asyncio
    async def test_relay_skips_already_locked_rows(self, service, mock_repo):
        """2.4: If repo returns empty (all locked by concurrent run), no dispatch."""
        mock_repo.fetch_pending_batch.return_value = []

        await service.process_pending()

        mock_repo.insert_audit_log.assert_not_called()
        mock_repo.mark_processed.assert_not_called()

    @pytest.mark.asyncio
    async def test_one_event_failure_does_not_abort_others(self, service, mock_repo):
        """2.4: An audit failure on event 1 should not prevent event 2 from being processed."""
        ev1 = _make_event(event_type="SaleConfirmed")
        ev2 = _make_event(event_type="PurchaseCreated")
        mock_repo.fetch_pending_batch.return_value = [ev1, ev2]
        # ev1 audit fails, ev2 audit succeeds
        mock_repo.insert_audit_log.side_effect = [RuntimeError("audit failure"), None]

        await service.process_pending()

        # ev1 NOT marked processed, ev2 IS marked processed
        assert mock_repo.mark_processed.call_count == 1
        mock_repo.mark_processed.assert_called_once_with(ev2["id"])
