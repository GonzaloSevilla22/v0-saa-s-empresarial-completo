"""
Schemas Pydantic v2 para bank-payment-routing C2 — lectura de bank_accounts.

Solo lectura: la creación/edición de cuentas bancarias vive en bank-account-ledger
(C1, RPCs rpc_create_bank_account/rpc_update_bank_account) — sin wiring de backend
en C1. C2 agrega el read endpoint que necesita el picker de cuenta bancaria en el
formulario de cobro/pago.

Models:
  BankAccountOut — fila de bank_accounts (picker de cuenta bancaria)
"""
from __future__ import annotations

import uuid
from decimal import Decimal

from pydantic import BaseModel, ConfigDict


class BankAccountOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id:              uuid.UUID
    account_id:      uuid.UUID
    name:            str
    bank_name:       str | None = None
    cbu:             str | None = None
    alias:           str | None = None
    currency:        str
    is_active:       bool
