"""
C-25 v20-outbox-activation — Outbox relay router

Endpoint: POST /outbox/process-pending
  Idempotent relay trigger — processes one batch of pending outbox events.
  Called by the pg_cron job relay-process-outbox (Decision 1).

3-layer: router → OutboxRelayService → OutboxRepository
No service_role; JWT-passthrough connection (Decision 4).
"""
from __future__ import annotations

import asyncpg
from fastapi import APIRouter, Depends

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.repositories.outbox_repository import OutboxRepository
from backend.services.outbox_relay_service import OutboxRelayService

router = APIRouter(prefix="/outbox", tags=["outbox"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> OutboxRepository:
    return OutboxRepository(conn)


def get_service(repo: OutboxRepository = Depends(get_repo)) -> OutboxRelayService:
    return OutboxRelayService(repo=repo)


@router.post("/process-pending")
async def process_pending_outbox(
    service: OutboxRelayService = Depends(get_service),
    auth: dict = Depends(get_current_user),
) -> dict:
    """Idempotent relay: process one batch of pending outbox events.

    Called by the pg_cron job relay-process-outbox every minute.
    Returns the number of events marked processed in this run.
    Failures are logged and left pending for retry on the next run.
    """
    processed = await service.process_pending()
    return {"processed": processed}
