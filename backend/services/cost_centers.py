from __future__ import annotations

from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.cost_center_repository import CostCenterRepository


async def list_cost_centers(
    repo: CostCenterRepository,
    auth: dict,
    account_id: str,
    *,
    active_only: bool = True,
) -> list:
    """List cost centers for the account. Available to all members (read-only)."""
    # No require_role here — reads are permitted to all account members.
    # The DB-level SELECT policy (RLS members_select) already enforces account scope.
    return await repo.list_by_account(account_id, active_only=active_only)


async def create_cost_center(
    repo: CostCenterRepository,
    auth: dict,
    account_id: str,
    name: str,
    code: str | None,
) -> dict:
    """Create a cost center. Requires owner or admin.

    Defence-in-depth: require_role here + RLS is_account_writer on the DB.
    Name is normalised (strip) before persistence.
    """
    require_role(auth, ["owner", "admin"])
    normalised_name = name.strip()
    record = await repo.create(account_id, name=normalised_name, code=code)
    if record is None:
        raise HTTPException(status_code=500, detail="Error al crear el centro de costo")
    return dict(record)


async def update_cost_center(
    repo: CostCenterRepository,
    auth: dict,
    account_id: str,
    cost_center_id: str,
    name: str,
    code: str | None,
) -> dict:
    """Update name/code of a cost center. Requires owner or admin."""
    require_role(auth, ["owner", "admin"])
    normalised_name = name.strip()
    record = await repo.update(cost_center_id, account_id, name=normalised_name, code=code)
    if record is None:
        raise HTTPException(status_code=404, detail="Centro de costo no encontrado")
    return dict(record)


async def deactivate_cost_center(
    repo: CostCenterRepository,
    auth: dict,
    account_id: str,
    cost_center_id: str,
) -> dict:
    """Soft-delete a cost center (is_active=false). Requires owner or admin.

    Preserves historical references: existing expenses/purchases that point to
    this center retain their cost_center_id — the name is still readable via JOIN.
    """
    require_role(auth, ["owner", "admin"])
    record = await repo.deactivate(cost_center_id, account_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Centro de costo no encontrado")
    return dict(record)
