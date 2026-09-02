from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import make_token

CLIENT_ROW = {
    "id": "33333333-3333-3333-3333-333333333333",
    "user_id": "11111111-1111-1111-1111-111111111111",
    "name": "Acme Corp",
    "email": "acme@example.com",
    "phone": "+54 261 555-1234",
    "created_at": "2024-01-10T09:00:00",
}


async def test_get_clients_ok(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[CLIENT_ROW])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/clients", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    data = resp.json()
    assert data[0]["name"] == "Acme Corp"


async def test_get_clients_empty(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/clients", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    assert resp.json() == []


def _plan_limits_row(max_products: int = 100, max_clients: int = 50, max_suppliers: int = 20) -> dict:
    return {"max_products": max_products, "max_clients": max_clients, "max_suppliers": max_suppliers}


def _client_create_fetchrow_side_effect(count: int = 0, max_clients: int = 50):
    async def _side_effect(query, *args):
        if "plan_limits" in query:
            return _plan_limits_row(max_clients=max_clients)
        if "COUNT" in query:
            return {"total": count}
        return CLIENT_ROW

    return _side_effect


async def test_create_client_ok(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(side_effect=_client_create_fetchrow_side_effect(count=5))
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/clients",
            json={"name": "Acme Corp", "email": "acme@example.com"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    assert resp.json()["name"] == "Acme Corp"


async def test_create_client_member_forbidden(async_client, mock_pool):
    pool, conn = mock_pool
    member_token = make_token({"role": "member"})
    conn.fetchrow = AsyncMock(return_value=CLIENT_ROW)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/clients",
            json={"name": "Test"},
            headers={"Authorization": f"Bearer {member_token}"},
        )
    assert resp.status_code == 403


# ── billing-pro-trial (D5, tasks 6.3/6.4): límite de clientes por plan ───────


async def test_create_client_plan_gratis_over_limit_returns_403(async_client, mock_pool):
    """Plan gratis: max_clients=50 (plan_limits). El cliente 51 se rechaza."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user", "app_metadata": {"plan": "gratis"}})
    conn.fetchrow = AsyncMock(side_effect=_client_create_fetchrow_side_effect(count=50, max_clients=50))
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/clients",
            json={"name": "Cliente 51"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 403
    assert "límite" in resp.json()["detail"].lower() or "plan" in resp.json()["detail"].lower()


async def test_create_client_ok_under_limit(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user", "app_metadata": {"plan": "gratis"}})
    conn.fetchrow = AsyncMock(side_effect=_client_create_fetchrow_side_effect(count=49, max_clients=50))
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/clients",
            json={"name": "Cliente 50"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201


async def test_create_client_excess_of_other_resource_does_not_block(async_client, mock_pool):
    """TRIANGULATE (6.6.a): excedente de PRODUCTOS no bloquea la creación de un
    CLIENTE — el guard es por recurso, no global a la cuenta."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user", "app_metadata": {"plan": "gratis"}})
    # 9 clientes, muy por debajo del límite — el excedente sería en productos,
    # que este endpoint ni consulta.
    conn.fetchrow = AsyncMock(side_effect=_client_create_fetchrow_side_effect(count=9, max_clients=50))
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/clients",
            json={"name": "Cliente nuevo"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201


async def test_client_count_for_plan_limit_excludes_soft_deleted(async_client, mock_pool):
    """El contador del límite de plan no cuenta clientes borrados."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    count_sql = {}

    async def fetchrow_side_effect(query, *args):
        if "plan_limits" in query:
            return _plan_limits_row()
        if "COUNT" in query:
            count_sql["sql"] = query
            return {"total": 5}
        return CLIENT_ROW

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/clients",
            json={"name": "Cliente"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    assert "deleted_at IS NULL" in count_sql["sql"]


async def test_get_client_cross_org_returns_404(async_client, mock_pool):
    pool, conn = mock_pool
    conn.fetchrow = AsyncMock(return_value=None)
    other_token = make_token({"sub": "other-user-id"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/clients/cli-uuid-1",
            headers={"Authorization": f"Bearer {other_token}"},
        )
    assert resp.status_code == 404


# ── Identidad fiscal (C-22 v20-fiscal-identity-clients) ─────────────────────

FISCAL_CLIENT_ROW = {
    **CLIENT_ROW,
    "name": "ACME S.R.L.",
    "tax_id": "30-71234567-1",
    "iva_condition": "responsable_inscripto",
    "legal_name": "ACME Sociedad de Responsabilidad Limitada",
}


def _fiscal_fetchrow_side_effect(insert_row: dict):
    async def _side_effect(query, *args):
        if "plan_limits" in query:
            return _plan_limits_row()
        if "COUNT" in query:
            return {"total": 5}
        return insert_row

    return _side_effect


async def test_create_client_with_fiscal_identity(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(side_effect=_fiscal_fetchrow_side_effect(FISCAL_CLIENT_ROW))
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/clients",
            json={
                "name": "ACME S.R.L.",
                "tax_id": "30-71234567-1",
                "iva_condition": "responsable_inscripto",
                "legal_name": "ACME Sociedad de Responsabilidad Limitada",
            },
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    data = resp.json()
    assert data["tax_id"] == "30-71234567-1"
    assert data["iva_condition"] == "responsable_inscripto"
    assert data["legal_name"] == "ACME Sociedad de Responsabilidad Limitada"
    insert_args = conn.fetchrow.await_args.args
    assert "30-71234567-1" in insert_args
    assert "responsable_inscripto" in insert_args


async def test_create_client_without_fiscal_identity_returns_nulls(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    row = {**CLIENT_ROW, "tax_id": None, "iva_condition": None, "legal_name": None}
    conn.fetchrow = AsyncMock(side_effect=_fiscal_fetchrow_side_effect(row))
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/clients",
            json={"name": "Acme Corp"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    data = resp.json()
    assert data["tax_id"] is None
    assert data["iva_condition"] is None
    assert data["legal_name"] is None


async def test_create_client_invalid_iva_condition_returns_422(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value=FISCAL_CLIENT_ROW)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/clients",
            json={"name": "Test", "iva_condition": "inscripto_raro"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 422
    conn.fetchrow.assert_not_awaited()


# ── v3-soft-delete-policy (5.1): borrado soft + lecturas filtradas ───────────


async def test_delete_client_is_soft_delete(async_client, mock_pool):
    """DELETE /clients/{id} responde 204 y emite UPDATE ... deleted_at (soft),
    nunca un DELETE físico."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value=CLIENT_ROW)  # get_by_id del service
    conn.execute = AsyncMock(return_value="UPDATE 1")

    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/clients/{CLIENT_ROW['id']}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )

    assert resp.status_code == 204
    sql = conn.execute.call_args.args[0]
    assert "UPDATE clients" in sql
    assert "deleted_at = now()" in sql
    assert "DELETE FROM" not in sql
    # deleted_by = usuario autenticado (RN-B2, task 5.6)
    assert "11111111-1111-1111-1111-111111111111" in conn.execute.call_args.args


async def test_list_clients_excludes_soft_deleted(async_client, valid_token, mock_pool):
    """El listado filtra deleted_at IS NULL (RN-B1)."""
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[CLIENT_ROW])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/clients", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    assert "deleted_at IS NULL" in conn.fetch.call_args.args[0]


async def test_get_client_excludes_soft_deleted(async_client, valid_token, mock_pool):
    """El GET por id filtra deleted_at IS NULL (RN-B1) — un borrado es 404."""
    pool, conn = mock_pool
    conn.fetchrow = AsyncMock(return_value=None)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            f"/clients/{CLIENT_ROW['id']}",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 404
    assert "deleted_at IS NULL" in conn.fetchrow.call_args.args[0]


# ── clientes-frecuentes-historial (5.1 RED / 5.2 GREEN / 5.3 TRIANGULATE) ────

ACTIVITY_ROW = {
    "id": "33333333-3333-3333-3333-333333333333",
    "name": "Acme Corp",
    "email": "acme@example.com",
    "phone": "+54 261 555-1234",
    "tax_id": None,
    "iva_condition": None,
    "legal_name": None,
    "created_at": "2024-01-10T09:00:00",
    "purchase_count": 5,
    "purchase_count_90d": 3,
    "total_spent": "15000.00",
    "last_purchase_date": "2026-08-01",
    "days_since_last_purchase": 13,
    "activity_status": "frecuente",
}

PURCHASE_ROW = {
    "operation_id": "op-1",
    "operation_date": "2026-08-01",
    "item_count": 3,
    "total": "3000.00",
}


def _activity_fetch_side_effect(rows: list[dict], today: str = "2026-08-14"):
    async def _side_effect(query, *args):
        return rows

    return _side_effect


async def test_get_client_activity_ok(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetchval = AsyncMock(side_effect=["2026-08-14", 1])  # get_reference_today, luego COUNT
    conn.fetch = AsyncMock(return_value=[ACTIVITY_ROW])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/clients/activity?page=0&size=25",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    data = resp.json()
    assert data["items"][0]["activity_status"] == "frecuente"
    assert data["items"][0]["purchase_count"] == 5
    assert data["total"] == 1
    assert data["page"] == 0
    assert "pages" in data


async def test_get_client_activity_filters_by_status(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetchval = AsyncMock(side_effect=["2026-08-14", 0])
    conn.fetch = AsyncMock(return_value=[])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/clients/activity?activity_status=inactivo",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    args = conn.fetch.call_args.args
    assert "inactivo" in args


async def test_get_client_activity_search(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetchval = AsyncMock(side_effect=["2026-08-14", 0])
    conn.fetch = AsyncMock(return_value=[])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/clients/activity?search=acme",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    args = conn.fetch.call_args.args
    assert "acme" in args


async def test_get_client_activity_invalid_sort_returns_422_without_query(
    async_client, valid_token, mock_pool
):
    """5.3 TRIANGULATE: `sort` fuera del conjunto admitido → 422 RFC 7807 sin
    ejecutar la consulta (Pydantic valida antes del cuerpo del endpoint)."""
    pool, conn = mock_pool
    conn.fetchval = AsyncMock(return_value="2026-08-14")
    conn.fetch = AsyncMock(return_value=[])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/clients/activity?sort=bogus",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 422
    conn.fetch.assert_not_awaited()
    conn.fetchval.assert_not_awaited()


async def test_get_client_activity_invalid_status_returns_422(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetchval = AsyncMock(return_value="2026-08-14")
    conn.fetch = AsyncMock(return_value=[])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/clients/activity?activity_status=bogus",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 422
    conn.fetch.assert_not_awaited()


async def test_get_client_purchases_ok(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetchrow = AsyncMock(return_value=ACTIVITY_ROW)  # get_by_id + get_activity_for
    conn.fetchval = AsyncMock(side_effect=["2026-08-14", 1])  # today, luego COUNT
    conn.fetch = AsyncMock(return_value=[PURCHASE_ROW])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            f"/clients/{ACTIVITY_ROW['id']}/purchases",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    data = resp.json()
    assert data["items"][0]["operation_id"] == "op-1"
    assert data["items"][0]["item_count"] == 3
    assert "summary" in data
    assert data["summary"]["purchase_count"] == 5


async def test_get_client_purchases_nonexistent_client_returns_404(async_client, valid_token, mock_pool):
    """client-purchase-history §"Cliente de otra organización": el sistema
    responde 404 RFC 7807 sin revelar datos, tanto para inexistente como
    para cliente de otra cuenta (get_by_id ya filtra por account_id)."""
    pool, conn = mock_pool
    conn.fetchrow = AsyncMock(return_value=None)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/clients/00000000-0000-0000-0000-000000000000/purchases",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 404


async def test_get_client_purchases_page_out_of_range_keeps_total(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetchrow = AsyncMock(return_value=ACTIVITY_ROW)
    conn.fetchval = AsyncMock(side_effect=["2026-08-14", 5])
    conn.fetch = AsyncMock(return_value=[])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            f"/clients/{ACTIVITY_ROW['id']}/purchases?page=99&size=25",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    data = resp.json()
    assert data["items"] == []
    assert data["total"] == 5


# ── 5.4 REGRESIÓN — GET /clients conserva su lista plana ────────────────────


async def test_list_clients_response_is_a_plain_list_not_an_envelope(
    async_client, valid_token, mock_pool
):
    """data-api-endpoints §"Compatibilidad del listado plano de clientes":
    GET /clients sigue devolviendo `list[ClientOut]`, sin envelope
    {items,total,page,pages} — guardarraíl de los 6 consumidores de
    selectores (ventas, pos, configuración, sale-form, client-form,
    client-import-dialog)."""
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[CLIENT_ROW])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/clients", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    data = resp.json()
    assert isinstance(data, list)
    assert "items" not in data if isinstance(data, dict) else True
    assert data[0]["name"] == "Acme Corp"


async def test_update_client_fiscal_fields_only(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    updated_row = {
        **CLIENT_ROW,
        "tax_id": "20-12345678-6",
        "iva_condition": "monotributista",
        "legal_name": None,
    }
    conn.fetchrow = AsyncMock(return_value=updated_row)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            f"/clients/{CLIENT_ROW['id']}",
            json={"tax_id": "20-12345678-6", "iva_condition": "monotributista"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 200
    data = resp.json()
    assert data["tax_id"] == "20-12345678-6"
    assert data["iva_condition"] == "monotributista"
    assert data["name"] == "Acme Corp"
    update_sql = conn.fetchrow.await_args.args[0]
    assert "UPDATE clients" in update_sql
    assert "tax_id" in update_sql
    assert "20-12345678-6" in conn.fetchrow.await_args.args


# ── cobranzas-panel (task 6.1 RED / 6.3 GREEN) — current_balance ─────────────


async def test_get_client_activity_includes_current_balance(async_client, valid_token, mock_pool):
    """El read-model expone el saldo de cuenta corriente por cliente (D9)."""
    pool, conn = mock_pool
    conn.fetchval = AsyncMock(side_effect=["2026-08-14", 1])
    conn.fetch = AsyncMock(return_value=[{**ACTIVITY_ROW, "current_balance": "12000.00"}])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/clients/activity?page=0&size=25",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    row = resp.json()["items"][0]
    assert float(row["current_balance"]) == 12000.0


async def test_get_client_activity_balance_defaults_to_zero_not_none(
    async_client, valid_token, mock_pool
):
    """Cliente sin cuenta corriente → saldo 0, no null: "sin cuenta" y
    "cuenta en cero" son lo mismo para quien lee la lista (spec
    client-activity, escenario 'Cliente sin cuenta corriente')."""
    pool, conn = mock_pool
    conn.fetchval = AsyncMock(side_effect=["2026-08-14", 1])
    conn.fetch = AsyncMock(return_value=[dict(ACTIVITY_ROW)])  # sin current_balance
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/clients/activity?page=0&size=25",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    row = resp.json()["items"][0]
    assert row["current_balance"] is not None
    assert float(row["current_balance"]) == 0.0
