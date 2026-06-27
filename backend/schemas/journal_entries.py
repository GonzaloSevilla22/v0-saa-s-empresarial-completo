"""
journal-entry-outbox — Pydantic v2 schemas (Task 6.2)

Response schema for GET /journal-entries.
No write schemas: the relay is the only writer (SECURITY DEFINER).
"""
from __future__ import annotations

import datetime
import uuid
from decimal import Decimal

from pydantic import BaseModel, ConfigDict


class JournalLineOut(BaseModel):
    """Debit or credit line of a journal entry."""

    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    entry_id: uuid.UUID
    account_code: str
    side: str  # 'debit' | 'credit'
    amount: Decimal
    line_no: int
    cost_center_id: uuid.UUID | None


class JournalEntryOut(BaseModel):
    """Journal entry header with its debit/credit lines.

    Fields:
        posted_at       — timestamp when the entry was posted (relay run time)
        status          — 'posted' | 'reversed'
        source_doc_type — e.g. 'SalesOrder', 'Purchase', 'CustomerAccount'
        source_doc_ref  — UUID of the originating business document
        reversal_of     — UUID of the original entry if this is a reversal
        lines           — debit and credit lines (ordered by line_no)
    """

    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    account_id: uuid.UUID
    posted_at: datetime.datetime
    status: str
    source_doc_type: str | None
    source_doc_ref: uuid.UUID | None
    reversal_of: uuid.UUID | None
    created_at: datetime.datetime
    lines: list[JournalLineOut] = []
