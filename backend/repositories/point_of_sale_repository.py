"""
C-27 v21-fiscal-profile — PointOfSaleRepository.

Acceso a datos de points_of_sale vía JWT-passthrough.
Design ref: D9 (RLS), D10 (multi-PV, account_id desnormalizado)

punto-venta-seleccion (D9): PV predeterminado por cuenta (`is_default`). Toda
sentencia filtra por `account_id` explícito — la RLS es red, no guard único.
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
        """Desactiva un punto de venta (is_active = false). No lo borra (conserva historial).

        punto-venta-seleccion: le quita la marca de predeterminado en la MISMA
        sentencia — el CHECK `points_of_sale_default_is_active` rechaza un
        predeterminado inactivo, y la cuenta queda sin predeterminado (ningún
        otro PV se promueve solo).
        """
        row = await self.fetchrow(
            """
            UPDATE public.points_of_sale
            SET is_active = false, is_default = false
            WHERE id = $1 AND account_id = $2
            RETURNING *
            """,
            pv_id,
            account_id,
        )
        return dict(row) if row else None

    async def set_default(self, pv_id: str, account_id: str) -> dict | None:
        """Marca el PV como predeterminado de la cuenta (D9).

        Dos sentencias, en este orden, dentro de una transacción (savepoint si
        el request ya abrió una): quitar la marca de cualquier otro PV de la
        cuenta y marcar el pedido. No una sola sentencia con
        `SET is_default = (id = $2)`: el índice único parcial se verifica fila
        por fila y no admite DEFERRABLE, así que fallaría según el orden físico.

        Devuelve None si el PV no existe, es de otra cuenta o está inactivo — y
        en ese caso REVIERTE la primera sentencia: la marca vigente queda
        intacta.

        Lock de transacción por cuenta (`pg_advisory_xact_lock`, hallazgo de
        red-team de punto-venta-seleccion) ANTES de la sentencia de limpieza:
        sin él, dos marcados concurrentes en PVs distintos de la misma cuenta
        no se serializaban — el segundo veía "UPDATE 0" en su propia limpieza
        (snapshot previo al commit del primero) y recién explotaba con un
        23505 genérico al confirmar, en vez de last-writer-wins ordenado.
        """
        try:
            async with self._conn.transaction():
                await self.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
                    account_id,
                )
                await self.execute(
                    """
                    UPDATE public.points_of_sale
                    SET is_default = false
                    WHERE account_id = $1 AND is_default AND id <> $2
                    """,
                    account_id,
                    pv_id,
                )
                row = await self.fetchrow(
                    """
                    UPDATE public.points_of_sale
                    SET is_default = true
                    WHERE id = $1 AND account_id = $2 AND is_active
                    RETURNING *
                    """,
                    pv_id,
                    account_id,
                )
                if row is None:
                    raise _PointOfSaleNotMarkable
        except _PointOfSaleNotMarkable:
            return None
        return dict(row)

    async def clear_default(self, account_id: str) -> None:
        """Deja la cuenta sin punto de venta predeterminado."""
        await self.execute(
            """
            UPDATE public.points_of_sale
            SET is_default = false
            WHERE account_id = $1 AND is_default
            """,
            account_id,
        )


class _PointOfSaleNotMarkable(Exception):
    """Interna de `set_default`: fuerza el rollback de la transacción cuando el
    PV pedido no se puede marcar (ajeno, inactivo o inexistente)."""
