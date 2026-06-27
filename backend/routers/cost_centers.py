from __future__ import annotations

import uuid

import asyncpg
from fastapi import APIRouter, Depends, Query

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.repositories.cost_center_repository import CostCenterRepository
from backend.schemas.cost_centers import CostCenterCreate, CostCenterOut, CostCenterUpdate
from backend.services import cost_centers as cc_service

router = APIRouter(prefix="/cost-centers", tags=["cost-centers"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> CostCenterRepository:
    return CostCenterRepository(conn)


@router.get("", response_model=list[CostCenterOut])
async def list_cost_centers(
    include_inactive: bool = Query(False, description="Include deactivated centers (owner/admin only)"),
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: CostCenterRepository = Depends(get_repo),
):
    """List cost centers for the current account.

    By default returns only active centers (is_active=true).
    Pass include_inactive=true to include deactivated ones (useful for admin screen).
    """
    active_only = not include_inactive
    return await cc_service.list_cost_centers(repo, auth, str(account_id), active_only=active_only)


@router.post("", response_model=CostCenterOut, status_code=201)
async def create_cost_center(
    payload: CostCenterCreate,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: CostCenterRepository = Depends(get_repo),
):
    """Create a new cost center. Requires owner or admin."""
    return await cc_service.create_cost_center(
        repo, auth, str(account_id),
        name=payload.name,
        code=payload.code,
    )


@router.patch("/{cost_center_id}", response_model=CostCenterOut)
async def update_cost_center(
    cost_center_id: str,
    payload: CostCenterUpdate,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: CostCenterRepository = Depends(get_repo),
):
    """Update name/code of a cost center. Requires owner or admin."""
    return await cc_service.update_cost_center(
        repo, auth, str(account_id), cost_center_id,
        name=payload.name,
        code=payload.code,
    )


@router.patch("/{cost_center_id}/deactivate", response_model=CostCenterOut)
async def deactivate_cost_center(
    cost_center_id: str,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: CostCenterRepository = Depends(get_repo),
):
    """Soft-delete a cost center (sets is_active=false). Requires owner or admin.

    Historical expenses and purchases retain their cost_center_id reference.
    The center is hidden from new-entry selectors but names are preserved for reporting.
    """
    return await cc_service.deactivate_cost_center(
        repo, auth, str(account_id), cost_center_id,
    )
