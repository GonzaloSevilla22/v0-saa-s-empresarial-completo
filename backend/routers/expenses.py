from __future__ import annotations

from collections.abc import AsyncGenerator

import asyncpg
from fastapi import APIRouter, Depends

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.repositories.expense_repository import ExpenseRepository
from backend.schemas.expenses import ExpenseCreate, ExpenseOut, ExpenseUpdate
from backend.services import expenses as expense_service

router = APIRouter(prefix="/expenses", tags=["expenses"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> ExpenseRepository:
    return ExpenseRepository(conn)


@router.get("", response_model=list[ExpenseOut])
async def list_expenses(
    auth: dict = Depends(get_current_user),
    repo: ExpenseRepository = Depends(get_repo),
):
    return await expense_service.list_expenses(repo, auth)


@router.get("/{expense_id}", response_model=ExpenseOut)
async def get_expense(
    expense_id: str,
    auth: dict = Depends(get_current_user),
    repo: ExpenseRepository = Depends(get_repo),
):
    return await expense_service.get_expense(repo, auth, expense_id)


@router.post("", response_model=ExpenseOut, status_code=201)
async def create_expense(
    payload: ExpenseCreate,
    auth: dict = Depends(get_current_user),
    repo: ExpenseRepository = Depends(get_repo),
):
    return await expense_service.create_expense(repo, auth, payload)


@router.put("/{expense_id}", response_model=ExpenseOut)
async def update_expense(
    expense_id: str,
    payload: ExpenseUpdate,
    auth: dict = Depends(get_current_user),
    repo: ExpenseRepository = Depends(get_repo),
):
    return await expense_service.update_expense(repo, auth, expense_id, payload)


@router.delete("/{expense_id}", status_code=204)
async def delete_expense(
    expense_id: str,
    auth: dict = Depends(get_current_user),
    repo: ExpenseRepository = Depends(get_repo),
):
    await expense_service.delete_expense(repo, auth, expense_id)
