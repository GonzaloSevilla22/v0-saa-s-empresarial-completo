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


async def test_create_client_ok(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value=CLIENT_ROW)
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


async def test_create_client_with_fiscal_identity(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value=FISCAL_CLIENT_ROW)
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
    conn.fetchrow = AsyncMock(return_value=row)
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
