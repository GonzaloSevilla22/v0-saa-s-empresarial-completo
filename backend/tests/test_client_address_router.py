"""
v3-catalog-masters — Router endpoint tests (task 6.1 RED / 6.2 GREEN / 6.3 TRIANGULATE).

Endpoints anidados bajo el cliente:
  GET    /clients/{client_id}/addresses
  POST   /clients/{client_id}/addresses
  PUT    /clients/{client_id}/addresses/{address_id}
  DELETE /clients/{client_id}/addresses/{address_id}
  POST   /clients/{client_id}/addresses/{address_id}/set-primary

Usa TestClient (async_client fixture de conftest.py) contra la app real;
mock_pool sustituye la conexión asyncpg — sin DB real.
"""
from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import make_token

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
CLIENT_ID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
ADDRESS_ID = "dddddddd-dddd-dddd-dddd-dddddddddddd"
ADDRESS_ID_2 = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"

CLIENT_ROW = {"id": CLIENT_ID, "account_id": ACCOUNT_ID, "name": "Acme Corp"}

ADDRESS_ROW = {
    "id": ADDRESS_ID,
    "account_id": ACCOUNT_ID,
    "client_id": CLIENT_ID,
    "alias": "Depósito",
    "street": "Calle Falsa 123",
    "city": None,
    "province": None,
    "postal_code": None,
    "notes": None,
    "is_primary": True,
    "created_at": "2026-08-13T10:00:00+00:00",
    "updated_at": None,
}

ADDRESS_ROW_2 = {**ADDRESS_ROW, "id": ADDRESS_ID_2, "alias": "Sucursal", "is_primary": False}


# ── 6.1 RED / 6.2 GREEN: GET (list) ────────────────────────────────────────────

class TestListClientAddressesEndpoint:
    @pytest.mark.asyncio
    async def test_get_addresses_ok(self, async_client, valid_token, mock_pool):
        pool, conn = mock_pool
        # 1st fetchrow = client lookup (service._require_live_client); fetch = list
        conn.fetchrow = AsyncMock(return_value=CLIENT_ROW)
        conn.fetch = AsyncMock(return_value=[ADDRESS_ROW])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/clients/{CLIENT_ID}/addresses",
                headers={"Authorization": f"Bearer {valid_token}"},
            )
        assert resp.status_code == 200
        data = resp.json()
        assert data[0]["alias"] == "Depósito"

    @pytest.mark.asyncio
    async def test_get_addresses_client_not_found_returns_404(self, async_client, valid_token, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=None)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/clients/nonexistent/addresses",
                headers={"Authorization": f"Bearer {valid_token}"},
            )
        assert resp.status_code == 404


# ── 6.1 RED / 6.2 GREEN: POST (create) ─────────────────────────────────────────

class TestCreateClientAddressEndpoint:
    @pytest.mark.asyncio
    async def test_post_valid_payload_returns_201(self, async_client, mock_pool):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(return_value=CLIENT_ROW)  # client lookup
        conn.fetchval = AsyncMock(return_value=0)  # count_live_for_client
        conn.fetch = AsyncMock(return_value=[])

        async def _fetchrow_side_effect(query, *args):
            if "INSERT INTO client_addresses" in query:
                return ADDRESS_ROW
            return CLIENT_ROW

        conn.fetchrow = AsyncMock(side_effect=_fetchrow_side_effect)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/clients/{CLIENT_ID}/addresses",
                json={"alias": "Depósito", "street": "Calle Falsa 123"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 201
        assert resp.json()["alias"] == "Depósito"

    @pytest.mark.asyncio
    async def test_post_without_write_permission_returns_403(self, async_client, mock_pool):
        pool, conn = mock_pool
        readonly_token = make_token({"role": "readonly"})
        conn.fetchrow = AsyncMock(return_value=CLIENT_ROW)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/clients/{CLIENT_ID}/addresses",
                json={"alias": "Depósito"},
                headers={"Authorization": f"Bearer {readonly_token}"},
            )
        assert resp.status_code == 403

    @pytest.mark.asyncio
    async def test_post_client_not_found_returns_404(self, async_client, mock_pool):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(return_value=None)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/clients/nonexistent/addresses",
                json={"alias": "Depósito"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 404

    @pytest.mark.asyncio
    async def test_post_unauthenticated_returns_401(self, async_client, mock_pool):
        pool, conn = mock_pool
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/clients/{CLIENT_ID}/addresses",
                json={"alias": "Depósito"},
            )
        assert resp.status_code == 401


# ── 6.1 RED / 6.2 GREEN: PUT (update) ──────────────────────────────────────────

class TestUpdateClientAddressEndpoint:
    @pytest.mark.asyncio
    async def test_put_valid_payload_returns_200(self, async_client, mock_pool):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        updated_row = {**ADDRESS_ROW, "city": "Godoy Cruz"}

        async def _fetchrow_side_effect(query, *args):
            if "UPDATE client_addresses" in query:
                return updated_row
            return CLIENT_ROW

        conn.fetchrow = AsyncMock(side_effect=_fetchrow_side_effect)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                f"/clients/{CLIENT_ID}/addresses/{ADDRESS_ID}",
                json={"city": "Godoy Cruz"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 200
        assert resp.json()["city"] == "Godoy Cruz"

    @pytest.mark.asyncio
    async def test_put_address_not_found_returns_404(self, async_client, mock_pool):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})

        async def _fetchrow_side_effect(query, *args):
            if "UPDATE client_addresses" in query:
                return None
            return CLIENT_ROW

        conn.fetchrow = AsyncMock(side_effect=_fetchrow_side_effect)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                f"/clients/{CLIENT_ID}/addresses/nonexistent",
                json={"city": "Godoy Cruz"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 404


# ── 6.1 RED / 6.2 GREEN: DELETE ─────────────────────────────────────────────────

class TestDeleteClientAddressEndpoint:
    @pytest.mark.asyncio
    async def test_delete_returns_204(self, async_client, mock_pool):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(return_value=CLIENT_ROW)  # client lookup + get_by_id(address)

        async def _fetchrow_side_effect(query, *args):
            return CLIENT_ROW if "clients" in query.lower() and "client_addresses" not in query.lower() else ADDRESS_ROW

        conn.fetchrow = AsyncMock(side_effect=_fetchrow_side_effect)
        conn.execute = AsyncMock(return_value="UPDATE 1")

        with patch("backend.core.database.pool", pool):
            resp = await async_client.delete(
                f"/clients/{CLIENT_ID}/addresses/{ADDRESS_ID}",
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 204
        sql = conn.execute.call_args.args[0]
        assert "UPDATE client_addresses" in sql
        assert "deleted_at = now()" in sql

    @pytest.mark.asyncio
    async def test_delete_without_permission_returns_403(self, async_client, mock_pool):
        pool, conn = mock_pool
        readonly_token = make_token({"role": "readonly"})
        conn.fetchrow = AsyncMock(return_value=CLIENT_ROW)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.delete(
                f"/clients/{CLIENT_ID}/addresses/{ADDRESS_ID}",
                headers={"Authorization": f"Bearer {readonly_token}"},
            )
        assert resp.status_code == 403


# ── 6.1 RED / 6.2 GREEN: POST set-primary ──────────────────────────────────────

class TestSetPrimaryClientAddressEndpoint:
    @pytest.mark.asyncio
    async def test_set_primary_returns_200(self, async_client, mock_pool):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})

        async def _fetchrow_side_effect(query, *args):
            if "rpc_set_primary_client_address" in query:
                return {**ADDRESS_ROW_2, "is_primary": True}
            if "client_addresses" in query:
                return ADDRESS_ROW_2
            return CLIENT_ROW

        conn.fetchrow = AsyncMock(side_effect=_fetchrow_side_effect)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/clients/{CLIENT_ID}/addresses/{ADDRESS_ID_2}/set-primary",
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 200
        assert resp.json()["is_primary"] is True

    @pytest.mark.asyncio
    async def test_set_primary_cross_client_returns_404(self, async_client, mock_pool):
        """address_id existe pero pertenece a OTRO cliente → 404 (task 6.1)."""
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        other_client_address = {**ADDRESS_ROW_2, "client_id": "other-client-id"}

        async def _fetchrow_side_effect(query, *args):
            if "client_addresses" in query:
                return other_client_address
            return CLIENT_ROW

        conn.fetchrow = AsyncMock(side_effect=_fetchrow_side_effect)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/clients/{CLIENT_ID}/addresses/{ADDRESS_ID_2}/set-primary",
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 404

    # ── 6.3 TRIANGULATE ─────────────────────────────────────────────────────────

    @pytest.mark.asyncio
    async def test_set_primary_idempotent_on_already_primary(self, async_client, mock_pool):
        """TRIANGULATE: marcar como primaria la que ya lo es no rompe (200)."""
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})

        async def _fetchrow_side_effect(query, *args):
            if "rpc_set_primary_client_address" in query:
                return ADDRESS_ROW  # ya era is_primary=True
            if "client_addresses" in query:
                return ADDRESS_ROW
            return CLIENT_ROW

        conn.fetchrow = AsyncMock(side_effect=_fetchrow_side_effect)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/clients/{CLIENT_ID}/addresses/{ADDRESS_ID}/set-primary",
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 200
        assert resp.json()["is_primary"] is True

    @pytest.mark.asyncio
    async def test_create_second_non_primary_address_does_not_touch_first(self, async_client, mock_pool):
        """TRIANGULATE: crear una 2da dirección no-primaria no toca la 1ra
        (el service consulta count_live_for_client, no hace UPDATE alguno
        sobre la existente)."""
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchval = AsyncMock(return_value=1)  # ya hay 1 dirección viva

        async def _fetchrow_side_effect(query, *args):
            if "INSERT INTO client_addresses" in query:
                return ADDRESS_ROW_2
            return CLIENT_ROW

        conn.fetchrow = AsyncMock(side_effect=_fetchrow_side_effect)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/clients/{CLIENT_ID}/addresses",
                json={"alias": "Sucursal"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 201
        assert resp.json()["is_primary"] is False
        # Ningún UPDATE se emitió sobre client_addresses (solo el INSERT vía
        # fetchrow); el único conn.execute es el set_config de JWT-passthrough
        # de get_db_conn, no una escritura sobre la dirección existente.
        for call in conn.execute.call_args_list:
            assert "UPDATE client_addresses" not in call.args[0]
