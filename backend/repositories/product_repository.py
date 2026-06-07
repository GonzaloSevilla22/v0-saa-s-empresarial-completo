from __future__ import annotations

import asyncpg

from backend.repositories.base import BaseRepository


class ProductRepository(BaseRepository):
    async def list_by_org(self, user_id: str) -> list[asyncpg.Record]:
        return await self.fetch(
            "SELECT * FROM products WHERE user_id = $1 ORDER BY name ASC",
            user_id,
        )

    async def get_by_id(self, product_id: str, user_id: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            "SELECT * FROM products WHERE id = $1 AND user_id = $2",
            product_id,
            user_id,
        )

    async def create(self, user_id: str, data: dict) -> asyncpg.Record | None:
        return await self.fetchrow(
            """
            INSERT INTO products (user_id, name, category, price, cost, stock, min_stock, barcode, sku,
                                  is_variant, stock_control_type)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
            RETURNING *
            """,
            user_id,
            data["name"],
            data.get("category"),
            data.get("price"),
            data.get("cost"),
            data.get("stock", 0),
            data.get("min_stock", 0),
            data.get("barcode"),
            data.get("sku"),
            data.get("is_variant", False),
            data.get("stock_control_type", "unit"),
        )

    async def update(self, product_id: str, user_id: str, data: dict) -> asyncpg.Record | None:
        fields = {k: v for k, v in data.items() if v is not None}
        if not fields:
            return await self.get_by_id(product_id, user_id)
        set_clauses = ", ".join(f"{k} = ${i + 3}" for i, k in enumerate(fields))
        values = list(fields.values())
        return await self.fetchrow(
            f"UPDATE products SET {set_clauses} WHERE id = $1 AND user_id = $2 RETURNING *",
            product_id,
            user_id,
            *values,
        )

    async def delete(self, product_id: str, user_id: str) -> str:
        return await self.execute(
            "DELETE FROM products WHERE id = $1 AND user_id = $2",
            product_id,
            user_id,
        )

    async def search_by_sku(self, sku: str, user_id: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            "SELECT * FROM products WHERE sku = $1 AND user_id = $2",
            sku,
            user_id,
        )

    async def search_by_barcode(self, barcode: str, user_id: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            "SELECT * FROM products WHERE barcode = $1 AND user_id = $2",
            barcode,
            user_id,
        )

    async def count_by_org(self, user_id: str) -> int:
        row = await self.fetchrow(
            "SELECT COUNT(*) AS total FROM products WHERE user_id = $1",
            user_id,
        )
        return int(row["total"]) if row else 0
