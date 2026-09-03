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

# branch-min-stock-realign: propaga products.min_stock a TODAS las filas
# branch_stock existentes del producto (semántica "aplica a todas las
# sucursales", decisión PO 2026-07-04). branch_stock.min_stock es la única
# fuente de verdad real del umbral de alerta (trigger check_branch_low_stock);
# products.min_stock queda DEPRECATED (columna legacy, ver COMMENT en la DB).
_SET_MIN_STOCK_SQL = "SELECT public.rpc_set_product_min_stock($1::uuid, $2::int)"

# productos-categorias-sku (D12): columnas que el UPDATE acepta en NULL explícito.
_NULLABLE_ON_UPDATE: frozenset[str] = frozenset({"sku", "category_id"})

# productos-categorias-sku (D14): recategorización en lote como UN SOLO UPDATE.
# `AND p.account_id = $2` ES el guard de tenencia (regla dura: todo repository
# filtra explícito por account_id; la RLS es red). Los ids ajenos no matchean
# el WHERE y no producen error (no revelan existencia). Cada id solicitado se
# normaliza a la RAÍZ de su grupo (COALESCE(parent_id, id)) y la escritura
# alcanza raíz + variantes — el invariante padre→variante no admite un estado
# intermedio (D11). `IS DISTINCT FROM $3` = idempotente y contador honesto.
_BULK_SET_CATEGORY_SQL = """
WITH requested AS (
    SELECT DISTINCT COALESCE(p.parent_id, p.id) AS root_id
      FROM products p
     WHERE p.id = ANY($1::uuid[])
       AND p.account_id = $2
       AND p.deleted_at IS NULL
)
UPDATE products p
   SET category_id = $3
  FROM requested r
 WHERE p.account_id = $2
   AND p.deleted_at IS NULL
   AND (p.id = r.root_id OR p.parent_id = r.root_id)
   AND p.category_id IS DISTINCT FROM $3
"""


class ProductRepository(BaseRepository):
    async def _propagate_min_stock(self, product_id: str, min_stock: int) -> None:
        """branch-min-stock-realign: propaga min_stock a todas las filas
        branch_stock existentes del producto, vía RPC SECURITY DEFINER
        (guard is_account_writer). Debe invocarse dentro de la misma
        transacción asyncpg que create()/update() usan para persistir el
        producto."""
        await self.fetchrow(_SET_MIN_STOCK_SQL, product_id, min_stock)

    async def list_by_org(self, account_id: str) -> list[dict]:
        # C-21: lee de v_products_with_stock para que el campo `stock` refleje
        # COALESCE(Σ branch_stock, 0) en lugar de products.stock.
        # La vista tiene security_invoker=true — respeta RLS.
        # v3-soft-delete-policy: la vista expone deleted_at → filtro RN-B1.
        return await self.fetch(
            "SELECT * FROM v_products_with_stock WHERE account_id = $1"
            + self.not_deleted_clause()
            + " ORDER BY name ASC",
            account_id,
        )

    async def get_by_id(self, product_id: str, account_id: str) -> asyncpg.Record | None:
        # C-21: ídem — usa la vista de compatibilidad para stock consistente.
        return await self.fetchrow(
            "SELECT * FROM v_products_with_stock WHERE id = $1 AND account_id = $2"
            + self.not_deleted_clause(),
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
                                      barcode, sku, parent_id, is_variant, stock_control_type,
                                      category_id)
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
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
                # productos-categorias-sku (D1): fuente de verdad; el trigger de
                # espejo deja products.category con el nombre de la categoría.
                data.get("category_id"),
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
            # branch-min-stock-realign: propagar min_stock DESPUÉS del delta
            # inicial, para que la fila branch_stock recién creada (si hubo
            # stock inicial) ya exista y reciba el min_stock del payload.
            if "min_stock" in data:
                await self._propagate_min_stock(str(row["id"]), int(data.get("min_stock") or 0))
            return await self.get_by_id(str(row["id"]), account_id)

    async def update(self, product_id: str, account_id: str, data: dict) -> asyncpg.Record | None:
        # productos-categorias-sku (D12): `sku` y `category_id` admiten None
        # EXPLÍCITO (= desasignar). El service sólo los incluye en `data`
        # cuando el cliente los mandó (model_fields_set), así que acá "está
        # en data" ya significa "informado". El resto conserva el filtro por
        # None previo (no ampliar el alcance — task 9.4).
        fields = {k: v for k, v in data.items() if v is not None or k in _NULLABLE_ON_UPDATE}
        # C-21 checkpoint #2: 'stock' no es columna de products — se aplica como
        # delta (target − Σ branch_stock) vía RPC.
        stock_target = fields.pop("stock", None)
        # branch-min-stock-realign: min_stock se persiste en products (dual-write
        # legacy) Y se propaga a branch_stock.min_stock (fuente de verdad real)
        # en la MISMA transacción, después del UPDATE de products.
        min_stock_target = fields.get("min_stock")
        if fields:
            set_clauses = ", ".join(f"{k} = ${i + 3}" for i, k in enumerate(fields))
            values = list(fields.values())
            await self.execute(
                f"UPDATE products SET {set_clauses} WHERE id = $1 AND account_id = $2",
                product_id,
                account_id,
                *values,
            )
        if min_stock_target is not None:
            await self._propagate_min_stock(product_id, int(min_stock_target))
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

    async def search_by_sku(self, sku: str, account_id: str) -> asyncpg.Record | None:
        # C-21 checkpoint #2: la vista expone stock = Σ branch_stock (ProductOut lo requiere)
        return await self.fetchrow(
            "SELECT * FROM v_products_with_stock WHERE sku = $1 AND account_id = $2"
            + self.not_deleted_clause(),
            sku,
            account_id,
        )

    async def search_by_barcode(self, barcode: str, account_id: str) -> asyncpg.Record | None:
        return await self.fetchrow(
            "SELECT * FROM v_products_with_stock WHERE barcode = $1 AND account_id = $2"
            + self.not_deleted_clause(),
            barcode,
            account_id,
        )

    async def bulk_set_category(self, product_ids: list[str], account_id: str, category_id: str) -> int:
        """D14: recategoriza en lote (un solo UPDATE, ver _BULK_SET_CATEGORY_SQL)
        y devuelve las filas realmente cambiadas. El trigger de espejo
        (trg_product_category_mirror) deja products.category correcto en
        cada fila tocada — y rechaza con P0404 una categoría de otra cuenta,
        defensa en profundidad detrás de la validación del service."""
        status = await self.execute(_BULK_SET_CATEGORY_SQL, product_ids, account_id, category_id)
        return int(status.rsplit(" ", 1)[-1])

    async def count_by_org(self, account_id: str) -> int:
        # v3-soft-delete-policy: los borrados no cuentan para el límite de plan
        # (borrar libera cupo — coherente con que el SKU se pueda recrear).
        row = await self.fetchrow(
            "SELECT COUNT(*) AS total FROM products WHERE account_id = $1"
            + self.not_deleted_clause(),
            account_id,
        )
        return int(row["total"]) if row else 0
