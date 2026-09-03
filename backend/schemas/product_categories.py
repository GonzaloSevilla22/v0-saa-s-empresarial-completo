from __future__ import annotations

import datetime
import uuid

from pydantic import BaseModel, ConfigDict, Field


class ProductCategoryCreate(BaseModel):
    """Payload for POST /product-categories (productos-categorias-sku, D7).

    Sin `kind`: una categoría de producto es puro rótulo del usuario. El
    nombre se normaliza en el service (trim + colapso de espacios); un nombre
    en blanco se rechaza con 422 y el duplicado case-insensitive con 409.
    """

    name: str = Field(..., min_length=1, description="Nombre de la categoría")
    sort_order: int | None = Field(
        None, description="Orden del selector (menor = primero). Ausente → al final del catálogo."
    )


class ProductCategoryUpdate(BaseModel):
    """Payload for PATCH /product-categories/{id}.

    Todos los campos son opcionales: campo ausente conserva (COALESCE en el
    repositorio). `is_active = true` es la reactivación de una categoría
    desactivada (spec product-category, "Reactivar una categoría").
    """

    name: str | None = Field(None, description="Nuevo nombre")
    sort_order: int | None = Field(None, description="Nuevo orden del selector")
    is_active: bool | None = Field(None, description="Reactivar (true) / desactivar (false)")


class ProductCategoryOut(BaseModel):
    """Response schema for product category endpoints."""

    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    account_id: uuid.UUID
    name: str
    is_active: bool
    sort_order: int
    created_at: datetime.datetime
