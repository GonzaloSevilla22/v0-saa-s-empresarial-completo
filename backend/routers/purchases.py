from __future__ import annotations

import uuid

import asyncpg
from fastapi import APIRouter, Depends, Query, Request

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.core.idempotency import require_idempotency_key
from backend.repositories.purchase_repository import PurchaseRepository
from backend.schemas.purchases import (
    PurchaseOperationIn,
    PurchaseOperationOut,
    PurchaseOperationUpdateIn,
    PurchasesPageOut,
)
from backend.services import purchases as purchases_service

router = APIRouter(prefix="/purchases", tags=["purchases"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> PurchaseRepository:
    return PurchaseRepository(conn)


@router.get("", response_model=PurchasesPageOut)
async def list_purchases(
    page: int = Query(0, ge=0),
    page_size: int = Query(25, ge=1, le=100),
    date_from: str | None = Query(None),
    date_to: str | None = Query(None),
    cost_center_id: uuid.UUID | None = Query(
        None, description="cost-center-surface: filtra por centro de costo de la operación"
    ),
    payment_method_id: uuid.UUID | None = Query(
        None, description="metodos-pago-operaciones: filtra por forma de pago de la operación"
    ),
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: PurchaseRepository = Depends(get_repo),
):
    return await purchases_service.list_purchases_paginated(
        repo, str(account_id), page, page_size, date_from, date_to,
        str(cost_center_id) if cost_center_id else None,
        str(payment_method_id) if payment_method_id else None,
    )


@router.delete("", status_code=204)
async def delete_purchases_by_operation(
    operation_id: str = Query(...),
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: PurchaseRepository = Depends(get_repo),
):
    await purchases_service.delete_purchase_operation(repo, auth, str(account_id), operation_id)


@router.delete("/{purchase_id}", status_code=204)
async def delete_purchase(
    purchase_id: str,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: PurchaseRepository = Depends(get_repo),
):
    await purchases_service.delete_purchase(repo, auth, str(account_id), purchase_id)


@router.post("", response_model=PurchaseOperationOut, status_code=201)
async def create_purchase(
    request: Request,
    payload: PurchaseOperationIn,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: PurchaseRepository = Depends(get_repo),
):
    # v3-api-standards §3.3: Idempotency-Key por header, con fallback al body.
    payload.idempotency_key = await require_idempotency_key(request, payload.idempotency_key)
    return await purchases_service.create_purchase_operation(repo, auth, str(account_id), payload)


@router.put("/operation")
async def update_purchase_operation(
    payload: PurchaseOperationUpdateIn,
    auth: dict = Depends(get_current_user),
    repo: PurchaseRepository = Depends(get_repo),
):
    """Edita una operación de compra: reemplaza sus ítems vía
    rpc_atomic_update_purchase_operation (REVERSE + APPLY de stock, atómico)."""
    # metodos-pago-operaciones (D5): "provided" se lee del JSON crudo
    # (model_fields_set), NUNCA de payload.payment_method_id is None — de lo
    # contrario "no lo mandé" y "lo mandé en null" serían indistinguibles y
    # cualquier edición sin el campo BORRARÍA el método vigente en silencio.
    payment_method_provided = "payment_method_id" in payload.model_fields_set
    # edicion-preserva-contexto (F1 §D3): mismo contrato tri-estado para branch_id.
    branch_provided = "branch_id" in payload.model_fields_set
    # compras-proveedor-cuenta-corriente (D7, task 9.4, OQ-5 opción A): mismo
    # contrato tri-estado para supplier_id y cost_center_id.
    supplier_provided = "supplier_id" in payload.model_fields_set
    cost_center_provided = "cost_center_id" in payload.model_fields_set
    await purchases_service.update_purchase_operation(
        repo,
        auth,
        payload,
        payment_method_provided,
        branch_provided,
        supplier_provided,
        cost_center_provided,
    )
    return {"ok": True}
