"""
Schemas Pydantic v2 para el historial de movimientos bancarios
(banco-caja-historial-ajustes, D3 — ledger-movement-history).

Separado de schemas/bank_reconciliation.py: el historial no es conciliación
(D3 del design — bank_reconciliation.py ya tiene 13 endpoints).
"""
from __future__ import annotations

import uuid
from datetime import date, datetime
from decimal import Decimal

from pydantic import BaseModel

from backend.schemas.common import PageOut


class BankMovementRow(BaseModel):
    """Fila del historial de una cuenta bancaria — todos los bank_movements,
    no solo los del tablero de conciliación."""

    id: uuid.UUID
    bank_account_id: uuid.UUID
    amount: Decimal
    balance_after: Decimal
    movement_type: str
    value_date: date | None = None
    description: str | None = None
    created_at: datetime
    reconciliation_status: str


class BankMovementPageOut(PageOut[BankMovementRow]):
    """v3-api-standards §2: envelope estándar {items,total,page,pages}."""
