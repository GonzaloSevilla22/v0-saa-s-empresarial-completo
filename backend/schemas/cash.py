from __future__ import annotations

import datetime
import uuid
from decimal import Decimal
from enum import Enum
from typing import Literal

from pydantic import BaseModel, ConfigDict, field_validator


# ── Enums ─────────────────────────────────────────────────────────────────────

class MovementType(str, Enum):
    sale             = "sale"
    purchase_payment = "purchase_payment"
    expense          = "expense"
    advance          = "advance"
    withdrawal       = "withdrawal"


# Movement types that are expected to be income (positive amount)
_INCOME_TYPES = {MovementType.sale, MovementType.advance}
# Movement types that are expected to be expenses (negative amount)
_EXPENSE_TYPES = {MovementType.purchase_payment, MovementType.expense, MovementType.withdrawal}


# ── Cashbox ───────────────────────────────────────────────────────────────────

class CashboxCreate(BaseModel):
    branch_id: uuid.UUID
    name: str
    currency: str = "ARS"


class CashboxOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    branch_id: uuid.UUID
    name: str
    currency: str
    created_at: datetime.datetime


# ── CashSession ───────────────────────────────────────────────────────────────

class OpenSessionIn(BaseModel):
    opening_balance: Decimal


class CloseSessionIn(BaseModel):
    counted_balance: Decimal


class CashSessionOut(BaseModel):
    """Output schema for a cash session (open or closed)."""
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    cashbox_id: uuid.UUID
    status: str
    opening_balance: Decimal
    closing_balance: Decimal | None = None
    counted_balance: Decimal | None = None
    expected_balance: Decimal | None = None
    difference: Decimal | None = None
    opened_by: uuid.UUID
    closed_by: uuid.UUID | None = None
    opened_at: datetime.datetime
    closed_at: datetime.datetime | None = None


class OpenSessionOut(BaseModel):
    """Output from rpc_open_cash_session (jsonb response)."""
    session_id: uuid.UUID
    cashbox_id: uuid.UUID
    status: str
    opening_balance: Decimal


class CloseSessionOut(BaseModel):
    """Output from rpc_close_cash_session (jsonb response)."""
    session_id: uuid.UUID
    status: str
    opening_balance: Decimal
    expected_balance: Decimal
    counted_balance: Decimal
    difference: Decimal
    closing_balance: Decimal


# ── CashMovement ──────────────────────────────────────────────────────────────

class RegisterMovementIn(BaseModel):
    """
    Input para registrar un movimiento de efectivo.

    OQ-2 (resuelto): amount lleva signo (ingresos +, egresos −).
    La coherencia signo↔tipo se valida acá (service layer — no en DB CHECK).
    El DB CHECK valida solo que movement_type pertenece al enum.
    """
    amount: Decimal
    movement_type: MovementType
    reference_id: uuid.UUID | None = None

    @field_validator("amount")
    @classmethod
    def validate_sign_coherence(cls, v, info):
        # Solo validar si tenemos el movement_type
        movement_type_value = info.data.get("movement_type")
        if movement_type_value is None:
            return v
        if movement_type_value in _INCOME_TYPES and v < 0:
            raise ValueError(
                f"movement_type '{movement_type_value}' es un ingreso: amount debe ser positivo."
            )
        if movement_type_value in _EXPENSE_TYPES and v > 0:
            raise ValueError(
                f"movement_type '{movement_type_value}' es un egreso: amount debe ser negativo."
            )
        return v


class RegisterMovementOut(BaseModel):
    """Output de rpc_register_cash_movement (jsonb response)."""
    movement_id: uuid.UUID


class CashMovementOut(BaseModel):
    """Output schema for a cash_movement row."""
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    session_id: uuid.UUID
    amount: Decimal
    movement_type: str
    reference_id: uuid.UUID | None = None
    balance_after: Decimal
    created_by: uuid.UUID
    created_at: datetime.datetime
