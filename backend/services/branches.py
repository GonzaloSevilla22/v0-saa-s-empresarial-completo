from __future__ import annotations

from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.branch_repository import BranchRepository
from backend.schemas.branches import BranchCreate, BranchUpdate


async def list_branches(repo: BranchRepository, auth: dict) -> list:
    return await repo.list_by_org(auth["user_id"])


async def get_branch(repo: BranchRepository, auth: dict, branch_id: str) -> dict:
    record = await repo.get_by_id(branch_id, auth["user_id"])
    if record is None:
        raise HTTPException(status_code=404, detail="Sucursal no encontrada")
    return dict(record)


async def create_branch(repo: BranchRepository, auth: dict, payload: BranchCreate) -> dict:
    require_role(auth, ["owner", "admin"])
    record = await repo.create(auth["user_id"], payload.model_dump())
    if record is None:
        raise HTTPException(status_code=500, detail="Error al crear la sucursal")
    return dict(record)


async def update_branch(
    repo: BranchRepository, auth: dict, branch_id: str, payload: BranchUpdate
) -> dict:
    require_role(auth, ["owner", "admin"])
    record = await repo.update(branch_id, auth["user_id"], payload.model_dump(exclude_none=True))
    if record is None:
        raise HTTPException(status_code=404, detail="Sucursal no encontrada")
    return dict(record)
