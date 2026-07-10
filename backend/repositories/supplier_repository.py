"""Repository de suppliers — v3-soft-delete-policy (task 5.3).

`suppliers` no exponía borrado en el backend (no existía repositorio). Se crea
alineado al patrón único de maestros: lecturas con filtro RN-B1
(`deleted_at IS NULL` por defecto, opt-in explícito para auditoría) y borrado
soft vía BaseRepository.soft_delete("suppliers", ...) (RN-B2).

Nota RLS: suppliers tiene account_id (20260613000002) y RLS propia
(20260613000004). JWT-passthrough del BaseRepository la mantiene activa.
"""
from __future__ import annotations

import asyncpg

from backend.repositories.base import BaseRepository


class SupplierRepository(BaseRepository):
    async def list_by_org(
        self, account_id: str, *, include_deleted: bool = False
    ) -> list[dict]:
        return await self.fetch(
            "SELECT * FROM suppliers WHERE account_id = $1"
            + self.not_deleted_clause(include_deleted=include_deleted)
            + " ORDER BY name ASC",
            account_id,
        )

    async def get_by_id(
        self, supplier_id: str, account_id: str
    ) -> asyncpg.Record | None:
        return await self.fetchrow(
            "SELECT * FROM suppliers WHERE id = $1 AND account_id = $2"
            + self.not_deleted_clause(),
            supplier_id,
            account_id,
        )
