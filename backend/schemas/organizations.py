from __future__ import annotations

import datetime

from pydantic import BaseModel, ConfigDict


class OrgOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    name: str | None = None
    created_at: datetime.datetime | None = None


class OrgSettingsUpdate(BaseModel):
    name: str | None = None
