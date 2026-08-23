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

    async def count_by_org(self, account_id: str) -> int:
        # D3 (compras-proveedor-cuenta-corriente): este contador NO se usa
        # para pre-chequear el límite de plan en el service — a diferencia de
        # ClientRepository.count_by_org, ese enforcement queda EXCLUSIVAMENTE
        # en trg_guard_supplier_plan_limit (única fuente, ve todos los
        # inserts). Se ofrece igual porque es una operación de lectura útil
        # (p. ej. para un futuro badge de "N/max" en el frontend) y porque
        # billing-pro-trial (D5/D7) ya excluye los borrados del límite —
        # mismo criterio acá: borrar libera cupo.
        row = await self.fetchrow(
            "SELECT COUNT(*) AS total FROM suppliers WHERE account_id = $1"
            + self.not_deleted_clause(),
            account_id,
        )
        return int(row["total"]) if row else 0

    async def create(self, account_id: str, data: dict) -> asyncpg.Record | None:
        # HALLAZGO (compras-proveedor-cuenta-corriente, fuera de alcance tocar
        # la migración en esta fase): suppliers.company_id sigue siendo
        # NOT NULL legacy con FK a companies(id) — nunca se dropeó tras
        # v20-tenancy-cleanup (20260613000002/3, ver también
        # 20260804000007:1070 y 20260817000001:928, que documentan el mismo
        # gotcha para sus companies sintéticas de test). Se resuelve acá con
        # el MISMO join company_users -> account_members que usó el backfill
        # histórico de 20260613000002 — no se crea una companies nueva desde
        # el endpoint. Si la cuenta no tiene ningún mapeo legacy (no debería
        # pasar: toda cuenta real viene de esa migración), el INSERT falla
        # con 23502 (not_null_violation) y sale 500 genérico — no hay un
        # ERRCODE de negocio propio para ese caso. Reportado como deuda a
        # verificar por el PO/orchestrator; la corrección correcta es una
        # migración futura que dropee la columna o el NOT NULL.
        return await self.fetchrow(
            """
            INSERT INTO suppliers (
                account_id, company_id, name, tax_id, iva_condition, legal_name, email, phone
            )
            VALUES (
                $1,
                (
                    SELECT cu.company_id
                    FROM company_users cu
                    JOIN account_members am ON am.user_id = cu.user_id
                    WHERE am.account_id = $1::uuid
                    LIMIT 1
                ),
                $2, $3, $4, $5, $6, $7
            )
            RETURNING *
            """,
            account_id,
            data["name"],
            data.get("tax_id"),
            data.get("iva_condition"),
            data.get("legal_name"),
            data.get("email"),
            data.get("phone"),
        )

    async def update(self, supplier_id: str, account_id: str, data: dict) -> asyncpg.Record | None:
        fields = {k: v for k, v in data.items() if v is not None}
        if not fields:
            return await self.get_by_id(supplier_id, account_id)
        set_clauses = ", ".join(f"{k} = ${i + 3}" for i, k in enumerate(fields))
        values = list(fields.values())
        return await self.fetchrow(
            f"UPDATE suppliers SET {set_clauses} WHERE id = $1 AND account_id = $2"
            + self.not_deleted_clause()
            + " RETURNING *",
            supplier_id,
            account_id,
            *values,
        )
