from __future__ import annotations

from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.client_repository import ClientRepository
from backend.repositories.plan_limits_repository import PlanLimitsRepository
from backend.schemas.clients import ClientCreate, ClientUpdate


async def list_clients(repo: ClientRepository, account_id: str) -> list:
    return await repo.list_by_org(account_id)


async def get_client(repo: ClientRepository, account_id: str, client_id: str) -> dict:
    record = await repo.get_by_id(client_id, account_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Cliente no encontrado")
    return dict(record)


async def create_client(
    repo: ClientRepository,
    auth: dict,
    account_id: str,
    payload: ClientCreate,
    plan_limits_repo: PlanLimitsRepository,
) -> dict:
    require_role(auth, ["user", "admin"])
    plan = auth.get("plan", "pro")
    limits = await plan_limits_repo.get_limits(plan)
    limit = limits["max_clients"]
    current_count = await repo.count_by_org(account_id)
    if current_count >= limit:
        raise HTTPException(
            status_code=403,
            detail=f"Límite de clientes alcanzado para el plan {plan} ({limit} máx.). Borrá clientes existentes o subí de plan.",
        )
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
    """v3-soft-delete-policy: borrado soft (RN-B1/RN-B2) — la fila persiste
    con deleted_at + deleted_by y sale de todas las lecturas por defecto."""
    require_role(auth, ["user", "admin"])
    existing = await repo.get_by_id(client_id, account_id)
    if existing is None:
        raise HTTPException(status_code=404, detail="Cliente no encontrado")
    await repo.soft_delete("clients", client_id, account_id, auth["user_id"])
