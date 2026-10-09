"""
stock-ledger-solo-rpc (tanda B, G4/G5 backend) — grupo 10 de tasks.md.

Contrato (spec branch-stock "El formulario de producto no edita el stock",
design D9/D10 y OQ-2):

  - `POST /products` con stock inicial DISTINTO de cero exige `CAN_STOCK`
    (owner/admin/stock) ANTES de escribir nada: 403 y NINGÚN `INSERT`, ni
    siquiera el conteo contra el límite del plan (10.1-10.3).
  - El stock inicial se registra con el motivo fijo "Stock inicial" y los flags
    `(TRUE, FALSE)` — la única combinación que acepta `rpc_apply_product_stock_delta`
    desde la tanda B (10.3).
  - `PUT /products/{id}` NO ajusta stock: un `stock` distinto del saldo actual
    es 422 `stock_adjust_required` sin escribir NADA; el mismo valor se ignora;
    la RPC de ajuste no se llama jamás desde el PUT (10.4/10.5).
  - Candado estructural (10.6): ningún archivo de `backend/` invoca
    `rpc_apply_product_stock_delta` con flags distintos de `TRUE, FALSE`, y su
    único caller es el alta de producto con stock inicial. Reemplaza los tests
    de `StockRepository.adjust_with_event` (código muerto con
    `p_log_movement = FALSE`, retirado).
  - El conjunto `CAN_STOCK` documenta su primer consumidor (10.8).

Run: python -m pytest backend/tests/test_products_stock_ledger.py -q -p no:cacheprovider
"""
from __future__ import annotations

import ast
import re
from decimal import Decimal
from pathlib import Path
from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import make_token

PRODUCT_ID = "22222222-2222-2222-2222-222222222222"
USER_ID = "11111111-1111-1111-1111-111111111111"
BACKEND = Path(__file__).resolve().parents[1]

PRODUCT_ROW = {
    "id": PRODUCT_ID,
    "user_id": USER_ID,
    "name": "Empanada",
    "category": None,
    "category_id": None,
    "price": "150.0000",
    "cost": "80.0000",
    "stock": "25.5000",
    "min_stock": 0,
    "barcode": None,
    "sku": "EMP-001",
    "parent_id": None,
    "is_variant": False,
    "base_unit_id": None,
    "stock_control_type": "tracked",
    "created_at": "2024-01-01T08:00:00",
}


def _token(*roles: str) -> str:
    return make_token({"role": "user", "app_metadata": {"account_roles": list(roles)}})


def _wire(conn) -> list[tuple[str, str, tuple]]:
    """Cablea `conn` para el alta/edición de un producto y devuelve la lista
    (método, query, args) de TODO lo que se ejecutó, en orden."""
    executed: list[tuple[str, str, tuple]] = []

    async def _fetchrow(query, *args):
        executed.append(("fetchrow", query, args))
        if "plan_limits" in query:
            return {"max_products": 100, "max_clients": 50, "max_suppliers": 20}
        if "COUNT" in query:
            return {"total": 3}
        if "INSERT INTO products" in query:
            return {"id": PRODUCT_ID}
        return PRODUCT_ROW

    async def _execute(query, *args):
        executed.append(("execute", query, args))
        return "UPDATE 1"

    async def _fetchval(query, *args):
        executed.append(("fetchval", query, args))
        if "rpc_my_active_account_roles" in query:
            return ["owner"]
        return None

    conn.fetchrow = AsyncMock(side_effect=_fetchrow)
    conn.execute = AsyncMock(side_effect=_execute)
    conn.fetchval = AsyncMock(side_effect=_fetchval)
    return executed


def _stock_rpc_calls(executed) -> list[tuple[str, str, tuple]]:
    return [e for e in executed if "rpc_apply_product_stock_delta" in e[1]]


def _writes(executed) -> list[tuple[str, str, tuple]]:
    return [
        e for e in executed
        if "INSERT INTO products" in e[1] or "UPDATE products" in e[1] or "rpc_apply_product_stock_delta" in e[1]
    ]


# ── 10.1 RED / 10.2 GREEN: el alta con stock exige CAN_STOCK antes de escribir ──


class TestCreateProductInitialStockRole:
    @pytest.mark.asyncio
    @pytest.mark.parametrize("roles", [("seller",), ("cashier",), ("purchases",), ("accountant",), ("viewer",)])
    async def test_roles_without_can_stock_get_403_and_nothing_is_written(self, async_client, mock_pool, roles):
        pool, conn = mock_pool
        executed = _wire(conn)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products",
                json={"name": "Empanada", "stock": 5},
                headers={"Authorization": f"Bearer {_token(*roles)}"},
            )
        assert resp.status_code == 403
        assert "stock" in resp.json()["detail"]
        # Ni el producto, ni la RPC de stock, ni siquiera el conteo contra el
        # límite del plan: el guard va ANTES de cualquier lectura de negocio.
        touched = [e[1] for e in executed if any(
            marker in e[1] for marker in ("INSERT INTO products", "rpc_apply_product_stock_delta", "plan_limits", "COUNT")
        )]
        assert touched == [], f"el 403 debía ocurrir antes de escribir o contar, pero se ejecutó: {touched}"

    @pytest.mark.asyncio
    async def test_a_negative_initial_stock_is_also_an_adjustment_and_needs_the_role(self, async_client, mock_pool):
        pool, conn = mock_pool
        executed = _wire(conn)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products",
                json={"name": "Empanada", "stock": -3},
                headers={"Authorization": f"Bearer {_token('seller')}"},
            )
        assert resp.status_code == 403
        assert _writes(executed) == []

    @pytest.mark.asyncio
    async def test_the_role_is_resolved_from_the_database_when_the_token_carries_none(self, async_client, mock_pool):
        pool, conn = mock_pool
        executed = _wire(conn)

        async def _roles(query, *args):
            executed.append(("fetchval", query, args))
            return ["seller"] if "rpc_my_active_account_roles" in query else None

        conn.fetchval = AsyncMock(side_effect=_roles)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products",
                json={"name": "Empanada", "stock": 5},
                headers={"Authorization": f"Bearer {make_token({'role': 'user'})}"},
            )
        assert resp.status_code == 403
        assert _writes(executed) == []


# ── 10.3 TRIANGULATE ────────────────────────────────────────────────────────────


class TestCreateProductInitialStockTriangulation:
    @pytest.mark.asyncio
    @pytest.mark.parametrize("roles", [("owner",), ("admin",), ("stock",), ("seller", "stock")])
    async def test_roles_with_can_stock_create_the_product_with_the_fixed_reason(self, async_client, mock_pool, roles):
        pool, conn = mock_pool
        executed = _wire(conn)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products",
                json={"name": "Empanada", "stock": 5},
                headers={"Authorization": f"Bearer {_token(*roles)}"},
            )
        assert resp.status_code == 201
        calls = _stock_rpc_calls(executed)
        assert len(calls) == 1
        _, _, args = calls[0]
        # (product_id, delta, branch, reason, p_log_movement, p_allow_negative)
        assert args[1] == Decimal("5")
        assert args[2] is None
        assert args[3:] == ("Stock inicial", True, False)

    @pytest.mark.asyncio
    async def test_a_seller_can_create_a_product_without_initial_stock(self, async_client, mock_pool):
        pool, conn = mock_pool
        executed = _wire(conn)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products",
                json={"name": "Empanada", "stock": 0},
                headers={"Authorization": f"Bearer {_token('seller')}"},
            )
        assert resp.status_code == 201
        assert _stock_rpc_calls(executed) == []
        assert not any("rpc_my_active_account_roles" in e[1] for e in executed), (
            "sin stock inicial no hay chequeo del rol de stock"
        )

    @pytest.mark.asyncio
    async def test_a_seller_can_create_a_product_when_the_payload_omits_stock(self, async_client, mock_pool):
        pool, conn = mock_pool
        executed = _wire(conn)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products",
                json={"name": "Empanada"},
                headers={"Authorization": f"Bearer {_token('seller')}"},
            )
        assert resp.status_code == 201
        assert _stock_rpc_calls(executed) == []


# ── 10.4 RED / 10.5 GREEN: el PUT no ajusta stock ───────────────────────────────


class TestUpdateProductNeverAdjustsStock:
    @pytest.mark.asyncio
    async def test_a_stock_different_from_the_balance_is_rejected_and_nothing_is_written(self, async_client, mock_pool):
        pool, conn = mock_pool
        executed = _wire(conn)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                f"/products/{PRODUCT_ID}",
                json={"name": "Otro nombre", "price": 200, "stock": 30},
                headers={"Authorization": f"Bearer {_token('owner')}"},
            )
        assert resp.status_code == 422
        body = resp.json()
        assert body["code"] == "stock_adjust_required"
        assert body["field"] == "stock"
        assert "Ajustar stock" in body["detail"]
        # "antes de escribir ningún campo": ni el nombre ni el precio.
        assert _writes(executed) == [], f"el 422 debía ocurrir antes de escribir: {_writes(executed)}"

    @pytest.mark.asyncio
    async def test_a_stale_stock_after_a_sale_is_rejected_instead_of_creating_a_phantom_adjustment(
        self, async_client, mock_pool
    ):
        """El bug que cierra D9: el formulario trae stock 25.5, una venta lo deja
        en 23.5 y se guarda un cambio de PRECIO con el 25.5 viejo. Antes el
        backend re-sumaba +2 como "Ajuste manual de stock"."""
        pool, conn = mock_pool
        executed = _wire(conn)

        async def _fetchrow(query, *args):
            executed.append(("fetchrow", query, args))
            return {**PRODUCT_ROW, "stock": "23.5000"}

        conn.fetchrow = AsyncMock(side_effect=_fetchrow)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                f"/products/{PRODUCT_ID}",
                json={"price": 175, "stock": 25.5},
                headers={"Authorization": f"Bearer {_token('owner')}"},
            )
        assert resp.status_code == 422
        assert resp.json()["code"] == "stock_adjust_required"
        assert _writes(executed) == []

    @pytest.mark.asyncio
    async def test_the_same_stock_is_ignored_and_the_rest_of_the_edit_goes_through(self, async_client, mock_pool):
        pool, conn = mock_pool
        executed = _wire(conn)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                f"/products/{PRODUCT_ID}",
                json={"name": "Otro nombre", "stock": 25.5},
                headers={"Authorization": f"Bearer {_token('owner')}"},
            )
        assert resp.status_code == 200
        assert _stock_rpc_calls(executed) == [], "mismo valor: la RPC de ajuste no se llama"
        updates = [e for e in executed if e[0] == "execute" and "UPDATE products" in e[1]]
        assert len(updates) == 1
        assert "stock" not in updates[0][1].lower().replace("min_stock", "").replace("stock_control_type", ""), (
            f"el UPDATE de products no debe tocar stock: {updates[0][1]}"
        )

    @pytest.mark.asyncio
    async def test_an_edit_without_stock_behaves_as_before(self, async_client, mock_pool):
        pool, conn = mock_pool
        executed = _wire(conn)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                f"/products/{PRODUCT_ID}",
                json={"name": "Otro nombre"},
                headers={"Authorization": f"Bearer {_token('seller')}"},
            )
        assert resp.status_code == 200
        assert _stock_rpc_calls(executed) == []

    @pytest.mark.asyncio
    async def test_the_edit_never_calls_the_stock_rpc_even_for_a_role_that_can_adjust(self, async_client, mock_pool):
        pool, conn = mock_pool
        executed = _wire(conn)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                f"/products/{PRODUCT_ID}",
                json={"stock": 99},
                headers={"Authorization": f"Bearer {_token('owner', 'stock')}"},
            )
        assert resp.status_code == 422
        assert _stock_rpc_calls(executed) == []

    @pytest.mark.asyncio
    async def test_the_edit_of_a_product_that_does_not_exist_is_a_404_not_a_422(self, async_client, mock_pool):
        pool, conn = mock_pool
        executed = _wire(conn)

        async def _fetchrow(query, *args):
            executed.append(("fetchrow", query, args))
            return None

        conn.fetchrow = AsyncMock(side_effect=_fetchrow)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                f"/products/{PRODUCT_ID}",
                json={"stock": 99},
                headers={"Authorization": f"Bearer {_token('owner')}"},
            )
        assert resp.status_code == 404


# ── 10.6 candado estructural ────────────────────────────────────────────────────

_RPC = "rpc_apply_product_stock_delta"


def _backend_sources() -> list[Path]:
    """Código de producción del backend: todo `.py` salvo `tests/`, `.venv/` y
    cachés."""
    skip = {"tests", ".venv", "__pycache__"}
    return [p for p in BACKEND.rglob("*.py") if not (set(p.relative_to(BACKEND).parts) & skip)]


class TestStockRpcStructuralLock:
    def test_only_the_product_repository_mentions_the_stock_rpc(self):
        """Antes también la nombraba `StockRepository.adjust_with_event` (código
        muerto, el único `p_log_movement = FALSE` del repo)."""
        mentioning = sorted(
            str(p.relative_to(BACKEND)).replace("\\", "/")
            for p in _backend_sources()
            if _RPC in p.read_text(encoding="utf-8")
        )
        assert mentioning == ["repositories/product_repository.py"], mentioning

    def test_no_sql_literal_calls_the_rpc_with_a_flag_other_than_true_false(self):
        """Ningún literal de SQL del backend la llama con `FALSE` en el 5º
        parámetro (p_log_movement) ni `TRUE` en el 6º (p_allow_negative) escritos
        a mano; los flags viajan como parámetros y se afirman en el test de abajo."""
        offenders: list[str] = []
        pattern = re.compile(rf"{_RPC}\s*\((?P<args>[^)]*)\)", re.S)
        for path in _backend_sources():
            text = path.read_text(encoding="utf-8")
            for match in pattern.finditer(text):
                args = [a.strip() for a in match.group("args").split(",")]
                for idx, literal in ((4, "false"), (5, "true")):
                    if len(args) > idx and args[idx].lower() == literal:
                        offenders.append(f"{path.relative_to(BACKEND)}: {match.group(0)!r}")
        assert offenders == [], offenders

    def test_the_only_call_site_passes_the_fixed_reason_and_the_true_false_flags(self):
        """AST de `product_repository.py`: todo uso de `_APPLY_STOCK_DELTA_SQL`
        termina en `"Stock inicial", True, False`."""
        source = (BACKEND / "repositories" / "product_repository.py").read_text(encoding="utf-8")
        tree = ast.parse(source)
        call_sites: list[ast.Call] = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and any(
                isinstance(arg, ast.Name) and arg.id == "_APPLY_STOCK_DELTA_SQL" for arg in node.args
            ):
                call_sites.append(node)
        assert len(call_sites) == 1, f"el stock inicial del alta es el único caller; hay {len(call_sites)}"
        trailing = call_sites[0].args[-3:]
        assert [getattr(a, "value", None) for a in trailing] == ["Stock inicial", True, False]

    def test_the_dead_adjust_with_event_producer_is_gone(self):
        from backend.repositories.stock_repository import StockRepository

        assert not hasattr(StockRepository, "adjust_with_event")


# ── 10.8 documentación de CAN_STOCK ─────────────────────────────────────────────


class TestCanStockConsumer:
    def test_can_stock_documents_its_first_consumer_and_the_sql_tie(self):
        text = (BACKEND / "core" / "rbac.py").read_text(encoding="utf-8")
        marker = "CAN_STOCK: frozenset[str]"
        head = text[: text.index(marker)]
        comment = head[head.rindex("\n\n"):]
        assert "stock-ledger-solo-rpc" in comment
        assert "_stock_assert_can_adjust" in comment
        assert "POST /products" in comment

    def test_can_stock_content_is_the_set_signed_by_the_po(self):
        from backend.core.rbac import CAN_STOCK

        assert CAN_STOCK == frozenset({"owner", "admin", "stock"})
