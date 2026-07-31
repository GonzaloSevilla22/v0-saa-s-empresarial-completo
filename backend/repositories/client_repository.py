from __future__ import annotations

import asyncpg

from backend.repositories.base import BaseRepository


class ClientRepository(BaseRepository):
    """v3-soft-delete-policy: las lecturas excluyen filas borradas (RN-B1) y
    el borrado es soft vía BaseRepository.soft_delete("clients", ...) (RN-B2)."""

    async def list_by_org(self, account_id: str) -> list[dict]:
        return await self.fetch(
            "SELECT * FROM clients WHERE account_id = $1"
            + self.not_deleted_clause()
            + " ORDER BY name ASC",
            account_id,
        )

    async def get_by_id(self, client_id: str, account_id: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            "SELECT * FROM clients WHERE id = $1 AND account_id = $2"
            + self.not_deleted_clause(),
            client_id,
            account_id,
        )

    async def count_by_org(self, account_id: str) -> int:
        # billing-pro-trial (D5/D7): borrados no cuentan para el límite —
        # borrar libera cupo, mismo patrón que ProductRepository.count_by_org.
        row = await self.fetchrow(
            "SELECT COUNT(*) AS total FROM clients WHERE account_id = $1"
            + self.not_deleted_clause(),
            account_id,
        )
        return int(row["total"]) if row else 0

    async def create(self, user_id: str, account_id: str, data: dict) -> asyncpg.Record | None:
        return await self.fetchrow(
            """
            INSERT INTO clients (user_id, account_id, name, email, phone, tax_id, iva_condition, legal_name)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
            RETURNING *
            """,
            user_id,
            account_id,
            data["name"],
            data.get("email"),
            data.get("phone"),
            data.get("tax_id"),
            data.get("iva_condition"),
            data.get("legal_name"),
        )

    async def update(self, client_id: str, account_id: str, data: dict) -> asyncpg.Record | None:
        fields = {k: v for k, v in data.items() if v is not None}
        if not fields:
            return await self.get_by_id(client_id, account_id)
        set_clauses = ", ".join(f"{k} = ${i + 3}" for i, k in enumerate(fields))
        values = list(fields.values())
        return await self.fetchrow(
            f"UPDATE clients SET {set_clauses} WHERE id = $1 AND account_id = $2"
            + self.not_deleted_clause()
            + " RETURNING *",
            client_id,
            account_id,
            *values,
        )
