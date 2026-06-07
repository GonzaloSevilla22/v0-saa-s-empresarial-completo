from __future__ import annotations

from pydantic import BaseModel


class MpNotificationData(BaseModel):
    id: str | None = None


class MpNotification(BaseModel):
    type: str | None = None
    data: MpNotificationData | None = None


class WebhookResponse(BaseModel):
    ok: bool
    idempotent: bool | None = None
    shadow: bool | None = None
    skipped: bool | None = None
    status: str | None = None
    error: str | None = None
