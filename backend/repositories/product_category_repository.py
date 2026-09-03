from __future__ import annotations

import asyncpg

from backend.repositories.base import BaseRepository


class ProductCategoryRepository(BaseRepository):
    """Repository for the product_categories catalog (productos-categorias-sku).

    Espejo de PaymentMethodRepository sin `kind`: escribe directo a la tabla
    (sin RPC SECURITY DEFINER — el catálogo no maneja dinero). Todo SELECT/
    UPDATE filtra EXPLÍCITO por account_id (regla dura del proyecto: la RLS
    is_account_writer es red, no guard único). JWT-passthrough (invariante de
    BaseRepository) mantiene la RLS activa.
    """

    _COLUMNS = "id, account_id, name, is_active, sort_order, created_at"

    async def list_by_account(
        self,
        account_id: str,
        *,
        active_only: bool = True,
    ) -> list[dict]:
        """Return the account's categories ordered by sort_order.

        RN-B1 (soft-delete-policy): ambas ramas excluyen filas BORRADAS
        (deleted_at IS NULL). active_only=False sigue mostrando las
        DESACTIVADAS (is_active=false) — baja lógica reversible, no borrado.
        """
        if active_only:
            return await self.fetch(
                f"""
                SELECT {self._COLUMNS}
                FROM   product_categories
                WHERE  account_id = $1
                  AND  is_active = TRUE
                  AND  deleted_at IS NULL
                ORDER BY sort_order, name
                """,
                account_id,
            )
        return await self.fetch(
            f"""
            SELECT {self._COLUMNS}
            FROM   product_categories
            WHERE  account_id = $1
              AND  deleted_at IS NULL
            ORDER BY sort_order, name
            """,
            account_id,
        )

    async def get_by_id(self, category_id: str, account_id: str) -> asyncpg.Record | None:
        """Fetch a live (not deleted) category scoped to the account —
        activa o no (un producto puede seguir imputado a una desactivada)."""
        return await self.fetchrow(
            f"""
            SELECT {self._COLUMNS}
            FROM   product_categories
            WHERE  id = $1 AND account_id = $2
              AND  deleted_at IS NULL
            """,
            category_id,
            account_id,
        )

    async def get_active_by_id(self, category_id: str, account_id: str) -> asyncpg.Record | None:
        """D14: la categoría DESTINO de la recategorización en lote debe estar
        viva Y activa — una desactivada no vuelve a recibir imputaciones."""
        return await self.fetchrow(
            f"""
            SELECT {self._COLUMNS}
            FROM   product_categories
            WHERE  id = $1 AND account_id = $2
              AND  is_active = TRUE
              AND  deleted_at IS NULL
            """,
            category_id,
            account_id,
        )

    async def create(
        self,
        account_id: str,
        name: str,
        sort_order: int | None = None,
    ) -> asyncpg.Record | None:
        """Insert a category. sort_order ausente → al FINAL del catálogo
        (MAX + 1 entre filas vivas), nunca 0: en 0 se colaría delante de las
        7 sembradas (1..7). El unique (account_id, lower(name)) parcial de la
        DB es la fuente de verdad del duplicado; el service traduce el 23505."""
        return await self.fetchrow(
            f"""
            INSERT INTO product_categories (account_id, name, sort_order)
            VALUES (
                $1,
                $2,
                COALESCE(
                    $3::int,
                    (SELECT COALESCE(MAX(sort_order), 0) + 1
                       FROM product_categories
                      WHERE account_id = $1 AND deleted_at IS NULL)
                )
            )
            RETURNING {self._COLUMNS}
            """,
            account_id,
            name,
            sort_order,
        )

    async def update(
        self,
        category_id: str,
        account_id: str,
        *,
        name: str | None,
        sort_order: int | None,
        is_active: bool | None,
    ) -> asyncpg.Record | None:
        """Rename / reorder / (re)activate. Campo None = conservar (COALESCE).
        Devuelve None si la fila no existe, está borrada o no pertenece a la
        cuenta — el service lo traduce a 404 sin revelar cuál de las tres."""
        return await self.fetchrow(
            f"""
            UPDATE product_categories
            SET    name       = COALESCE($3, name),
                   sort_order = COALESCE($4, sort_order),
                   is_active  = COALESCE($5, is_active)
            WHERE  id = $1 AND account_id = $2
              AND  deleted_at IS NULL
            RETURNING {self._COLUMNS}
            """,
            category_id,
            account_id,
            name,
            sort_order,
            is_active,
        )

    async def deactivate(self, category_id: str, account_id: str) -> asyncpg.Record | None:
        """Baja lógica REVERSIBLE (D3): is_active=false. Nunca DELETE físico —
        la FK products.category_id es ON DELETE RESTRICT y los productos ya
        imputados conservan su category_id y su nombre legible."""
        return await self.fetchrow(
            f"""
            UPDATE product_categories
            SET    is_active = FALSE
            WHERE  id = $1 AND account_id = $2
              AND  deleted_at IS NULL
            RETURNING {self._COLUMNS}
            """,
            category_id,
            account_id,
        )
