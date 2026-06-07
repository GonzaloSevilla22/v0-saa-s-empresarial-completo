from __future__ import annotations

import datetime
import uuid

from pydantic import BaseModel, ConfigDict


class ClientCreate(BaseModel):
    name: str
    email: str | None = None
    phone: str | None = None


class ClientUpdate(BaseModel):
    name: str | None = None
    email: str | None = None
    phone: str | None = None


class ClientOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    user_id: uuid.UUID
    name: str
    email: str | None
    phone: str | None
    created_at: datetime.datetime
