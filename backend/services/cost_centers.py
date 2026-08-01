from __future__ import annotations

from fastapi import HTTPException

from backend.core.guards import require_account_role
from backend.repositories.cost_center_repository import CostCenterRepository


async def list_cost_centers(
    repo: CostCenterRepository,
    auth: dict,
    account_id: str,
    *,
    active_only: bool = True,
) -> list:
    """List cost centers for the account. Available to all members (read-only)."""
    # No guard here — reads are permitted to all account members.
    # The DB-level SELECT policy (RLS members_select) already enforces account scope.
    return await repo.list_by_account(account_id, active_only=active_only)


async def create_cost_center(
    repo: CostCenterRepository,
    auth: dict,
    account_id: str,
    name: str,
    code: str | None,
    *,
    conn,
) -> dict:
    """Create a cost center. Requires TENANT role owner or admin (D9).

    v31-authz-token-hook D9: cost_centers es el único consumidor que gatea
    contra el rol de TENANT (account_members.role) — antes de este change
    comparaba contra el rol de PLATAFORMA (`require_role`, siempre "user"/
    "admin" de profiles), lo que producía 403 universal incluso para el
    dueño de la cuenta (criterio de aceptación (a) — 0 filas en prod).
    Defence-in-depth: require_account_role acá + RLS is_account_writer en la
    DB. Name is normalised (strip) before persistence.
    """
    await require_account_role(conn, auth, ["owner", "admin"])
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
    *,
    conn,
) -> dict:
    """Update name/code of a cost center. Requires TENANT role owner or admin (D9)."""
    await require_account_role(conn, auth, ["owner", "admin"])
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
    *,
    conn,
) -> dict:
    """Soft-delete a cost center (is_active=false). Requires TENANT role owner or admin (D9).

    Preserves historical references: existing expenses/purchases that point to
    this center retain their cost_center_id — the name is still readable via JOIN.
    """
    await require_account_role(conn, auth, ["owner", "admin"])
    record = await repo.deactivate(cost_center_id, account_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Centro de costo no encontrado")
    return dict(record)
