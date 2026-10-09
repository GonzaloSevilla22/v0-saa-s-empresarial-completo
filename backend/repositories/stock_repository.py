from __future__ import annotations

import asyncpg

from backend.repositories.base import BaseRepository

# stock-ledger-solo-rpc (D10): `adjust_with_event` se RETIRÓ. Era código muerto (sin
# callers) y el único del repo que llamaba a la RPC de delta de stock con
# p_log_movement = FALSE — cambiar el saldo SIN movimiento, que desde la tanda B la
# RPC rechaza con P0400 (el candado de test_products_stock_ledger.py impide que
# el nombre de esa RPC reaparezca fuera de product_repository.py). El evento `StockAdjusted` no tiene consumidor
# (test_journal_consumer.py lo lista como fuera de alcance), así que retirar su
# único productor no deja a nadie sin datos.

class StockRepository(BaseRepository):
    async def get_stock_by_product(self, product_id: str, account_id: str) -> asyncpg.Record | None:
        # C-21: reads from branch_stock (SUM por account_id) en lugar de products.stock.
        # Corrige también la tenancy: usa account_id, no user_id (alineado con C-19).
        # JOIN a products para preservar el 404 si el producto no existe bajo esa cuenta.
        # Si el producto existe pero sin filas branch_stock, COALESCE retorna 0.
        return await self.fetchrow(
            """
            SELECT
                p.id AS product_id,
                COALESCE(
                    (SELECT SUM(bs.quantity)
                     FROM branch_stock bs
                     WHERE bs.product_id = p.id
                       AND bs.account_id = $2),
                    0
                ) AS stock
            FROM products p
            WHERE p.id = $1
              AND p.account_id = $2
              AND p.deleted_at IS NULL
            """,
            product_id,
            account_id,
        )

    async def list_movements(self, product_id: str, account_id: str) -> list[dict]:
        return await self.fetch(
            """
            SELECT sm.* FROM stock_movements sm
            JOIN products p ON p.id = sm.product_id
            WHERE sm.product_id = $1 AND p.account_id = $2
            ORDER BY sm.created_at DESC
            """,
            product_id,
            account_id,
        )

    async def transfer(
        self, from_branch_id: str, to_branch_id: str, product_id: str, quantity: float
    ) -> asyncpg.Record | None:
        return await self.call_rpc(
            "rpc_transfer_stock",
            p_from_branch_id=from_branch_id,
            p_to_branch_id=to_branch_id,
            p_product_id=product_id,
            p_quantity=quantity,
        )

