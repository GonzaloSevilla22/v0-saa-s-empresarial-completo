from __future__ import annotations

import datetime
import uuid

from pydantic import BaseModel, ConfigDict

# compras-proveedor-cuenta-corriente (D2/OQ-3 opción A): FiscalIdentity es un
# Value Object COMPARTIDO entre Customer y Supplier (RN-96) — el Literal de
# condición IVA se REUTILIZA del módulo canónico de clients, nunca se
# redeclara (regla PO "reutilización antes que repetición").
from backend.schemas.clients import IvaCondition


class SupplierCreate(BaseModel):
    name: str
    tax_id: str | None = None
    iva_condition: IvaCondition | None = None
    legal_name: str | None = None
    email: str | None = None
    phone: str | None = None


class SupplierUpdate(BaseModel):
    name: str | None = None
    tax_id: str | None = None
    iva_condition: IvaCondition | None = None
    legal_name: str | None = None
    email: str | None = None
    phone: str | None = None


class SupplierOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    tax_id: str | None = None
    iva_condition: str | None = None
    legal_name: str | None = None
    email: str | None = None
    phone: str | None = None
    created_at: datetime.datetime
