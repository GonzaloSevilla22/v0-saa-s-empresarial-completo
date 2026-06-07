from __future__ import annotations

from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.expense_repository import ExpenseRepository
from backend.schemas.expenses import ExpenseCreate, ExpenseUpdate


async def list_expenses(repo: ExpenseRepository, auth: dict) -> list:
    return await repo.list_by_org(auth["user_id"])


async def get_expense(repo: ExpenseRepository, auth: dict, expense_id: str) -> dict:
    record = await repo.get_by_id(expense_id, auth["user_id"])
    if record is None:
        raise HTTPException(status_code=404, detail="Gasto no encontrado")
    return dict(record)


async def create_expense(repo: ExpenseRepository, auth: dict, payload: ExpenseCreate) -> dict:
    require_role(auth, ["owner", "admin"])
    record = await repo.create(auth["user_id"], payload.model_dump())
    if record is None:
        raise HTTPException(status_code=500, detail="Error al crear el gasto")
    return dict(record)


async def update_expense(
    repo: ExpenseRepository, auth: dict, expense_id: str, payload: ExpenseUpdate
) -> dict:
    require_role(auth, ["owner", "admin"])
    record = await repo.update(expense_id, auth["user_id"], payload.model_dump(exclude_none=True))
    if record is None:
        raise HTTPException(status_code=404, detail="Gasto no encontrado")
    return dict(record)


async def delete_expense(repo: ExpenseRepository, auth: dict, expense_id: str) -> None:
    require_role(auth, ["owner", "admin"])
    existing = await repo.get_by_id(expense_id, auth["user_id"])
    if existing is None:
        raise HTTPException(status_code=404, detail="Gasto no encontrado")
    await repo.delete(expense_id, auth["user_id"])
