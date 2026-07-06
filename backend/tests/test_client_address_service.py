"""
v3-catalog-masters — ClientAddressService TDD tests (task 5.1 RED / 5.2 GREEN).

Cubre: require_role(["user","admin"]) en mutaciones; 404 si el cliente no
existe o está borrado; auto-primaria en la primera dirección viva; set_primary
delega en el repo (que a su vez delega en el RPC); delete usa soft_delete().
Repository mockeado — sin interacción real con la DB.
"""
from __future__ import annotations

from unittest.mock import AsyncMock

import pytest
from fastapi import HTTPException

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
CLIENT_ID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
ADDRESS_ID = "dddddddd-dddd-dddd-dddd-dddddddddddd"
ADDRESS_ID_2 = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
USER_ID = "11111111-1111-1111-1111-111111111111"

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


def _make_auth(role: str) -> dict:
    return {"user_id": USER_ID, "role": role}


_SENTINEL = object()


def _make_repo(
    *,
    client_addr_result=_SENTINEL,
    create_result=_SENTINEL,
    update_result=_SENTINEL,
    set_primary_result=_SENTINEL,
    count_live=0,
    get_by_id_result=_SENTINEL,
):
    repo = AsyncMock()
    repo.list_by_client = AsyncMock(
        return_value=[ADDRESS_ROW] if client_addr_result is _SENTINEL else client_addr_result
    )
    repo.get_by_id = AsyncMock(
        return_value=ADDRESS_ROW if get_by_id_result is _SENTINEL else get_by_id_result
    )
    repo.count_live_for_client = AsyncMock(return_value=count_live)
    repo.create = AsyncMock(return_value=ADDRESS_ROW if create_result is _SENTINEL else create_result)
    repo.update = AsyncMock(return_value=ADDRESS_ROW if update_result is _SENTINEL else update_result)
    repo.set_primary = AsyncMock(
        return_value={**ADDRESS_ROW_2, "is_primary": True}
        if set_primary_result is _SENTINEL
        else set_primary_result
    )
    repo.soft_delete = AsyncMock(return_value=True)
    return repo


def _make_client_repo(get_result=_SENTINEL):
    client_repo = AsyncMock()
    client_repo.get_by_id = AsyncMock(
        return_value=CLIENT_ROW if get_result is _SENTINEL else get_result
    )
    return client_repo


# ── 5.1 RED: list requiere cliente vivo ────────────────────────────────────────

class TestClientAddressServiceList:
    @pytest.mark.asyncio
    async def test_list_returns_addresses_for_live_client(self):
        from backend.services.client_addresses import list_client_addresses

        repo = _make_repo()
        client_repo = _make_client_repo()
        auth = _make_auth("member")

        result = await list_client_addresses(repo, client_repo, auth, ACCOUNT_ID, CLIENT_ID)

        assert len(result) == 1
        repo.list_by_client.assert_awaited_once_with(CLIENT_ID, ACCOUNT_ID)

    @pytest.mark.asyncio
    async def test_list_raises_404_when_client_not_found(self):
        """El cliente inexistente/borrado → 404 antes de tocar client_addresses."""
        from backend.services.client_addresses import list_client_addresses

        repo = _make_repo()
        client_repo = _make_client_repo(get_result=None)
        auth = _make_auth("member")

        with pytest.raises(HTTPException) as exc_info:
            await list_client_addresses(repo, client_repo, auth, ACCOUNT_ID, "nonexistent")

        assert exc_info.value.status_code == 404
        repo.list_by_client.assert_not_awaited()


# ── 5.1 RED: create — require_role + auto-primaria en la primera ──────────────

class TestClientAddressServiceCreate:
    @pytest.mark.asyncio
    async def test_create_readonly_role_raises_403(self):
        from backend.services.client_addresses import create_client_address
        from backend.schemas.client_addresses import ClientAddressCreate

        repo = _make_repo()
        client_repo = _make_client_repo()
        auth = _make_auth("readonly")
        payload = ClientAddressCreate(alias="Depósito")

        with pytest.raises(HTTPException) as exc_info:
            await create_client_address(repo, client_repo, auth, ACCOUNT_ID, CLIENT_ID, payload)

        assert exc_info.value.status_code == 403
        repo.create.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_create_first_address_is_marked_primary(self):
        """La primera dirección viva de un cliente se marca primaria automáticamente."""
        from backend.services.client_addresses import create_client_address
        from backend.schemas.client_addresses import ClientAddressCreate

        repo = _make_repo(count_live=0, create_result=ADDRESS_ROW)
        client_repo = _make_client_repo()
        auth = _make_auth("user")
        payload = ClientAddressCreate(alias="Depósito", street="Calle Falsa 123")

        result = await create_client_address(repo, client_repo, auth, ACCOUNT_ID, CLIENT_ID, payload)

        assert result["is_primary"] is True
        repo.create.assert_awaited_once()
        call_kwargs = repo.create.call_args.kwargs
        assert call_kwargs["is_primary"] is True

    @pytest.mark.asyncio
    async def test_create_second_address_is_not_primary(self):
        """Si el cliente ya tiene una dirección viva, la nueva NO es primaria."""
        from backend.services.client_addresses import create_client_address
        from backend.schemas.client_addresses import ClientAddressCreate

        repo = _make_repo(count_live=1, create_result=ADDRESS_ROW_2)
        client_repo = _make_client_repo()
        auth = _make_auth("user")
        payload = ClientAddressCreate(alias="Sucursal")

        result = await create_client_address(repo, client_repo, auth, ACCOUNT_ID, CLIENT_ID, payload)

        assert result["is_primary"] is False
        call_kwargs = repo.create.call_args.kwargs
        assert call_kwargs["is_primary"] is False

    @pytest.mark.asyncio
    async def test_create_raises_404_when_client_not_found_or_deleted(self):
        from backend.services.client_addresses import create_client_address
        from backend.schemas.client_addresses import ClientAddressCreate

        repo = _make_repo()
        client_repo = _make_client_repo(get_result=None)
        auth = _make_auth("user")
        payload = ClientAddressCreate(alias="Depósito")

        with pytest.raises(HTTPException) as exc_info:
            await create_client_address(repo, client_repo, auth, ACCOUNT_ID, "nonexistent", payload)

        assert exc_info.value.status_code == 404
        repo.create.assert_not_awaited()


# ── 5.1 RED: update ─────────────────────────────────────────────────────────────

class TestClientAddressServiceUpdate:
    @pytest.mark.asyncio
    async def test_update_readonly_role_raises_403(self):
        from backend.services.client_addresses import update_client_address
        from backend.schemas.client_addresses import ClientAddressUpdate

        repo = _make_repo()
        client_repo = _make_client_repo()
        auth = _make_auth("readonly")
        payload = ClientAddressUpdate(city="Godoy Cruz")

        with pytest.raises(HTTPException) as exc_info:
            await update_client_address(
                repo, client_repo, auth, ACCOUNT_ID, CLIENT_ID, ADDRESS_ID, payload
            )

        assert exc_info.value.status_code == 403
        repo.update.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_update_not_found_raises_404(self):
        from backend.services.client_addresses import update_client_address
        from backend.schemas.client_addresses import ClientAddressUpdate

        repo = _make_repo(update_result=None)
        client_repo = _make_client_repo()
        auth = _make_auth("user")
        payload = ClientAddressUpdate(city="Godoy Cruz")

        with pytest.raises(HTTPException) as exc_info:
            await update_client_address(
                repo, client_repo, auth, ACCOUNT_ID, CLIENT_ID, "nonexistent", payload
            )

        assert exc_info.value.status_code == 404


# ── 5.1 RED: set_primary — dirección de otro cliente/cuenta rechazada ─────────

class TestClientAddressServiceSetPrimary:
    @pytest.mark.asyncio
    async def test_set_primary_delegates_to_rpc_via_repo(self):
        from backend.services.client_addresses import set_primary_client_address

        repo = _make_repo(
            get_by_id_result=ADDRESS_ROW_2,
            set_primary_result={**ADDRESS_ROW_2, "is_primary": True},
        )
        client_repo = _make_client_repo()
        auth = _make_auth("user")

        result = await set_primary_client_address(
            repo, client_repo, auth, ACCOUNT_ID, CLIENT_ID, ADDRESS_ID_2
        )

        assert result["is_primary"] is True
        repo.set_primary.assert_awaited_once_with(ADDRESS_ID_2, ACCOUNT_ID)

    @pytest.mark.asyncio
    async def test_set_primary_address_not_belonging_to_client_returns_404(self):
        """La dirección existe pero pertenece a OTRO cliente → rechazado."""
        from backend.services.client_addresses import set_primary_client_address

        other_client_address = {**ADDRESS_ROW_2, "client_id": "other-client-id"}
        repo = _make_repo(get_by_id_result=other_client_address)
        client_repo = _make_client_repo()
        auth = _make_auth("user")

        with pytest.raises(HTTPException) as exc_info:
            await set_primary_client_address(
                repo, client_repo, auth, ACCOUNT_ID, CLIENT_ID, ADDRESS_ID_2
            )

        assert exc_info.value.status_code == 404
        repo.set_primary.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_set_primary_nonexistent_address_returns_404(self):
        from backend.services.client_addresses import set_primary_client_address

        repo = _make_repo(get_by_id_result=None)
        client_repo = _make_client_repo()
        auth = _make_auth("user")

        with pytest.raises(HTTPException) as exc_info:
            await set_primary_client_address(
                repo, client_repo, auth, ACCOUNT_ID, CLIENT_ID, "nonexistent"
            )

        assert exc_info.value.status_code == 404
        repo.set_primary.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_set_primary_readonly_role_raises_403(self):
        from backend.services.client_addresses import set_primary_client_address

        repo = _make_repo(get_by_id_result=ADDRESS_ROW_2)
        client_repo = _make_client_repo()
        auth = _make_auth("readonly")

        with pytest.raises(HTTPException) as exc_info:
            await set_primary_client_address(
                repo, client_repo, auth, ACCOUNT_ID, CLIENT_ID, ADDRESS_ID_2
            )

        assert exc_info.value.status_code == 403
        repo.set_primary.assert_not_awaited()


# ── 5.1 RED: delete es soft ─────────────────────────────────────────────────────

class TestClientAddressServiceDelete:
    @pytest.mark.asyncio
    async def test_delete_uses_soft_delete(self):
        from backend.services.client_addresses import delete_client_address

        repo = _make_repo(get_by_id_result=ADDRESS_ROW)
        client_repo = _make_client_repo()
        auth = _make_auth("user")

        await delete_client_address(repo, client_repo, auth, ACCOUNT_ID, CLIENT_ID, ADDRESS_ID)

        repo.soft_delete.assert_awaited_once_with(
            "client_addresses", ADDRESS_ID, ACCOUNT_ID, USER_ID
        )

    @pytest.mark.asyncio
    async def test_delete_readonly_role_raises_403(self):
        from backend.services.client_addresses import delete_client_address

        repo = _make_repo(get_by_id_result=ADDRESS_ROW)
        client_repo = _make_client_repo()
        auth = _make_auth("readonly")

        with pytest.raises(HTTPException) as exc_info:
            await delete_client_address(repo, client_repo, auth, ACCOUNT_ID, CLIENT_ID, ADDRESS_ID)

        assert exc_info.value.status_code == 403
        repo.soft_delete.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_delete_not_found_raises_404(self):
        from backend.services.client_addresses import delete_client_address

        repo = _make_repo(get_by_id_result=None)
        client_repo = _make_client_repo()
        auth = _make_auth("user")

        with pytest.raises(HTTPException) as exc_info:
            await delete_client_address(repo, client_repo, auth, ACCOUNT_ID, CLIENT_ID, "nonexistent")

        assert exc_info.value.status_code == 404


# ── 5.3 TRIANGULATE ─────────────────────────────────────────────────────────────

class TestClientAddressServiceTriangulate:
    @pytest.mark.asyncio
    async def test_admin_role_can_create(self):
        """TRIANGULATE: admin (además de user) puede crear."""
        from backend.services.client_addresses import create_client_address
        from backend.schemas.client_addresses import ClientAddressCreate

        repo = _make_repo(count_live=0, create_result=ADDRESS_ROW)
        client_repo = _make_client_repo()
        auth = _make_auth("admin")
        payload = ClientAddressCreate(alias="Depósito")

        result = await create_client_address(repo, client_repo, auth, ACCOUNT_ID, CLIENT_ID, payload)

        assert result is not None
        repo.create.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_set_primary_idempotent_on_already_primary(self):
        """TRIANGULATE: marcar como primaria la que ya es primaria no rompe."""
        from backend.services.client_addresses import set_primary_client_address

        repo = _make_repo(
            get_by_id_result=ADDRESS_ROW,  # ya es is_primary=True
            set_primary_result=ADDRESS_ROW,
        )
        client_repo = _make_client_repo()
        auth = _make_auth("user")

        result = await set_primary_client_address(
            repo, client_repo, auth, ACCOUNT_ID, CLIENT_ID, ADDRESS_ID
        )

        assert result["is_primary"] is True
        repo.set_primary.assert_awaited_once_with(ADDRESS_ID, ACCOUNT_ID)
