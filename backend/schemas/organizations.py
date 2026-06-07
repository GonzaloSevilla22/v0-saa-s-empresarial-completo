from __future__ import annotations

import datetime
import uuid

from pydantic import BaseModel, ConfigDict


class OrgOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str | None = None
    created_at: datetime.datetime | None = None


class OrgSettingsUpdate(BaseModel):
    name: str | None = None
