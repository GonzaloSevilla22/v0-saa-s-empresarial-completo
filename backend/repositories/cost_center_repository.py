from __future__ import annotations

import asyncpg

from backend.repositories.base import BaseRepository


class CostCenterRepository(BaseRepository):
    """Repository for cost_centers catalog (cost-center-dimension, V2.5 Finanzas).

    Writes directly to the cost_centers table — no SECURITY DEFINER RPC needed
    because this catalog does not handle money. RLS (is_account_writer) acts as
    the DB-level gate; the service layer adds require_role as defence-in-depth.
    JWT-passthrough (from BaseRepository invariant) keeps RLS active.
    """

    async def list_by_account(
        self,
        account_id: str,
        *,
        active_only: bool = True,
    ) -> list[dict]:
        """Return cost centers for the account.

        Args:
            account_id: The tenant account UUID (scoped by RLS too).
            active_only: If True (default), only return is_active=true rows.
                         If False, return all rows (for admin management screen).
        """
        if active_only:
            return await self.fetch(
                """
                SELECT id, account_id, name, code, is_active, created_at
                FROM   cost_centers
                WHERE  account_id = $1
                  AND  is_active = TRUE
                ORDER BY name
                """,
                account_id,
            )
        return await self.fetch(
            """
            SELECT id, account_id, name, code, is_active, created_at
            FROM   cost_centers
            WHERE  account_id = $1
            ORDER BY name
            """,
            account_id,
        )

    async def get_by_id(
        self,
        cost_center_id: str,
        account_id: str,
    ) -> asyncpg.Record | None:
        """Fetch a single cost center by id scoped to the account."""
        return await self.fetchrow(
            """
            SELECT id, account_id, name, code, is_active, created_at
            FROM   cost_centers
            WHERE  id = $1 AND account_id = $2
            """,
            cost_center_id,
            account_id,
        )

    async def create(
        self,
        account_id: str,
        name: str,
        code: str | None = None,
    ) -> asyncpg.Record | None:
        """Insert a new cost center and return the created row.

        The UNIQUE(account_id, lower(name)) index enforces case-insensitive
        uniqueness at the DB level. Callers should normalize name (strip) before
        calling this; the service layer is responsible for trimming.
        """
        return await self.fetchrow(
            """
            INSERT INTO cost_centers (account_id, name, code)
            VALUES ($1, $2, $3)
            RETURNING id, account_id, name, code, is_active, created_at
            """,
            account_id,
            name,
            code,
        )

    async def update(
        self,
        cost_center_id: str,
        account_id: str,
        name: str,
        code: str | None,
    ) -> asyncpg.Record | None:
        """Update name and/or code of a cost center. Returns updated row or None."""
        return await self.fetchrow(
            """
            UPDATE cost_centers
            SET    name = $3,
                   code = $4
            WHERE  id = $1 AND account_id = $2
            RETURNING id, account_id, name, code, is_active, created_at
            """,
            cost_center_id,
            account_id,
            name,
            code,
        )

    async def deactivate(
        self,
        cost_center_id: str,
        account_id: str,
    ) -> asyncpg.Record | None:
        """Soft-delete: set is_active=false. Preserves historical references.

        Physical DELETE is intentionally avoided so that existing expenses/purchases
        that reference this cost center keep their cost_center_id intact
        (the ON DELETE SET NULL FK is a last-resort safety net only).
        """
        return await self.fetchrow(
            """
            UPDATE cost_centers
            SET    is_active = FALSE
            WHERE  id = $1 AND account_id = $2
            RETURNING id, account_id, name, code, is_active, created_at
            """,
            cost_center_id,
            account_id,
        )
