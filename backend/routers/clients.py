from __future__ import annotations

import uuid

import asyncpg
from fastapi import APIRouter, Depends

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.repositories.client_repository import ClientRepository
from backend.schemas.clients import ClientCreate, ClientOut, ClientUpdate
from backend.services import clients as client_service

router = APIRouter(prefix="/clients", tags=["clients"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> ClientRepository:
    return ClientRepository(conn)


@router.get("", response_model=list[ClientOut])
async def list_clients(
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ClientRepository = Depends(get_repo),
):
    return await client_service.list_clients(repo, str(account_id))


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
):
    return await client_service.create_client(repo, auth, str(account_id), payload)


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
