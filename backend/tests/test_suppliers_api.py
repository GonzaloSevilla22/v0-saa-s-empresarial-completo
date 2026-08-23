"""compras-proveedor-cuenta-corriente (task 7.1-7.7): ABM de proveedores,
molde exacto de test_clients.py — router -> service (require_role) ->
SupplierRepository (extendido con create/update/count_by_org).

D3: el service NO precuenta contra el límite de plan — eso lo hace
exclusivamente el trigger `trg_guard_supplier_plan_limit` (ERRCODE P0B10,
mapeado a 403 en backend/core/errors.py, task 8.x). Por eso, a diferencia de
test_clients.py, ningún test acá mockea una fila de `plan_limits`.
"""
from __future__ import annotations

from unittest.mock import AsyncMock, patch

import asyncpg
import pytest

from backend.tests.conftest import make_token

SUPPLIER_ID = "55555555-5555-5555-5555-555555555555"

SUPPLIER_ROW = {
    "id": SUPPLIER_ID,
    "name": "Distribuidora Sur",
    "email": "ventas@distribuidorasur.com",
    "phone": "+54 261 555-9876",
    "tax_id": None,
    "iva_condition": None,
    "legal_name": None,
    "created_at": "2024-01-10T09:00:00",
}

FISCAL_SUPPLIER_ROW = {
    **SUPPLIER_ROW,
    "name": "Insumos del Este S.A.",
    "tax_id": "30-71234567-1",
    "iva_condition": "responsable_inscripto",
    "legal_name": "Insumos del Este Sociedad Anónima",
}


# ── 7.1 RED / listado ────────────────────────────────────────────────────────


async def test_get_suppliers_ok(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[SUPPLIER_ROW])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/suppliers", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    data = resp.json()
    assert data[0]["name"] == "Distribuidora Sur"


async def test_get_suppliers_empty(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/suppliers", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    assert resp.json() == []


async def test_list_suppliers_excludes_soft_deleted(async_client, valid_token, mock_pool):
    """RN-B1: el listado filtra deleted_at IS NULL."""
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[SUPPLIER_ROW])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/suppliers", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    sql = conn.fetch.call_args.args[0]
    assert "deleted_at IS NULL" in sql
    assert "ORDER BY name" in sql


# ── alta ──────────────────────────────────────────────────────────────────


async def test_create_supplier_ok(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value=SUPPLIER_ROW)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/suppliers",
            json={"name": "Distribuidora Sur", "email": "ventas@distribuidorasur.com"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    assert resp.json()["name"] == "Distribuidora Sur"


async def test_create_supplier_member_forbidden(async_client, mock_pool):
    pool, conn = mock_pool
    member_token = make_token({"role": "member"})
    conn.fetchrow = AsyncMock(return_value=SUPPLIER_ROW)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/suppliers",
            json={"name": "Test"},
            headers={"Authorization": f"Bearer {member_token}"},
        )
    assert resp.status_code == 403
    conn.fetchrow.assert_not_awaited()


async def test_create_supplier_does_not_precount_plan_limit(async_client, mock_pool):
    """D3: a diferencia de create_client, el service NO consulta plan_limits —
    el trigger trg_guard_supplier_plan_limit es la única capa que enforcea el
    límite (task 8.x mapea su rechazo P0B10 -> 403)."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value=SUPPLIER_ROW)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/suppliers",
            json={"name": "Distribuidora Sur"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    # Una sola llamada a fetchrow (el INSERT) — nunca una consulta previa a plan_limits.
    assert conn.fetchrow.await_count == 1
    insert_sql = conn.fetchrow.await_args.args[0]
    assert "plan_limits" not in insert_sql


# ── 7.7 TRIANGULATE — identidad fiscal completa vs. solo nombre ─────────────


async def test_create_supplier_with_full_fiscal_identity(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value=FISCAL_SUPPLIER_ROW)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/suppliers",
            json={
                "name": "Insumos del Este S.A.",
                "tax_id": "30-71234567-1",
                "iva_condition": "responsable_inscripto",
                "legal_name": "Insumos del Este Sociedad Anónima",
            },
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    data = resp.json()
    assert data["tax_id"] == "30-71234567-1"
    assert data["iva_condition"] == "responsable_inscripto"
    assert data["legal_name"] == "Insumos del Este Sociedad Anónima"
    insert_args = conn.fetchrow.await_args.args
    assert "30-71234567-1" in insert_args
    assert "responsable_inscripto" in insert_args


async def test_create_supplier_with_only_name(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value=SUPPLIER_ROW)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/suppliers",
            json={"name": "Distribuidora Sur"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    data = resp.json()
    assert data["tax_id"] is None
    assert data["iva_condition"] is None
    assert data["legal_name"] is None


async def test_create_supplier_invalid_iva_condition_returns_422(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value=FISCAL_SUPPLIER_ROW)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/suppliers",
            json={"name": "Test", "iva_condition": "inscripto_raro"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 422
    conn.fetchrow.assert_not_awaited()


# ── review B (BE-4): name en blanco es rechazado, alta y edición ───────────


async def test_create_supplier_blank_name_returns_422(async_client, mock_pool):
    """BE-4: " " (solo whitespace) no es un nombre válido — mismo criterio
    que rechazar el campo ausente, para no crear proveedores fantasma."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value=SUPPLIER_ROW)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/suppliers",
            json={"name": "   "},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 422
    assert resp.json()["field"] == "name"
    conn.fetchrow.assert_not_awaited()


async def test_update_supplier_blank_name_returns_422(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            f"/suppliers/{SUPPLIER_ID}",
            json={"name": "   "},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 422
    assert resp.json()["field"] == "name"
    conn.fetchrow.assert_not_awaited()


async def test_update_supplier_null_name_returns_422(async_client, mock_pool):
    """BE-1/SPEC-03: name informado como null explícito (a diferencia de
    ausente) también se rechaza -- el nombre no es un campo desimputable."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            f"/suppliers/{SUPPLIER_ID}",
            json={"name": None},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 422
    assert resp.json()["field"] == "name"
    conn.fetchrow.assert_not_awaited()


async def test_update_supplier_omitted_name_preserves(async_client, mock_pool):
    """Contraparte: name AUSENTE del payload no dispara ninguna validación —
    solo el envío explícito (blank o null) lo hace."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    updated_row = {**SUPPLIER_ROW, "phone": "+54 261 555-0000"}
    conn.fetchrow = AsyncMock(return_value=updated_row)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            f"/suppliers/{SUPPLIER_ID}",
            json={"phone": "+54 261 555-0000"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 200
    sql = conn.fetchrow.call_args.args[0]
    assert "name" not in sql.split("SET", 1)[1].split("WHERE", 1)[0]


# ── edición ───────────────────────────────────────────────────────────────


async def test_update_supplier_ok(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    updated_row = {**SUPPLIER_ROW, "phone": "+54 261 555-0000"}
    conn.fetchrow = AsyncMock(return_value=updated_row)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            f"/suppliers/{SUPPLIER_ID}",
            json={"phone": "+54 261 555-0000"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 200
    assert resp.json()["phone"] == "+54 261 555-0000"


async def test_update_supplier_member_forbidden(async_client, mock_pool):
    pool, conn = mock_pool
    member_token = make_token({"role": "member"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            f"/suppliers/{SUPPLIER_ID}",
            json={"phone": "+54 261 555-0000"},
            headers={"Authorization": f"Bearer {member_token}"},
        )
    assert resp.status_code == 403


async def test_update_supplier_cross_org_returns_404(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value=None)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            f"/suppliers/{SUPPLIER_ID}",
            json={"phone": "+54 261 555-0000"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 404


# ── review B (BE-1/SPEC-03): PUT /suppliers/{id} tri-estado real ───────────
# Antes, el service armaba el patch con payload.model_dump(exclude_none=True)
# y el repository filtraba "v is not None" -- un `tax_id: null` del form se
# ignoraba en silencio (ni preservaba con intención ni desimputaba: el
# usuario pedía borrar el campo y el campo seguía ahí). El contrato correcto
# es tri-estado por PRESENCIA (payload.model_fields_set), igual que
# payment_method_id/branch_id/supplier_id en la edición de operaciones.


async def test_update_supplier_clears_tax_id_with_explicit_null(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value={**SUPPLIER_ROW, "tax_id": None})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            f"/suppliers/{SUPPLIER_ID}",
            json={"tax_id": None},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 200
    sql = conn.fetchrow.call_args.args[0]
    set_clause = sql.split("SET", 1)[1].split("WHERE", 1)[0]
    assert "tax_id" in set_clause
    assert None in conn.fetchrow.call_args.args


async def test_update_supplier_clears_email_with_explicit_null(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value={**SUPPLIER_ROW, "email": None})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            f"/suppliers/{SUPPLIER_ID}",
            json={"email": None},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 200
    sql = conn.fetchrow.call_args.args[0]
    set_clause = sql.split("SET", 1)[1].split("WHERE", 1)[0]
    assert "email" in set_clause
    assert None in conn.fetchrow.call_args.args


async def test_update_supplier_clears_phone_with_explicit_null(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value={**SUPPLIER_ROW, "phone": None})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            f"/suppliers/{SUPPLIER_ID}",
            json={"phone": None},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 200
    sql = conn.fetchrow.call_args.args[0]
    set_clause = sql.split("SET", 1)[1].split("WHERE", 1)[0]
    assert "phone" in set_clause
    assert None in conn.fetchrow.call_args.args


async def test_update_supplier_clears_iva_condition_with_explicit_null(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value={**SUPPLIER_ROW, "iva_condition": None})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            f"/suppliers/{SUPPLIER_ID}",
            json={"iva_condition": None},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 200
    sql = conn.fetchrow.call_args.args[0]
    set_clause = sql.split("SET", 1)[1].split("WHERE", 1)[0]
    assert "iva_condition" in set_clause
    assert None in conn.fetchrow.call_args.args


async def test_update_supplier_omitted_fields_are_never_sent_to_repo(async_client, mock_pool):
    """Sin tax_id/email/phone/legal_name/iva_condition en el JSON, el UPDATE
    solo toca el campo realmente enviado (phone) -- el resto ni siquiera
    aparece en el SET, así que se preserva sin ambigüedad."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value={**SUPPLIER_ROW, "phone": "+54 261 555-0000"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            f"/suppliers/{SUPPLIER_ID}",
            json={"phone": "+54 261 555-0000"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 200
    sql = conn.fetchrow.call_args.args[0]
    set_clause = sql.split("SET", 1)[1].split("WHERE", 1)[0]
    for field in ("tax_id", "email", "legal_name", "iva_condition"):
        assert field not in set_clause


# ── baja (soft delete) ───────────────────────────────────────────────────────


async def test_delete_supplier_is_soft_delete(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value=SUPPLIER_ROW)  # get_by_id del service
    conn.execute = AsyncMock(return_value="UPDATE 1")
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/suppliers/{SUPPLIER_ID}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 204
    sql = conn.execute.call_args.args[0]
    assert "UPDATE suppliers" in sql
    assert "deleted_at = now()" in sql
    assert "DELETE FROM" not in sql
    assert "11111111-1111-1111-1111-111111111111" in conn.execute.call_args.args


async def test_delete_supplier_member_forbidden(async_client, mock_pool):
    pool, conn = mock_pool
    member_token = make_token({"role": "member"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/suppliers/{SUPPLIER_ID}",
            headers={"Authorization": f"Bearer {member_token}"},
        )
    assert resp.status_code == 403
    conn.fetchrow.assert_not_called()


async def test_delete_supplier_not_found(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value=None)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            f"/suppliers/{SUPPLIER_ID}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 404


async def test_delete_supplier_twice_second_call_is_404_not_crash(async_client, mock_pool):
    """7.6 TRIANGULATE: 'borrar dos veces -> no-op' — la segunda llamada NO
    reintenta el UPDATE (get_by_id ya filtra deleted_at IS NULL) y responde
    404 en vez de reventar o soft-deletear dos veces."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(side_effect=[SUPPLIER_ROW, None])
    conn.execute = AsyncMock(return_value="UPDATE 1")
    with patch("backend.core.database.pool", pool):
        first = await async_client.delete(
            f"/suppliers/{SUPPLIER_ID}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
        second = await async_client.delete(
            f"/suppliers/{SUPPLIER_ID}",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert first.status_code == 204
    assert second.status_code == 404
    # el segundo intento no llega a soft_delete: como mucho un UPDATE suppliers
    # (el del primer borrado) entre todas las llamadas a execute() del request
    # (las otras son el SET del JWT-passthrough de cada conexión).
    soft_delete_calls = [
        c for c in conn.execute.call_args_list if "UPDATE suppliers" in c.args[0]
    ]
    assert len(soft_delete_calls) == 1


# ── 7.6 TRIANGULATE — aislamiento por cuenta (get) ──────────────────────────


async def test_get_supplier_cross_org_returns_404(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetchrow = AsyncMock(return_value=None)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            f"/suppliers/{SUPPLIER_ID}",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 404
    assert "deleted_at IS NULL" in conn.fetchrow.call_args.args[0]


async def test_get_supplier_ok(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetchrow = AsyncMock(return_value=SUPPLIER_ROW)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            f"/suppliers/{SUPPLIER_ID}",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 200
    assert resp.json()["id"] == SUPPLIER_ID


# ── review B (SEC-3): un id malformado en el path es 422, no 500 ───────────
# Antes supplier_id: str dejaba pasar "abc" hasta el repository, que lo
# mandaba tal cual como parámetro $1::uuid a asyncpg -- DataError sin
# sqlstate mapeado en _BUSINESS_ERRCODE_STATUS -> caía al catch-all 500.
# uuid.UUID en la firma del router (mismo patrón que supplier_accounts.py,
# la superficie hermana de ESTA misma entidad) hace que FastAPI lo rechace
# en el borde con un 422 RFC 7807 estándar, antes de tocar la DB.


async def test_get_supplier_malformed_id_returns_422(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/suppliers/abc",
            headers={"Authorization": f"Bearer {valid_token}"},
        )
    assert resp.status_code == 422
    assert resp.json()["field"] == "supplier_id"
    conn.fetchrow.assert_not_awaited()


async def test_update_supplier_malformed_id_returns_422(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.put(
            "/suppliers/abc",
            json={"phone": "+54 261 555-0000"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 422
    assert resp.json()["field"] == "supplier_id"
    conn.fetchrow.assert_not_awaited()


async def test_delete_supplier_malformed_id_returns_422(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            "/suppliers/abc",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 422
    assert resp.json()["field"] == "supplier_id"
    conn.fetchrow.assert_not_awaited()


# ── 8.1/8.3 — el límite de plan (P0B10) llega traducido al cliente ─────────


async def test_create_supplier_over_plan_limit_returns_403(async_client, mock_pool):
    """8.1 RED / 8.2 GREEN: trg_guard_supplier_plan_limit rechaza el INSERT
    con P0B10 -> el handler global lo traduce a 403 (antes de mapear, 500)."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user", "app_metadata": {"plan": "gratis"}})
    err = asyncpg.exceptions.RaiseError(
        "Límite de proveedores alcanzado para el plan gratis (20 máx.). "
        "Borrá proveedores existentes o subí de plan."
    )
    err.sqlstate = "P0B10"
    conn.fetchrow = AsyncMock(side_effect=err)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/suppliers",
            json={"name": "Proveedor 21"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 403


async def test_create_supplier_over_plan_limit_detail_names_plan_limit_and_action(
    async_client, mock_pool
):
    """8.3 TRIANGULATE: el detail del RFC 7807 nombra el plan, el límite
    numérico y la acción que destraba (borrar proveedores o subir de plan) —
    el mismo mensaje que escribe fn_guard_supplier_plan_limit, preservado tal
    cual por asyncpg_error_handler (texto seguro: lo escribe nuestro propio
    SQL)."""
    pool, conn = mock_pool
    owner_token = make_token({"role": "user", "app_metadata": {"plan": "gratis"}})
    err = asyncpg.exceptions.RaiseError(
        "Límite de proveedores alcanzado para el plan gratis (20 máx.). "
        "Borrá proveedores existentes o subí de plan."
    )
    err.sqlstate = "P0B10"
    conn.fetchrow = AsyncMock(side_effect=err)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/suppliers",
            json={"name": "Proveedor 21"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 403
    detail = resp.json()["detail"].lower()
    assert "plan" in detail
    assert "20" in detail
    assert "borrá proveedores" in detail or "subí de plan" in detail
    assert resp.json()["code"] == "P0B10"


# review B (BE-3): test_deleted_supplier_frees_quota_for_the_count era
# tautologico -- mockeaba count_by_org para devolver {"total": 19} y solo
# reafirmaba ese mismo valor mockeado, sin ejercitar ninguna regla real.
# La cobertura real de count_by_org (SQL exacto: tabla suppliers,
# account_id = $1, deleted_at IS NULL) ya vive en
# test_supplier_repository.py::test_count_by_org_excludes_soft_deleted --
# se borra en vez de duplicarla. El comportamiento del TRIGGER
# (fn_guard_supplier_plan_limit contando solo vivos) se cubre en SQL, no
# en este archivo -- ver el gate 9 del baseline SQL de este change.
