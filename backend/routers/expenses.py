from __future__ import annotations

import json
import uuid

import asyncpg
from fastapi import APIRouter, Depends, Query, Request

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.core.idempotency import require_idempotency_key
from backend.repositories.expense_repository import ExpenseRepository
from backend.schemas.expenses import (
    ExpenseCreate,
    ExpenseImportIn,
    ExpenseImportOut,
    ExpenseOut,
    ExpensesPageOut,
    ExpenseUpdate,
)
from backend.services import expenses as expense_service

router = APIRouter(prefix="/expenses", tags=["expenses"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> ExpenseRepository:
    return ExpenseRepository(conn)


# gastos-forma-pago D18 — BREAKING de API interna sancionado: la respuesta deja
# de ser una lista plana y pasa al envelope estándar {items,total,page,pages}.
# El único consumidor es el frontend propio. Los filtros se resuelven en el
# servidor, igual que en GET /sales — sin eso, el listado no puede paginar ni
# recibir los derivados de bloqueo, que no son columnas de `expenses`.
@router.get("", response_model=ExpensesPageOut)
async def list_expenses(
    page: int = Query(0, ge=0),
    page_size: int = Query(25, ge=1, le=100),
    date_from: str | None = Query(None),
    date_to: str | None = Query(None),
    search: str | None = Query(None, description="coincide en categoría o descripción"),
    cost_center_id: uuid.UUID | None = Query(None),
    payment_method_id: uuid.UUID | None = Query(
        None, description="gastos-forma-pago: filtra por forma de pago imputada"
    ),
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ExpenseRepository = Depends(get_repo),
):
    return await expense_service.list_expenses(
        repo,
        str(account_id),
        page=page,
        page_size=page_size,
        date_from=date_from,
        date_to=date_to,
        search=search,
        cost_center_id=str(cost_center_id) if cost_center_id else None,
        payment_method_id=str(payment_method_id) if payment_method_id else None,
    )


@router.get("/{expense_id}", response_model=ExpenseOut)
async def get_expense(
    expense_id: str,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ExpenseRepository = Depends(get_repo),
):
    return await expense_service.get_expense(repo, str(account_id), expense_id)


@router.post("", response_model=ExpenseOut, status_code=201)
async def create_expense(
    payload: ExpenseCreate,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ExpenseRepository = Depends(get_repo),
):
    return await expense_service.create_expense(repo, auth, str(account_id), payload)


@router.post("/import", response_model=ExpenseImportOut)
async def import_expenses(
    request: Request,
    payload: ExpenseImportIn,
    auth: dict = Depends(get_current_user),
    repo: ExpenseRepository = Depends(get_repo),
):
    """importador-gastos-transaccional: lote transaccional, todo o nada.

    v3-api-standards §3.3: `Idempotency-Key` por header, con fallback al
    body — misma precedencia que el resto de las mutaciones no idempotentes
    del proyecto (calcado de `POST /bank-accounts/{id}/statement-imports`).
    """
    idempotency_key = await require_idempotency_key(request, payload.idempotency_key)
    rows_json = json.dumps(
        [
            {
                "row_no": row.row_no,
                "description": row.description,
                "category": row.category,
                "amount": str(row.amount),
                "date": row.date.isoformat(),
                "payment_method_name": row.payment_method_name,
                "branch_name": row.branch_name,
                "cost_center_name": row.cost_center_name,
            }
            for row in payload.rows
        ]
    )
    return await expense_service.import_expenses(
        repo,
        auth,
        idempotency_key=idempotency_key,
        rows_json=rows_json,
        file_name=payload.file_name,
        file_hash=payload.file_hash,
        default_payment_method_id=str(payload.default_payment_method_id) if payload.default_payment_method_id else None,
        default_branch_id=str(payload.default_branch_id) if payload.default_branch_id else None,
        default_cost_center_id=str(payload.default_cost_center_id) if payload.default_cost_center_id else None,
        fallback_bank_account_id=str(payload.fallback_bank_account_id) if payload.fallback_bank_account_id else None,
        dry_run=payload.dry_run,
    )


@router.put("/{expense_id}", response_model=ExpenseOut)
async def update_expense(
    expense_id: str,
    payload: ExpenseUpdate,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ExpenseRepository = Depends(get_repo),
):
    return await expense_service.update_expense(repo, auth, str(account_id), expense_id, payload)


@router.delete("/{expense_id}", status_code=204)
async def delete_expense(
    expense_id: str,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ExpenseRepository = Depends(get_repo),
):
    await expense_service.delete_expense(repo, auth, str(account_id), expense_id)
