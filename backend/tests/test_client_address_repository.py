"""
v3-catalog-masters — ClientAddressRepository TDD tests (task 3.1 RED / 3.2 GREEN).

Tests cover ClientAddressRepository methods via asyncpg mock. No real DB is
touched — all SQL is verified through call_args, mirroring
test_cost_center_repository.py / test_bank_account_crud.py conventions.
"""
from __future__ import annotations

from unittest.mock import AsyncMock

import pytest

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
CLIENT_ID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
ADDRESS_ID = "dddddddd-dddd-dddd-dddd-dddddddddddd"
ADDRESS_ID_2 = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"

ADDRESS_ROW = {
    "id": ADDRESS_ID,
    "account_id": ACCOUNT_ID,
    "client_id": CLIENT_ID,
    "alias": "Depósito",
    "street": "Calle Falsa 123",
    "city": "Mendoza",
    "province": "Mendoza",
    "postal_code": "5500",
    "notes": None,
    "is_primary": True,
    "created_at": "2026-08-13T10:00:00+00:00",
    "updated_at": None,
}

ADDRESS_ROW_2 = {
    **ADDRESS_ROW,
    "id": ADDRESS_ID_2,
    "alias": "Sucursal",
    "is_primary": False,
}


@pytest.fixture
def client_address_repo():
    from backend.repositories.client_address_repository import ClientAddressRepository

    conn = AsyncMock()
    return ClientAddressRepository(conn), conn


# ── 3.1 RED: list_by_client ────────────────────────────────────────────────────

class TestClientAddressRepositoryList:
    @pytest.mark.asyncio
    async def test_list_by_client_excludes_deleted(self, client_address_repo):
        """list_by_client excluye direcciones borradas (RN-B1: deleted_at IS NULL)."""
        repo, conn = client_address_repo
        conn.fetch = AsyncMock(return_value=[ADDRESS_ROW])

        result = await repo.list_by_client(CLIENT_ID, ACCOUNT_ID)

        assert len(result) == 1
        sql = conn.fetch.call_args.args[0]
        assert "deleted_at IS NULL" in sql

    @pytest.mark.asyncio
    async def test_list_by_client_filters_by_account_id(self, client_address_repo):
        """list_by_client filtra por account_id (aislamiento de tenancy)."""
        repo, conn = client_address_repo
        conn.fetch = AsyncMock(return_value=[])

        await repo.list_by_client(CLIENT_ID, ACCOUNT_ID)

        args = conn.fetch.call_args.args
        assert CLIENT_ID in args
        assert ACCOUNT_ID in args

    @pytest.mark.asyncio
    async def test_list_by_client_empty_when_no_addresses(self, client_address_repo):
        repo, conn = client_address_repo
        conn.fetch = AsyncMock(return_value=[])

        result = await repo.list_by_client(CLIENT_ID, ACCOUNT_ID)

        assert result == []


# ── 3.1 RED: get_by_id ─────────────────────────────────────────────────────────

class TestClientAddressRepositoryGetById:
    @pytest.mark.asyncio
    async def test_get_by_id_returns_row(self, client_address_repo):
        repo, conn = client_address_repo
        conn.fetchrow = AsyncMock(return_value=ADDRESS_ROW)

        result = await repo.get_by_id(ADDRESS_ID, ACCOUNT_ID)

        assert result is not None
        assert dict(result)["id"] == ADDRESS_ID

    @pytest.mark.asyncio
    async def test_get_by_id_excludes_deleted(self, client_address_repo):
        repo, conn = client_address_repo
        conn.fetchrow = AsyncMock(return_value=None)

        await repo.get_by_id(ADDRESS_ID, ACCOUNT_ID)

        sql = conn.fetchrow.call_args.args[0]
        assert "deleted_at IS NULL" in sql

    @pytest.mark.asyncio
    async def test_get_by_id_returns_none_when_not_found(self, client_address_repo):
        repo, conn = client_address_repo
        conn.fetchrow = AsyncMock(return_value=None)

        result = await repo.get_by_id("nonexistent", ACCOUNT_ID)

        assert result is None


# ── 3.1 RED: count_live_for_client ─────────────────────────────────────────────

class TestClientAddressRepositoryCountLive:
    @pytest.mark.asyncio
    async def test_count_live_for_client_returns_zero_when_none(self, client_address_repo):
        repo, conn = client_address_repo
        conn.fetchval = AsyncMock(return_value=0)

        result = await repo.count_live_for_client(CLIENT_ID, ACCOUNT_ID)

        assert result == 0

    @pytest.mark.asyncio
    async def test_count_live_for_client_excludes_deleted(self, client_address_repo):
        repo, conn = client_address_repo
        conn.fetchval = AsyncMock(return_value=1)

        await repo.count_live_for_client(CLIENT_ID, ACCOUNT_ID)

        sql = conn.fetchval.call_args.args[0]
        assert "deleted_at IS NULL" in sql


# ── 3.1 RED: create — marca primaria la primera dirección ─────────────────────

class TestClientAddressRepositoryCreate:
    @pytest.mark.asyncio
    async def test_create_first_address_marks_primary(self, client_address_repo):
        """create() con is_primary=True (decidido por el service en la 1ra alta)
        persiste is_primary=true."""
        repo, conn = client_address_repo
        conn.fetchrow = AsyncMock(return_value=ADDRESS_ROW)

        result = await repo.create(
            account_id=ACCOUNT_ID,
            client_id=CLIENT_ID,
            data={"alias": "Depósito", "street": "Calle Falsa 123"},
            is_primary=True,
        )

        assert result is not None
        assert dict(result)["is_primary"] is True
        sql = conn.fetchrow.call_args.args[0].upper()
        assert "INSERT" in sql
        assert "RETURNING" in sql

    @pytest.mark.asyncio
    async def test_create_second_address_not_primary_by_default(self, client_address_repo):
        """create() con is_primary=False (decidido por el service cuando ya
        existe una primaria) persiste is_primary=false."""
        repo, conn = client_address_repo
        conn.fetchrow = AsyncMock(return_value=ADDRESS_ROW_2)

        result = await repo.create(
            account_id=ACCOUNT_ID,
            client_id=CLIENT_ID,
            data={"alias": "Sucursal"},
            is_primary=False,
        )

        assert dict(result)["is_primary"] is False
        args = conn.fetchrow.call_args.args
        assert False in args


# ── 3.1 RED: update ────────────────────────────────────────────────────────────

class TestClientAddressRepositoryUpdate:
    @pytest.mark.asyncio
    async def test_update_returns_updated_row(self, client_address_repo):
        repo, conn = client_address_repo
        updated = {**ADDRESS_ROW, "city": "Godoy Cruz"}
        conn.fetchrow = AsyncMock(return_value=updated)

        result = await repo.update(
            ADDRESS_ID, ACCOUNT_ID, {"city": "Godoy Cruz"}
        )

        assert result is not None
        assert dict(result)["city"] == "Godoy Cruz"
        sql = conn.fetchrow.call_args.args[0].upper()
        assert "UPDATE" in sql

    @pytest.mark.asyncio
    async def test_update_excludes_deleted(self, client_address_repo):
        repo, conn = client_address_repo
        conn.fetchrow = AsyncMock(return_value=None)

        await repo.update(ADDRESS_ID, ACCOUNT_ID, {"city": "X"})

        sql = conn.fetchrow.call_args.args[0]
        assert "deleted_at IS NULL" in sql

    @pytest.mark.asyncio
    async def test_update_not_found_returns_none(self, client_address_repo):
        repo, conn = client_address_repo
        conn.fetchrow = AsyncMock(return_value=None)

        result = await repo.update("nonexistent", ACCOUNT_ID, {"city": "X"})

        assert result is None


# ── 3.1 RED: set_primary delega en el RPC ──────────────────────────────────────

class TestClientAddressRepositorySetPrimary:
    @pytest.mark.asyncio
    async def test_set_primary_invokes_rpc(self, client_address_repo):
        """set_primary delega en rpc_set_primary_client_address (switch atómico
        en DB, D3 del design) — no hace dos UPDATEs sueltos desde Python."""
        repo, conn = client_address_repo
        conn.fetchrow = AsyncMock(return_value={**ADDRESS_ROW_2, "is_primary": True})

        result = await repo.set_primary(ADDRESS_ID_2, ACCOUNT_ID)

        assert result is not None
        assert dict(result)["is_primary"] is True
        sql = conn.fetchrow.call_args.args[0]
        assert "rpc_set_primary_client_address" in sql

    @pytest.mark.asyncio
    async def test_set_primary_passes_address_and_account_id(self, client_address_repo):
        repo, conn = client_address_repo
        conn.fetchrow = AsyncMock(return_value=ADDRESS_ROW)

        await repo.set_primary(ADDRESS_ID, ACCOUNT_ID)

        args = conn.fetchrow.call_args.args
        assert ADDRESS_ID in args
        assert ACCOUNT_ID in args

    @pytest.mark.asyncio
    async def test_set_primary_returns_none_when_rpc_returns_none(self, client_address_repo):
        """Si la RPC no encuentra la fila (o el driver la mapea a None), el
        repo propaga None — el service lo traduce a 404."""
        repo, conn = client_address_repo
        conn.fetchrow = AsyncMock(return_value=None)

        result = await repo.set_primary("nonexistent", ACCOUNT_ID)

        assert result is None


# ═══════════════════════════════════════════════════════════════════════════════
# v3-soft-delete-policy: client_addresses en la allowlist de soft_delete()
# ═══════════════════════════════════════════════════════════════════════════════

class TestClientAddressSoftDelete:
    @pytest.mark.asyncio
    async def test_soft_delete_client_addresses_allowed_and_marks_row(self, client_address_repo):
        """"client_addresses" está en SOFT_DELETE_TABLES — el borrado real
        setea deleted_at + deleted_by (RN-B2), nunca DELETE físico."""
        repo, conn = client_address_repo
        conn.execute = AsyncMock(return_value="UPDATE 1")

        affected = await repo.soft_delete(
            "client_addresses", ADDRESS_ID, ACCOUNT_ID,
            "11111111-1111-1111-1111-111111111111",
        )

        assert affected is True
        sql = conn.execute.call_args.args[0]
        assert "UPDATE client_addresses" in sql
        assert "deleted_at = now()" in sql
        assert "DELETE FROM" not in sql
