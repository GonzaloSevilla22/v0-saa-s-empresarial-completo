"""
Schemas Pydantic v2 para bank-reconciliation C3.

El extracto llega como filas NORMALIZADAS (D2): el parseo CSV/Excel vive en el
cliente; acá se valida el shape antes de tocar la DB (doble red con los guards
P0400 de la RPC).
"""
from __future__ import annotations

import uuid
from datetime import date, datetime
from decimal import Decimal

from typing import Literal

from pydantic import BaseModel, Field, field_validator


# ── Import de extracto ─────────────────────────────────────────────────────────

class StatementLineIn(BaseModel):
    line_no: int = Field(ge=1)
    value_date: date
    description: str | None = None
    amount: Decimal
    balance: Decimal | None = None


class StatementImportIn(BaseModel):
    # v3-api-standards §3.2: opcional+deprecado — el header `Idempotency-Key`
    # es el transporte preferido (D4); fallback de body durante la ventana
    # de compatibilidad (OQ2).
    idempotency_key: str | None = Field(default=None, min_length=1, max_length=128)
    file_name: str = Field(min_length=1, max_length=255)
    file_hash: str = Field(min_length=16, max_length=128)
    lines: list[StatementLineIn] = Field(min_length=1, max_length=5000)


class StatementImportOut(BaseModel):
    import_id: uuid.UUID
    line_count: int
    period_from: date | None = None
    period_to: date | None = None
    replayed: bool


class StatementImportListItem(BaseModel):
    id: uuid.UUID
    bank_account_id: uuid.UUID
    file_name: str
    period_from: date
    period_to: date
    line_count: int
    created_at: datetime


class StatementLineOut(BaseModel):
    id: uuid.UUID
    line_no: int
    value_date: date
    description: str | None = None
    amount: Decimal
    balance: Decimal | None = None
    matched: bool


# ── Sesión de conciliación ─────────────────────────────────────────────────────

class SessionOpenIn(BaseModel):
    period_from: date
    period_to: date
    statement_closing_balance: Decimal


class SessionOpenOut(BaseModel):
    session_id: uuid.UUID
    bank_account_id: uuid.UUID
    status: str
    period_from: date
    period_to: date
    statement_closing_balance: Decimal


class SessionOut(BaseModel):
    id: uuid.UUID
    bank_account_id: uuid.UUID
    status: str
    period_from: date
    period_to: date
    statement_closing_balance: Decimal
    ledger_closing_balance: Decimal | None = None
    difference: Decimal | None = None
    close_reason: str | None = None
    opened_at: datetime | None = None
    closed_at: datetime | None = None


class SessionCloseIn(BaseModel):
    close_reason: str | None = None


class SessionCloseOut(BaseModel):
    session_id: uuid.UUID
    status: str
    statement_closing_balance: Decimal
    ledger_closing_balance: Decimal
    difference: Decimal


# ── Matching ───────────────────────────────────────────────────────────────────

class MatchCreateIn(BaseModel):
    statement_line_ids: list[uuid.UUID] = Field(min_length=1)
    bank_movement_ids: list[uuid.UUID] = Field(min_length=1)


class MatchGroupOut(BaseModel):
    match_group: uuid.UUID
    session_id: uuid.UUID
    line_count: int
    movement_count: int
    amount: Decimal


class MatchListItem(BaseModel):
    match_group: uuid.UUID
    matched_at: datetime
    line_count: int
    movement_count: int
    amount: Decimal


class UndoMatchIn(BaseModel):
    undo_reason: str = Field(min_length=1)


class UndoMatchOut(BaseModel):
    match_group: uuid.UUID
    undone_rows: int
    movement_count: int
    status: str


class PendingMovementOut(BaseModel):
    id: uuid.UUID
    amount: Decimal
    movement_type: str
    value_date: date | None = None
    description: str | None = None
    balance_after: Decimal
    reconciliation_status: str


class ManualMovementIn(BaseModel):
    """Carga manual "solo anotar" (V1): tipos manuales ampliados por C3.

    card_settlement queda fuera del Literal — reservado a los escritores
    automáticos de C2 (doble red con el P0410 de la RPC).

    banco-caja-historial-ajustes (D6): `description` es obligatorio no vacío
    SOLO para movement_type='manual_adjustment' (validado acá como primera
    red — el guard P0413 de rpc_register_bank_movement es la autoridad
    final, D9 del design: el cliente/backend no reemplazan al servidor). Los
    demás tipos manuales conservan el motivo como opcional.
    """

    # v3-api-standards §3.2: opcional+deprecado (ver StatementImportIn).
    idempotency_key: str | None = Field(default=None, min_length=1, max_length=128)
    amount: Decimal
    movement_type: Literal[
        "transfer_in", "transfer_out", "manual_adjustment", "fee", "tax_debit", "interest"
    ]
    value_date: date | None = None
    # validate_default=True: sin esto, Pydantic v2 saltea el field_validator
    # cuando `description` viene ausente del payload (el caso real más común
    # — un formulario que no manda el campo, no que lo mande en null) — ver
    # el mismo hallazgo documentado en schemas/cash.py.
    description: str | None = Field(default=None, validate_default=True)

    @field_validator("description")
    @classmethod
    def validate_adjustment_reason(cls, v, info):
        movement_type_value = info.data.get("movement_type")
        if movement_type_value == "manual_adjustment" and (v is None or not v.strip()):
            raise ValueError(
                "un ajuste bancario manual_adjustment requiere un motivo no vacío (description)."
            )
        return v


class ManualMovementOut(BaseModel):
    movement_id: uuid.UUID | None = None
    balance_after: Decimal | None = None
    replayed: bool
    operation_id: uuid.UUID | None = None


class SuggestionOut(BaseModel):
    statement_line_id: uuid.UUID
    bank_movement_id: uuid.UUID
    amount: Decimal
    line_value_date: date
    movement_value_date: date | None = None
    line_description: str | None = None
    movement_description: str | None = None
