from __future__ import annotations

import copy

from fastapi import HTTPException

from backend.core.guards import require_account_role
from backend.core.rbac import CAN_CONFIGURE
from backend.repositories.scale_settings_repository import ScaleSettingsRepository
from backend.schemas.scale_settings import FACTORY_SCALE_SETTINGS, ScaleSettingsIn


async def get_scale_settings(repo: ScaleSettingsRepository, account_id: str) -> dict:
    """balanza-etiquetas-pos (D3): cualquier miembro lee la configuración. Sin
    fila = balanza deshabilitada con los formatos de fábrica (el primer PUT
    inserta)."""
    row = await repo.get(account_id)
    if row is None:
        return {**copy.deepcopy(FACTORY_SCALE_SETTINGS), "is_default": True}
    return {
        "enabled": row["enabled"],
        "layouts": row["layouts"],
        "is_default": False,
        "updated_at": row["updated_at"],
        "updated_by": row["updated_by"],
    }


async def save_scale_settings(
    repo: ScaleSettingsRepository,
    auth: dict,
    account_id: str,
    payload: ScaleSettingsIn,
    *,
    conn,
) -> dict:
    """balanza-etiquetas-pos (D3/D13): sólo owner/admin (CAN_CONFIGURE,
    capacidad sensible: la base es la autoridad del rol). Defensa en dos
    capas: este 403 legible + el disparador P0401 de la tabla. Las reglas D4
    ya las validó el esquema (422)."""
    await require_account_role(conn, auth, CAN_CONFIGURE)
    # Sin claves nulas: la forma guardada y devuelta es la del contrato
    # (`value?`/`decimals?` opcionales), igual a la que envía el frontend.
    layouts = [layout.model_dump(exclude_none=True) for layout in payload.layouts]
    row = await repo.upsert(account_id, payload.enabled, layouts, auth["user_id"])
    if row is None:
        raise HTTPException(status_code=500, detail="No se pudo guardar la configuración de la balanza")
    return {
        "enabled": row["enabled"],
        "layouts": row["layouts"],
        "is_default": False,
        "updated_at": row["updated_at"],
        "updated_by": row["updated_by"],
    }
