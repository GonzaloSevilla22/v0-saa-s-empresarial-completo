from __future__ import annotations

from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.expense_repository import ExpenseRepository
from backend.schemas.expenses import ExpenseCreate, ExpenseUpdate


async def list_expenses(repo: ExpenseRepository, account_id: str) -> list:
    return await repo.list_by_org(account_id)


async def get_expense(repo: ExpenseRepository, account_id: str, expense_id: str) -> dict:
    record = await repo.get_by_id(expense_id, account_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Gasto no encontrado")
    return dict(record)


async def create_expense(repo: ExpenseRepository, auth: dict, account_id: str, payload: ExpenseCreate) -> dict:
    require_role(auth, ["user", "admin"])
    # cost-center-dimension: cost_center_id is optional (None → NULL persisted)
    data = payload.model_dump()
    # Convert UUID to str for asyncpg compatibility
    if data.get("cost_center_id") is not None:
        data["cost_center_id"] = str(data["cost_center_id"])
    record = await repo.create(auth["user_id"], account_id, data)
    if record is None:
        raise HTTPException(status_code=500, detail="Error al crear el gasto")
    return dict(record)


async def update_expense(
    repo: ExpenseRepository, auth: dict, account_id: str, expense_id: str, payload: ExpenseUpdate
) -> dict:
    require_role(auth, ["user", "admin"])
    record = await repo.update(expense_id, account_id, payload.model_dump(exclude_none=True))
    if record is None:
        raise HTTPException(status_code=404, detail="Gasto no encontrado")
    return dict(record)


async def delete_expense(repo: ExpenseRepository, auth: dict, account_id: str, expense_id: str) -> None:
    require_role(auth, ["user", "admin"])
    existing = await repo.get_by_id(expense_id, account_id)
    if existing is None:
        raise HTTPException(status_code=404, detail="Gasto no encontrado")
    await repo.delete(expense_id, account_id)
