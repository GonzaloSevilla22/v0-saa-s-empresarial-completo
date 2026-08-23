"""
Schemas Pydantic v2 para bank_accounts — lectura (C2) y alta (bank-account-crud).

La creación/edición de cuentas bancarias vive en bank-account-ledger (C1, RPCs
rpc_create_bank_account/rpc_update_bank_account, migración 20260804000002).
bank-account-crud expone el alta (POST /bank-accounts) invocando la RPC ya
existente; sin migraciones nuevas.

Models:
  BankAccountOut    — fila de bank_accounts (picker de cuenta bancaria / respuesta del alta)
  BankAccountCreate — payload de POST /bank-accounts (D4: valida en el borde antes de
                      tocar la DB; la RPC es la autoridad final — P0400/P0411)
"""
from __future__ import annotations

import uuid
from datetime import date
from decimal import Decimal
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

# cuentas-billetera-tipo: dominio cerrado 'bank' | 'wallet' — mismo Literal en
# BankAccountOut (lectura) y BankAccountCreate (alta). El default 'bank' vive
# acá (schema) Y en la RPC (rpc_create_bank_account.p_account_kind DEFAULT
# 'bank') — dos capas, mismo valor, por diseño (D1 del design.md).
AccountKind = Literal["bank", "wallet"]


class BankAccountOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id:              uuid.UUID
    account_id:      uuid.UUID
    name:            str
    bank_name:       str | None = None
    cbu:             str | None = None
    alias:           str | None = None
    currency:        str
    account_kind:    AccountKind = "bank"
    is_active:       bool


class BankAccountCreate(BaseModel):
    """Payload for POST /bank-accounts.

    Mirrors rpc_create_bank_account's parameters (name, bank_name, cbu, alias,
    currency, opening_balance, opening_date, account_kind). cbu validation is
    intentionally duplicated here (early 422 feedback) and in the RPC (final
    authority, P0411); account_kind is validated here by Pydantic's Literal
    (422 before touching the DB) and again by the RPC's CHECK/domain guard
    (final authority, P0414) — cuentas-billetera-tipo.
    """

    name:            str = Field(..., min_length=1, description="Nombre de la cuenta bancaria")
    bank_name:       str | None = Field(None, description="Nombre del banco (opcional)")
    cbu:             str | None = Field(
        None,
        pattern=r"^\d{22}$",
        description="CBU de 22 dígitos numéricos (opcional)",
    )
    alias:           str | None = Field(None, description="Alias de la cuenta (opcional)")
    currency:        str = Field("ARS", description="Moneda de la cuenta (default ARS)")
    opening_balance: Decimal = Field(Decimal("0"), ge=0, description="Saldo inicial (base de cálculo, no genera movimiento)")
    opening_date:    date | None = Field(None, description="Fecha del saldo inicial (opcional)")
    account_kind:    AccountKind = Field("bank", description="Tipo de cuenta: banco real o billetera virtual (default 'bank')")

    @field_validator("name")
    @classmethod
    def _strip_and_validate_name(cls, v: str) -> str:
        stripped = v.strip()
        if not stripped:
            raise ValueError("El nombre de la cuenta es obligatorio")
        return stripped
