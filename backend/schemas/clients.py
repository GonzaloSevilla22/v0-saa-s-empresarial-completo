from __future__ import annotations

import datetime
import uuid
from decimal import Decimal
from typing import Literal

from pydantic import BaseModel, ConfigDict

from backend.core.client_activity import ClientActivityStatus
from backend.schemas.common import PageOut

IvaCondition = Literal[
    "responsable_inscripto", "monotributista", "exento", "consumidor_final"
]

# clientes-frecuentes-historial — client-activity §"Umbrales canónicos":
# el conjunto de estados y de columnas ordenables vive UNA sola vez acá
# (reexporta el Literal canónico de backend/core/client_activity.py).
ClientActivitySort = Literal["name", "last_purchase", "total_spent", "purchase_count"]
SortDir = Literal["asc", "desc"]


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


# ── clientes-frecuentes-historial ────────────────────────────────────────────
# client-activity + client-purchase-history: agregados de actividad comercial
# y historial de compras por operación. `activity_status` viaja ya resuelto
# desde ClientRepository — el frontend NO reimplementa la clasificación.


class ClientActivityOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    email: str | None
    phone: str | None
    tax_id: str | None = None
    iva_condition: str | None = None
    legal_name: str | None = None
    created_at: datetime.datetime
    purchase_count: int
    purchase_count_90d: int
    total_spent: Decimal
    last_purchase_date: datetime.date | None = None
    days_since_last_purchase: int | None = None
    activity_status: ClientActivityStatus


class ClientPurchaseOut(BaseModel):
    """Una fila por operación de venta (client-purchase-history
    §"Historial de compras del cliente")."""

    model_config = ConfigDict(from_attributes=True)

    operation_id: str
    operation_date: datetime.date
    item_count: int
    total: Decimal


class ClientPurchaseSummaryOut(BaseModel):
    """Resumen acumulado — se calcula sobre TODAS las operaciones del
    cliente, independiente de la página del historial visible
    (client-purchase-history §"Resumen acumulado")."""

    purchase_count: int
    total_spent: Decimal
    last_purchase_date: datetime.date | None = None
    days_since_last_purchase: int | None = None


ClientActivityPageOut = PageOut[ClientActivityOut]


class ClientPurchasesPageOut(PageOut[ClientPurchaseOut]):
    """Envelope estándar {items,total,page,pages} + `summary`, calculado una
    sola vez por request sobre la totalidad de las operaciones — no cambia
    al paginar el historial."""

    summary: ClientPurchaseSummaryOut
