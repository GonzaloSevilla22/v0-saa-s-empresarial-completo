from __future__ import annotations

import uuid

import asyncpg
from fastapi import APIRouter, Depends, Query

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.repositories.client_repository import ClientRepository
from backend.repositories.plan_limits_repository import PlanLimitsRepository
from backend.schemas.clients import (
    ClientActivityPageOut,
    ClientActivitySort,
    ClientActivityStatus,
    ClientCreate,
    ClientOut,
    ClientPurchasesPageOut,
    ClientUpdate,
    SortDir,
)
from backend.services import clients as client_service

router = APIRouter(prefix="/clients", tags=["clients"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> ClientRepository:
    return ClientRepository(conn)


def get_plan_limits_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> PlanLimitsRepository:
    return PlanLimitsRepository(conn)


@router.get("", response_model=list[ClientOut])
async def list_clients(
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ClientRepository = Depends(get_repo),
):
    """data-api-endpoints §"Compatibilidad del listado plano de clientes":
    contrato INTACTO — lista plana sin envelope, consumida como selector por
    6 pantallas (ventas, pos, configuración, sale-form, client-form,
    client-import-dialog)."""
    return await client_service.list_clients(repo, str(account_id))


# clientes-frecuentes-historial: DEBE registrarse antes de "/{client_id}" —
# de lo contrario "activity" matchea como client_id y nunca llega acá.
@router.get("/activity", response_model=ClientActivityPageOut)
async def list_client_activity(
    search: str | None = Query(None),
    activity_status: ClientActivityStatus | None = Query(None),
    sort: ClientActivitySort = Query("last_purchase"),
    sort_dir: SortDir = Query("desc"),
    page: int = Query(0, ge=0),
    size: int = Query(25, ge=1, le=200),
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ClientRepository = Depends(get_repo),
):
    """client-activity: listado paginado de clientes con sus agregados de
    actividad comercial. `sort`/`activity_status` son `Literal` — un valor
    fuera del conjunto admitido responde 422 RFC 7807 sin ejecutar la
    consulta (validación de Pydantic antes del cuerpo del endpoint)."""
    return await client_service.list_client_activity(
        repo,
        str(account_id),
        page=page,
        size=size,
        search=search,
        activity_status=activity_status,
        sort=sort,
        sort_dir=sort_dir,
    )


@router.get("/{client_id}/purchases", response_model=ClientPurchasesPageOut)
async def list_client_purchases(
    client_id: str,
    page: int = Query(0, ge=0),
    size: int = Query(25, ge=1, le=200),
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ClientRepository = Depends(get_repo),
):
    """client-purchase-history: historial paginado por operación + resumen
    acumulado (independiente de la página visible)."""
    return await client_service.get_client_purchases(
        repo, str(account_id), client_id, page=page, size=size
    )


@router.get("/{client_id}", response_model=ClientOut)
async def get_client(
    client_id: str,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ClientRepository = Depends(get_repo),
):
    return await client_service.get_client(repo, str(account_id), client_id)


@router.post("", response_model=ClientOut, status_code=201)
async def create_client(
    payload: ClientCreate,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ClientRepository = Depends(get_repo),
    plan_limits_repo: PlanLimitsRepository = Depends(get_plan_limits_repo),
):
    return await client_service.create_client(repo, auth, str(account_id), payload, plan_limits_repo)


@router.put("/{client_id}", response_model=ClientOut)
async def update_client(
    client_id: str,
    payload: ClientUpdate,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ClientRepository = Depends(get_repo),
):
    return await client_service.update_client(repo, auth, str(account_id), client_id, payload)


@router.delete("/{client_id}", status_code=204)
async def delete_client(
    client_id: str,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ClientRepository = Depends(get_repo),
):
    await client_service.delete_client(repo, auth, str(account_id), client_id)
