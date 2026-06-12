from __future__ import annotations

from decimal import Decimal

import asyncpg

from backend.repositories.base import BaseRepository

# C-21 checkpoint #2: products.stock no existe — branch_stock es el único ledger.
# Este RPC aplica deltas validando que el producto pertenezca a la cuenta del caller.
_APPLY_STOCK_DELTA_SQL = (
    "SELECT public.rpc_apply_product_stock_delta("
    "$1::uuid, $2::numeric, $3::uuid, $4::text, $5::boolean, $6::boolean)"
)


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
        # C-21 checkpoint #2: el INSERT no escribe stock (columna eliminada);
        # el stock inicial va a branch_stock vía RPC, todo en una transacción.
        async with self._conn.transaction():
            row = await self.fetchrow(
                """
                INSERT INTO products (user_id, account_id, name, category, price, cost, min_stock,
                                      barcode, sku, parent_id, is_variant, stock_control_type)
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
                RETURNING id
                """,
                user_id,
                account_id,
                data["name"],
                data.get("category"),
                data.get("price"),
                data.get("cost"),
                data.get("min_stock", 0),
                data.get("barcode"),
                data.get("sku"),
                data.get("parent_id"),
                data.get("is_variant", False),
                data.get("stock_control_type", "unit"),
            )
            if row is None:
                return None
            initial_stock = data.get("stock") or Decimal("0")
            if Decimal(str(initial_stock)) != 0:
                await self.fetchrow(
                    _APPLY_STOCK_DELTA_SQL,
                    str(row["id"]), Decimal(str(initial_stock)), None,
                    "Stock inicial", True, False,
                )
            return await self.get_by_id(str(row["id"]), account_id)

    async def update(self, product_id: str, account_id: str, data: dict) -> asyncpg.Record | None:
        fields = {k: v for k, v in data.items() if v is not None}
        # C-21 checkpoint #2: 'stock' no es columna de products — se aplica como
        # delta (target − Σ branch_stock) vía RPC.
        stock_target = fields.pop("stock", None)
        if fields:
            set_clauses = ", ".join(f"{k} = ${i + 3}" for i, k in enumerate(fields))
            values = list(fields.values())
            await self.execute(
                f"UPDATE products SET {set_clauses} WHERE id = $1 AND account_id = $2",
                product_id,
                account_id,
                *values,
            )
        if stock_target is not None:
            current = await self._conn.fetchval(
                "SELECT stock FROM v_products_with_stock WHERE id = $1 AND account_id = $2",
                product_id,
                account_id,
            )
            if current is None:
                return None
            delta = Decimal(str(stock_target)) - Decimal(str(current))
            if delta != 0:
                await self.fetchrow(
                    _APPLY_STOCK_DELTA_SQL,
                    product_id, delta, None,
                    "Ajuste manual de stock", True, False,
                )
        return await self.get_by_id(product_id, account_id)

    async def delete(self, product_id: str, account_id: str) -> str:
        return await self.execute(
            "DELETE FROM products WHERE id = $1 AND account_id = $2",
            product_id,
            account_id,
        )

    async def search_by_sku(self, sku: str, account_id: str) -> asyncpg.Record | None:
        # C-21 checkpoint #2: la vista expone stock = Σ branch_stock (ProductOut lo requiere)
        return await self.fetchrow(
            "SELECT * FROM v_products_with_stock WHERE sku = $1 AND account_id = $2",
            sku,
            account_id,
        )

    async def search_by_barcode(self, barcode: str, account_id: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            "SELECT * FROM v_products_with_stock WHERE barcode = $1 AND account_id = $2",
            barcode,
            account_id,
        )

    async def count_by_org(self, account_id: str) -> int:
        row = await self.fetchrow(
            "SELECT COUNT(*) AS total FROM products WHERE account_id = $1",
            account_id,
        )
        return int(row["total"]) if row else 0
