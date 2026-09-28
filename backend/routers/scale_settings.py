from __future__ import annotations

import uuid

import asyncpg
from fastapi import APIRouter, Depends

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.repositories.scale_settings_repository import ScaleSettingsRepository
from backend.schemas.scale_settings import ScaleSettingsIn, ScaleSettingsOut
from backend.services import scale_settings as scale_settings_service

router = APIRouter(prefix="/scale-settings", tags=["scale-settings"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> ScaleSettingsRepository:
    return ScaleSettingsRepository(conn)


@router.get("", response_model=ScaleSettingsOut, response_model_exclude_none=True)
async def get_scale_settings(
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ScaleSettingsRepository = Depends(get_repo),
):
    """balanza-etiquetas-pos (D13): cualquier miembro; sin fila → fábrica deshabilitada."""
    return await scale_settings_service.get_scale_settings(repo, str(account_id))


@router.put("", response_model=ScaleSettingsOut, response_model_exclude_none=True)
async def put_scale_settings(
    payload: ScaleSettingsIn,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ScaleSettingsRepository = Depends(get_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """balanza-etiquetas-pos (D13): payload completo; sólo owner/admin."""
    return await scale_settings_service.save_scale_settings(
        repo, auth, str(account_id), payload, conn=conn,
    )
