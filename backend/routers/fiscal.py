"""
C-27 v21-fiscal-profile — Router fiscal.

Endpoints:
  GET  /fiscal/profile          — obtener perfil fiscal de la cuenta
  POST /fiscal/profile          — crear/actualizar perfil fiscal
  PUT  /fiscal/profile          — alias de POST (upsert)
  GET  /fiscal/points-of-sale   — listar PVs
  POST /fiscal/points-of-sale   — crear PV
  PATCH /fiscal/points-of-sale/{id} — desactivar PV
  POST /fiscal/documents/emit   — emitir comprobante pending_cae (OQ-3)
  POST /fiscal/documents/process-pending — relay del CAE (pg_cron + fire-and-forget)

Sin lógica de negocio en el router: solo parse + DI + response.
Design ref: D9, D10, D11; 3 capas: router → service → repository.
"""
from __future__ import annotations

import uuid

import asyncpg
from fastapi import APIRouter, Depends

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.repositories.fiscal_document_repository import FiscalDocumentRepository
from backend.repositories.fiscal_profile_repository import FiscalProfileRepository
from backend.repositories.point_of_sale_repository import PointOfSaleRepository
from backend.schemas.fiscal import (
    EmitPendingCAERequest,
    FiscalProfileCreate,
    FiscalProfileOut,
    PointOfSaleCreate,
    PointOfSaleOut,
)
from backend.services.fiscal import fiscal_profile_service as svc
from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter

router = APIRouter(prefix="/fiscal", tags=["fiscal"])


# ── Dependency factories ──────────────────────────────────────────────────────

def get_fp_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> FiscalProfileRepository:
    return FiscalProfileRepository(conn)


def get_pv_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> PointOfSaleRepository:
    return PointOfSaleRepository(conn)


def get_doc_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> FiscalDocumentRepository:
    return FiscalDocumentRepository(conn)


# ── FiscalProfile endpoints ───────────────────────────────────────────────────

@router.get("/profile", response_model=FiscalProfileOut)
async def get_profile(
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: FiscalProfileRepository = Depends(get_fp_repo),
):
    return await svc.get_fiscal_profile(repo, str(account_id))


@router.post("/profile", response_model=FiscalProfileOut, status_code=200)
async def create_or_update_profile(
    payload: FiscalProfileCreate,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: FiscalProfileRepository = Depends(get_fp_repo),
):
    return await svc.upsert_fiscal_profile(repo, auth, str(account_id), payload)


@router.put("/profile", response_model=FiscalProfileOut, status_code=200)
async def update_profile(
    payload: FiscalProfileCreate,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: FiscalProfileRepository = Depends(get_fp_repo),
):
    return await svc.upsert_fiscal_profile(repo, auth, str(account_id), payload)


# ── PointOfSale endpoints ─────────────────────────────────────────────────────

@router.get("/points-of-sale", response_model=list[PointOfSaleOut])
async def list_points_of_sale(
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: PointOfSaleRepository = Depends(get_pv_repo),
):
    return await svc.list_points_of_sale(repo, str(account_id))


@router.post("/points-of-sale", response_model=PointOfSaleOut, status_code=201)
async def create_point_of_sale(
    payload: PointOfSaleCreate,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    pv_repo: PointOfSaleRepository = Depends(get_pv_repo),
    fp_repo: FiscalProfileRepository = Depends(get_fp_repo),
):
    return await svc.create_point_of_sale(pv_repo, fp_repo, auth, str(account_id), payload)


@router.patch("/points-of-sale/{pv_id}", response_model=PointOfSaleOut)
async def deactivate_point_of_sale(
    pv_id: str,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: PointOfSaleRepository = Depends(get_pv_repo),
):
    return await svc.deactivate_point_of_sale(repo, auth, str(account_id), pv_id)


# ── FiscalDocument endpoints ──────────────────────────────────────────────────

@router.post("/documents/emit")
async def emit_pending_cae(
    payload: EmitPendingCAERequest,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Emite un comprobante fiscal en pending_cae (OQ-3: solo maquinaria).

    Resuelve el PV efectivo (D11): error P0422 si hay varios y no se especifica.
    No toca AFIP: persiste en pending_cae para el relay del CAE (D5/D6).
    """
    return await svc.emit_pending_cae(conn, auth, str(account_id), payload)


@router.post("/documents/process-pending")
async def process_pending_cae(
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    doc_repo: FiscalDocumentRepository = Depends(get_doc_repo),
):
    """Procesa documentos pending_cae con el relay idempotente (OQ-1=A).

    Disparado por pg_cron cada minuto y fire-and-forget al emitir.
    Usa el WSFEStubAdapter por defecto — inyectar WSFEAdapter real vía DI
    cuando el certificado esté disponible.
    """
    adapter = WSFEStubAdapter()
    return await svc.process_pending_documents(doc_repo, adapter)
