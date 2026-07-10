"""
v3-catalog-masters — ClientAddressService (V3 §7.3).

Cada operación valida PRIMERO que el cliente exista y esté vivo (404 si no) —
las direcciones de un cliente soft-deleteado quedan lógicamente inalcanzables
sin necesidad de propagarles deleted_at (D4 del design). La primera dirección
viva de un cliente se marca primaria automáticamente (D3); el switch entre
primarias siempre pasa por el RPC rpc_set_primary_client_address (vía
repo.set_primary), nunca dos UPDATEs sueltos desde Python.
"""
from __future__ import annotations

from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.client_address_repository import ClientAddressRepository
from backend.repositories.client_repository import ClientRepository
from backend.schemas.client_addresses import ClientAddressCreate, ClientAddressUpdate


async def _require_live_client(client_repo: ClientRepository, account_id: str, client_id: str) -> None:
    client = await client_repo.get_by_id(client_id, account_id)
    if client is None:
        raise HTTPException(status_code=404, detail="Cliente no encontrado")


async def list_client_addresses(
    repo: ClientAddressRepository,
    client_repo: ClientRepository,
    auth: dict,
    account_id: str,
    client_id: str,
) -> list:
    await _require_live_client(client_repo, account_id, client_id)
    return await repo.list_by_client(client_id, account_id)


async def create_client_address(
    repo: ClientAddressRepository,
    client_repo: ClientRepository,
    auth: dict,
    account_id: str,
    client_id: str,
    payload: ClientAddressCreate,
) -> dict:
    require_role(auth, ["user", "admin"])
    await _require_live_client(client_repo, account_id, client_id)

    live_count = await repo.count_live_for_client(client_id, account_id)
    is_first = live_count == 0

    record = await repo.create(
        account_id=account_id,
        client_id=client_id,
        data=payload.model_dump(),
        is_primary=is_first,
    )
    if record is None:
        raise HTTPException(status_code=500, detail="Error al crear la dirección")
    return dict(record)


async def update_client_address(
    repo: ClientAddressRepository,
    client_repo: ClientRepository,
    auth: dict,
    account_id: str,
    client_id: str,
    address_id: str,
    payload: ClientAddressUpdate,
) -> dict:
    require_role(auth, ["user", "admin"])
    await _require_live_client(client_repo, account_id, client_id)

    record = await repo.update(address_id, account_id, payload.model_dump(exclude_none=True))
    if record is None:
        raise HTTPException(status_code=404, detail="Dirección no encontrada")
    return dict(record)


async def set_primary_client_address(
    repo: ClientAddressRepository,
    client_repo: ClientRepository,
    auth: dict,
    account_id: str,
    client_id: str,
    address_id: str,
) -> dict:
    """Switch atómico de la dirección primaria (D3 del design).

    Valida que la dirección exista, esté viva y pertenezca al `client_id`
    indicado ANTES de invocar el RPC — un `address_id` de otro cliente (aunque
    sea de la misma cuenta) se rechaza con 404, sin tocar ninguna fila.
    """
    require_role(auth, ["user", "admin"])
    await _require_live_client(client_repo, account_id, client_id)

    address = await repo.get_by_id(address_id, account_id)
    if address is None or dict(address)["client_id"] != client_id:
        raise HTTPException(status_code=404, detail="Dirección no encontrada")

    record = await repo.set_primary(address_id, account_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Dirección no encontrada")
    return dict(record)


async def delete_client_address(
    repo: ClientAddressRepository,
    client_repo: ClientRepository,
    auth: dict,
    account_id: str,
    client_id: str,
    address_id: str,
) -> None:
    """v3-soft-delete-policy: borrado soft (RN-B1/RN-B2)."""
    require_role(auth, ["user", "admin"])
    await _require_live_client(client_repo, account_id, client_id)

    existing = await repo.get_by_id(address_id, account_id)
    if existing is None:
        raise HTTPException(status_code=404, detail="Dirección no encontrada")
    await repo.soft_delete("client_addresses", address_id, account_id, auth["user_id"])
