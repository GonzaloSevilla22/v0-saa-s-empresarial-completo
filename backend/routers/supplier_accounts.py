"""
Router para C-30 — SupplierAccount / PaymentMade / SupplierCharge.

Routes:
  POST /supplier-accounts                 → create (or get existing) SupplierAccount
  GET  /proveedores/{supplier_id}/cuenta  → saldo + historial
  POST /supplier-accounts/payments        → registrar pago (PaymentMade)
  POST /supplier-accounts/charges         → registrar cargo manual

Arquitectura dura: routers = validación + DI únicamente.
Toda lógica y guards de rol viven en services/supplier_accounts.py.
"""
from __future__ import annotations

import uuid
from typing import Literal, Optional

import asyncpg
from fastapi import APIRouter, Depends, Query, Request

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.core.idempotency import require_idempotency_key
from backend.repositories.supplier_account_repository import SupplierAccountRepository
from backend.schemas.supplier_accounts import (
    PayablePageOut,
    PayablesSummaryOut,
    CreateSupplierAccountOut,
    PaymentMadeIn,
    PaymentMadeOut,
    PaymentReversalIn,
    PaymentReversalOut,
    SupplierAccountOut,
    SupplierChargeIn,
    SupplierChargeOut,
    SupplierMovementPageOut,
)
from backend.services import supplier_accounts as supplier_account_service

router = APIRouter(tags=["supplier-accounts"])
# cobranzas-vencimientos (task 7.5): read-model agregado de acreedores —
# espejo estructural del report_router de customer_accounts (/reports/*).
report_router = APIRouter(prefix="/reports/payables", tags=["supplier-accounts"])


def get_supplier_account_repo(
    conn: asyncpg.Connection = Depends(get_db_conn),
) -> SupplierAccountRepository:
    return SupplierAccountRepository(conn)


@router.post("/supplier-accounts", response_model=CreateSupplierAccountOut, status_code=201)
async def create_supplier_account(
    supplier_id: uuid.UUID,
    auth: dict = Depends(get_current_user),
    repo: SupplierAccountRepository = Depends(get_supplier_account_repo),
):
    """Crea o retorna la cuenta corriente de un proveedor (idempotente)."""
    return await supplier_account_service.create_account(repo, auth, str(supplier_id))


@router.get("/proveedores/{supplier_id}/cuenta")
async def get_supplier_account(
    supplier_id: uuid.UUID,
    auth: dict = Depends(get_current_user),
    conn: asyncpg.Connection = Depends(get_db_conn),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """Devuelve el saldo actual + historial de la cuenta corriente del proveedor."""
    repo = SupplierAccountRepository(conn)
    return await supplier_account_service.get_account(repo, str(account_id), str(supplier_id))


@router.get("/supplier-accounts/{supplier_account_id}/movements", response_model=SupplierMovementPageOut)
async def list_supplier_movements(
    supplier_account_id: uuid.UUID,
    page: int = Query(0, ge=0),
    size: int = Query(50, ge=1, le=200),
    auth: dict = Depends(get_current_user),
    repo: SupplierAccountRepository = Depends(get_supplier_account_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """v3-api-standards §2.8: envelope estándar {items,total,page,pages}.

    (Fix de paso: el endpoint llamaba a `get_account` con el
    `supplier_account_id` en lugar del `supplier_id` — nunca devolvía
    movimientos correctamente. Ahora usa el listado dedicado.)

    fix/tenancy-bank-accounts-leak: account_id resuelto del caller y pasado
    explícito — nunca confiar solo en RLS.
    """
    return await supplier_account_service.list_movements(
        repo, str(supplier_account_id), str(account_id), page=page, size=size
    )


@router.post("/supplier-accounts/payments", response_model=PaymentMadeOut)
async def register_payment_made(
    request: Request,
    payload: PaymentMadeIn,
    auth: dict = Depends(get_current_user),
    repo: SupplierAccountRepository = Depends(get_supplier_account_repo),
):
    """Registra un pago al proveedor. Idempotente.

    v3-api-standards §3.3: Idempotency-Key por header, con fallback al body.
    """
    payload.idempotency_key = await require_idempotency_key(request, payload.idempotency_key)
    return await supplier_account_service.register_payment_made(repo, auth, payload)


@router.post("/supplier-accounts/charges", response_model=SupplierChargeOut)
async def register_supplier_charge(
    request: Request,
    payload: SupplierChargeIn,
    auth: dict = Depends(get_current_user),
    repo: SupplierAccountRepository = Depends(get_supplier_account_repo),
):
    """Registra un cargo manual en la cuenta corriente del proveedor. Idempotente.

    v3-api-standards §3.3: Idempotency-Key por header, con fallback al body.
    """
    payload.idempotency_key = await require_idempotency_key(request, payload.idempotency_key)
    return await supplier_account_service.register_supplier_charge(repo, auth, payload)


@router.delete("/supplier-accounts/payments/{payment_id}", response_model=PaymentReversalOut)
async def reverse_payment_made(
    payment_id: uuid.UUID,
    payload: Optional[PaymentReversalIn] = None,
    auth: dict = Depends(get_current_user),
    repo: SupplierAccountRepository = Depends(get_supplier_account_repo),
):
    """cobranzas-reverso (task 10.4): anula un pago a proveedor. Espejo
    exacto de customer_accounts.py::reverse_payment_received."""
    reason_payload = payload if payload is not None else PaymentReversalIn()
    return await supplier_account_service.reverse_payment_made(
        repo, auth, str(payment_id), reason_payload
    )


@report_router.get("", response_model=PayablePageOut)
async def payables_report(
    page: int = Query(0, ge=0),
    size: int = Query(25, ge=1, le=200),
    sort: Literal[
        "balance", "days_since_last_charge", "days_since_last_payment", "supplier_name"
    ] = Query("balance"),
    sort_dir: Literal["asc", "desc"] = Query("desc"),
    bucket: Literal[
        "overdue", "current", "overdue_1_30", "overdue_31_60",
        "overdue_60_plus", "no_due_date",
    ] | None = Query(None),
    auth: dict = Depends(get_current_user),
    repo: SupplierAccountRepository = Depends(get_supplier_account_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """cobranzas-vencimientos (task 7.5): listado paginado de acreedores con
    aging — espejo exacto de GET /reports/receivables. `bucket` como Literal:
    un valor fuera del dominio devuelve 422 sin ejecutar ninguna consulta."""
    return await supplier_account_service.list_payables(
        repo, auth, str(account_id),
        page=page, size=size, sort=sort, sort_dir=sort_dir, bucket=bucket,
    )


@report_router.get("/summary", response_model=PayablesSummaryOut)
async def payables_summary(
    auth: dict = Depends(get_current_user),
    repo: SupplierAccountRepository = Depends(get_supplier_account_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """cobranzas-vencimientos (task 7.5): total por pagar + total vencido +
    cantidad de acreedores — derivado del MISMO RPC que el listado."""
    return await supplier_account_service.get_payables_summary(
        repo, auth, str(account_id)
    )
