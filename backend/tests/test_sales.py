from __future__ import annotations

import re
from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import make_token

OPERATION_ROW = {
    "operation_id": "66666666-6666-6666-6666-666666666666",
    "operation_kind": "sale",
}

SALE_PAYLOAD = {
    "idempotency_key": "key-abc-123",
    "org_id": "org-uuid-1",
    "items": [
        {"product_id": "prod-uuid-1", "quantity": "2.0000", "amount": "300.00"}
    ],
}


async def test_create_sale_ok(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})

    async def fetchrow_side_effect(query, *args):
        if "operation_idempotency" in query:
            return None
        return OPERATION_ROW

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/sales",
            json=SALE_PAYLOAD,
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    assert resp.json()["operation_id"] == "66666666-6666-6666-6666-666666666666"


async def test_create_sale_idempotent(async_client, mock_pool):
    """Duplicate idempotency_key returns existing operation (HTTP 201 with same data)."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value=OPERATION_ROW)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/sales",
            json=SALE_PAYLOAD,
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    assert resp.json()["operation_id"] == "66666666-6666-6666-6666-666666666666"


async def test_create_sale_member_forbidden(async_client, mock_pool):
    pool, conn = mock_pool
    member_token = make_token({"role": "member"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/sales",
            json=SALE_PAYLOAD,
            headers={"Authorization": f"Bearer {member_token}"},
        )
    assert resp.status_code == 403


async def test_create_sale_passes_canal_to_rpc(async_client, mock_pool):
    """El canal del payload llega como argumento del RPC rpc_create_sale_operation."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    captured: dict = {}

    async def fetchrow_side_effect(query, *args):
        if "operation_idempotency" in query:
            return None
        captured["query"] = query
        captured["args"] = args
        return OPERATION_ROW

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/sales",
            json={**SALE_PAYLOAD, "canal": "instagram"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    assert "rpc_create_sale_operation" in captured["query"]
    assert "instagram" in captured["args"]


async def test_create_sale_without_canal_passes_none(async_client, mock_pool):
    """Sin canal en el payload, el RPC recibe NULL (ventas legacy = 'Sin canal').

    metodos-pago-operaciones agregó payment_method_id después de canal;
    pagos-cableados-restantes (OQ-C) agrega cash_session_id trailing después
    de payment_method_id; pos-banco-movimientos agrega bank_account_id
    trailing después de cash_session_id — se verifica canal/payment_method_id/
    cash_session_id/bank_account_id por posición (-4/-3/-2/-1), no por "último".
    """
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    captured: dict = {}

    async def fetchrow_side_effect(query, *args):
        if "operation_idempotency" in query:
            return None
        captured["args"] = args
        return OPERATION_ROW

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/sales",
            json=SALE_PAYLOAD,
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    assert captured["args"][-4] is None  # canal
    assert captured["args"][-3] is None  # payment_method_id
    assert captured["args"][-2] is None  # cash_session_id
    assert captured["args"][-1] is None  # bank_account_id


async def test_create_sale_passes_bank_account_id_to_rpc(async_client, mock_pool):
    """pos-banco-movimientos (D2): el bank_account_id del payload (override
    del chip de destino) llega como argumento trailing del RPC
    rpc_create_sale_operation — passthrough sin lógica de negocio en el
    backend (la RPC resuelve/valida/aplica el guard de período conciliado)."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    captured: dict = {}
    bank_account_id = "99999999-9999-9999-9999-999999999999"

    async def fetchrow_side_effect(query, *args):
        if "operation_idempotency" in query:
            return None
        captured["query"] = query
        captured["args"] = args
        return OPERATION_ROW

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/sales",
            json={**SALE_PAYLOAD, "bank_account_id": bank_account_id},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    assert "rpc_create_sale_operation" in captured["query"]
    assert "p_bank_account_id" in captured["query"]
    assert bank_account_id in [str(a) for a in captured["args"]]


async def test_create_sale_passes_cash_session_id_to_rpc(async_client, mock_pool):
    """pagos-cableados-restantes (OQ-C): el cash_session_id del payload llega
    como argumento trailing del RPC rpc_create_sale_operation — el opt-in de
    caja del formulario de venta. Las tres condiciones (kind=cash, sesión
    abierta en la sucursal efectiva, fecha=hoy) se validan en la RPC (D4); el
    backend sólo propaga el parámetro, sin lógica de negocio en el router."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    captured: dict = {}
    session_id = "88888888-8888-8888-8888-888888888888"

    async def fetchrow_side_effect(query, *args):
        if "operation_idempotency" in query:
            return None
        captured["query"] = query
        captured["args"] = args
        return OPERATION_ROW

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/sales",
            json={**SALE_PAYLOAD, "cash_session_id": session_id},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    assert "rpc_create_sale_operation" in captured["query"]
    assert "p_cash_session_id" in captured["query"]
    assert session_id in [str(a) for a in captured["args"]]


async def test_create_sale_passes_payment_method_id_to_rpc(async_client, mock_pool):
    """metodos-pago-operaciones: el payment_method_id del payload llega como
    último argumento del RPC rpc_create_sale_operation."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    captured: dict = {}
    pm_id = "77777777-7777-7777-7777-777777777777"

    async def fetchrow_side_effect(query, *args):
        if "operation_idempotency" in query:
            return None
        captured["query"] = query
        captured["args"] = args
        return OPERATION_ROW

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/sales",
            json={**SALE_PAYLOAD, "payment_method_id": pm_id},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    assert "rpc_create_sale_operation" in captured["query"]
    assert "p_payment_method_id" in captured["query"]
    assert pm_id in [str(a) for a in captured["args"]]


SALE_ID = "11111111-1111-1111-1111-111111111111"
OPERATION_ID = "66666666-6666-6666-6666-666666666666"

UPDATE_PAYLOAD = {
    "sale_ids": [SALE_ID],
    "client_id": None,
    "date": "2024-01-15",
    "currency": "ARS",
    "items": [{"product_id": "prod-uuid-1", "quantity": "1.0", "amount": "100.00"}],
}


async def test_delete_sale_ok(async_client, mock_pool):
    """DELETE /sales/{id} elimina una venta simple → 204."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})

    async def fetchrow_side_effect(query, *args):
        # Header de la venta encontrado; sin product_id en sale_items → sin stock.
        if "FROM sales WHERE id" in query:
            return {"id": SALE_ID, "operation_id": None}
        return None

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/sales/{SALE_ID}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 204


async def test_delete_sale_not_found(async_client, mock_pool):
    """Venta inexistente (o de otra org, vía RLS) → 404."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value=None)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/sales/{SALE_ID}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 404


async def test_delete_sale_member_forbidden(async_client, mock_pool):
    pool, conn = mock_pool
    member_token = make_token({"role": "member"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/sales/{SALE_ID}",
            headers={"Authorization": f"Bearer {member_token}"},
        )
    assert resp.status_code == 403


async def test_delete_sales_by_operation_ok(async_client, mock_pool):
    """DELETE /sales?operation_id= elimina toda la operación agrupada → 204."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetch = AsyncMock(return_value=[{"id": SALE_ID}])
    conn.fetchrow = AsyncMock(return_value=None)  # sin product_id → sin reversa de stock
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/sales?operation_id={OPERATION_ID}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 204


async def test_delete_sales_by_operation_not_found(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetch = AsyncMock(return_value=[])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/sales?operation_id={OPERATION_ID}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 404


async def test_delete_sale_calls_stock_reversal_rpc(async_client, mock_pool):
    """v31-tenancy-pool-rls (colisión #3, sign-off PO 2026-08-01): el borrado
    de una venta ya NO hace su propio lookup de stock_movements + rpc_apply_
    product_stock_delta + DELETE — delega TODO eso, de una, a
    rpc_reverse_stock_movement (inserta un contramovimiento en vez de borrar
    del ledger append-only — cubre por igual la ruta C-29/POS sin sale_items
    y la ruta v2, porque ya no hay ninguna rama por sale_items en el
    repository). La aritmética de stock/branch_stock se prueba contra
    Postgres real en el gate SQL (stock-a/b/c de
    20260828000001_v31_rls_collision_rpcs.sql) — acá se prueba el CONTRATO:
    delete_by_id llama la RPC exactamente una vez, con (sale_id, reason)."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    reversal_calls: list = []

    async def fetchrow_side_effect(query, *args):
        if "FROM sales WHERE id" in query:
            return {"id": SALE_ID, "operation_id": None}
        return None

    async def fetch_side_effect(query, *args):
        if "rpc_reverse_stock_movement" in query:
            reversal_calls.append(args)
            return []
        return []

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    conn.fetch = AsyncMock(side_effect=fetch_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/sales/{SALE_ID}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 204
    assert len(reversal_calls) == 1, "rpc_reverse_stock_movement no se llamó"
    sale_id, reason = reversal_calls[0]
    assert sale_id == SALE_ID
    assert reason == "Venta eliminada"


async def test_delete_sales_by_operation_calls_stock_reversal_rpc_per_sale(async_client, mock_pool):
    """delete_by_operation llama rpc_reverse_stock_movement una vez POR
    venta del lote (TRIANGULATE: 2 ventas distintas del mismo operation_id)."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    reversal_calls: list = []
    sale_a = "11111111-1111-1111-1111-1111111111aa"
    sale_b = "11111111-1111-1111-1111-1111111111bb"

    async def fetch_side_effect(query, *args):
        if "SELECT id FROM sales WHERE operation_id" in query:
            return [{"id": sale_a}, {"id": sale_b}]
        if "rpc_reverse_stock_movement" in query:
            reversal_calls.append(args)
            return []
        return []

    conn.fetch = AsyncMock(side_effect=fetch_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/sales?operation_id={OPERATION_ID}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 204
    assert len(reversal_calls) == 2
    assert reversal_calls[0] == (sale_a, "Venta eliminada (operación)")
    assert reversal_calls[1] == (sale_b, "Venta eliminada (operación)")


async def test_update_sale_operation_ok(async_client, mock_pool):
    """PUT /sales/operation invoca rpc_atomic_update_sale_operation → 200."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    captured: dict = {}

    async def execute_side_effect(query, *args):
        captured["query"] = query
        return "SELECT 1"

    conn.execute = AsyncMock(side_effect=execute_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            "/sales/operation",
            json=UPDATE_PAYLOAD,
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 200
    assert "rpc_atomic_update_sale_operation" in captured["query"]


async def test_update_sale_operation_member_forbidden(async_client, mock_pool):
    pool, conn = mock_pool
    member_token = make_token({"role": "member"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            "/sales/operation",
            json=UPDATE_PAYLOAD,
            headers={"Authorization": f"Bearer {member_token}"},
        )
    assert resp.status_code == 403


# ── metodos-pago-operaciones: edición preserva/cambia/desimputa (D5) ────────
#
# payment_method_id es tri-estado por AUSENCIA en el JSON (model_fields_set),
# no por valor: ausente = preservar (el RPC hace COALESCE contra el vigente);
# presente con null = desimputar explícito; presente con uuid = reimputar.

PM_ID = "88888888-8888-8888-8888-888888888888"


async def test_update_sale_operation_without_field_preserves(async_client, mock_pool):
    """Sin payment_method_id en el JSON, p_payment_method_provided=false — el
    RPC preserva el vigente vía COALESCE.

    edicion-preserva-contexto agregó branch_id/branch_provided/canal/
    canal_provided DESPUÉS de payment_method_id/payment_method_provided en la
    firma del RPC (parámetros nuevos al final, §D4) — por eso ahora son
    args[-6]/args[-5], no args[-2]/args[-1].
    """
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    captured: dict = {}

    async def execute_side_effect(query, *args):
        captured["query"] = query
        captured["args"] = args
        return "SELECT 1"

    conn.execute = AsyncMock(side_effect=execute_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            "/sales/operation",
            json=UPDATE_PAYLOAD,
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 200
    assert captured["args"][-6] is None      # payment_method_id
    assert captured["args"][-5] is False     # payment_method_provided


async def test_update_sale_operation_with_payment_method_reimputes(async_client, mock_pool):
    """Con payment_method_id explícito, p_payment_method_provided=true — reimputa."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    captured: dict = {}

    async def execute_side_effect(query, *args):
        captured["args"] = args
        return "SELECT 1"

    conn.execute = AsyncMock(side_effect=execute_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            "/sales/operation",
            json={**UPDATE_PAYLOAD, "payment_method_id": PM_ID},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 200
    assert PM_ID in [str(a) for a in captured["args"]]
    assert captured["args"][-5] is True  # payment_method_provided


async def test_update_sale_operation_with_explicit_null_clears(async_client, mock_pool):
    """El sentinel 'Sin especificar' viaja como payment_method_id: null EXPLÍCITO
    en el JSON (presente en model_fields_set) — desimputa, distinto de ausente."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    captured: dict = {}

    async def execute_side_effect(query, *args):
        captured["args"] = args
        return "SELECT 1"

    conn.execute = AsyncMock(side_effect=execute_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            "/sales/operation",
            json={**UPDATE_PAYLOAD, "payment_method_id": None},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 200
    assert captured["args"][-6] is None   # payment_method_id explícito NULL
    assert captured["args"][-5] is True   # provided=true (distinto del caso ausente)


# ── edicion-preserva-contexto: branch_id/canal tri-estado (F1 §D3) ─────────
#
# Mismo contrato tri-estado que payment_method_id, ahora para branch_id y
# canal: ausente en el JSON = preservar (RPC hace COALESCE contra el
# vigente); presente (incluso null) = el RPC decide reimputar/desimputar.

BRANCH_ID = "99999999-9999-9999-9999-999999999999"


async def test_update_sale_operation_without_branch_canal_preserves(async_client, mock_pool):
    """Sin branch_id/canal en el JSON → ambos *_provided=false; el RPC preserva."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    captured: dict = {}

    async def execute_side_effect(query, *args):
        captured["args"] = args
        return "SELECT 1"

    conn.execute = AsyncMock(side_effect=execute_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            "/sales/operation",
            json=UPDATE_PAYLOAD,
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 200
    assert captured["args"][-4] is None   # branch_id
    assert captured["args"][-3] is False  # branch_provided
    assert captured["args"][-2] is None   # canal
    assert captured["args"][-1] is False  # canal_provided


async def test_update_sale_operation_with_branch_id_reimputes(async_client, mock_pool):
    """Con branch_id explícito → branch_provided=true, el uuid viaja al RPC."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    captured: dict = {}

    async def execute_side_effect(query, *args):
        captured["args"] = args
        return "SELECT 1"

    conn.execute = AsyncMock(side_effect=execute_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            "/sales/operation",
            json={**UPDATE_PAYLOAD, "branch_id": BRANCH_ID},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 200
    assert BRANCH_ID in [str(a) for a in captured["args"]]
    assert captured["args"][-3] is True  # branch_provided


async def test_update_sale_operation_with_canal_reimputes(async_client, mock_pool):
    """Con canal explícito → canal_provided=true."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    captured: dict = {}

    async def execute_side_effect(query, *args):
        captured["args"] = args
        return "SELECT 1"

    conn.execute = AsyncMock(side_effect=execute_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            "/sales/operation",
            json={**UPDATE_PAYLOAD, "canal": "instagram"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 200
    assert captured["args"][-2] == "instagram"
    assert captured["args"][-1] is True  # canal_provided


async def test_update_sale_operation_with_explicit_null_branch_clears(async_client, mock_pool):
    """branch_id: null EXPLÍCITO en el JSON → provided=true, desimputa (no
    indistinguible del caso ausente)."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    captured: dict = {}

    async def execute_side_effect(query, *args):
        captured["args"] = args
        return "SELECT 1"

    conn.execute = AsyncMock(side_effect=execute_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            "/sales/operation",
            json={**UPDATE_PAYLOAD, "branch_id": None},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 200
    assert captured["args"][-4] is None  # branch_id explícito NULL
    assert captured["args"][-3] is True  # provided=true


async def test_update_sale_operation_propagates_invoiced_immutable_as_409(async_client, mock_pool):
    """edicion-preserva-contexto (F2): P0423 del RPC (operación facturada,
    inmutable) llega al cliente como 409 problem+json vía el handler global
    de asyncpg.PostgresError — el router no necesita un except propio."""
    import asyncpg

    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})

    class _FakePgError(asyncpg.PostgresError):
        def __init__(self, message, sqlstate):
            super().__init__(message)
            self.sqlstate = sqlstate

    async def execute_side_effect(query, *args):
        raise _FakePgError(
            "invoiced_operation_immutable: emití una nota de crédito y registrá una venta nueva",
            "P0423",
        )

    conn.execute = AsyncMock(side_effect=execute_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            "/sales/operation",
            json=UPDATE_PAYLOAD,
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 409
    assert resp.headers["content-type"].startswith("application/problem+json")
    body = resp.json()
    assert body["code"] == "P0423"
    assert "nota de crédito" in body["detail"]


async def test_list_sales_ok(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchval = AsyncMock(return_value=0)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/sales", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    body = resp.json()
    # v3-api-standards §2: envelope estándar {items, total, page, pages}
    assert body["items"] == []
    assert body["total"] == 0
    assert body["page"] == 0
    assert body["pages"] == 0


async def test_list_sales_envelope_has_page_and_pages(async_client, valid_token, mock_pool):
    """TRIANGULATE: con resultados, pages = ceil(total/size) y page eco del pedido."""
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchval = AsyncMock(return_value=30)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/sales?page=0&page_size=25",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] == 30
    assert body["page"] == 0
    assert body["pages"] == 2


async def test_list_sales_page_out_of_range_returns_empty_items(async_client, valid_token, mock_pool):
    """2.10: página fuera de rango -> 200 con items vacío, no error."""
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchval = AsyncMock(return_value=5)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/sales?page=99&page_size=25",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["items"] == []
    assert body["total"] == 5
    assert body["page"] == 99


async def test_list_sales_page_size_over_max_returns_422(async_client, valid_token, mock_pool):
    """2.10: page_size sobre la cota máxima (100) -> 422 problem+json."""
    pool, conn = mock_pool
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/sales?page_size=99999",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 422
    assert resp.headers["content-type"].startswith("application/problem+json")
    conn.fetch.assert_not_awaited()


# ── metodos-pago-operaciones: filtro por forma de pago en el listado ────────

def _capture_sales_queries(conn):
    captured: dict[str, tuple] = {}

    async def fetchval_side_effect(query, *args):
        captured["count"] = (query, args)
        return 0

    async def fetch_side_effect(query, *args):
        captured["rows"] = (query, args)
        return []

    conn.fetchval = AsyncMock(side_effect=fetchval_side_effect)
    conn.fetch = AsyncMock(side_effect=fetch_side_effect)
    return captured


async def test_list_sales_filters_by_payment_method(async_client, valid_token, mock_pool):
    """GET /sales?payment_method_id=... propaga el uuid a la query de datos
    y al COUNT (mismo criterio que cost_center_id en compras)."""
    pool, conn = mock_pool
    captured = _capture_sales_queries(conn)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            f"/sales?payment_method_id={PM_ID}",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    rows_query, rows_args = captured["rows"]
    count_query, count_args = captured["count"]
    assert "payment_method_id" in rows_query
    assert "payment_method_id" in count_query
    assert PM_ID in [str(a) for a in rows_args]
    assert PM_ID in [str(a) for a in count_args]


async def test_list_sales_exposes_branch_canal_unit_for_edit_prefill(async_client, valid_token, mock_pool):
    """edicion-preserva-contexto (D11): sin branch_id/canal/unit_id en la
    lectura, el form de edición no tiene con qué prefillear."""
    pool, conn = mock_pool
    captured = _capture_sales_queries(conn)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/sales", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    rows_query, _ = captured["rows"]
    assert "s.branch_id" in rows_query
    assert "s.canal" in rows_query
    assert "unit_id" in rows_query


async def test_list_sales_row_exposes_is_invoiced_flag(async_client, valid_token, mock_pool):
    """edicion-preserva-contexto (F2/D11): is_invoiced viaja en la fila para
    que el form se abra en solo lectura antes de que el usuario intente
    editar una operación facturada."""
    pool, conn = mock_pool
    row = {
        "id": SALE_ID, "date": "2026-01-15", "client_id": None, "operation_id": OPERATION_ID,
        "currency": "ARS", "product_id": None, "quantity": "1", "amount": "100.00",
        "total": "100.00", "product_name": None, "client_name": None,
        "branch_id": None, "canal": None, "unit_id": None,
        "payment_method_id": None, "payment_method_name": None, "payment_method_kind": None,
        "is_invoiced": True,
    }
    conn.fetch = AsyncMock(return_value=[row])
    conn.fetchval = AsyncMock(return_value=1)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/sales", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    assert resp.json()["items"][0]["is_invoiced"] is True


async def test_list_sales_row_exposes_is_payment_locked_flag(async_client, valid_token, mock_pool):
    """pagos-cableados-restantes (D6): is_payment_locked viaja en la fila para
    que la lista deshabilite 'Editar' ANTES de que el usuario intente
    modificar una operación con cargo de cuenta corriente o movimiento de
    caja ya posteado (mismo predicado que el guard P0423 de
    rpc_atomic_update_sale_operation — ver SalesRepository)."""
    pool, conn = mock_pool
    row = {
        "id": SALE_ID, "date": "2026-01-15", "client_id": None, "operation_id": OPERATION_ID,
        "currency": "ARS", "product_id": None, "quantity": "1", "amount": "100.00",
        "total": "100.00", "product_name": None, "client_name": None,
        "branch_id": None, "canal": None, "unit_id": None,
        "payment_method_id": None, "payment_method_name": None, "payment_method_kind": None,
        "is_invoiced": False, "is_payment_locked": True,
    }
    conn.fetch = AsyncMock(return_value=[row])
    conn.fetchval = AsyncMock(return_value=1)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/sales", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    assert resp.json()["items"][0]["is_payment_locked"] is True


async def test_list_sales_row_exposes_payment_lock_query_predicate(async_client, valid_token, mock_pool):
    """El predicado de is_payment_locked cubre AMBAS convenciones de
    reference_id de la migración pagos-cableados-restantes: operation_id
    (formulario) y sales_orders.id (POS). pos-banco-movimientos (D8) suma
    bank_movements al mismo predicado, mismas dos convenciones."""
    pool, conn = mock_pool
    captured = _capture_sales_queries(conn)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/sales", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    rows_query, _ = captured["rows"]
    assert "customer_account_movements" in rows_query
    assert "cash_movements" in rows_query
    assert "bank_movements" in rows_query
    assert "is_payment_locked" in rows_query


async def test_list_sales_exposes_payment_method_of_the_operation(async_client, valid_token, mock_pool):
    """La fila devuelta expone payment_method_id + nombre + kind, con la
    derivación de lectura del POS vía LEFT JOIN sales_orders (D7)."""
    pool, conn = mock_pool
    captured = _capture_sales_queries(conn)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/sales", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    rows_query, _ = captured["rows"]
    assert "payment_method_id" in rows_query
    assert "sales_orders" in rows_query
    assert "payment_method_name" in rows_query
    assert "payment_method_kind" in rows_query


async def test_list_sales_pos_derivation_joins_by_payment_method_id_not_kind(
    async_client, valid_token, mock_pool
):
    """limpiezas-pagos-admin (G1b, D3, task 5.1): la derivación de lectura del
    POS SHALL unir payment_methods por identidad (pos_pm.id = so.payment_
    method_id), no por kind. `payment_methods.kind` no es único dentro de
    una cuenta — nada impide crear dos formas de pago del mismo kind desde
    el manager de Configuración — así que un JOIN por kind puede devolver
    más de una fila por venta y duplicar la operación en el listado (bug
    latente, D3 de design.md). No hay forma de ejercitar el fan-out con
    filas reales contra este pool mockeado (conn.fetch no ejecuta SQL de
    verdad), así que el gate verifica la propiedad estructural que lo
    elimina por construcción: el texto de la query nunca vuelve a unir
    payment_methods por kind contra sales_orders.payment_method (columna
    retirada en este mismo change) y siempre lo hace por
    sales_orders.payment_method_id."""
    pool, conn = mock_pool
    captured = _capture_sales_queries(conn)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/sales", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    rows_query, _ = captured["rows"]
    assert "pos_pm.id" in rows_query
    assert "so.payment_method_id" in rows_query
    # El JOIN por kind (bug latente de fan-out) no debe reaparecer. pos_pm.kind
    # sigue apareciendo en el SELECT (expone el kind del método resuelto) —
    # lo que no debe existir es la CONDICIÓN de join contra el kind.
    assert re.search(r"pos_pm\.kind\s*=\s*so\.payment_method", rows_query) is None
