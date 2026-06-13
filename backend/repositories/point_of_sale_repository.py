"""
C-27 v21-fiscal-profile — PointOfSaleRepository.

Acceso a datos de points_of_sale vía JWT-passthrough.
Design ref: D9 (RLS), D10 (multi-PV, account_id desnormalizado)
"""
from __future__ import annotations

from backend.repositories.base import BaseRepository


class PointOfSaleRepository(BaseRepository):
    """Repository para points_of_sale."""

    async def list_by_account(self, account_id: str) -> list[dict]:
        """Lista todos los PVs de la cuenta (activos e inactivos)."""
        return await self.fetch(
            """
            SELECT * FROM public.points_of_sale
            WHERE account_id = $1
            ORDER BY numero ASC
            """,
            account_id,
        )

    async def get_by_id(self, pv_id: str, account_id: str) -> dict | None:
        row = await self.fetchrow(
            "SELECT * FROM public.points_of_sale WHERE id = $1 AND account_id = $2",
            pv_id,
            account_id,
        )
        return dict(row) if row else None

    async def create(self, account_id: str, fiscal_profile_id: str, data: dict) -> dict | None:
        """Crea un nuevo punto de venta para la cuenta.

        Raises asyncpg.UniqueViolationError si (fiscal_profile_id, numero) ya existe → 409.
        """
        row = await self.fetchrow(
            """
            INSERT INTO public.points_of_sale
              (fiscal_profile_id, account_id, branch_id, numero)
            VALUES ($1, $2, $3, $4)
            RETURNING *
            """,
            fiscal_profile_id,
            account_id,
            data.get("branch_id"),
            data["numero"],
        )
        return dict(row) if row else None

    async def deactivate(self, pv_id: str, account_id: str) -> dict | None:
        """Desactiva un punto de venta (is_active = false). No lo borra (conserva historial)."""
        row = await self.fetchrow(
            """
            UPDATE public.points_of_sale
            SET is_active = FALSE
            WHERE id = $1 AND account_id = $2
            RETURNING *
            """,
            pv_id,
            account_id,
        )
        return dict(row) if row else None
