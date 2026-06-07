from __future__ import annotations

import datetime
import uuid

from pydantic import BaseModel, ConfigDict


class BranchCreate(BaseModel):
    name: str


class BranchUpdate(BaseModel):
    name: str | None = None


class BranchOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    user_id: uuid.UUID
    name: str
    created_at: datetime.datetime
