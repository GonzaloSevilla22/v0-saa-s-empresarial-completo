from __future__ import annotations

import uuid

import asyncpg
from fastapi import APIRouter, Depends

from backend.core.auth import get_current_user
from backend.core.database import get_account_id, get_db_conn
from backend.repositories.branch_repository import BranchRepository
from backend.schemas.branches import BranchCreate, BranchOut, BranchUpdate
from backend.services import branches as branch_service

router = APIRouter(prefix="/branches", tags=["branches"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> BranchRepository:
    return BranchRepository(conn)


@router.get("", response_model=list[BranchOut])
async def list_branches(
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: BranchRepository = Depends(get_repo),
):
    return await branch_service.list_branches(repo, str(account_id))


@router.get("/{branch_id}", response_model=BranchOut)
async def get_branch(
    branch_id: str,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: BranchRepository = Depends(get_repo),
):
    return await branch_service.get_branch(repo, str(account_id), branch_id)


@router.post("", response_model=BranchOut, status_code=201)
async def create_branch(
    payload: BranchCreate,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: BranchRepository = Depends(get_repo),
):
    return await branch_service.create_branch(repo, auth, str(account_id), payload)


@router.put("/{branch_id}", response_model=BranchOut)
async def update_branch(
    branch_id: str,
    payload: BranchUpdate,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: BranchRepository = Depends(get_repo),
):
    return await branch_service.update_branch(repo, auth, str(account_id), branch_id, payload)
