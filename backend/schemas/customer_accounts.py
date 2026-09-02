"""
Schemas Pydantic v2 para C-30 — CustomerAccount / PaymentReceived.
bank-payment-routing C2: PaymentReceivedIn gana payment_method + bank_account_id
(taxonomía {cash,transfer,card,check}, default cash, retrocompatible).

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

from pydantic import BaseModel, ConfigDict, field_validator, model_validator

from backend.schemas.common import PageOut


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
    # caja-compras-cobranzas (OQ-1, task 8.5): resuelto por LEFT JOIN a
    # payments_received cuando movement_type='payment_received'. NULL para
    # todo el resto de los tipos y para los cobros históricos (sin backfill).
    payment_method:       str | None = None
    # cobranzas-reverso (D12, task 8.2): derivados en el SERVIDOR con EXISTS
    # — nunca columnas denormalizadas (regla D5 de delete-guard-ledgers).
    # is_reversible: el movimiento es 'payment_received' Y su documento sigue
    # vivo en payments_received. is_reversal_blocked: el cobro tiene
    # movimiento de caja Y no hay sesión abierta en esa caja — el MISMO EXISTS
    # que evalúa rpc_reverse_payment_received. Default False: un movimiento
    # sin resolver esos EXISTS (p.ej. en un test que no los provee) nunca
    # ofrece la acción por default.
    is_reversible:        bool = False
    is_reversal_blocked:  bool = False
    # cobranzas-reverso (task 9.2): mismo molde que PurchaseOperationOut
    # (has_cash_movement/has_bank_movement) — el diálogo de anulación los
    # necesita para enumerar sólo las patas que aplican a ESTE pago.
    has_cash_movement:    bool = False
    has_bank_movement:    bool = False


# v3-api-standards §2.7: envelope estándar {items,total,page,pages} para
# GET /customer-accounts/{id}/movements — reemplaza la lista plana de
# limit/offset. BREAKING sancionado (OQ1 PO).
AccountMovementPageOut = PageOut[AccountMovementOut]


class CreateCustomerAccountOut(BaseModel):
    customer_account_id: uuid.UUID
    client_id:           uuid.UUID
    balance:             Decimal


class PaymentReceivedIn(BaseModel):
    # v3-api-standards §3.2: opcional+deprecado (D4).
    idempotency_key:    str | None = None
    client_id:          uuid.UUID
    amount:             Decimal
    reference_sale_id:  uuid.UUID | None = None
    # bank-payment-routing C2: taxonomía {cash,transfer,card,check}. Default 'cash'
    # (aditivo, retrocompatible — mismo criterio que el RPC).
    payment_method:     str = "cash"
    bank_account_id:    uuid.UUID | None = None
    # caja-compras-cobranzas (D5): opt-in de caja. NULL = el cobro no toca
    # caja. Con sesión informada, la RPC valida DOS condiciones (no tres: el
    # cobro no tiene fecha ni sucursal propias) y rechaza con P0422 si alguna
    # falla.
    cash_session_id:    uuid.UUID | None = None

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
    def validate_bank_account_required_for_bank_method(self) -> "PaymentReceivedIn":
        if self.payment_method in ("transfer", "card", "check") and self.bank_account_id is None:
            raise ValueError(
                f"payment_method={self.payment_method} exige bank_account_id"
            )
        return self

    @model_validator(mode="after")
    def validate_cash_session_requires_cash_method(self) -> "PaymentReceivedIn":
        # caja-compras-cobranzas (task 8.1): defensa en profundidad — la
        # autoridad sigue siendo la RPC (P0422 cash_optin_requires_cash_kind),
        # pero rechazar acá evita el round-trip cuando el payload ya es
        # incoherente (mismo criterio que el guard de cuenta bancaria de
        # arriba).
        if self.cash_session_id is not None and self.payment_method != "cash":
            raise ValueError(
                f"cash_session_id sólo aplica si payment_method=cash (recibido: {self.payment_method})"
            )
        return self


class PaymentReceivedOut(BaseModel):
    payment_id:           uuid.UUID | None
    customer_account_id:  uuid.UUID | None
    balance_after:        Decimal | None
    replayed:             bool
    operation_id:         uuid.UUID | None = None


class PaymentReversalIn(BaseModel):
    """cobranzas-reverso (D1 apply, OQ-2): motivo OPCIONAL — se muestra en el
    diálogo y viaja al `description` del contra-movimiento de caja y al
    payload del evento, pero nunca es exigido (rpc_reverse_payment_received
    no lo requiere; D9: la anulación es idempotente por ausencia del
    documento, sin p_idempotency_key)."""
    reason: str | None = None


class PaymentReversalOut(BaseModel):
    """Respuesta de rpc_reverse_payment_received (jsonb)."""
    payment_id:           uuid.UUID
    reversed:              bool
    account_movement_id:  uuid.UUID
    cash_reversal_id:      uuid.UUID | None = None
    bank_reversals:        int = 0
