from __future__ import annotations

import datetime
import uuid
from typing import Literal

from pydantic import BaseModel, ConfigDict

IvaCondition = Literal[
    "responsable_inscripto", "monotributista", "exento", "consumidor_final"
]


class ClientCreate(BaseModel):
    name: str
    email: str | None = None
    phone: str | None = None
    tax_id: str | None = None
    iva_condition: IvaCondition | None = None
    legal_name: str | None = None


class ClientUpdate(BaseModel):
    name: str | None = None
    email: str | None = None
    phone: str | None = None
    tax_id: str | None = None
    iva_condition: IvaCondition | None = None
    legal_name: str | None = None


class ClientOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    user_id: uuid.UUID
    name: str
    email: str | None
    phone: str | None
    tax_id: str | None = None
    iva_condition: str | None = None
    legal_name: str | None = None
    created_at: datetime.datetime
