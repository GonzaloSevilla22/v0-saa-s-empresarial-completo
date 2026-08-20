from __future__ import annotations

import datetime
import uuid

import asyncpg
from fastapi import APIRouter, Depends, Query

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.repositories.payment_method_repository import PaymentMethodRepository
from backend.schemas.payment_methods import (
    PaymentMethodCreate,
    PaymentMethodOut,
    PaymentMethodReportRow,
    PaymentMethodUpdate,
)
from backend.services import payment_methods as pm_service

router = APIRouter(prefix="/payment-methods", tags=["payment-methods"])
report_router = APIRouter(prefix="/reports/payment-methods", tags=["payment-methods"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> PaymentMethodRepository:
    return PaymentMethodRepository(conn)


@router.get("", response_model=list[PaymentMethodOut])
async def list_payment_methods(
    include_inactive: bool = Query(False, description="Include deactivated methods (owner/admin only)"),
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: PaymentMethodRepository = Depends(get_repo),
):
    """List payment methods for the current account.

    By default returns only active methods (is_active=true).
    Pass include_inactive=true to include deactivated ones (admin screen).
    """
    active_only = not include_inactive
    return await pm_service.list_payment_methods(repo, auth, str(account_id), active_only=active_only)


@router.post("", response_model=PaymentMethodOut, status_code=201)
async def create_payment_method(
    payload: PaymentMethodCreate,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: PaymentMethodRepository = Depends(get_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Create a new payment method. Requires TENANT role owner or admin."""
    return await pm_service.create_payment_method(
        repo, auth, str(account_id),
        name=payload.name,
        kind=payload.kind,
        sort_order=payload.sort_order,
        conn=conn,
    )


@router.patch("/{payment_method_id}", response_model=PaymentMethodOut)
async def update_payment_method(
    payment_method_id: str,
    payload: PaymentMethodUpdate,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: PaymentMethodRepository = Depends(get_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Update name/sort_order/bank_account_id of a payment method. Requires
    TENANT role owner or admin.

    `kind` is immutable (D2) — not accepted in this payload.

    pos-banco-movimientos (D7): `bank_account_id` is tri-state by ABSENCE of
    the key, never by `is None` — same contract as `payment_method_id` in
    `SaleOperationUpdateIn`. Not sending the field preserves the current
    default; sending it as `null` unassigns; sending a uuid (re)assigns.
    """
    bank_account_provided = "bank_account_id" in payload.model_fields_set
    return await pm_service.update_payment_method(
        repo, auth, str(account_id), payment_method_id,
        name=payload.name,
        sort_order=payload.sort_order,
        bank_account_id=str(payload.bank_account_id) if payload.bank_account_id else None,
        bank_account_provided=bank_account_provided,
        conn=conn,
    )


@router.patch("/{payment_method_id}/deactivate", response_model=PaymentMethodOut)
async def deactivate_payment_method(
    payment_method_id: str,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: PaymentMethodRepository = Depends(get_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Soft-delete a payment method (sets is_active=false). Requires TENANT role owner or admin.

    Historical sales/purchases retain their payment_method_id reference.
    """
    return await pm_service.deactivate_payment_method(
        repo, auth, str(account_id), payment_method_id,
        conn=conn,
    )


@report_router.get("", response_model=list[PaymentMethodReportRow])
async def payment_method_report(
    start: datetime.date = Query(..., description="Fecha desde (inclusive)"),
    end: datetime.date = Query(..., description="Fecha hasta (inclusive)"),
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: PaymentMethodRepository = Depends(get_repo),
):
    """Ventas y compras agregadas por forma de pago en el rango [start, end].

    Disponible a todo miembro de la cuenta, sin gate de plan (D10) — mismo
    criterio que el reporte de centros de costo: el catálogo está disponible
    en todos los planes, gatear su único lector dejaría al free imputando
    datos que no puede leer. NO resta notas de crédito (excepción documentada
    a RN-D1 — ver rpc_payment_method_report).
    """
    return await pm_service.get_payment_method_report(repo, auth, str(account_id), start, end)
