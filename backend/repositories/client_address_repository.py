"""
v3-catalog-masters — ClientAddressRepository (V3 §7.3).

Direcciones operativas múltiples por cliente. Scope de tenancy DIRECTO por
account_id (D2 del design) — habilita reutilizar BaseRepository.soft_delete()
sin JOIN a clients. JWT-passthrough (invariante de BaseRepository) mantiene
la RLS org-based activa.

El switch de dirección primaria (set_primary) delega SIEMPRE en el RPC
rpc_set_primary_client_address (SQL, D3 del design) — nunca dos UPDATEs
sueltos desde Python, que dejarían una ventana donde el índice único parcial
rechazaría el segundo UPDATE (subir la nueva antes de bajar la vieja).
"""
from __future__ import annotations

import asyncpg

from backend.repositories.base import BaseRepository

_ADDRESS_COLUMNS = (
    "id, account_id, client_id, alias, street, city, province, postal_code, "
    "notes, is_primary, created_at, updated_at"
)


class ClientAddressRepository(BaseRepository):
    """v3-soft-delete-policy: las lecturas excluyen filas borradas (RN-B1) y
    el borrado es soft vía BaseRepository.soft_delete("client_addresses", ...) (RN-B2)."""

    async def list_by_client(self, client_id: str, account_id: str) -> list[dict]:
        return await self.fetch(
            f"""
            SELECT {_ADDRESS_COLUMNS}
            FROM   client_addresses
            WHERE  client_id = $1 AND account_id = $2
            """
            + self.not_deleted_clause()
            + " ORDER BY is_primary DESC, created_at ASC",
            client_id,
            account_id,
        )

    async def get_by_id(self, address_id: str, account_id: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            f"""
            SELECT {_ADDRESS_COLUMNS}
            FROM   client_addresses
            WHERE  id = $1 AND account_id = $2
            """
            + self.not_deleted_clause(),
            address_id,
            account_id,
        )

    async def count_live_for_client(self, client_id: str, account_id: str) -> int:
        return await self._conn.fetchval(
            "SELECT COUNT(*) FROM client_addresses WHERE client_id = $1 AND account_id = $2"
            + self.not_deleted_clause(),
            client_id,
            account_id,
        )

    async def create(
        self, *, account_id: str, client_id: str, data: dict, is_primary: bool
    ) -> asyncpg.Record | None:
        return await self.fetchrow(
            f"""
            INSERT INTO client_addresses
                (account_id, client_id, alias, street, city, province, postal_code, notes, is_primary)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
            RETURNING {_ADDRESS_COLUMNS}
            """,
            account_id,
            client_id,
            data.get("alias"),
            data.get("street"),
            data.get("city"),
            data.get("province"),
            data.get("postal_code"),
            data.get("notes"),
            is_primary,
        )

    async def update(
        self, address_id: str, account_id: str, data: dict
    ) -> asyncpg.Record | None:
        fields = {k: v for k, v in data.items() if v is not None}
        if not fields:
            return await self.get_by_id(address_id, account_id)
        set_clauses = ", ".join(f"{k} = ${i + 3}" for i, k in enumerate(fields))
        values = list(fields.values())
        return await self.fetchrow(
            f"UPDATE client_addresses SET {set_clauses}, updated_at = now() "
            "WHERE id = $1 AND account_id = $2"
            + self.not_deleted_clause()
            + f" RETURNING {_ADDRESS_COLUMNS}",
            address_id,
            account_id,
            *values,
        )

    async def set_primary(self, address_id: str, account_id: str) -> asyncpg.Record | None:
        """Delega el switch atómico en rpc_set_primary_client_address (D3)."""
        return await self.fetchrow(
            "SELECT * FROM rpc_set_primary_client_address($1, $2)",
            address_id,
            account_id,
        )
