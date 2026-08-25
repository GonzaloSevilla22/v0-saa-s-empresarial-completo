from __future__ import annotations

import datetime
import uuid
from decimal import Decimal

from pydantic import BaseModel, ConfigDict


class BranchCreate(BaseModel):
    name: str


class BranchUpdate(BaseModel):
    name: str | None = None
    # sucursal-guard-vaciado-auditoria (task 5.3): BranchRepository.update
    # construye un UPDATE genérico sobre las claves no-None del payload — es
    # el camino #3 de los 4 caminos de baja que el design.md identifica
    # ("actualización directa que hace el backend contra la tabla"). Antes de
    # este campo, el schema no dejaba llegar is_active a la query y por lo
    # tanto no cruzaba el disparador NUNCA — no porque estuviera protegido,
    # sino porque el camino era inalcanzable por accidente. Ahora SÍ llega, y
    # el disparador trg_guard_branch_decommission (migración 20261014000001)
    # es lo que realmente lo protege.
    is_active: bool | None = None


class BranchOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    # sucursal-guard-vaciado-auditoria (task 5.4): el modelo declaraba
    # `user_id`, una columna que NO existe en `branches` (la tabla usa
    # `account_id`) — mentía y nunca lo notó nadie porque ningún caller pedía
    # ese campo. Se reemplaza por los campos reales que la pantalla necesita:
    # account_id, address, is_active y la autoría de alta/baja (G2).
    account_id: uuid.UUID
    name: str
    address: str | None = None
    is_active: bool
    created_at: datetime.datetime
    # C-26: lifecycle operacional
    status: str | None = None
    opened_at: datetime.datetime | None = None
    closed_at: datetime.datetime | None = None
    # sucursal-guard-vaciado-auditoria (G2, D6): autoría de alta y de baja.
    # NULL en sucursales preexistentes (sin backfill) y en las altas de
    # camino de sistema — la pantalla lo muestra como "no registrado".
    created_by: uuid.UUID | None = None
    deactivated_at: datetime.datetime | None = None
    deactivated_by: uuid.UUID | None = None


class BranchLifecycleOut(BaseModel):
    branch_id: uuid.UUID
    status: str
    changed: bool


class StockTransferOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    product_id: uuid.UUID
    product_name: str
    from_branch_id: uuid.UUID
    from_branch_name: str
    to_branch_id: uuid.UUID
    to_branch_name: str
    quantity: Decimal
    status: str
    created_at: datetime.datetime
