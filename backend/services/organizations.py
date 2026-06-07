from __future__ import annotations

from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.organization_repository import OrganizationRepository
from backend.schemas.organizations import OrgSettingsUpdate


async def get_org(repo: OrganizationRepository, auth: dict, org_id: str) -> dict:
    record = await repo.get_by_id(org_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Organización no encontrada")
    return dict(record)


async def update_org_settings(
    repo: OrganizationRepository, auth: dict, org_id: str, payload: OrgSettingsUpdate
) -> dict:
    require_role(auth, ["owner"])
    record = await repo.update_settings(org_id, payload.model_dump(exclude_none=True))
    if record is None:
        raise HTTPException(status_code=404, detail="Organización no encontrada")
    return dict(record)
