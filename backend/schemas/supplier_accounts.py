"""
Schemas Pydantic v2 para C-30 — SupplierAccount / PaymentMade / SupplierCharge.
bank-payment-routing C2: PaymentMadeIn gana payment_method + bank_account_id
(taxonomía {cash,transfer,card,check}, default cash, retrocompatible).

Enums:
  SupplierMovementType: purchase | payment_made | debit_note | adjustment

Models:
  SupplierAccountOut        — fila de supplier_accounts
  SupplierMovementOut       — fila de supplier_account_movements
  PaymentMadeIn             — payload de rpc_register_payment_made
  PaymentMadeOut            — respuesta de rpc_register_payment_made
  SupplierChargeIn          — payload de rpc_register_supplier_charge
  SupplierChargeOut         — respuesta de rpc_register_supplier_charge
  CreateSupplierAccountOut  — respuesta de rpc_create_supplier_account
"""
from __future__ import annotations

import datetime
import uuid
from decimal import Decimal
from enum import Enum

from pydantic import BaseModel, ConfigDict, field_validator, model_validator


class SupplierMovementType(str, Enum):
    purchase    = "purchase"
    payment_made = "payment_made"
    debit_note  = "debit_note"
    adjustment  = "adjustment"


class SupplierAccountOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id:          uuid.UUID
    account_id:  uuid.UUID
    supplier_id: uuid.UUID
    balance:     Decimal
    created_at:  datetime.datetime


class SupplierMovementOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id:                   uuid.UUID
    supplier_account_id:  uuid.UUID
    account_id:           uuid.UUID
    amount:               Decimal
    balance_after:        Decimal
    movement_type:        str
    reference_id:         uuid.UUID | None = None
    created_by:           uuid.UUID
    created_at:           datetime.datetime


class CreateSupplierAccountOut(BaseModel):
    supplier_account_id: uuid.UUID
    supplier_id:         uuid.UUID
    balance:             Decimal


class PaymentMadeIn(BaseModel):
    idempotency_key:       str
    supplier_id:           uuid.UUID
    amount:                Decimal
    reference_purchase_id: uuid.UUID | None = None
    # bank-payment-routing C2: taxonomía {cash,transfer,card,check}. Default 'cash'
    # (aditivo, retrocompatible — mismo criterio que el RPC).
    payment_method:        str = "cash"
    bank_account_id:       uuid.UUID | None = None

    @field_validator("amount")
    @classmethod
    def validate_positive(cls, v: Decimal) -> Decimal:
        if v <= 0:
            raise ValueError("amount debe ser > 0")
        return v

    @field_validator("payment_method")
    @classmethod
    def validate_payment_method(cls, v: str) -> str:
        if v not in ("cash", "transfer", "card", "check"):
            raise ValueError("payment_method debe ser uno de: cash, transfer, card, check")
        return v

    @model_validator(mode="after")
    def validate_bank_account_required_for_bank_method(self) -> "PaymentMadeIn":
        if self.payment_method in ("transfer", "card", "check") and self.bank_account_id is None:
            raise ValueError(
                f"payment_method={self.payment_method} exige bank_account_id"
            )
        return self


class PaymentMadeOut(BaseModel):
    payment_id:           uuid.UUID | None
    supplier_account_id:  uuid.UUID | None
    balance_after:        Decimal | None
    replayed:             bool
    operation_id:         uuid.UUID | None = None


class SupplierChargeIn(BaseModel):
    idempotency_key: str
    supplier_id:     uuid.UUID
    amount:          Decimal
    reference_id:    uuid.UUID | None = None

    @field_validator("amount")
    @classmethod
    def validate_positive(cls, v: Decimal) -> Decimal:
        if v <= 0:
            raise ValueError("amount debe ser > 0")
        return v


class SupplierChargeOut(BaseModel):
    movement_id:          uuid.UUID | None
    supplier_account_id:  uuid.UUID | None
    balance_after:        Decimal | None
    replayed:             bool
    operation_id:         uuid.UUID | None = None
