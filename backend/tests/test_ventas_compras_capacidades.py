"""multiusuario-operativo TANDA B (10.1): las ventas y las compras se autorizan por
CAPACIDAD DE ROL de la cuenta activa, en FastAPI y en la base.

Tres cosas, una por clase:

  * `TestMirror` — las constantes de `backend/core/rbac.py` (`CAN_SELL`, `CAN_PURCHASE`,
    `CAN_MODIFY_ANY_DOCUMENT`) son EXACTAMENTE los arrays que la migración
    `20261083000001` pasa a `_account_assert_capability` / usa en
    `_account_assert_document_authority`. Mismo patrón que los espejos de remitos y
    presupuestos: si alguien cambia uno sin el otro, falla acá.
  * `TestRoleMatrix` — los services llaman `require_account_role` con la capacidad del
    dominio ANTES de tocar la RPC: alta, edición y borrado de venta exigen `CAN_SELL`; los
    de compra, `CAN_PURCHASE`. Un rol sin la capacidad recibe 403 sin que ninguna RPC se
    ejecute. La regla de autor (dueño y administrador sobre lo ajeno; el resto, lo propio)
    la decide la BASE: acá se verifica que su rechazo llega como 403 RFC 7807.
  * `TestOldToken` — un token sin `account_id` (emitido antes del deploy) no confía en sus
    claims de rol y consulta la base, también en estos endpoints.
"""
from __future__ import annotations

import re
from pathlib import Path
from unittest.mock import AsyncMock, patch

import asyncpg
import pytest

from backend.core.rbac import CAN_MODIFY_ANY_DOCUMENT, CAN_PURCHASE, CAN_SELL
from backend.tests.conftest import account_roles_fetchval, make_token, tenant_token
from backend.tests.test_purchases import (
    CREATE_PURCHASE_PAYLOAD,
    OPERATION_ID as PURCHASE_OPERATION_ID,
    PURCHASE_ID,
    UPDATE_PAYLOAD as PURCHASE_UPDATE_PAYLOAD,
)
from backend.tests.test_sales import (
    OPERATION_ROW,
    SALE_ID,
    SALE_PAYLOAD,
    UPDATE_PAYLOAD as SALE_UPDATE_PAYLOAD,
    _UPDATE_RPC_RESULT,
    OPERATION_ID as SALE_OPERATION_ID,
)

MIGRATION = (
    Path(__file__).resolve().parents[2]
    / "supabase"
    / "migrations"
    / "20261083000001_multiusuario_operaciones.sql"
)

SALE_FUNCTIONS = (
    "rpc_create_sale_operation",
    "rpc_create_sale_operation_v2",
    "rpc_atomic_update_sale_operation",
    "rpc_delete_sale_operation",
)
PURCHASE_FUNCTIONS = (
    "rpc_create_purchase_operation",
    "rpc_create_purchase_operation_v2",
    "rpc_atomic_update_purchase_operation",
    "rpc_delete_purchase_operation",
)

SELL_ALLOWED = sorted(CAN_SELL)
SELL_DENIED = ["purchases", "stock", "accountant", "viewer"]
PURCHASE_ALLOWED = sorted(CAN_PURCHASE)
PURCHASE_DENIED = ["seller", "cashier", "stock", "accountant", "viewer"]


# ── Espejo con la migración ──────────────────────────────────────────────────


def _function_sql(fn: str) -> str:
    """El `CREATE OR REPLACE FUNCTION public.<fn>(` … `$function$;` de la migración."""
    sql = MIGRATION.read_text(encoding="utf-8")
    m = re.search(
        r"CREATE OR REPLACE FUNCTION public\." + re.escape(fn) + r"\(.*?\n\$function\$;\n",
        sql,
        re.S,
    )
    assert m, f"{fn} no está redefinida en {MIGRATION.name}"
    return m.group(0)


def _roles_of_capability_calls(fn: str) -> list[frozenset[str]]:
    body = _function_sql(fn)
    out = []
    for m in re.finditer(r"_account_assert_capability\(\s*v_account_id,\s*ARRAY\[([^\]]*)\]", body):
        out.append(frozenset(re.findall(r"'([a-z_]+)'", m.group(1))))
    return out


class TestMirror:
    @pytest.mark.parametrize("fn", SALE_FUNCTIONS)
    def test_las_funciones_de_venta_exigen_can_sell(self, fn):
        calls = _roles_of_capability_calls(fn)
        assert calls, f"{fn} no llama a _account_assert_capability"
        assert all(c == CAN_SELL for c in calls), f"{fn}: {calls} != CAN_SELL {sorted(CAN_SELL)}"

    @pytest.mark.parametrize("fn", PURCHASE_FUNCTIONS)
    def test_las_funciones_de_compra_exigen_can_purchase(self, fn):
        calls = _roles_of_capability_calls(fn)
        assert calls, f"{fn} no llama a _account_assert_capability"
        assert all(c == CAN_PURCHASE for c in calls), f"{fn}: {calls} != CAN_PURCHASE {sorted(CAN_PURCHASE)}"

    def test_el_deposito_no_compra(self):
        """OQ-3 (b): la compra NO suma `stock` (el depósito recibe por remito)."""
        assert "stock" not in CAN_PURCHASE
        assert "stock" not in CAN_SELL

    def test_la_regla_de_autor_es_dueno_y_admin(self):
        """OQ-4 (b): sobre un documento ajeno sólo dueño y administrador."""
        m = re.search(
            r"CREATE OR REPLACE FUNCTION public\._account_assert_document_authority\(.*?\n\$function\$;\n",
            MIGRATION.read_text(encoding="utf-8"),
            re.S,
        )
        assert m
        arrays = re.findall(r"&&\s*ARRAY\[([^\]]*)\]", m.group(0))
        assert arrays, "el helper no compara los roles contra un ARRAY"
        assert {frozenset(re.findall(r"'([a-z_]+)'", a)) for a in arrays} == {CAN_MODIFY_ANY_DOCUMENT}

    @pytest.mark.parametrize(
        "fn",
        ["rpc_atomic_update_sale_operation", "rpc_atomic_update_purchase_operation",
         "rpc_delete_sale_operation", "rpc_delete_purchase_operation"],
    )
    def test_edicion_y_borrado_aplican_la_regla_de_autor(self, fn):
        assert "_account_assert_document_authority(" in _function_sql(fn)

    def test_ninguna_funcion_autoriza_por_autor(self):
        for fn in SALE_FUNCTIONS + PURCHASE_FUNCTIONS + ("_purchase_operation_core",):
            body = _function_sql(fn)
            code = re.sub(r"--[^\n]*", "", re.sub(r"/\*.*?\*/", "", body, flags=re.S))
            assert "v_product.user_id" not in code, fn
            assert not re.search(r"user_id\s*(<>|!=)\s*v_uid", code), fn


# ── Matriz de roles sobre los endpoints ──────────────────────────────────────


def _rpc_queries(conn) -> list[str]:
    """Todo texto SQL que llegó a la conexión (fetch/fetchrow/fetchval/execute)."""
    out: list[str] = []
    for m in (conn.fetch, conn.fetchrow, conn.fetchval, conn.execute):
        for call in m.call_args_list:
            if call.args:
                out.append(str(call.args[0]))
    return out


def _touched_operation_rpc(conn) -> bool:
    return any(
        re.search(r"rpc_(create|atomic_update|delete)_(sale|purchase)_operation", q) for q in _rpc_queries(conn)
    )


# (método, ruta, json, qué mockear para que el camino feliz no falle)
def _sale_requests():
    return [
        ("post", "/sales", SALE_PAYLOAD, "fetchrow_op"),
        ("put", "/sales/operation", SALE_UPDATE_PAYLOAD, "fetchval_update"),
        ("delete", f"/sales?operation_id={SALE_OPERATION_ID}", None, "fetchrow_true"),
        ("delete", f"/sales/{SALE_ID}", None, "fetchrow_true"),
    ]


def _purchase_requests():
    return [
        ("post", "/purchases", CREATE_PURCHASE_PAYLOAD, "fetchrow_op"),
        ("put", "/purchases/operation", PURCHASE_UPDATE_PAYLOAD, "execute_ok"),
        ("delete", f"/purchases?operation_id={PURCHASE_OPERATION_ID}", None, "fetchrow_true"),
        ("delete", f"/purchases/{PURCHASE_ID}", None, "fetchrow_true"),
    ]


def _prime(conn, how: str) -> None:
    if how == "fetchrow_op":
        # el repositorio consulta primero la idempotencia (None = clave nueva) y recién después llama a la RPC
        async def _fetchrow(query, *args):
            return None if "operation_idempotency" in str(query) else OPERATION_ROW

        conn.fetchrow = AsyncMock(side_effect=_fetchrow)
    elif how == "fetchrow_true":
        conn.fetchrow = AsyncMock(return_value={"result": True})
    elif how == "fetchval_update":
        conn.fetchval = AsyncMock(return_value=_UPDATE_RPC_RESULT)
    elif how == "execute_ok":
        conn.execute = AsyncMock(return_value="SELECT 1")


async def _call(async_client, method, url, payload, token):
    kwargs = {"headers": {"Authorization": f"Bearer {token}"}}
    if payload is not None:
        kwargs["json"] = payload
    return await getattr(async_client, method)(url, **kwargs)


class TestRoleMatrix:
    @pytest.mark.parametrize("role", SELL_DENIED)
    @pytest.mark.parametrize("request_", _sale_requests(), ids=lambda r: f"{r[0].upper()} {r[1].split('?')[0]}")
    async def test_venta_sin_can_sell_es_403_sin_tocar_la_rpc(self, async_client, mock_pool, role, request_):
        pool, conn = mock_pool
        method, url, payload, how = request_
        _prime(conn, how)
        with patch("backend.core.database.pool", pool):
            resp = await _call(async_client, method, url, payload, tenant_token([role]))
        assert resp.status_code == 403, resp.text
        assert not _touched_operation_rpc(conn), f"{role}: la RPC se ejecutó pese al 403: {_rpc_queries(conn)}"

    @pytest.mark.parametrize("role", SELL_ALLOWED)
    @pytest.mark.parametrize("request_", _sale_requests(), ids=lambda r: f"{r[0].upper()} {r[1].split('?')[0]}")
    async def test_venta_con_can_sell_llega_a_la_rpc(self, async_client, mock_pool, role, request_):
        pool, conn = mock_pool
        method, url, payload, how = request_
        _prime(conn, how)
        with patch("backend.core.database.pool", pool):
            resp = await _call(async_client, method, url, payload, tenant_token([role]))
        assert resp.status_code in (200, 201, 204), resp.text
        assert _touched_operation_rpc(conn)

    @pytest.mark.parametrize("role", PURCHASE_DENIED)
    @pytest.mark.parametrize("request_", _purchase_requests(), ids=lambda r: f"{r[0].upper()} {r[1].split('?')[0]}")
    async def test_compra_sin_can_purchase_es_403_sin_tocar_la_rpc(self, async_client, mock_pool, role, request_):
        pool, conn = mock_pool
        method, url, payload, how = request_
        _prime(conn, how)
        with patch("backend.core.database.pool", pool):
            resp = await _call(async_client, method, url, payload, tenant_token([role]))
        assert resp.status_code == 403, resp.text
        assert not _touched_operation_rpc(conn), f"{role}: la RPC se ejecutó pese al 403: {_rpc_queries(conn)}"

    @pytest.mark.parametrize("role", PURCHASE_ALLOWED)
    @pytest.mark.parametrize("request_", _purchase_requests(), ids=lambda r: f"{r[0].upper()} {r[1].split('?')[0]}")
    async def test_compra_con_can_purchase_llega_a_la_rpc(self, async_client, mock_pool, role, request_):
        pool, conn = mock_pool
        method, url, payload, how = request_
        _prime(conn, how)
        with patch("backend.core.database.pool", pool):
            resp = await _call(async_client, method, url, payload, tenant_token([role]))
        assert resp.status_code in (200, 201, 204), resp.text
        assert _touched_operation_rpc(conn)

    async def test_un_multirol_usa_la_union_de_sus_roles(self, async_client, mock_pool):
        """vendedor + compras: vende y compra (la capacidad se evalúa sobre el CONJUNTO)."""
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=OPERATION_ROW)
        with patch("backend.core.database.pool", pool):
            sale = await _call(async_client, "post", "/sales", SALE_PAYLOAD, tenant_token(["seller", "purchases"]))
            purchase = await _call(
                async_client, "post", "/purchases", CREATE_PURCHASE_PAYLOAD, tenant_token(["seller", "purchases"])
            )
        assert sale.status_code == 201 and purchase.status_code == 201

    async def test_el_rol_de_plataforma_member_sigue_siendo_403(self, async_client, mock_pool):
        """CONTROL: `require_role` (rol de PLATAFORMA) sigue rechazando antes que la capacidad."""
        pool, conn = mock_pool
        token = tenant_token(["owner"], role="member")
        with patch("backend.core.database.pool", pool):
            resp = await _call(async_client, "post", "/sales", SALE_PAYLOAD, token)
        assert resp.status_code == 403
        assert not _touched_operation_rpc(conn)

    @pytest.mark.parametrize(
        "sqlstate, status, fragment",
        [
            ("P0403", 403, "insufficient_role"),
            ("P0401", 403, "unauthorized"),
            ("P0404", 404, "Product not found"),
        ],
    )
    async def test_el_rechazo_de_la_base_llega_como_problem_json(
        self, async_client, mock_pool, sqlstate, status, fragment
    ):
        """Los tres rechazos de la tanda B (rol, autor, tenencia) llegan como RFC 7807 con su `code`."""
        pool, conn = mock_pool

        class _FakePgError(asyncpg.PostgresError):
            def __init__(self, message, sqlstate):
                super().__init__(message)
                self.sqlstate = sqlstate

        conn.fetchrow = AsyncMock(side_effect=_FakePgError(f"{fragment}: x", sqlstate))
        with patch("backend.core.database.pool", pool):
            resp = await _call(async_client, "post", "/sales", SALE_PAYLOAD, tenant_token(["owner"]))
        assert resp.status_code == status
        assert resp.headers["content-type"].startswith("application/problem+json")
        assert resp.json()["code"] == sqlstate

    async def test_el_alta_de_venta_por_pos_no_cambia(self, async_client, mock_pool):
        """CONTROL de alcance: el POS (`POST /sales-orders/quick-sale`) sigue con `is_account_writer`
        —su capacidad fina es un candidato—, así que esta tanda NO lo toca."""
        from backend.routers import sales_orders

        src = Path(sales_orders.__file__).read_text(encoding="utf-8")
        assert "CAN_SELL" not in src


class TestOldToken:
    """D4: un token SIN `account_id` no confía en sus claims de rol y consulta la base."""

    async def test_token_viejo_con_claim_de_vendedor_pero_viewer_en_la_base_es_403(self, async_client, mock_pool):
        pool, conn = mock_pool
        # claims de rol presentes pero sin `account_id`: no valen
        token = make_token({"role": "user", "app_metadata": {"account_roles": ["seller"], "account_id": None}})
        conn.fetchval = account_roles_fetchval(["viewer"])
        conn.fetchrow = AsyncMock(return_value=OPERATION_ROW)
        with patch("backend.core.database.pool", pool):
            resp = await _call(async_client, "post", "/sales", SALE_PAYLOAD, token)
        assert resp.status_code == 403
        assert not _touched_operation_rpc(conn)

    async def test_token_viejo_y_vendedor_en_la_base_pasa(self, async_client, mock_pool):
        pool, conn = mock_pool
        token = make_token({"role": "user", "app_metadata": {"account_roles": ["viewer"], "account_id": None}})
        conn.fetchval = account_roles_fetchval(["seller"])
        conn.fetchrow = AsyncMock(return_value=OPERATION_ROW)
        with patch("backend.core.database.pool", pool):
            resp = await _call(async_client, "post", "/sales", SALE_PAYLOAD, token)
        assert resp.status_code == 201


# ── `created_by`: la autoría llega al listado (D9, OQ-4 b) ─────────────────────


class TestCreatedByInListings:
    """La interfaz oculta «Editar» / «Eliminar» sobre lo ajeno cuando el rol no es dueño ni administrador;
    para eso el listado expone quién cargó cada operación. Es sólo informativo (la autoridad es la RPC)."""

    async def test_el_listado_de_ventas_selecciona_y_devuelve_created_by(self, async_client, mock_pool, valid_token):
        pool, conn = mock_pool
        author = "99999999-9999-9999-9999-999999999999"
        captured: dict = {}

        async def _fetch(query, *args):
            captured["query"] = str(query)
            return [{
                "id": SALE_ID, "date": "2026-10-16", "client_id": None, "operation_id": SALE_OPERATION_ID,
                "currency": "ARS", "product_id": None, "quantity": 1, "amount": 100, "total": 100,
                "product_name": "X", "client_name": None, "created_by": author,
            }]

        conn.fetch = AsyncMock(side_effect=_fetch)
        conn.fetchval = AsyncMock(return_value=1)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/sales", headers={"Authorization": f"Bearer {valid_token}"})
        assert resp.status_code == 200
        assert re.search(r"s\.user_id\s+AS\s+created_by", captured["query"])
        assert resp.json()["items"][0]["created_by"] == author

    async def test_el_listado_de_compras_selecciona_y_devuelve_created_by(self, async_client, mock_pool, valid_token):
        pool, conn = mock_pool
        author = "88888888-8888-8888-8888-888888888888"
        captured: dict = {}

        async def _fetch(query, *args):
            captured["query"] = str(query)
            return [{
                "id": PURCHASE_ID, "date": "2026-10-16", "operation_id": PURCHASE_OPERATION_ID, "description": None,
                "product_id": None, "quantity": 1, "amount": 50, "total": 50, "product_name": "Y", "created_by": author,
            }]

        conn.fetch = AsyncMock(side_effect=_fetch)
        conn.fetchval = AsyncMock(return_value=1)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/purchases", headers={"Authorization": f"Bearer {valid_token}"})
        assert resp.status_code == 200
        assert re.search(r"p\.user_id\s+AS\s+created_by", captured["query"])
        assert resp.json()["items"][0]["created_by"] == author
