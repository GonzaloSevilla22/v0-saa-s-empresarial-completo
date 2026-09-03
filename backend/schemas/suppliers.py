from __future__ import annotations

import datetime
import uuid
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, field_validator

# compras-proveedor-cuenta-corriente (D2/OQ-3 opción A): FiscalIdentity es un
# Value Object COMPARTIDO entre Customer y Supplier (RN-96) — el Literal de
# condición IVA se REUTILIZA del módulo canónico de clients, nunca se
# redeclara (regla PO "reutilización antes que repetición").
from backend.schemas.clients import IvaCondition

# review B (BE-4): name nunca puede ser un string vacío o solo whitespace —
# Annotated + StringConstraints(strip_whitespace=True, min_length=1) rechaza
# "   " con un 422 automático (loc=('name',), verificado empíricamente:
# Pydantic v2 reporta el `loc` del campo, no de la rama del Union, cuando el
# tipo del input solo calza con una rama).
_SupplierName = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1)]


class SupplierCreate(BaseModel):
    name: _SupplierName
    tax_id: str | None = None
    iva_condition: IvaCondition | None = None
    legal_name: str | None = None
    email: str | None = None
    phone: str | None = None
    # cobranzas-vencimientos (D2): plazo de pago propio del proveedor —
    # espejo exacto de clients.payment_terms_days. None = hereda / sin
    # vencimiento; nunca cero. Negativo → 422.
    payment_terms_days: Annotated[int, Field(ge=0)] | None = None


class SupplierUpdate(BaseModel):
    """review B (BE-1/BE-4, tri-estado real): a diferencia de tax_id/email/
    phone/iva_condition/legal_name (desimputables — ausente preserva,
    presente+null borra), `name` NUNCA puede quedar en null: es el único
    campo obligatorio del maestro. `field_validator` (no `model_validator`,
    ver la nota de cash.py sobre por qué — preserva el `loc` del campo
    ofensor) solo se dispara cuando el campo fue ENVIADO explícitamente
    (Pydantic v2 no corre field_validator sobre el default de un campo
    ausente salvo validate_default=True) — así que null explícito rechaza,
    pero omitir el campo no."""

    name: str | None = None
    tax_id: str | None = None
    iva_condition: IvaCondition | None = None
    legal_name: str | None = None
    email: str | None = None
    phone: str | None = None
    # cobranzas-vencimientos (D14): tri-estado real via model_fields_set del
    # service (BE-1) — ausente preserva, null limpia, valor setea.
    payment_terms_days: Annotated[int, Field(ge=0)] | None = None

    @field_validator("name")
    @classmethod
    def _name_cannot_be_cleared(cls, v: str | None) -> str | None:
        if v is None:
            raise ValueError("el nombre del proveedor no puede quedar vacío")
        stripped = v.strip()
        if not stripped:
            raise ValueError("el nombre del proveedor no puede quedar vacío")
        return stripped


class SupplierOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    tax_id: str | None = None
    iva_condition: str | None = None
    legal_name: str | None = None
    email: str | None = None
    phone: str | None = None
    payment_terms_days: int | None = None
    created_at: datetime.datetime
