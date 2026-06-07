from __future__ import annotations

import asyncpg
from fastapi import APIRouter, Depends

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.repositories.organization_repository import OrganizationRepository
from backend.schemas.organizations import OrgOut, OrgSettingsUpdate
from backend.services import organizations as org_service

router = APIRouter(prefix="/organizations", tags=["organizations"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> OrganizationRepository:
    return OrganizationRepository(conn)


@router.get("/{org_id}", response_model=OrgOut)
async def get_org(
    org_id: str,
    auth: dict = Depends(get_current_user),
    repo: OrganizationRepository = Depends(get_repo),
):
    return await org_service.get_org(repo, auth, org_id)


@router.put("/{org_id}/settings", response_model=OrgOut)
async def update_org_settings(
    org_id: str,
    payload: OrgSettingsUpdate,
    auth: dict = Depends(get_current_user),
    repo: OrganizationRepository = Depends(get_repo),
):
    return await org_service.update_org_settings(repo, auth, org_id, payload)
