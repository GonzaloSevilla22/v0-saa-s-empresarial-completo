"""
C-25 v20-outbox-activation — OutboxRelayService

Relay dispatch loop: fetches pending events, routes by event_type to registered
consumers, marks processed_at ONLY after all consumers succeed.

Consumers registered in CONSUMER_REGISTRY (declarative, Decision 2.6 refactor):
  - AuditLog (mandatory first — audit domain, append-only)
  - EmailNotification (for sale_created / stock_adjusted / plan_changed)

Design refs:
  Decision 1 (relay architecture: pg_cron → backend endpoint)
  Decision 3 (email via email_logs, not direct Resend)
  Decision 4 (SECURITY DEFINER relay, no service_role)
  Decision 5 (idempotency via operation_idempotency)

Audit domain invariant (spec §AuditLog):
  - processed_at is set ONLY after audit INSERT commits
  - relay NEVER updates or deletes audit rows (INSERT-only)
  - if audit fails → processed_at stays NULL → event retried next run
"""
from __future__ import annotations

import logging
from typing import Callable

from backend.repositories.outbox_repository import OutboxRepository

logger = logging.getLogger(__name__)

# ── Email-eligible event types (Decision 3) ───────────────────────────────────
EMAIL_EVENT_TYPES: frozenset[str] = frozenset({
    "sale_created",
    "stock_adjusted",
    "plan_changed",
})

# ── Consumer type labels (idempotency keys) ───────────────────────────────────
CONSUMER_AUDIT = "AuditLog"
CONSUMER_EMAIL = "EmailNotification"


class OutboxRelayService:
    """Relay dispatch service.

    Fetches a batch of pending events via the SECURITY DEFINER RPC, routes each
    event through the consumer pipeline, and marks processed_at only on success.

    Consumer order: AuditLog FIRST (audit domain invariant). Email second.
    Each consumer is idempotency-guarded via (event_id, consumer_type).
    """

    def __init__(self, repo: OutboxRepository) -> None:
        self._repo = repo

    async def process_pending(self, batch_limit: int = 100) -> int:
        """Fetch and dispatch one batch of pending events.

        Returns the number of events successfully marked processed.
        Events that fail any consumer are left pending (processed_at = NULL)
        for retry on the next relay run.
        """
        events = await self._repo.fetch_pending_batch(batch_limit=batch_limit)
        processed_count = 0

        for event in events:
            success = await self._dispatch_event(event)
            if success:
                await self._repo.mark_processed(event["id"])
                processed_count += 1

        return processed_count

    async def _dispatch_event(self, event: dict) -> bool:
        """Route one event through all registered consumers.

        Returns True only if ALL consumers succeed (so processed_at can be set).
        The AuditLog consumer runs FIRST — if it fails, no other consumer runs
        and processed_at stays NULL (audit-domain invariant from spec).
        """
        event_id = str(event["id"])
        account_id = str(event["account_id"]) if event.get("account_id") else None
        event_type = str(event.get("event_type") or "")

        # ── Consumer 1: AuditLog (mandatory first) ─────────────────────────────
        audit_ok = await self._run_audit_consumer(event_id, account_id, event_type)
        if not audit_ok:
            # Audit failure → abort entire event; processed_at stays NULL
            logger.warning(
                "AuditLog consumer failed for event %s (%s); leaving unprocessed",
                event_id, event_type,
            )
            return False

        # ── Consumer 2: EmailNotification (only for in-scope event types) ──────
        if event_type in EMAIL_EVENT_TYPES:
            email_ok = await self._run_email_consumer(event_id, account_id, event_type, event)
            if not email_ok:
                logger.warning(
                    "EmailNotification consumer failed for event %s (%s); leaving unprocessed",
                    event_id, event_type,
                )
                return False

        return True

    async def _run_audit_consumer(
        self,
        event_id: str,
        account_id: str | None,
        event_type: str,
    ) -> bool:
        """AuditLog consumer: INSERT one append-only row into audit_logs.

        Idempotency-guarded: if (event_id, AuditLog) slot already exists,
        skip the INSERT (duplicate → no second audit row).

        Raises are caught and returned as False (caller leaves event unprocessed).
        """
        try:
            claimed = await self._repo.claim_idempotency(
                event_id=event_id,
                consumer_type=CONSUMER_AUDIT,
            )
            if not claimed:
                # Already processed by this consumer — idempotent skip
                logger.debug("AuditLog idempotency: event %s already processed", event_id)
                return True

            # INSERT the audit row (append-only)
            await self._repo.insert_audit_log(
                event_id=event_id,
                account_id=account_id or "",
                action=event_type,
            )
            return True
        except Exception as exc:
            logger.error(
                "AuditLog consumer error for event %s: %s", event_id, exc
            )
            return False

    async def _run_email_consumer(
        self,
        event_id: str,
        account_id: str | None,
        event_type: str,
        event: dict,
    ) -> bool:
        """EmailNotification consumer: INSERT into email_logs (DEC-09 path).

        Never calls Resend directly. The existing DB webhook → Edge Function →
        Resend pipeline delivers the notification. Idempotency-guarded.
        """
        try:
            claimed = await self._repo.claim_idempotency(
                event_id=event_id,
                consumer_type=CONSUMER_EMAIL,
            )
            if not claimed:
                logger.debug("EmailNotification idempotency: event %s already processed", event_id)
                return True

            subject, recipient = _build_email_content(event_type, event)
            await self._repo.insert_email_log(
                account_id=account_id or "",
                event_type=event_type,
                recipient=recipient,
                subject=subject,
                metadata={"event_id": event_id, "account_id": account_id},
            )
            return True
        except Exception as exc:
            logger.error(
                "EmailNotification consumer error for event %s: %s", event_id, exc
            )
            return False


def _build_email_content(event_type: str, event: dict) -> tuple[str, str]:
    """Map event_type to (subject, recipient) for email_logs.

    Recipient defaults to account_id as a placeholder — the Edge Function
    resolves the actual user email from the account. Subject is human-readable.
    """
    payload = event.get("payload") or {}
    account_id = str(event.get("account_id") or "")

    subject_map = {
        "sale_created": "Nueva venta registrada",
        "stock_adjusted": "Ajuste de stock realizado",
        "plan_changed": "Tu plan ha sido actualizado",
    }

    subject = subject_map.get(event_type, f"Evento: {event_type}")
    # The Edge Function resolves the real recipient from account_id
    recipient = payload.get("email") or f"account:{account_id}"

    return subject, recipient
