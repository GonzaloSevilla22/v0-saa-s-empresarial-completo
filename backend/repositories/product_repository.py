from __future__ import annotations

import asyncpg

from backend.repositories.base import BaseRepository


class ProductRepository(BaseRepository):
    async def list_by_org(self, account_id: str) -> list[dict]:
        # C-21: lee de v_products_with_stock para que el campo `stock` refleje
        # COALESCE(Σ branch_stock, 0) en lugar de products.stock.
        # La vista tiene security_invoker=true — respeta RLS.
        return await self.fetch(
            "SELECT * FROM v_products_with_stock WHERE account_id = $1 ORDER BY name ASC",
            account_id,
        )

    async def get_by_id(self, product_id: str, account_id: str) -> asyncpg.Record | None:
        # C-21: ídem — usa la vista de compatibilidad para stock consistente.
        return await self.fetchrow(
            "SELECT * FROM v_products_with_stock WHERE id = $1 AND account_id = $2",
            product_id,
            account_id,
        )

    async def create(self, user_id: str, account_id: str, data: dict) -> asyncpg.Record | None:
        return await self.fetchrow(
            """
            INSERT INTO products (user_id, account_id, name, category, price, cost, stock, min_stock,
                                  barcode, sku, parent_id, is_variant, stock_control_type)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
            RETURNING *
            """,
            user_id,
            account_id,
            data["name"],
            data.get("category"),
            data.get("price"),
            data.get("cost"),
            data.get("stock", 0),
            data.get("min_stock", 0),
            data.get("barcode"),
            data.get("sku"),
            data.get("parent_id"),
            data.get("is_variant", False),
            data.get("stock_control_type", "unit"),
        )

    async def update(self, product_id: str, account_id: str, data: dict) -> asyncpg.Record | None:
        fields = {k: v for k, v in data.items() if v is not None}
        if not fields:
            return await self.get_by_id(product_id, account_id)
        set_clauses = ", ".join(f"{k} = ${i + 3}" for i, k in enumerate(fields))
        values = list(fields.values())
        return await self.fetchrow(
            f"UPDATE products SET {set_clauses} WHERE id = $1 AND account_id = $2 RETURNING *",
            product_id,
            account_id,
            *values,
        )

    async def delete(self, product_id: str, account_id: str) -> str:
        return await self.execute(
            "DELETE FROM products WHERE id = $1 AND account_id = $2",
            product_id,
            account_id,
        )

    async def search_by_sku(self, sku: str, account_id: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            "SELECT * FROM products WHERE sku = $1 AND account_id = $2",
            sku,
            account_id,
        )

    async def search_by_barcode(self, barcode: str, account_id: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            "SELECT * FROM products WHERE barcode = $1 AND account_id = $2",
            barcode,
            account_id,
        )

    async def count_by_org(self, account_id: str) -> int:
        row = await self.fetchrow(
            "SELECT COUNT(*) AS total FROM products WHERE account_id = $1",
            account_id,
        )
        return int(row["total"]) if row else 0
