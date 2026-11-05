"""
productos-padre-variantes — TANDA A, grupo 3: contrato del padre y herencia de la variante
(tasks 3.1 RED, 3.3 RED).

Contrato (specs product-variants + product-sku + product-category, design D1/D2/D3/D4):
  - `POST /products` con `stock_control_type = 'variant_only'` responde 422
    `parent_field_not_allowed` (con `field`) si informa precio != 0, costo no nulo,
    stock != 0, SKU no vacío, código de barras no vacío o `parent_id`, ANTES de
    contar el plan o escribir nada.
  - `min_stock` en el ALTA de un padre se TOLERA y se neutraliza a 0 (ver
    `design.md`, «Notas de implementación de la tanda A», DV-1): el formulario
    anterior lo manda siempre (default 10) y rechazarlo rompería el alta de padres
    hasta que llegue la tanda B.
  - `PUT /products/{id}` sobre un `variant_only` acepta el valor VIGENTE y el
    neutro (0 / nulo / vacío) y rechaza un valor distinto; el costo 0 se escribe
    como NULL (el CHECK de la base exige NULL).
  - `PUT` no cambia `stock_control_type` hacia o desde `variant_only`
    (422 `stock_control_type_locked`); el mismo tipo se acepta.
  - El alta de una variante deja `base_unit_id` NULL (hereda del padre); la edición
    de una variante ignora `base_unit_id` sin validarlo ni escribirlo.
  - El 23514 de `products_variant_only_no_price_cost` sale como el mismo 422.

Run: python -m pytest backend/tests/test_products_padre_variantes.py -q -p no:cacheprovider
"""
from __future__ import annotations

import uuid
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock

import asyncpg
import pytest

from backend.core.errors import ProblemHTTPException
from backend.schemas.products import ProductCreate, ProductUpdate
from backend.services import products as svc

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
PARENT_ID = "33333333-3333-3333-3333-333333333333"
PRODUCT_ID = "22222222-2222-2222-2222-222222222222"
USER_ID = "11111111-1111-1111-1111-111111111111"
KG_UNIT = uuid.UUID("44444444-4444-4444-4444-444444444444")

AUTH = {"role": "user", "user_id": USER_ID, "plan": "pro"}

PARENT_ROW = {
    "id": PARENT_ID, "name": "Remera", "category_id": uuid.UUID("55555555-5555-5555-5555-555555555555"),
    "price": Decimal("0"), "cost": None, "stock": Decimal("0"), "min_stock": 10, "barcode": "7790001",
    "sku": None, "parent_id": None, "is_variant": False, "stock_control_type": "variant_only",
    "base_unit_id": None, "scale_plu": None,
}
SIMPLE_ROW = {**PARENT_ROW, "id": PRODUCT_ID, "stock_control_type": "tracked", "price": Decimal("100"),
              "cost": Decimal("50"), "barcode": None}
VARIANT_ROW = {**SIMPLE_ROW, "parent_id": PARENT_ID, "is_variant": True}


def _repos(existing=None):
    repo = MagicMock()
    repo.create = AsyncMock(return_value={"id": PRODUCT_ID})
    repo.update = AsyncMock(return_value={"id": PRODUCT_ID})
    repo.get_by_id = AsyncMock(return_value=existing)
    repo.count_by_org = AsyncMock(return_value=1)
    repo.unit_visible_to_account = AsyncMock(return_value=True)
    repo.has_stock_or_movements = AsyncMock(return_value=False)
    repo.has_lines_in_other_unit = AsyncMock(return_value=False)
    plan_repo = MagicMock()
    plan_repo.get_limits = AsyncMock(return_value={"max_products": 100})
    return repo, plan_repo


async def _create(payload: ProductCreate, repo, plan_repo):
    return await svc.create_product(repo, AUTH, ACCOUNT_ID, payload, plan_repo, MagicMock())


async def _update(payload: ProductUpdate, repo, **provided):
    return await svc.update_product(repo, AUTH, ACCOUNT_ID, PRODUCT_ID, payload, **provided)


def _check(constraint: str) -> asyncpg.CheckViolationError:
    err = asyncpg.CheckViolationError("new row violates check constraint")
    err.constraint_name = constraint
    return err


# ── 3.1 Alta de un padre: el contrato ───────────────────────────────────────

class TestParentCreateContract:
    @pytest.mark.parametrize(
        "field, kwargs",
        [
            ("price", {"price": Decimal("1500")}),
            ("cost", {"cost": Decimal("800")}),
            ("cost", {"cost": Decimal("0")}),
            ("stock", {"stock": Decimal("10")}),
            ("sku", {"sku": "REM-1"}),
            ("barcode", {"barcode": "7790001"}),
            ("parent_id", {"parent_id": PARENT_ID}),
        ],
    )
    async def test_parent_with_forbidden_field_is_422_before_writing(self, field, kwargs):
        repo, plan_repo = _repos()
        payload = ProductCreate(name="Remera", stock_control_type="variant_only", **kwargs)

        with pytest.raises(ProblemHTTPException) as exc:
            await _create(payload, repo, plan_repo)

        assert exc.value.status_code == 422
        assert exc.value.code == "parent_field_not_allowed"
        assert exc.value.field == field
        repo.create.assert_not_awaited()
        plan_repo.get_limits.assert_not_awaited()  # antes de contar el plan o escribir nada

    async def test_parent_with_only_neutral_values_is_created_without_price_cost(self):
        repo, plan_repo = _repos()
        payload = ProductCreate(
            name="Remera", stock_control_type="variant_only", price=Decimal("0"), cost=None,
            sku="   ", barcode="", stock=Decimal("0"),
        )

        await _create(payload, repo, plan_repo)

        data = repo.create.await_args.args[2]
        assert data["stock_control_type"] == "variant_only"
        assert not data.get("price")
        assert data.get("cost") is None
        assert data["sku"] is None

    async def test_parent_min_stock_is_tolerated_and_neutralised(self):
        """DV-1: el formulario anterior manda minStock = 10 al crear un padre."""
        repo, plan_repo = _repos()
        payload = ProductCreate(name="Remera", stock_control_type="variant_only", min_stock=Decimal("10"))

        await _create(payload, repo, plan_repo)

        assert repo.create.await_args.args[2]["min_stock"] == 0

    async def test_simple_product_keeps_every_field(self):
        """Control: un producto que NO es padre conserva precio, costo, stock, SKU y código."""
        repo, plan_repo = _repos()
        payload = ProductCreate(
            name="Gaseosa", stock_control_type="tracked", price=Decimal("1500"), cost=Decimal("800"),
            sku="GAS-1", barcode="779", min_stock=Decimal("3"),
        )
        conn = MagicMock()

        await svc.create_product(repo, AUTH, ACCOUNT_ID, payload, plan_repo, MagicMock(), conn=conn)

        data = repo.create.await_args.args[2]
        assert data["price"] == Decimal("1500") and data["cost"] == Decimal("800")
        assert data["sku"] == "GAS-1" and data["barcode"] == "779" and data["min_stock"] == Decimal("3")


# ── 3.1 Variante: hereda la unidad ──────────────────────────────────────────

class TestVariantInheritsUnit:
    async def test_variant_create_ignores_the_informed_unit(self):
        repo, plan_repo = _repos(existing=PARENT_ROW)
        payload = ProductCreate(
            name="Remera roja", parent_id=PARENT_ID, is_variant=True, stock_control_type="tracked",
            base_unit_id=KG_UNIT, price=Decimal("1200"), cost=Decimal("700"),
        )

        await _create(payload, repo, plan_repo)

        data = repo.create.await_args.args[2]
        assert data["base_unit_id"] is None, "la variante hereda por COALESCE(propia, padre): NULL"
        repo.unit_visible_to_account.assert_not_awaited()
        # la variante conserva su precio y costo propios: no hay herencia de precio
        assert data["price"] == Decimal("1200") and data["cost"] == Decimal("700")

    async def test_non_variant_create_still_resolves_and_keeps_its_unit(self):
        repo, plan_repo = _repos()
        payload = ProductCreate(name="Tomate", stock_control_type="tracked", base_unit_id=KG_UNIT)

        await _create(payload, repo, plan_repo)

        assert repo.create.await_args.args[2]["base_unit_id"] == str(KG_UNIT)
        repo.unit_visible_to_account.assert_awaited_once()

    async def test_variant_update_ignores_the_informed_unit(self):
        repo, _ = _repos(existing=VARIANT_ROW)
        payload = ProductUpdate(name="Remera roja", base_unit_id=KG_UNIT)

        await _update(payload, repo, base_unit_provided=True)

        data = repo.update.await_args.args[2]
        assert "base_unit_id" not in data
        repo.unit_visible_to_account.assert_not_awaited()
        repo.has_stock_or_movements.assert_not_awaited()  # ni siquiera pasa por el guard de unidad
        repo.has_lines_in_other_unit.assert_not_awaited()

    async def test_variant_update_with_null_unit_is_also_ignored(self):
        repo, _ = _repos(existing=VARIANT_ROW)

        await _update(ProductUpdate(name="x", base_unit_id=None), repo, base_unit_provided=True)

        assert "base_unit_id" not in repo.update.await_args.args[2]

    async def test_non_variant_update_still_validates_and_writes_its_unit(self):
        repo, _ = _repos(existing=SIMPLE_ROW)

        await _update(ProductUpdate(base_unit_id=KG_UNIT), repo, base_unit_provided=True)

        assert repo.update.await_args.args[2]["base_unit_id"] == str(KG_UNIT)
        repo.unit_visible_to_account.assert_awaited_once()


# ── 3.3 Edición de un padre ─────────────────────────────────────────────────

class TestParentUpdateContract:
    async def test_old_form_payload_with_current_and_neutral_values_is_accepted(self):
        """Compatibilidad con el formulario anterior: manda el valor vigente en cada guardado."""
        repo, _ = _repos(existing=PARENT_ROW)
        payload = ProductUpdate(
            name="Remera nueva", barcode="7790001", price=Decimal("0"), min_stock=Decimal("10"),
            stock_control_type="variant_only", stock=Decimal("0"),
        )

        await _update(payload, repo)

        data = repo.update.await_args.args[2]
        assert data["name"] == "Remera nueva" and data["barcode"] == "7790001"

    @pytest.mark.parametrize(
        "field, payload_kwargs, provided",
        [
            ("price", {"price": Decimal("1500")}, {}),
            ("barcode", {"barcode": "9999999"}, {}),
            ("min_stock", {"min_stock": Decimal("5")}, {}),
            ("sku", {"sku": "REM-1"}, {"sku_provided": True}),
            ("cost", {"cost": Decimal("5")}, {"cost_provided": True}),
        ],
    )
    async def test_a_different_value_is_422_and_nothing_is_written(self, field, payload_kwargs, provided):
        repo, _ = _repos(existing=PARENT_ROW)

        with pytest.raises(ProblemHTTPException) as exc:
            await _update(ProductUpdate(name="x", **payload_kwargs), repo, **provided)

        assert exc.value.status_code == 422
        assert exc.value.code == "parent_field_not_allowed"
        assert exc.value.field == field
        repo.update.assert_not_awaited()

    async def test_clearing_values_is_accepted(self):
        repo, _ = _repos(existing={**PARENT_ROW, "sku": "OLD", "cost": None})

        await _update(ProductUpdate(name="x", sku=None, cost=None, barcode=""), repo, sku_provided=True, cost_provided=True)

        data = repo.update.await_args.args[2]
        assert data["sku"] is None and data["cost"] is None

    async def test_cost_zero_on_a_parent_is_written_as_null(self):
        """El CHECK de la base exige cost NULL: el neutro 0 se normaliza a NULL."""
        repo, _ = _repos(existing=PARENT_ROW)

        await _update(ProductUpdate(name="x", cost=Decimal("0")), repo, cost_provided=True)

        assert repo.update.await_args.args[2]["cost"] is None

    async def test_current_legacy_sku_is_accepted_when_resent(self):
        repo, _ = _repos(existing={**PARENT_ROW, "sku": "LEGACY"})

        await _update(ProductUpdate(name="x", sku="LEGACY"), repo, sku_provided=True)

        assert repo.update.await_args.args[2]["sku"] == "LEGACY"

    async def test_non_parent_update_is_not_restricted(self):
        """Control: un producto simple edita precio, costo, SKU y código sin restricción."""
        repo, _ = _repos(existing=SIMPLE_ROW)

        await _update(
            ProductUpdate(price=Decimal("999"), cost=Decimal("400"), sku="X-1", barcode="123"),
            repo, sku_provided=True, cost_provided=True,
        )

        data = repo.update.await_args.args[2]
        assert data["price"] == Decimal("999") and data["cost"] == Decimal("400") and data["sku"] == "X-1"


class TestStockControlTypeLocked:
    @pytest.mark.parametrize(
        "existing, new_type",
        [
            (SIMPLE_ROW, "variant_only"),
            ({**SIMPLE_ROW, "stock_control_type": "untracked"}, "variant_only"),
            (PARENT_ROW, "tracked"),
            (PARENT_ROW, "untracked"),
        ],
    )
    async def test_transition_to_or_from_variant_only_is_422(self, existing, new_type):
        repo, _ = _repos(existing=existing)

        with pytest.raises(ProblemHTTPException) as exc:
            await _update(ProductUpdate(stock_control_type=new_type), repo)

        assert exc.value.status_code == 422
        assert exc.value.code == "stock_control_type_locked"
        assert exc.value.field == "stock_control_type"
        repo.update.assert_not_awaited()

    @pytest.mark.parametrize("existing, same_type", [(PARENT_ROW, "variant_only"), (SIMPLE_ROW, "tracked")])
    async def test_sending_the_same_type_is_accepted(self, existing, same_type):
        repo, _ = _repos(existing=existing)

        await _update(ProductUpdate(name="x", stock_control_type=same_type), repo)

        repo.update.assert_awaited_once()

    async def test_changing_between_non_parent_types_is_accepted(self):
        repo, _ = _repos(existing=SIMPLE_ROW)

        await _update(ProductUpdate(stock_control_type="untracked"), repo)

        assert repo.update.await_args.args[2]["stock_control_type"] == "untracked"


# ── 3.3 El 23514 del CHECK de la base ───────────────────────────────────────

class TestCheckViolationTranslation:
    def test_translate_check_violation_maps_the_parent_price_cost_check(self):
        problem = svc._translate_check_violation(_check("products_variant_only_no_price_cost"))

        assert isinstance(problem, ProblemHTTPException)
        assert problem.status_code == 422 and problem.code == "parent_field_not_allowed"

    def test_translate_check_violation_keeps_the_scale_plu_mapping(self):
        problem = svc._translate_check_violation(_check("products_scale_plu_not_parent"))

        assert problem is not None and problem.code == "scale_plu_parent"

    def test_translate_check_violation_ignores_unknown_constraints(self):
        assert svc._translate_check_violation(_check("some_other_check")) is None

    async def test_update_translates_the_database_check(self):
        repo, _ = _repos(existing=SIMPLE_ROW)
        repo.update = AsyncMock(side_effect=_check("products_variant_only_no_price_cost"))

        with pytest.raises(ProblemHTTPException) as exc:
            await _update(ProductUpdate(name="x"), repo)

        assert exc.value.status_code == 422 and exc.value.code == "parent_field_not_allowed"

    async def test_create_translates_the_database_check(self):
        repo, plan_repo = _repos()
        repo.create = AsyncMock(side_effect=_check("products_variant_only_no_price_cost"))

        with pytest.raises(ProblemHTTPException) as exc:
            await _create(ProductCreate(name="x", stock_control_type="tracked"), repo, plan_repo)

        assert exc.value.status_code == 422 and exc.value.code == "parent_field_not_allowed"


# ── Forma HTTP (RFC 7807 con code y field) ──────────────────────────────────

class TestHttpShape:
    async def test_post_parent_with_price_returns_problem_json(self, async_client, mock_pool):
        from unittest.mock import patch

        from backend.tests.conftest import make_token

        pool, conn = mock_pool
        token = make_token({"role": "user", "app_metadata": {"account_role": "owner"}})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products",
                json={"name": "Remera", "stock_control_type": "variant_only", "price": 1500},
                headers={"Authorization": f"Bearer {token}"},
            )

        assert resp.status_code == 422
        body = resp.json()
        assert body["code"] == "parent_field_not_allowed" and body["field"] == "price"
