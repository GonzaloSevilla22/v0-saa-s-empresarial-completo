from __future__ import annotations

import json

from backend.repositories.base import BaseRepository


def _jsonb(value):
    """asyncpg entrega jsonb como str sin codec registrado (mismo criterio que
    el resto de los repositories)."""
    return json.loads(value) if isinstance(value, str) else value


_COLUMNS = "account_id, enabled, layouts, updated_at, updated_by"


class ScaleSettingsRepository(BaseRepository):
    """balanza-etiquetas-pos (D3/D13): una fila por cuenta en `scale_settings`.

    Filtra explícito por `account_id` (regla dura de tenencia: la RLS es red,
    no guard único). La escritura además la sostiene la base con el disparador
    owner/admin (P0401); el service da el 403 legible antes.
    """

    async def get(self, account_id: str) -> dict | None:
        row = await self.fetchrow(
            f"SELECT {_COLUMNS} FROM scale_settings WHERE account_id = $1",
            account_id,
        )
        if row is None:
            return None
        data = dict(row)
        data["layouts"] = _jsonb(data["layouts"])
        return data

    async def upsert(self, account_id: str, enabled: bool, layouts: list[dict], user_id: str) -> dict | None:
        row = await self.fetchrow(
            f"""
            INSERT INTO scale_settings (account_id, enabled, layouts, updated_at, updated_by)
            VALUES ($1, $2, $3::jsonb, now(), $4)
            ON CONFLICT (account_id) DO UPDATE
               SET enabled    = EXCLUDED.enabled,
                   layouts    = EXCLUDED.layouts,
                   updated_at = now(),
                   updated_by = EXCLUDED.updated_by
             WHERE scale_settings.account_id = $1
            RETURNING {_COLUMNS}
            """,
            account_id,
            enabled,
            json.dumps(layouts),
            user_id,
        )
        if row is None:
            return None
        data = dict(row)
        data["layouts"] = _jsonb(data["layouts"])
        return data
