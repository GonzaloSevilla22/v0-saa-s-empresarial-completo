"""
C-27 v21-fiscal-profile — Router fiscal.
C-31 v21-wsfe-homologacion-wiring — endpoints de upload del cert + factory.

Endpoints:
  GET  /fiscal/profile          — obtener perfil fiscal de la cuenta
  POST /fiscal/profile          — crear/actualizar perfil fiscal
  PUT  /fiscal/profile          — alias de POST (upsert)
  POST /fiscal/profile/cert-upload-url — signed upload URL para cert/key (C-31)
  PUT  /fiscal/profile/cert-path       — persistir path del .crt (C-31)
  GET  /fiscal/points-of-sale   — listar PVs
  POST /fiscal/points-of-sale   — crear PV
  PATCH /fiscal/points-of-sale/{id} — desactivar PV
  POST /fiscal/documents/emit   — emitir comprobante pending_cae (OQ-3)
  POST /fiscal/documents/process-pending — relay del CAE (usuario, JWT-scoped)
  POST /fiscal/documents/process-pending-cron — relay del CAE (máquina, pg_cron, Bearer secret)

Sin lógica de negocio en el router: solo parse + DI + response.
Design ref: D9, D10, D11; 3 capas: router → service → repository.
C-31 Design ref: W1 (dos PEM), W2 (signed PUT, .key nunca devuelta), W4 (factory)
"""
from __future__ import annotations

import hmac
import logging
import uuid

import asyncpg
from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request

from backend.core.auth import get_current_user
from backend.core.config import settings
from backend.core.database import get_db_conn, get_service_conn
from backend.core.deps import get_account_id
from backend.repositories.fiscal_document_repository import FiscalDocumentRepository
from backend.repositories.fiscal_profile_repository import FiscalProfileRepository
from backend.repositories.point_of_sale_repository import PointOfSaleRepository
from backend.schemas.fiscal import (
    CertPathUpdate,
    CertUploadUrlOut,
    CertUploadUrlRequest,
    EmitPendingCAERequest,
    FiscalProfileCreate,
    FiscalProfileOut,
    PointOfSaleCreate,
    PointOfSaleOut,
)
from backend.services.fiscal import fiscal_profile_service as svc
from backend.services.fiscal.adapter_factory import build_cae_adapter, build_cae_adapter_from_settings
from backend.services.fiscal.fiscal_profile_service import process_doc_by_id_background

logger = logging.getLogger(__name__)

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


# ── Cert upload endpoints (C-31) ─────────────────────────────────────────────

def get_storage_service_client():
    """Dependency: Supabase Storage service client (service_role, D7/DEC-13).

    Genera el cliente de Storage con service_role SOLO para operaciones aisladas del cert:
      - generar la signed upload URL (cert-upload-url)
    Puede ser sobreescrito en tests vía app.dependency_overrides.
    """
    from backend.core.config import settings as _settings
    try:
        from supabase import create_client  # type: ignore[import]
        return create_client(_settings.supabase_url, _settings.supabase_service_role_key)
    except ImportError as exc:
        raise HTTPException(
            status_code=503,
            detail="Supabase Storage client no disponible en este entorno. Instalar: pip install supabase",
        ) from exc


@router.post(
    "/profile/cert-upload-url",
    response_model=CertUploadUrlOut,
    status_code=200,
    # v22 DEPRECATED: este endpoint es del modelo per-account (pre-delegación).
    # En el modelo de delegación (v22), el cert vive en AFIP_PLATFORM_CERT (env Render)
    # y NO se sube por cuenta. Endpoint conservado como fallback avanzado (OQ-2).
    # No usar en nuevas integraciones — el flujo normal es Administrador de Relaciones ARCA.
    deprecated=True,
    summary="[DEPRECATED v22] Generar URL de upload de certificado per-account (fallback avanzado)",
)
async def cert_upload_url(
    payload: CertUploadUrlRequest,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    storage_client=Depends(get_storage_service_client),
):
    """Genera una signed upload URL para subir el certificado o la clave privada.

    DEPRECADO (v22): el modelo de delegación (v22) usa el cert de plataforma
    (AFIP_PLATFORM_CERT en env Render), no cert per-account. Este endpoint se
    conserva como opción avanzada/fallback para integraciones legacy (OQ-2).

    El path canónico se deriva server-side del account_id del JWT (W1, W2).
    La .key viaja solo en el PUT al bucket privado — nunca se loguea ni devuelve.

    Governance CRÍTICO: usa service_role SOLO para generar la signed URL (D7/DEC-13).
    """
    result = await svc.create_cert_upload_url(str(account_id), auth, payload, storage_client)
    return result


@router.put(
    "/profile/cert-path",
    response_model=FiscalProfileOut,
    status_code=200,
    # v22 DEPRECATED: idem cert-upload-url — fallback avanzado del modelo per-account.
    deprecated=True,
    summary="[DEPRECATED v22] Persistir path del certificado per-account (fallback avanzado)",
)
async def update_cert_path(
    payload: CertPathUpdate,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: FiscalProfileRepository = Depends(get_fp_repo),
):
    """Persiste el path del certificado .crt en fiscal_profiles.

    DEPRECADO (v22): el modelo de delegación usa el cert de plataforma (env Render).
    Solo el .crt dispara este PUT. La .key NO toca este campo (W2).
    La respuesta es FiscalProfileOut — sin contenido del cert/key.
    """
    return await svc.set_cert_path(repo, auth, str(account_id), payload)


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
    background_tasks: BackgroundTasks,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Emite un comprobante fiscal en pending_cae (OQ-3: solo maquinaria).

    Resuelve el PV efectivo (D11): error P0422 si hay varios y no se especifica.
    No toca AFIP: persiste en pending_cae; luego dispara fire-and-forget para
    intentar el CAE inmediatamente (OQ-1=A, D6). El pg_cron actúa como backstop.
    """
    result = await svc.emit_pending_cae(conn, auth, str(account_id), payload)

    # Fire-and-forget: intenta el CAE de inmediato para el doc recién emitido.
    # La conexión del request ya será liberada — process_doc_by_id_background
    # abre su propia service conn (BYPASSRLS). El claim_pending guard garantiza
    # que si el pg_cron se superpone, solo uno llama a request_cae.
    doc_id = result.get("id") or result.get("fiscal_document_id")
    if doc_id:
        background_tasks.add_task(process_doc_by_id_background, doc_id)
        logger.debug("[emit_pending_cae] Scheduled background relay for doc %s", doc_id)

    return result


@router.post("/documents/process-pending")
async def process_pending_cae(
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    doc_repo: FiscalDocumentRepository = Depends(get_doc_repo),
    fp_repo: FiscalProfileRepository = Depends(get_fp_repo),
):
    """Procesa documentos pending_cae con el relay idempotente (OQ-1=A).

    Endpoint de usuario: JWT-scoped, single-account. Útil como trigger manual.
    v22: el adapter se decide por el gate "platform cert configured?" — ya NO por
    certificado_afip_path per-account. Si el cert de plataforma no está en env →
    stub (default seguro). Si está → WSFEAdapter real (delegación).
    """
    # v22: gate de plataforma (no per-account cert).
    # build_cae_adapter_from_settings lee AFIP_PLATFORM_CERT/KEY/CUIT del env.
    adapter = build_cae_adapter_from_settings()
    return await svc.process_pending_documents(doc_repo, adapter)


@router.post("/documents/process-pending-cron")
async def process_pending_cae_cron(
    request: Request,
    conn: asyncpg.Connection = Depends(get_service_conn),
):
    """Machine endpoint: relay del CAE cross-account para pg_cron (OQ-1=A, D6).

    Autenticación: shared secret ONLY (no JWT).
    Requiere header 'Authorization: Bearer <RELAY_SECRET>'.
    Si RELAY_SECRET no está configurado o la cabecera es incorrecta → 401 (fail-closed).

    Usa get_service_conn() (BYPASSRLS) para procesar docs de TODAS las cuentas.
    Anti-double-CAE: claim_pending garantiza que cada doc es procesado por exactamente
    un caller (fire-and-forget vs pg_cron no duplican la llamada a request_cae).

    TODO: inyectar WSFEAdapter real por cuenta/ambiente cuando el cert AFIP esté
    disponible (ARCA homologación). El stub es seguro — no llama a AFIP real.
    """
    # ── Auth: shared secret (mirrors payments.py mercadopago_webhook_secret pattern) ──
    configured_secret = settings.relay_secret
    if not configured_secret:
        # fail-closed: if env var is not set, reject ALL calls
        raise HTTPException(status_code=401, detail="Relay secret not configured")

    auth_header = request.headers.get("Authorization", "")
    if not auth_header.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing Authorization header")

    provided_secret = auth_header[len("Bearer "):]
    if not hmac.compare_digest(provided_secret, configured_secret):
        raise HTTPException(status_code=401, detail="Invalid relay secret")

    # ── Process all pending docs cross-account ────────────────────────────────
    # v22: adapter real vs stub → gate de plataforma (cert en env vars).
    # Un único adapter para todos los docs del cron (todos usan el mismo cert de plataforma).
    # Auth.Cuit = cuit_emisor de cada doc (no el del representante) — ver WSFEAdapter._call_wsfe.
    doc_repo = FiscalDocumentRepository(conn)

    # v22: build desde settings (AFIP_PLATFORM_CERT/KEY/CUIT) — no per-account
    platform_adapter = build_cae_adapter_from_settings()
    summary = await svc.process_all_pending_documents(doc_repo, adapter=platform_adapter)
    logger.info("[process_pending_cae_cron] %s", summary)
    return summary
