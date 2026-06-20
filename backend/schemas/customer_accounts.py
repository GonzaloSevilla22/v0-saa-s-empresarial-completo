"""
Schemas Pydantic v2 para C-30 — CustomerAccount / PaymentReceived.

Enums:
  CustomerMovementType: sale | payment_received | credit_note | adjustment

Models:
  CustomerAccountOut       — fila de customer_accounts
  AccountMovementOut       — fila de customer_account_movements
  PaymentReceivedIn        — payload de rpc_register_payment_received
  PaymentReceivedOut       — respuesta de rpc_register_payment_received
  CreateCustomerAccountOut — respuesta de rpc_create_customer_account
"""
from __future__ import annotations

import datetime
import uuid
from decimal import Decimal
from enum import Enum

from pydantic import BaseModel, ConfigDict, field_validator


class CustomerMovementType(str, Enum):
    sale             = "sale"
    payment_received = "payment_received"
    credit_note      = "credit_note"
    adjustment       = "adjustment"


class CustomerAccountOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id:         uuid.UUID
    account_id: uuid.UUID
    client_id:  uuid.UUID
    balance:    Decimal
    created_at: datetime.datetime


class AccountMovementOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id:                   uuid.UUID
    customer_account_id:  uuid.UUID
    account_id:           uuid.UUID
    amount:               Decimal
    balance_after:        Decimal
    movement_type:        str
    reference_id:         uuid.UUID | None = None
    created_by:           uuid.UUID
    created_at:           datetime.datetime


class CreateCustomerAccountOut(BaseModel):
    customer_account_id: uuid.UUID
    client_id:           uuid.UUID
    balance:             Decimal


class PaymentReceivedIn(BaseModel):
    idempotency_key:    str
    client_id:          uuid.UUID
    amount:             Decimal
    reference_sale_id:  uuid.UUID | None = None

    @field_validator("amount")
    @classmethod
    def validate_positive(cls, v: Decimal) -> Decimal:
        if v <= 0:
            raise ValueError("amount debe ser > 0")
        return v


class PaymentReceivedOut(BaseModel):
    payment_id:           uuid.UUID | None
    customer_account_id:  uuid.UUID | None
    balance_after:        Decimal | None
    replayed:             bool
    operation_id:         uuid.UUID | None = None
