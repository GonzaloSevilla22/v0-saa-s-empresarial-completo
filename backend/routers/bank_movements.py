"""
Router para el historial de movimientos bancarios
(banco-caja-historial-ajustes, D3 — ledger-movement-history).

Routes:
  GET /bank-accounts/{bank_account_id}/movements → historial paginado de la cuenta

Vive en un router propio, no dentro de bank_reconciliation.py (D3 del
design): el historial no es conciliación, y bank_reconciliation.py ya tiene
13 endpoints.

Arquitectura dura: routers = validación + DI únicamente; la lógica vive en
el service, el aislamiento por tenant en la RLS (JWT-passthrough).
"""
from __future__ import annotations

import uuid
from datetime import date

import asyncpg
from fastapi import APIRouter, Depends, Query

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.repositories.bank_account_repository import BankAccountRepository
from backend.schemas.bank_movements import BankMovementPageOut
from backend.services import bank_movements as bank_movements_service

router = APIRouter(tags=["bank-movements"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> BankAccountRepository:
    return BankAccountRepository(conn)


@router.get("/bank-accounts/{bank_account_id}/movements", response_model=BankMovementPageOut)
async def list_bank_account_movements(
    bank_account_id: str,
    page: int = Query(0, ge=0, description="Página, 0-based"),
    size: int = Query(30, ge=1, le=500, description="Tamaño de página (máx 500)"),
    types: list[str] | None = Query(None, description="Filtro por movement_type (repetible)"),
    status: str | None = Query(None, description="Filtro por reconciliation_status"),
    q: str | None = Query(None, description="Búsqueda de texto sobre el motivo (server-side)"),
    date_from: date | None = Query(None, alias="from"),
    date_to: date | None = Query(None, alias="to"),
    auth: dict = Depends(get_current_user),
    repo: BankAccountRepository = Depends(get_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """fix/tenancy-bank-accounts-leak: account_id resuelto del caller y
    verificado como dueño del bank_account_id (404 si no) antes de listar."""
    return await bank_movements_service.list_movements(
        repo, bank_account_id, account_id=str(account_id), page=page, size=size,
        types=types, status=status, q=q, date_from=date_from, date_to=date_to,
    )
