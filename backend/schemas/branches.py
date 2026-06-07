from __future__ import annotations

import datetime

from pydantic import BaseModel, ConfigDict


class BranchCreate(BaseModel):
    name: str


class BranchUpdate(BaseModel):
    name: str | None = None


class BranchOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    user_id: str
    name: str
    created_at: datetime.datetime
