from __future__ import annotations

from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.client_repository import ClientRepository
from backend.schemas.clients import ClientCreate, ClientUpdate


async def list_clients(repo: ClientRepository, account_id: str) -> list:
    return await repo.list_by_org(account_id)


async def get_client(repo: ClientRepository, account_id: str, client_id: str) -> dict:
    record = await repo.get_by_id(client_id, account_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Cliente no encontrado")
    return dict(record)


async def create_client(repo: ClientRepository, auth: dict, account_id: str, payload: ClientCreate) -> dict:
    require_role(auth, ["user", "admin"])
    record = await repo.create(auth["user_id"], account_id, payload.model_dump())
    if record is None:
        raise HTTPException(status_code=500, detail="Error al crear el cliente")
    return dict(record)


async def update_client(
    repo: ClientRepository, auth: dict, account_id: str, client_id: str, payload: ClientUpdate
) -> dict:
    require_role(auth, ["user", "admin"])
    record = await repo.update(client_id, account_id, payload.model_dump(exclude_none=True))
    if record is None:
        raise HTTPException(status_code=404, detail="Cliente no encontrado")
    return dict(record)


async def delete_client(repo: ClientRepository, auth: dict, account_id: str, client_id: str) -> None:
    require_role(auth, ["user", "admin"])
    existing = await repo.get_by_id(client_id, account_id)
    if existing is None:
        raise HTTPException(status_code=404, detail="Cliente no encontrado")
    await repo.delete(client_id, account_id)
