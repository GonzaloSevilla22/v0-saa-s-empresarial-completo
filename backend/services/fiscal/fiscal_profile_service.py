"""
C-27 v21-fiscal-profile — Fiscal service: FiscalProfile + PointOfSale + emisión.

Capa de servicio (lógica de negocio + guards). Sin lógica en los routers.
Design ref: D9 (require_role), D10 (multi-PV), D11 (P0422 ambiguous_point_of_sale)
"""
from __future__ import annotations

from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.fiscal_profile_repository import FiscalProfileRepository
from backend.repositories.fiscal_document_repository import FiscalDocumentRepository
from backend.repositories.point_of_sale_repository import PointOfSaleRepository
from backend.schemas.fiscal import (
    EmitPendingCAERequest,
    FiscalProfileCreate,
    PointOfSaleCreate,
)
from backend.services.fiscal.cae_relay_processor import CAERelayProcessor
from backend.services.fiscal.fiscal_document_port import FiscalDocumentPort
from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter


# ── FiscalProfile ──────────────────────────────────────────────────────────────

async def get_fiscal_profile(repo: FiscalProfileRepository, account_id: str) -> dict:
    """Obtiene el perfil fiscal de la cuenta. 404 si no existe."""
    profile = await repo.get_by_account_id(account_id)
    if profile is None:
        raise HTTPException(status_code=404, detail="Perfil fiscal no encontrado")
    return profile


async def upsert_fiscal_profile(
    repo: FiscalProfileRepository,
    auth: dict,
    account_id: str,
    payload: FiscalProfileCreate,
) -> dict:
    """Crea o actualiza el perfil fiscal. Solo owner/admin."""
    require_role(auth, ["user", "admin"])
    result = await repo.upsert(account_id, payload.model_dump(exclude_none=True))
    if result is None:
        raise HTTPException(status_code=500, detail="Error al guardar el perfil fiscal")
    return result


# ── PointOfSale ────────────────────────────────────────────────────────────────

async def list_points_of_sale(repo: PointOfSaleRepository, account_id: str) -> list:
    """Lista todos los puntos de venta de la cuenta."""
    return await repo.list_by_account(account_id)


async def create_point_of_sale(
    pv_repo: PointOfSaleRepository,
    fp_repo: FiscalProfileRepository,
    auth: dict,
    account_id: str,
    payload: PointOfSaleCreate,
) -> dict:
    """Crea un punto de venta. Solo owner/admin. La cuenta debe tener perfil fiscal."""
    require_role(auth, ["user", "admin"])

    profile = await fp_repo.get_by_account_id(account_id)
    if profile is None:
        raise HTTPException(
            status_code=404,
            detail="La cuenta no tiene perfil fiscal. Configurá el perfil antes de agregar puntos de venta.",
        )

    result = await pv_repo.create(
        account_id=account_id,
        fiscal_profile_id=str(profile["id"]),
        data=payload.model_dump(exclude_none=True),
    )
    if result is None:
        raise HTTPException(status_code=500, detail="Error al crear el punto de venta")
    return result


async def deactivate_point_of_sale(
    repo: PointOfSaleRepository,
    auth: dict,
    account_id: str,
    pv_id: str,
) -> dict:
    """Desactiva un punto de venta. Solo owner/admin."""
    require_role(auth, ["user", "admin"])
    result = await repo.deactivate(pv_id, account_id)
    if result is None:
        raise HTTPException(status_code=404, detail="Punto de venta no encontrado")
    return result


# ── Emisión de comprobantes (pending_cae) ─────────────────────────────────────

async def emit_pending_cae(
    conn,
    auth: dict,
    account_id: str,
    payload: EmitPendingCAERequest,
) -> dict:
    """Emite un comprobante fiscal en pending_cae (OQ-3: maquinaria + endpoint directo).

    Llama a rpc_emit_pending_cae vía la DB (que resuelve el PV, reserva el número
    y persiste el fiscal_document). Sin tocar AFIP en este path (D5).
    """
    import json
    require_role(auth, ["user", "admin"])

    row = await conn.fetchrow(
        """
        SELECT public.rpc_emit_pending_cae(
          p_comprobante_type  => $1,
          p_total             => $2,
          p_client_id         => $3,
          p_point_of_sale_id  => $4
        ) AS result
        """,
        payload.comprobante_type,
        payload.total,
        str(payload.client_id) if payload.client_id else None,
        str(payload.point_of_sale_id) if payload.point_of_sale_id else None,
    )
    if row is None:
        raise HTTPException(status_code=500, detail="Error al emitir el comprobante")

    result = row["result"]
    if isinstance(result, str):
        result = json.loads(result)
    return dict(result)


async def process_pending_documents(
    doc_repo: FiscalDocumentRepository,
    adapter: FiscalDocumentPort,
    limit: int = 10,
) -> dict:
    """Procesa hasta `limit` documentos pending_cae con el relay idempotente.

    Retorna un resumen de lo procesado.
    """
    docs = await doc_repo.list_pending(limit=limit)
    processor = CAERelayProcessor(adapter=adapter, repo=doc_repo)

    processed = 0
    for doc in docs:
        await processor.process_document(doc)
        processed += 1

    return {"processed": processed, "total_found": len(docs)}
