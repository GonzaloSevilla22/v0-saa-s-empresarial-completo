"""
Router para C-30 — CustomerAccount / PaymentReceived.

Routes:
  POST /customer-accounts                → create (or get existing) CustomerAccount
  GET  /clientes/{client_id}/cuenta      → saldo + historial
  GET  /customer-accounts/{id}/movements → lista de movimientos paginados
  POST /customer-accounts/payments       → registrar cobro (PaymentReceived)

Arquitectura dura: routers = validación + DI únicamente.
Toda lógica y guards de rol viven en services/customer_accounts.py.
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
from backend.repositories.customer_account_repository import CustomerAccountRepository
from backend.schemas.customer_accounts import (
    AccountMovementPageOut,
    CollectionSettingsIn,
    CollectionSettingsOut,
    CreateCustomerAccountOut,
    CustomerAccountOut,
    PaymentReceivedIn,
    PaymentReceivedOut,
    PaymentReversalIn,
    PaymentReversalOut,
    ReceivablePageOut,
    ReceivablesSummaryOut,
)
from backend.services import customer_accounts as customer_account_service

router = APIRouter(tags=["customer-accounts"])
# cobranzas-panel: read-model agregado de deudores — espejo estructural del
# report_router de payment_methods (/reports/*).
report_router = APIRouter(prefix="/reports/receivables", tags=["customer-accounts"])
# cobranzas-vencimientos (task 7.8): plazo de pago por defecto de la cuenta —
# politica comercial, hogar canonico en /settings/*.
settings_router = APIRouter(prefix="/settings/collections", tags=["customer-accounts"])


def get_customer_account_repo(
    conn: asyncpg.Connection = Depends(get_db_conn),
) -> CustomerAccountRepository:
    return CustomerAccountRepository(conn)


@router.post("/customer-accounts", response_model=CreateCustomerAccountOut, status_code=201)
async def create_customer_account(
    client_id: uuid.UUID,
    auth: dict = Depends(get_current_user),
    repo: CustomerAccountRepository = Depends(get_customer_account_repo),
):
    """Crea o retorna la cuenta corriente de un cliente (idempotente)."""
    return await customer_account_service.create_account(repo, auth, str(client_id))


@router.get("/clientes/{client_id}/cuenta")
async def get_customer_account(
    client_id: uuid.UUID,
    auth: dict = Depends(get_current_user),
    conn: asyncpg.Connection = Depends(get_db_conn),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """Devuelve el saldo actual + historial de la cuenta corriente del cliente."""
    repo = CustomerAccountRepository(conn)
    return await customer_account_service.get_account(repo, str(account_id), str(client_id))


@router.get("/customer-accounts/{customer_account_id}/movements", response_model=AccountMovementPageOut)
async def list_customer_movements(
    customer_account_id: uuid.UUID,
    page: int = Query(0, ge=0),
    size: int = Query(50, ge=1, le=200),
    auth: dict = Depends(get_current_user),
    repo: CustomerAccountRepository = Depends(get_customer_account_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """v3-api-standards §2.7: envelope estándar {items,total,page,pages}.

    fix/tenancy-bank-accounts-leak: account_id resuelto del caller y pasado
    explícito — nunca confiar solo en RLS."""
    return await customer_account_service.list_movements(
        repo, str(customer_account_id), str(account_id), page=page, size=size
    )


@router.post("/customer-accounts/payments", response_model=PaymentReceivedOut)
async def register_payment_received(
    request: Request,
    payload: PaymentReceivedIn,
    auth: dict = Depends(get_current_user),
    repo: CustomerAccountRepository = Depends(get_customer_account_repo),
):
    """Registra un cobro en la cuenta corriente del cliente. Idempotente.

    v3-api-standards §3.3: Idempotency-Key por header, con fallback al body.
    """
    payload.idempotency_key = await require_idempotency_key(request, payload.idempotency_key)
    return await customer_account_service.register_payment_received(repo, auth, payload)


@router.delete("/customer-accounts/payments/{payment_id}", response_model=PaymentReversalOut)
async def reverse_payment_received(
    payment_id: uuid.UUID,
    payload: Optional[PaymentReversalIn] = None,
    auth: dict = Depends(get_current_user),
    repo: CustomerAccountRepository = Depends(get_customer_account_repo),
):
    """cobranzas-reverso (task 10.3): anula un cobro de cuenta corriente.

    Motivo opcional por body (D9 — sin Idempotency-Key: es idempotente por
    ausencia del documento, el segundo intento falla P0404). El cuerpo entero
    es opcional: un DELETE sin body llega con payload=None.
    """
    reason_payload = payload if payload is not None else PaymentReversalIn()
    return await customer_account_service.reverse_payment_received(
        repo, auth, str(payment_id), reason_payload
    )


@report_router.get("", response_model=ReceivablePageOut)
async def receivables_report(
    page: int = Query(0, ge=0),
    size: int = Query(25, ge=1, le=200),
    sort: Literal[
        "balance", "days_since_last_charge", "days_since_last_payment", "client_name"
    ] = Query("balance"),
    sort_dir: Literal["asc", "desc"] = Query("desc"),
    bucket: Literal[
        "overdue", "current", "overdue_1_30", "overdue_31_60",
        "overdue_60_plus", "no_due_date",
    ] | None = Query(None),
    auth: dict = Depends(get_current_user),
    repo: CustomerAccountRepository = Depends(get_customer_account_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """cobranzas-panel: listado paginado de deudores (envelope estándar).

    cobranzas-vencimientos (task 7.2): `bucket` filtra por tramo de
    vencimiento — Literal (422 fuera del dominio, sin consulta), resuelto en
    el servidor sobre el conjunto completo, nunca sobre la página visible.

    `sort`/`sort_dir` como Literal: un valor fuera del dominio devuelve 422
    sin ejecutar ninguna consulta (D3 — mismo patrón que GET /clients/activity).
    El orden se resuelve en el servidor sobre el conjunto completo; default
    balance DESC. Sin gate de plan (D10).
    """
    return await customer_account_service.list_receivables(
        repo, auth, str(account_id),
        page=page, size=size, sort=sort, sort_dir=sort_dir, bucket=bucket,
    )


@report_router.get("/summary", response_model=ReceivablesSummaryOut)
async def receivables_summary(
    auth: dict = Depends(get_current_user),
    repo: CustomerAccountRepository = Depends(get_customer_account_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """cobranzas-panel (D2): total por cobrar + cantidad de deudores.

    Dos escalares y ninguna fila — es lo que consume el KPI del Tablero.
    Derivado del MISMO RPC que el listado: el total cierra contra la tabla.
    """
    return await customer_account_service.get_receivables_summary(
        repo, auth, str(account_id)
    )


@settings_router.get("", response_model=CollectionSettingsOut)
async def get_collection_settings(
    auth: dict = Depends(get_current_user),
    repo: CustomerAccountRepository = Depends(get_customer_account_repo),
    account_id: uuid.UUID = Depends(get_account_id),
):
    """cobranzas-vencimientos (task 7.8): plazo de pago por defecto de la
    cuenta. None = sin plazo definido (nunca significa 0)."""
    return await customer_account_service.get_collection_settings(
        repo, str(account_id)
    )


@settings_router.patch("", response_model=CollectionSettingsOut)
async def set_collection_settings(
    payload: CollectionSettingsIn,
    auth: dict = Depends(get_current_user),
    repo: CustomerAccountRepository = Depends(get_customer_account_repo),
):
    """cobranzas-vencimientos (task 7.8): fija (o limpia, con null) el plazo
    por defecto vía rpc_set_default_payment_terms — guard is_account_writer
    (P0401 → 403). Negativo → 422 en el schema, sin tocar la DB."""
    return await customer_account_service.set_collection_settings(
        repo, auth, payload.default_payment_terms_days
    )
