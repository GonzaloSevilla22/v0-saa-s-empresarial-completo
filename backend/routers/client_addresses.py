from __future__ import annotations

import uuid

import asyncpg
from fastapi import APIRouter, Depends

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.repositories.client_address_repository import ClientAddressRepository
from backend.repositories.client_repository import ClientRepository
from backend.schemas.client_addresses import ClientAddressCreate, ClientAddressOut, ClientAddressUpdate
from backend.services import client_addresses as client_address_service

router = APIRouter(prefix="/clients/{client_id}/addresses", tags=["client-addresses"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> ClientAddressRepository:
    return ClientAddressRepository(conn)


def get_client_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> ClientRepository:
    return ClientRepository(conn)


@router.get("", response_model=list[ClientAddressOut])
async def list_client_addresses(
    client_id: str,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ClientAddressRepository = Depends(get_repo),
    client_repo: ClientRepository = Depends(get_client_repo),
):
    return await client_address_service.list_client_addresses(
        repo, client_repo, auth, str(account_id), client_id
    )


@router.post("", response_model=ClientAddressOut, status_code=201)
async def create_client_address(
    client_id: str,
    payload: ClientAddressCreate,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ClientAddressRepository = Depends(get_repo),
    client_repo: ClientRepository = Depends(get_client_repo),
):
    return await client_address_service.create_client_address(
        repo, client_repo, auth, str(account_id), client_id, payload
    )


@router.put("/{address_id}", response_model=ClientAddressOut)
async def update_client_address(
    client_id: str,
    address_id: str,
    payload: ClientAddressUpdate,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ClientAddressRepository = Depends(get_repo),
    client_repo: ClientRepository = Depends(get_client_repo),
):
    return await client_address_service.update_client_address(
        repo, client_repo, auth, str(account_id), client_id, address_id, payload
    )


@router.delete("/{address_id}", status_code=204)
async def delete_client_address(
    client_id: str,
    address_id: str,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ClientAddressRepository = Depends(get_repo),
    client_repo: ClientRepository = Depends(get_client_repo),
):
    await client_address_service.delete_client_address(
        repo, client_repo, auth, str(account_id), client_id, address_id
    )


@router.post("/{address_id}/set-primary", response_model=ClientAddressOut)
async def set_primary_client_address(
    client_id: str,
    address_id: str,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: ClientAddressRepository = Depends(get_repo),
    client_repo: ClientRepository = Depends(get_client_repo),
):
    return await client_address_service.set_primary_client_address(
        repo, client_repo, auth, str(account_id), client_id, address_id
    )
