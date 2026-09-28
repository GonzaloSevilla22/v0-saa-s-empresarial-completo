"""
balanza-etiquetas-pos — grupo 2: `scale_plu` en productos (tasks 2.1 RED,
2.3 TRIANGULATE).

Contrato (spec product-sku + design D2/D13/D14):
  - `ProductCreate.scale_plu` opcional, entero 1..999.999 (422 fuera de rango).
  - `ProductUpdate.scale_plu` TRI-ESTADO por AUSENCIA de la clave
    (`model_fields_set`, nunca `is None`): ausente conserva, valor asigna,
    `null` desasigna.
  - 23505 de `idx_products_scale_plu_account_unique` → 409 que nombra el código.
  - Un `variant_only` no admite PLU: 422 legible ANTES de escribir, y el 23514
    de `products_scale_plu_not_parent` (la regla vive en la base) → 422.
  - `ProductOut` sin la clave deserializa con `scale_plu = None`.
  - El REPOSITORY persiste de verdad: el INSERT de `create()` lleva la columna
    y el valor; `update()` con `scale_plu = None` escribe el NULL (antes el
    INSERT tenía lista fija de columnas y el UPDATE descartaba los `None`).
  - Import: `scale_plu` viaja a la RPC; un error de fila vuelve con su `row`
    y el mensaje con el código.

Run: python -m pytest backend/tests/test_products_scale_plu.py -q -p no:cacheprovider
"""
from __future__ import annotations

import json
from unittest.mock import AsyncMock, MagicMock, patch

import asyncpg
import pytest
from pydantic import ValidationError

from backend.tests.conftest import make_token

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
PRODUCT_ID = "22222222-2222-2222-2222-222222222222"
USER_ID = "11111111-1111-1111-1111-111111111111"

PRODUCT_ROW = {
    "id": PRODUCT_ID,
    "user_id": USER_ID,
    "name": "Tomate",
    "category": None,
    "category_id": None,
    "price": "4.8000",
    "cost": None,
    "stock": "10.0000",
    "min_stock": 0,
    "barcode": None,
    "sku": "TOM-01",
    "parent_id": None,
    "is_variant": False,
    "base_unit_id": None,
    "stock_control_type": "tracked",
    "created_at": "2026-09-28T08:00:00",
    "scale_plu": 509,
}
PARENT_ROW = {**PRODUCT_ROW, "stock_control_type": "variant_only", "scale_plu": None}


def _owner() -> str:
    return make_token({"role": "user", "app_metadata": {"account_role": "owner"}})


def _unique(constraint: str) -> asyncpg.UniqueViolationError:
    err = asyncpg.UniqueViolationError("duplicate key value violates unique constraint")
    err.constraint_name = constraint
    return err


def _check(constraint: str) -> asyncpg.CheckViolationError:
    err = asyncpg.CheckViolationError("new row violates check constraint")
    err.constraint_name = constraint
    return err


def _raise_on_update(exc):
    """Sólo el UPDATE de products falla: la dependencia de conexión también usa
    `execute` (claims, rol) y no debe verse afectada."""
    async def _execute(query, *args):
        if "UPDATE products" in query:
            raise exc
        return "SET"
    return _execute


def _update_call(conn):
    for call in conn.execute.call_args_list:
        if "UPDATE products" in call.args[0]:
            return call
    return None


def _create_side_effect(*, insert_raises=None, returned=PRODUCT_ROW):
    async def fetchrow_side_effect(query, *args):
        if "plan_limits" in query:
            return {"max_products": 100, "max_clients": 50, "max_suppliers": 20}
        if "COUNT" in query:
            return {"total": 5}
        if "INSERT INTO products" in query:
            if insert_raises is not None:
                raise insert_raises
            return {"id": PRODUCT_ID}
        return returned
    return fetchrow_side_effect


def _insert_call(conn):
    for call in conn.fetchrow.call_args_list:
        if "INSERT INTO products" in call.args[0]:
            return call
    return None


# ── Schemas ─────────────────────────────────────────────────────────────────

class TestScalePluSchemas:
    def test_create_accepts_plu_in_range(self):
        from backend.schemas.products import ProductCreate

        assert ProductCreate(name="Tomate", scale_plu=509).scale_plu == 509
        assert ProductCreate(name="Tomate", scale_plu=999999).scale_plu == 999999
        assert ProductCreate(name="Tomate").scale_plu is None

    @pytest.mark.parametrize("bad", [0, -1, 1000000])
    def test_create_rejects_plu_out_of_range(self, bad):
        from backend.schemas.products import ProductCreate

        with pytest.raises(ValidationError):
            ProductCreate(name="Tomate", scale_plu=bad)

    @pytest.mark.parametrize("bad", [0, 1000000])
    def test_update_rejects_plu_out_of_range(self, bad):
        from backend.schemas.products import ProductUpdate

        with pytest.raises(ValidationError):
            ProductUpdate(scale_plu=bad)

    def test_update_distinguishes_absent_from_null(self):
        from backend.schemas.products import ProductUpdate

        assert "scale_plu" not in ProductUpdate(price=10).model_fields_set
        assert "scale_plu" in ProductUpdate(scale_plu=None).model_fields_set

    def test_product_out_without_key_deserializes_to_none(self):
        from backend.schemas.products import ProductOut

        row = {k: v for k, v in PRODUCT_ROW.items() if k != "scale_plu"}
        assert ProductOut.model_validate(row).scale_plu is None
        assert ProductOut.model_validate(PRODUCT_ROW).scale_plu == 509

    @pytest.mark.parametrize("bad", [0, 1000000])
    def test_import_row_rejects_plu_out_of_range(self, bad):
        from backend.schemas.products import ProductImportRowIn

        with pytest.raises(ValidationError):
            ProductImportRowIn(row_no=1, name="Tomate", scale_plu=bad)

    def test_import_row_plu_optional(self):
        from backend.schemas.products import ProductImportRowIn

        assert ProductImportRowIn(row_no=1, name="Tomate").scale_plu is None
        assert ProductImportRowIn(row_no=1, name="Tomate", scale_plu=261).scale_plu == 261


# ── Repository: persiste de verdad ──────────────────────────────────────────

def _repo_with_conn():
    from backend.repositories.product_repository import ProductRepository

    conn = AsyncMock()
    tx = AsyncMock()
    tx.__aenter__ = AsyncMock(return_value=None)
    tx.__aexit__ = AsyncMock(return_value=False)
    conn.transaction = MagicMock(return_value=tx)
    conn.fetchrow = AsyncMock(side_effect=[{"id": PRODUCT_ID}, PRODUCT_ROW])
    conn.execute = AsyncMock(return_value="UPDATE 1")
    return ProductRepository(conn), conn


class TestScalePluRepository:
    async def test_create_inserts_scale_plu_column_and_value(self):
        repo, conn = _repo_with_conn()

        await repo.create(USER_ID, ACCOUNT_ID, {"name": "Tomate", "scale_plu": 509})

        sql, *args = conn.fetchrow.call_args_list[0].args
        assert "INSERT INTO products" in sql
        columns = sql.split("(", 1)[1].split(")", 1)[0]
        assert "scale_plu" in columns, "el INSERT con lista fija de columnas perdía el PLU en silencio"
        position = [c.strip() for c in columns.split(",")].index("scale_plu")
        assert args[position] == 509

    async def test_create_without_plu_inserts_null(self):
        repo, conn = _repo_with_conn()

        await repo.create(USER_ID, ACCOUNT_ID, {"name": "Tomate"})

        sql, *args = conn.fetchrow.call_args_list[0].args
        columns = [c.strip() for c in sql.split("(", 1)[1].split(")", 1)[0].split(",")]
        assert "scale_plu" in columns
        assert args[columns.index("scale_plu")] is None

    async def test_update_with_none_clears_the_plu(self):
        repo, conn = _repo_with_conn()
        conn.fetchrow = AsyncMock(return_value={**PRODUCT_ROW, "scale_plu": None})

        await repo.update(PRODUCT_ID, ACCOUNT_ID, {"scale_plu": None})

        call = _update_call(conn)
        assert call is not None, "un null explícito de scale_plu debía producir un UPDATE (antes se descartaba)"
        assert "scale_plu = $3" in call.args[0]
        assert call.args[3] is None

    async def test_update_with_value_assigns_the_plu(self):
        repo, conn = _repo_with_conn()
        conn.fetchrow = AsyncMock(return_value=PRODUCT_ROW)

        await repo.update(PRODUCT_ID, ACCOUNT_ID, {"scale_plu": 261})

        call = _update_call(conn)
        assert call is not None and "scale_plu = $3" in call.args[0]
        assert call.args[3] == 261
        assert call.args[1] == PRODUCT_ID and call.args[2] == ACCOUNT_ID


# ── Alta (POST /products) ───────────────────────────────────────────────────

class TestCreateWithScalePlu:
    async def test_create_persists_plu(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(side_effect=_create_side_effect())
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products", json={"name": "Tomate", "scale_plu": 509},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 201
        assert resp.json()["scale_plu"] == 509
        assert 509 in _insert_call(conn).args[1:]

    async def test_create_out_of_range_is_422(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(side_effect=_create_side_effect())
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products", json={"name": "Tomate", "scale_plu": 1000000},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 422
        assert _insert_call(conn) is None

    async def test_create_duplicate_plu_is_409_naming_code(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(
            side_effect=_create_side_effect(insert_raises=_unique("idx_products_scale_plu_account_unique"))
        )
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products", json={"name": "Tomate", "scale_plu": 509},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 409
        body = resp.json()
        assert "509" in body["detail"]
        assert body.get("field") == "scale_plu"

    async def test_create_variant_only_with_plu_is_422_before_writing(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(side_effect=_create_side_effect())
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products",
                json={"name": "Remera", "stock_control_type": "variant_only", "scale_plu": 509},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 422
        assert "variante" in resp.json()["detail"]
        assert _insert_call(conn) is None

    async def test_create_check_violation_from_db_is_422(self, async_client, mock_pool):
        """La base es la fuente de verdad: si el 23514 del CHECK llega igual
        (carrera, camino no cubierto por el guard previo), sale 422 legible."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(
            side_effect=_create_side_effect(insert_raises=_check("products_scale_plu_not_parent"))
        )
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products", json={"name": "Tomate", "scale_plu": 509},
                headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 422
        assert "variante" in resp.json()["detail"]


# ── Edición (PUT /products/{id}) ────────────────────────────────────────────

class TestUpdateScalePluTriState:
    async def _put(self, async_client, pool, body):
        with patch("backend.core.database.pool", pool):
            return await async_client.put(
                f"/products/{PRODUCT_ID}", json=body,
                headers={"Authorization": f"Bearer {_owner()}"},
            )

    async def test_absent_preserves(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=PRODUCT_ROW)
        resp = await self._put(async_client, pool, {"price": 5})
        assert resp.status_code == 200
        call = _update_call(conn)
        assert call is not None and "scale_plu" not in call.args[0]

    async def test_value_assigns(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value={**PRODUCT_ROW, "scale_plu": None})
        resp = await self._put(async_client, pool, {"scale_plu": 261})
        assert resp.status_code == 200
        call = _update_call(conn)
        assert call is not None and "scale_plu = $" in call.args[0]
        assert 261 in call.args[1:]

    async def test_null_clears(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=PRODUCT_ROW)
        resp = await self._put(async_client, pool, {"scale_plu": None})
        assert resp.status_code == 200
        call = _update_call(conn)
        assert call is not None and "scale_plu = $" in call.args[0]
        assert call.args[3:] == (None,)

    async def test_duplicate_is_409_naming_code(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value={**PRODUCT_ROW, "scale_plu": None})
        conn.execute = AsyncMock(side_effect=_raise_on_update(_unique("idx_products_scale_plu_account_unique")))
        resp = await self._put(async_client, pool, {"scale_plu": 509})
        assert resp.status_code == 409
        assert "509" in resp.json()["detail"]

    async def test_assign_to_variant_only_is_422_without_update(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=PARENT_ROW)
        resp = await self._put(async_client, pool, {"scale_plu": 509})
        assert resp.status_code == 422
        assert "variante" in resp.json()["detail"]
        assert _update_call(conn) is None

    async def test_convert_to_variant_only_with_plu_is_422(self, async_client, mock_pool):
        """Un producto con PLU que pasa a padre: el service lee `existing`
        también cuando cambia stock_control_type."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=PRODUCT_ROW)
        resp = await self._put(async_client, pool, {"stock_control_type": "variant_only"})
        assert resp.status_code == 422
        assert _update_call(conn) is None

    async def test_convert_to_variant_only_clearing_plu_passes(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=PRODUCT_ROW)
        resp = await self._put(async_client, pool, {"stock_control_type": "variant_only", "scale_plu": None})
        assert resp.status_code == 200
        call = _update_call(conn)
        assert call is not None and "scale_plu = $" in call.args[0]

    async def test_clear_plu_on_variant_only_passes(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=PARENT_ROW)
        resp = await self._put(async_client, pool, {"scale_plu": None})
        assert resp.status_code == 200

    async def test_check_violation_from_db_is_422(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value={**PRODUCT_ROW, "scale_plu": None})
        conn.execute = AsyncMock(side_effect=_raise_on_update(_check("products_scale_plu_not_parent")))
        resp = await self._put(async_client, pool, {"scale_plu": 509})
        assert resp.status_code == 422
        assert "variante" in resp.json()["detail"]

    async def test_get_returns_plu(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=PRODUCT_ROW)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/products/{PRODUCT_ID}", headers={"Authorization": f"Bearer {_owner()}"},
            )
        assert resp.status_code == 200
        assert resp.json()["scale_plu"] == 509


# ── Import (2.3 TRIANGULATE) ────────────────────────────────────────────────

def _rpc_row(result: dict) -> dict:
    return {"result": json.dumps(result)}


_IMPORT_BASE = {
    "import_id": None, "inserted": 0, "updated": 0, "new_categories": [],
    "plan": None, "replayed": False, "dry_run": False,
}


class TestImportScalePlu:
    async def test_plu_travels_to_rpc(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=_rpc_row({**_IMPORT_BASE, "committed": True, "inserted": 2, "errors": []}))
        payload = {
            "file_name": "f.csv", "file_hash": "h",
            "rows": [
                {"row_no": 1, "name": "Zanahoria", "scale_plu": 261},
                {"row_no": 2, "name": "Papa"},
            ],
        }
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products/import", json=payload,
                headers={"Authorization": f"Bearer {make_token({'role': 'user'})}", "Idempotency-Key": "k-plu"},
            )
        assert resp.status_code == 200
        rows_sent = json.loads(conn.fetchrow.call_args.args[2])
        assert rows_sent[0]["scale_plu"] == 261
        # Ausente viaja como null: la RPC lo lee como ausencia (COALESCE conserva).
        assert rows_sent[1]["scale_plu"] is None

    async def test_row_error_names_code(self, async_client, mock_pool):
        pool, conn = mock_pool
        rejected = {
            **_IMPORT_BASE, "committed": False,
            "errors": [{"row": 2, "sku": "CEB", "name": "Cebolla",
                        "message": "El código de balanza 509 ya lo usa otro producto de tu cuenta"}],
        }
        conn.fetchrow = AsyncMock(return_value=_rpc_row(rejected))
        payload = {
            "file_name": "f.csv", "file_hash": "h",
            "rows": [{"row_no": 1, "name": "Batata"}, {"row_no": 2, "name": "Cebolla", "sku": "CEB", "scale_plu": 509}],
        }
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products/import", json=payload,
                headers={"Authorization": f"Bearer {make_token({'role': 'user'})}", "Idempotency-Key": "k-plu-2"},
            )
        assert resp.status_code == 200
        body = resp.json()
        assert body["committed"] is False
        assert body["errors"][0]["row"] == 2
        assert "509" in body["errors"][0]["message"]

    async def test_out_of_range_plu_in_import_is_422(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=_rpc_row({**_IMPORT_BASE, "committed": True, "errors": []}))
        payload = {"file_name": "f.csv", "file_hash": "h", "rows": [{"row_no": 1, "name": "X", "scale_plu": 0}]}
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products/import", json=payload,
                headers={"Authorization": f"Bearer {make_token({'role': 'user'})}", "Idempotency-Key": "k-plu-3"},
            )
        assert resp.status_code == 422
        conn.fetchrow.assert_not_awaited()
