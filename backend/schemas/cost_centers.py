from __future__ import annotations

import datetime
import uuid

from pydantic import BaseModel, ConfigDict, Field


class CostCenterCreate(BaseModel):
    """Payload for POST /cost-centers."""

    name: str = Field(..., min_length=1, description="Nombre del centro de costo")
    code: str | None = Field(None, description="Código corto opcional (ej: MKTO)")


class CostCenterUpdate(BaseModel):
    """Payload for PATCH /cost-centers/{id}."""

    name: str = Field(..., min_length=1, description="Nuevo nombre del centro de costo")
    code: str | None = Field(None, description="Nuevo código corto (null para borrar)")


class CostCenterOut(BaseModel):
    """Response schema for cost center CRUD endpoints."""

    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    account_id: uuid.UUID
    name: str
    code: str | None
    is_active: bool
    created_at: datetime.datetime
