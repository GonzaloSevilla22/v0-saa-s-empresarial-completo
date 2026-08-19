from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import make_token

PURCHASE_ID = "22222222-2222-2222-2222-222222222222"

UPDATE_PAYLOAD = {
    "purchase_ids": [PURCHASE_ID],
    "date": "2024-01-15",
    "description": "Reposición",
    "items": [{"product_id": "prod-uuid-1", "quantity": "3.0", "amount": "80.00"}],
}


async def test_update_purchase_operation_ok(async_client, mock_pool):
    """PUT /purchases/operation invoca rpc_atomic_update_purchase_operation → 200."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    captured: dict = {}

    async def execute_side_effect(query, *args):
        captured["query"] = query
        return "SELECT 1"

    conn.execute = AsyncMock(side_effect=execute_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            "/purchases/operation",
            json=UPDATE_PAYLOAD,
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 200
    assert "rpc_atomic_update_purchase_operation" in captured["query"]


# ── metodos-pago-operaciones: creación con forma de pago ────────────────────

PM_ID = "88888888-8888-8888-8888-888888888888"

CREATE_PURCHASE_PAYLOAD = {
    "idempotency_key": "purchase-key-abc",
    "org_id": "org-uuid-1",
    "items": [{"product_id": "prod-uuid-1", "quantity": "2.0000", "amount": "80.00"}],
}


async def test_create_purchase_passes_payment_method_id_to_rpc(async_client, mock_pool):
    """El payment_method_id del payload llega como argumento del RPC
    rpc_create_purchase_operation (mismo patrón que cost_center_id)."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    captured: dict = {}

    async def fetchrow_side_effect(query, *args):
        if "operation_idempotency" in query:
            return None
        captured["query"] = query
        captured["args"] = args
        return {"operation_id": PURCHASE_ID, "operation_kind": "purchase"}

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/purchases",
            json={**CREATE_PURCHASE_PAYLOAD, "payment_method_id": PM_ID},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    assert "rpc_create_purchase_operation" in captured["query"]
    assert PM_ID in [str(a) for a in captured["args"]]


async def test_create_purchase_without_payment_method_passes_none(async_client, mock_pool):
    """Sin payment_method_id en el payload, el RPC recibe NULL."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    captured: dict = {}

    async def fetchrow_side_effect(query, *args):
        if "operation_idempotency" in query:
            return None
        captured["args"] = args
        return {"operation_id": PURCHASE_ID, "operation_kind": "purchase"}

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/purchases",
            json=CREATE_PURCHASE_PAYLOAD,
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    assert captured["args"][-1] is None  # payment_method_id


# ── metodos-pago-operaciones: edición preserva/cambia/desimputa (D5) ────────

async def test_update_purchase_operation_without_field_preserves(async_client, mock_pool):
    """Sin payment_method_id en el JSON, p_payment_method_provided=false — el
    RPC preserva el vigente vía COALESCE."""
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
            "/purchases/operation",
            json=UPDATE_PAYLOAD,
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 200
    assert captured["args"][-2] is None
    assert captured["args"][-1] is False


async def test_update_purchase_operation_with_explicit_null_clears(async_client, mock_pool):
    """payment_method_id: null EXPLÍCITO en el JSON (sentinel "Sin especificar")
    — desimputa, distinto de ausente (provided=true)."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    captured: dict = {}

    async def execute_side_effect(query, *args):
        captured["args"] = args
        return "SELECT 1"

    conn.execute = AsyncMock(side_effect=execute_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            "/purchases/operation",
            json={**UPDATE_PAYLOAD, "payment_method_id": None},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 200
    assert captured["args"][-2] is None
    assert captured["args"][-1] is True


async def test_update_purchase_operation_with_payment_method_reimputes(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    captured: dict = {}

    async def execute_side_effect(query, *args):
        captured["args"] = args
        return "SELECT 1"

    conn.execute = AsyncMock(side_effect=execute_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            "/purchases/operation",
            json={**UPDATE_PAYLOAD, "payment_method_id": PM_ID},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 200
    assert PM_ID in [str(a) for a in captured["args"]]
    assert captured["args"][-1] is True


async def test_update_purchase_operation_member_forbidden(async_client, mock_pool):
    pool, conn = mock_pool
    member_token = make_token({"role": "member"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            "/purchases/operation",
            json=UPDATE_PAYLOAD,
            headers={"Authorization": f"Bearer {member_token}"},
        )
    assert resp.status_code == 403


async def test_delete_purchase_calls_stock_reversal_rpc(async_client, mock_pool):
    """v31-tenancy-pool-rls (colisión #3, sign-off PO 2026-08-01): el borrado
    de una compra ya NO hace su propio lookup de stock_movements + rpc_apply_
    product_stock_delta + DELETE — delega TODO eso, de una, a
    rpc_reverse_stock_movement (que inserta un contramovimiento en vez de
    borrar del ledger append-only). La aritmética de stock/branch_stock se
    prueba contra Postgres real en el gate SQL (stock-a/b/c de
    20260828000001_v31_rls_collision_rpcs.sql) — acá se prueba el CONTRATO:
    delete_by_id llama la RPC exactamente una vez, con (purchase_id, reason)."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    reversal_calls: list = []

    async def fetchrow_side_effect(query, *args):
        if "FROM purchases WHERE id" in query:
            return {"id": PURCHASE_ID, "operation_id": None}
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
            f"/purchases/{PURCHASE_ID}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 204
    assert len(reversal_calls) == 1, "rpc_reverse_stock_movement no se llamó"
    purchase_id, reason = reversal_calls[0]
    assert purchase_id == PURCHASE_ID
    assert reason == "Compra eliminada"


# ── v3-api-standards §2.5: envelope estándar {items,total,page,pages} ───────


async def test_list_purchases_ok(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchval = AsyncMock(return_value=0)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/purchases", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["items"] == []
    assert body["total"] == 0
    assert body["page"] == 0
    assert body["pages"] == 0


async def test_list_purchases_envelope_has_page_and_pages(async_client, valid_token, mock_pool):
    """TRIANGULATE: con resultados, pages = ceil(total/size)."""
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchval = AsyncMock(return_value=30)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/purchases?page=0&page_size=25",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] == 30
    assert body["page"] == 0
    assert body["pages"] == 2


async def test_list_purchases_page_out_of_range_returns_empty_items(async_client, valid_token, mock_pool):
    """2.10: página fuera de rango -> 200 con items vacío, no error."""
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchval = AsyncMock(return_value=5)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/purchases?page=99&page_size=25",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["items"] == []
    assert body["total"] == 5
    assert body["page"] == 99


async def test_list_purchases_page_size_over_max_returns_422(async_client, valid_token, mock_pool):
    """2.10: page_size sobre la cota máxima (100) -> 422 problem+json."""
    pool, conn = mock_pool
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/purchases?page_size=99999",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 422
    assert resp.headers["content-type"].startswith("application/problem+json")
    conn.fetch.assert_not_awaited()


# ── cost-center-surface: filtro por centro de costo en el listado ───────────
#
# El centro de costo es un atributo DE LA OPERACIÓN (todas las líneas de una
# compra comparten el mismo valor), y la paginación de compras es por
# operación. Por eso el filtro tiene que entrar en la CTE `op_page` y en el
# COUNT — si se aplicara en el JOIN final devolvería operaciones parciales y
# descuadraría el `total` (design.md Decisión 6).

COST_CENTER_ID = "33333333-3333-3333-3333-333333333333"


def _capture_queries(conn):
    """Registra (query, args) de fetch y fetchval del listado paginado."""
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


async def test_list_purchases_filters_by_cost_center(async_client, valid_token, mock_pool):
    """GET /purchases?cost_center_id=... propaga el uuid a la query de datos."""
    pool, conn = mock_pool
    captured = _capture_queries(conn)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            f"/purchases?cost_center_id={COST_CENTER_ID}",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    rows_query, rows_args = captured["rows"]
    assert "cost_center_id" in rows_query
    assert str(COST_CENTER_ID) in [str(a) for a in rows_args]


async def test_list_purchases_cost_center_filter_applies_to_count(
    async_client, valid_token, mock_pool
):
    """El COUNT recibe el mismo filtro: si no, `total` y `pages` mienten."""
    pool, conn = mock_pool
    captured = _capture_queries(conn)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            f"/purchases?cost_center_id={COST_CENTER_ID}",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    count_query, count_args = captured["count"]
    assert "cost_center_id" in count_query
    assert str(COST_CENTER_ID) in [str(a) for a in count_args]


async def test_list_purchases_cost_center_filter_lives_inside_op_page_cte(
    async_client, valid_token, mock_pool
):
    """Decisión 6: el predicado va DENTRO de la CTE op_page, no en el join final.

    Se verifica posicionalmente: el filtro tiene que aparecer antes del cierre
    de la CTE (el `SELECT p.id` que arranca la query externa).
    """
    pool, conn = mock_pool
    captured = _capture_queries(conn)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            f"/purchases?cost_center_id={COST_CENTER_ID}",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    rows_query, _ = captured["rows"]
    filter_pos = rows_query.find("cost_center_id")
    outer_select_pos = rows_query.find("SELECT p.id")
    assert filter_pos != -1 and outer_select_pos != -1
    assert filter_pos < outer_select_pos, (
        "el filtro de centro de costo debe aplicarse dentro de la CTE op_page"
    )


async def test_list_purchases_without_cost_center_passes_none(
    async_client, valid_token, mock_pool
):
    """REGRESIÓN: sin el query param, el filtro viaja como None (no filtra)."""
    pool, conn = mock_pool
    captured = _capture_queries(conn)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/purchases", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    _, rows_args = captured["rows"]
    _, count_args = captured["count"]
    assert None in rows_args
    assert None in count_args
    assert resp.json()["total"] == 0


async def test_list_purchases_cost_center_combines_with_date_range(
    async_client, valid_token, mock_pool
):
    """TRIANGULATE: el filtro se compone con date_from/date_to."""
    pool, conn = mock_pool
    captured = _capture_queries(conn)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            f"/purchases?cost_center_id={COST_CENTER_ID}"
            "&date_from=2026-01-01&date_to=2026-01-31",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    _, rows_args = captured["rows"]
    as_text = [str(a) for a in rows_args]
    assert str(COST_CENTER_ID) in as_text
    assert "2026-01-01" in as_text
    assert "2026-01-31" in as_text


async def test_list_purchases_invalid_cost_center_returns_422(
    async_client, valid_token, mock_pool
):
    """TRIANGULATE: un cost_center_id que no es uuid → 422 problem+json."""
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchval = AsyncMock(return_value=0)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/purchases?cost_center_id=no-es-un-uuid",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 422
    assert resp.headers["content-type"].startswith("application/problem+json")
    conn.fetch.assert_not_awaited()


async def test_list_purchases_exposes_cost_center_of_the_operation(
    async_client, valid_token, mock_pool
):
    """La fila devuelta expone cost_center_id + nombre para el badge de la UI."""
    pool, conn = mock_pool
    captured = _capture_queries(conn)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/purchases", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    rows_query, _ = captured["rows"]
    assert "p.cost_center_id" in rows_query
    assert "cost_centers" in rows_query
    assert "cost_center_name" in rows_query


async def test_list_purchases_row_keeps_cost_center_name_in_response(
    async_client, valid_token, mock_pool
):
    """El schema de salida no descarta el nombre del centro (badge del listado)."""
    pool, conn = mock_pool
    row = {
        "id": PURCHASE_ID,
        "date": "2026-01-15",
        "operation_id": None,
        "description": "Insumos",
        "product_id": None,
        "quantity": "1",
        "amount": "100.00",
        "total": "100.00",
        "product_name": None,
        "cost_center_id": COST_CENTER_ID,
        "cost_center_name": "Logística",
    }
    conn.fetch = AsyncMock(return_value=[row])
    conn.fetchval = AsyncMock(return_value=1)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/purchases", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    item = resp.json()["items"][0]
    assert item["cost_center_id"] == COST_CENTER_ID
    assert item["cost_center_name"] == "Logística"


# ── metodos-pago-operaciones: filtro por forma de pago en el listado ────────

async def test_list_purchases_filters_by_payment_method(async_client, valid_token, mock_pool):
    """GET /purchases?payment_method_id=... propaga el uuid a la query de
    datos y al COUNT (mismo criterio que cost_center_id)."""
    pool, conn = mock_pool
    captured = _capture_queries(conn)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            f"/purchases?payment_method_id={PM_ID}",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    rows_query, rows_args = captured["rows"]
    count_query, count_args = captured["count"]
    assert "payment_method_id" in rows_query
    assert "payment_method_id" in count_query
    assert PM_ID in [str(a) for a in rows_args]
    assert PM_ID in [str(a) for a in count_args]


async def test_list_purchases_payment_method_and_cost_center_coexist(
    async_client, valid_token, mock_pool
):
    """Ambos filtros se pueden combinar en la misma consulta (D3: cada uno en
    su propia columna, sin pisarse)."""
    pool, conn = mock_pool
    captured = _capture_queries(conn)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            f"/purchases?payment_method_id={PM_ID}&cost_center_id={COST_CENTER_ID}",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    _, rows_args = captured["rows"]
    as_text = [str(a) for a in rows_args]
    assert PM_ID in as_text
    assert str(COST_CENTER_ID) in as_text


async def test_list_purchases_exposes_payment_method_of_the_operation(
    async_client, valid_token, mock_pool
):
    """La fila devuelta expone payment_method_id + nombre + kind para el badge."""
    pool, conn = mock_pool
    captured = _capture_queries(conn)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/purchases", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    rows_query, _ = captured["rows"]
    assert "p.payment_method_id" in rows_query
    assert "payment_method_name" in rows_query
    assert "payment_method_kind" in rows_query
