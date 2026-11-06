"""
productos-padre-variantes — TANDA A, grupo 6: endpoints (tasks 6.1 RED, 6.2 GREEN).

  - `POST /products/{id}/relabel-unit` (D7): `require_account_role(CAN_CONFIGURE)` con 403
    RFC 7807 `insufficient_role` ANTES de llamar la RPC; dry-run y aplicación llaman a
    `rpc_relabel_product_unit`; los errores de la RPC salen por `problem_from_pg_error`
    (`unit_relabel_conflict` 409, `product_not_found` 404, `insufficient_role` 403).
  - `PATCH /products/bulk-price` (D10): 1..500 ids, modo/dirección/valor validados por Pydantic
    (422), rol CAN_CONFIGURE (403 antes de la RPC), la ruta se declara antes de `/{product_id}`;
    un P0400 de la RPC sale como 422 (la regla de rango la repite la base).

Run: python -m pytest backend/tests/test_products_unit_relabel_bulk_price.py -q -p no:cacheprovider
"""
from __future__ import annotations

import json
import uuid
from decimal import Decimal
from unittest.mock import AsyncMock, patch

import asyncpg
import pytest
from pydantic import ValidationError

from backend.tests.conftest import account_roles_fetchval, tenant_token

PRODUCT_ID = "22222222-2222-2222-2222-222222222222"
UNIT_ID = "44444444-4444-4444-4444-444444444444"
ROOT_ID = "33333333-3333-3333-3333-333333333333"

RELABEL_RESULT = {
    "changed": True, "root_id": ROOT_ID, "unit_before": None, "unit_after": UNIT_ID,
    "variants": 3, "variants_with_own_unit": 2, "products_with_stock": 1, "movements": 4,
    "conflict_unit": None,
}
BULK_RESULT = {
    "requested": 2, "eligible": 2, "changed": 2, "unchanged": 0, "skipped_parents": 0, "clamped": 0,
    "sample": [{"id": PRODUCT_ID, "name": "Tomate", "price_before": 1000, "price_after": 1100}],
}


def _pg_error(sqlstate: str, message: str) -> asyncpg.PostgresError:
    err = asyncpg.PostgresError(message)
    err.sqlstate = sqlstate
    return err


def _headers(*roles: str) -> dict:
    return {"Authorization": f"Bearer {tenant_token(list(roles))}"}


def _rpc_calls(conn, rpc: str):
    return [c for c in conn.fetchrow.call_args_list if rpc in c.args[0]]


def _prepare(conn, roles, result):
    conn.fetchval = account_roles_fetchval(list(roles))
    conn.fetchrow = AsyncMock(return_value={"result": json.dumps(result)})


# ── Schemas ─────────────────────────────────────────────────────────────────

class TestRelabelSchemas:
    def test_unit_is_required_and_dry_run_defaults_to_false(self):
        from backend.schemas.products import ProductUnitRelabelIn

        with pytest.raises(ValidationError):
            ProductUnitRelabelIn()
        body = ProductUnitRelabelIn(base_unit_id=UNIT_ID)
        assert body.dry_run is False and str(body.base_unit_id) == UNIT_ID

    def test_out_parses_the_rpc_json(self):
        from backend.schemas.products import ProductUnitRelabelOut

        out = ProductUnitRelabelOut.model_validate(RELABEL_RESULT)
        assert out.changed is True and out.variants == 3 and out.conflict_unit is None


class TestBulkPriceSchemas:
    IDS = [str(uuid.uuid4())]

    def _make(self, **over):
        from backend.schemas.products import ProductBulkPriceIn

        data = {"product_ids": self.IDS, "mode": "percent", "direction": "increase", "value": 10}
        data.update(over)
        return ProductBulkPriceIn(**data)

    def test_valid_payload_defaults(self):
        body = self._make()
        assert body.dry_run is False and body.value == Decimal("10")

    @pytest.mark.parametrize("ids", [[], [str(uuid.uuid4()) for _ in range(501)]])
    def test_ids_between_1_and_500(self, ids):
        with pytest.raises(ValidationError):
            self._make(product_ids=ids)

    def test_exactly_500_ids_is_accepted(self):
        assert len(self._make(product_ids=[str(uuid.uuid4()) for _ in range(500)]).product_ids) == 500

    @pytest.mark.parametrize("over", [{"mode": "fixed"}, {"direction": "up"}, {"value": 0}, {"value": -3}])
    def test_invalid_mode_direction_or_value(self, over):
        with pytest.raises(ValidationError):
            self._make(**over)

    @pytest.mark.parametrize("over", [
        {"direction": "decrease", "value": 95},
        {"direction": "increase", "value": 1500},
    ])
    def test_effective_percentage_out_of_range(self, over):
        with pytest.raises(ValidationError):
            self._make(**over)

    @pytest.mark.parametrize("over", [
        {"direction": "decrease", "value": 90},
        {"direction": "increase", "value": 1000},
        {"mode": "amount", "direction": "decrease", "value": 99999},
    ])
    def test_range_borders_and_amounts_are_accepted(self, over):
        self._make(**over)

    def test_out_parses_the_rpc_json(self):
        from backend.schemas.products import ProductBulkPriceOut

        out = ProductBulkPriceOut.model_validate(BULK_RESULT)
        assert out.changed == 2 and out.sample[0].price_after == Decimal("1100")


# ── Repositorio ─────────────────────────────────────────────────────────────

class TestRepositoryCallsTheRpcs:
    async def test_relabel_unit_calls_the_rpc_with_positional_args(self):
        from backend.repositories.product_repository import ProductRepository

        conn = AsyncMock()
        conn.fetchrow = AsyncMock(return_value={"result": json.dumps(RELABEL_RESULT)})

        out = await ProductRepository(conn).relabel_unit(PRODUCT_ID, UNIT_ID, True)

        sql, *args = conn.fetchrow.call_args.args
        assert "public.rpc_relabel_product_unit($1::uuid, $2::uuid, $3::boolean)" in sql
        assert args == [PRODUCT_ID, UNIT_ID, True]
        assert out["changed"] is True

    async def test_bulk_adjust_prices_calls_the_rpc_with_positional_args(self):
        from backend.repositories.product_repository import ProductRepository

        conn = AsyncMock()
        conn.fetchrow = AsyncMock(return_value={"result": BULK_RESULT})

        out = await ProductRepository(conn).bulk_adjust_prices([PRODUCT_ID], "percent", "increase", Decimal("10"), False)

        sql, *args = conn.fetchrow.call_args.args
        assert "public.rpc_bulk_adjust_prices($1::uuid[], $2::text, $3::text, $4::numeric, $5::boolean)" in sql
        assert args == [[PRODUCT_ID], "percent", "increase", Decimal("10"), False]
        assert out["changed"] == 2


# ── POST /products/{id}/relabel-unit ────────────────────────────────────────

class TestRelabelEndpoint:
    async def _post(self, async_client, pool, roles, body):
        with patch("backend.core.database.pool", pool):
            return await async_client.post(
                f"/products/{PRODUCT_ID}/relabel-unit", json=body, headers=_headers(*roles),
            )

    async def test_dry_run_calls_the_rpc_and_returns_the_impact(self, async_client, mock_pool):
        pool, conn = mock_pool
        _prepare(conn, ["owner"], RELABEL_RESULT)

        resp = await self._post(async_client, pool, ["owner"], {"base_unit_id": UNIT_ID, "dry_run": True})

        assert resp.status_code == 200
        body = resp.json()
        assert body["changed"] is True and body["variants"] == 3 and body["movements"] == 4
        (call,) = _rpc_calls(conn, "rpc_relabel_product_unit")
        assert call.args[1:] == (PRODUCT_ID, UNIT_ID, True)

    async def test_apply_passes_dry_run_false(self, async_client, mock_pool):
        pool, conn = mock_pool
        _prepare(conn, ["admin"], RELABEL_RESULT)

        resp = await self._post(async_client, pool, ["admin"], {"base_unit_id": UNIT_ID})

        assert resp.status_code == 200
        (call,) = _rpc_calls(conn, "rpc_relabel_product_unit")
        assert call.args[3] is False

    @pytest.mark.parametrize("roles", [["stock"], ["cashier"], ["seller"], ["viewer"]])
    async def test_role_without_configure_capability_is_403_before_the_rpc(self, async_client, mock_pool, roles):
        pool, conn = mock_pool
        _prepare(conn, roles, RELABEL_RESULT)

        resp = await self._post(async_client, pool, roles, {"base_unit_id": UNIT_ID})

        assert resp.status_code == 403
        assert resp.json()["code"] == "insufficient_role"
        assert _rpc_calls(conn, "rpc_relabel_product_unit") == []

    @pytest.mark.parametrize("sqlstate, message, status, code", [
        ("P0409", "unit_relabel_conflict: la familia tiene operaciones cargadas en g", 409, "unit_relabel_conflict"),
        ("P0404", "product_not_found: el producto no existe o no pertenece a tu cuenta", 404, "product_not_found"),
        ("P0404", "base_unit_not_found: la unidad no existe o no pertenece a tu cuenta", 404, "base_unit_not_found"),
        ("P0403", "insufficient_role: tu rol no permite corregir la unidad de medida", 403, "insufficient_role"),
    ])
    async def test_rpc_errors_become_stable_problems(self, async_client, mock_pool, sqlstate, message, status, code):
        pool, conn = mock_pool
        conn.fetchval = account_roles_fetchval(["owner"])
        conn.fetchrow = AsyncMock(side_effect=_pg_error(sqlstate, message))

        resp = await self._post(async_client, pool, ["owner"], {"base_unit_id": UNIT_ID})

        assert resp.status_code == status
        assert resp.json()["code"] == code

    async def test_body_without_unit_is_422(self, async_client, mock_pool):
        pool, conn = mock_pool
        _prepare(conn, ["owner"], RELABEL_RESULT)

        resp = await self._post(async_client, pool, ["owner"], {})

        assert resp.status_code == 422
        assert _rpc_calls(conn, "rpc_relabel_product_unit") == []

    async def test_unmapped_sqlstate_is_not_swallowed(self, async_client, mock_pool):
        """Control: un error que no es de negocio no se convierte en un problema falso."""
        from backend.services import products as svc

        conn = AsyncMock()
        conn.fetchval = account_roles_fetchval(["owner"])
        repo = AsyncMock()
        repo.relabel_unit.side_effect = _pg_error("XX000", "boom")

        with pytest.raises(asyncpg.PostgresError):
            await svc.relabel_product_unit(
                repo, {"role": "user", "user_id": "u", "app_metadata": {}}, conn, PRODUCT_ID, UNIT_ID, False,
            )


# ── PATCH /products/bulk-price ──────────────────────────────────────────────

class TestBulkPriceEndpoint:
    BODY = {"product_ids": [PRODUCT_ID], "mode": "percent", "direction": "increase", "value": 10}

    async def _patch(self, async_client, pool, roles, body):
        with patch("backend.core.database.pool", pool):
            return await async_client.patch("/products/bulk-price", json=body, headers=_headers(*roles))

    async def test_preview_and_apply_call_the_rpc(self, async_client, mock_pool):
        pool, conn = mock_pool
        _prepare(conn, ["owner"], BULK_RESULT)

        resp = await self._patch(async_client, pool, ["owner"], {**self.BODY, "dry_run": True})

        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["changed"] == 2 and body["skipped_parents"] == 0
        assert Decimal(str(body["sample"][0]["price_before"])) == 1000 and Decimal(str(body["sample"][0]["price_after"])) == 1100
        (call,) = _rpc_calls(conn, "rpc_bulk_adjust_prices")
        ids, mode, direction, value, dry_run = call.args[1:]
        assert [str(i) for i in ids] == [PRODUCT_ID] and (mode, direction, dry_run) == ("percent", "increase", True)
        assert Decimal(str(value)) == Decimal("10")

    async def test_the_route_is_declared_before_the_id_routes(self, async_client, mock_pool):
        """Si `/{product_id}` se declarara antes, "bulk-price" se leería como un id."""
        pool, conn = mock_pool
        _prepare(conn, ["owner"], BULK_RESULT)

        resp = await self._patch(async_client, pool, ["owner"], self.BODY)

        assert resp.status_code == 200
        assert _rpc_calls(conn, "rpc_bulk_adjust_prices")[0].args[5] is False

    @pytest.mark.parametrize("roles", [["seller"], ["stock"], ["cashier"], ["viewer"]])
    async def test_role_without_configure_capability_is_403_before_the_rpc(self, async_client, mock_pool, roles):
        pool, conn = mock_pool
        _prepare(conn, roles, BULK_RESULT)

        resp = await self._patch(async_client, pool, roles, self.BODY)

        assert resp.status_code == 403
        assert resp.json()["code"] == "insufficient_role"
        assert _rpc_calls(conn, "rpc_bulk_adjust_prices") == []

    @pytest.mark.parametrize("over", [
        {"product_ids": []},
        {"product_ids": [str(uuid.uuid4()) for _ in range(501)]},
        {"mode": "fixed"},
        {"direction": "up"},
        {"value": 0},
        {"direction": "decrease", "value": 95},
        {"direction": "increase", "value": 1500},
    ])
    async def test_invalid_payload_is_422_without_calling_the_rpc(self, async_client, mock_pool, over):
        pool, conn = mock_pool
        _prepare(conn, ["owner"], BULK_RESULT)

        resp = await self._patch(async_client, pool, ["owner"], {**self.BODY, **over})

        assert resp.status_code == 422
        assert _rpc_calls(conn, "rpc_bulk_adjust_prices") == []

    async def test_rpc_validation_error_is_422_and_keeps_its_code(self, async_client, mock_pool):
        """La base repite la regla (defensa en profundidad): su P0400 sale como 422, no 400."""
        pool, conn = mock_pool
        conn.fetchval = account_roles_fetchval(["owner"])
        conn.fetchrow = AsyncMock(side_effect=_pg_error("P0400", "bulk_price_out_of_range: el porcentaje tiene que estar entre"))

        resp = await self._patch(async_client, pool, ["owner"], self.BODY)

        assert resp.status_code == 422
        assert resp.json()["code"] == "bulk_price_out_of_range"

    async def test_rpc_role_error_is_403(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchval = account_roles_fetchval(["owner"])
        conn.fetchrow = AsyncMock(side_effect=_pg_error("P0403", "insufficient_role: tu rol no permite modificar precios en lote"))

        resp = await self._patch(async_client, pool, ["owner"], self.BODY)

        assert resp.status_code == 403
        assert resp.json()["code"] == "insufficient_role"
