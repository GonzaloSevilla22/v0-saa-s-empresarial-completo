"""
v3-catalog-masters — Schemas Pydantic v2 para client_addresses (V3 §7.3).

Direcciones operativas/editables múltiples por cliente. Distinta de la
dirección FISCAL (vive en FiscalIdentity, inmutable por snapshot — no se
toca en este change).

Models:
  ClientAddressCreate — payload de POST /clients/{client_id}/addresses (todos
                        los campos de dirección son opcionales; is_primary NO
                        es parte del payload — lo decide el service en la
                        primera alta, D3 del design)
  ClientAddressUpdate — payload de PUT (todos opcionales, patch parcial)
  ClientAddressOut    — fila de client_addresses (from_attributes=True)
"""
from __future__ import annotations

import datetime
import uuid

from pydantic import BaseModel, ConfigDict


class ClientAddressCreate(BaseModel):
    alias: str | None = None
    street: str | None = None
    city: str | None = None
    province: str | None = None
    postal_code: str | None = None
    notes: str | None = None


class ClientAddressUpdate(BaseModel):
    alias: str | None = None
    street: str | None = None
    city: str | None = None
    province: str | None = None
    postal_code: str | None = None
    notes: str | None = None


class ClientAddressOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    account_id: uuid.UUID
    client_id: uuid.UUID
    alias: str | None = None
    street: str | None = None
    city: str | None = None
    province: str | None = None
    postal_code: str | None = None
    notes: str | None = None
    is_primary: bool
    created_at: datetime.datetime
    updated_at: datetime.datetime | None = None
