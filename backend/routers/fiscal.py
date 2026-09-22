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
  POST /fiscal/documents/process-pending-cron — relay del CAE (máquina, pg_cron, Bearer secret)

fiscal-emision-segura (G1, 2026-09-22): el relay del CAE tiene UN SOLO camino —
el cron. Se retiraron el disparo inmediato (`background_tasks.add_task`) de los
dos endpoints de emisión y el endpoint de usuario
`POST /fiscal/documents/process-pending`:
  - el disparo inmediato instanciaba el STUB a mano (CAE inventado) y sólo lo
    desarmaba un AttributeError de tipo; con `authorized` como estado terminal,
    un CAE falso ahí no lo corregía nadie;
  - `process-pending` construía el adapter REAL y NO llamaba `claim_pending`
    (docstring propio: "el endpoint de usuario ya es single-threaded", falso
    como argumento de concurrencia frente al cron), sin ningún caller en el
    frontend y expuesto a cualquier JWT válido.

Sin lógica de negocio en el router: solo parse + DI + response.
Design ref: D9, D10, D11; 3 capas: router → service → repository.
C-31 Design ref: W1 (dos PEM), W2 (signed PUT, .key nunca devuelta), W4 (factory)
"""
from __future__ import annotations

import hmac
import logging
import uuid

import asyncpg
from fastapi import APIRouter, Depends, HTTPException, Request

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
    EmitSubscriptionPaymentRequest,
    FiscalProfileCreate,
    FiscalProfileOut,
    PointOfSaleCreate,
    PointOfSaleOut,
)
from backend.services.fiscal import fiscal_profile_service as svc
from backend.services.fiscal.adapter_factory import build_cae_adapter, build_cae_adapter_from_settings

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/fiscal", tags=["fiscal"])


# ── Dependency factories ──────────────────────────────────────────────────────

def get_fp_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> FiscalProfileRepository:
    return FiscalProfileRepository(conn)


def get_pv_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> PointOfSaleRepository:
    return PointOfSaleRepository(conn)


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
        # fix/service-role-key-env-alias: `Settings` no declara
        # `supabase_service_role_key` — el campo real es `service_role_key`
        # (alias SUPABASE_SERVICE_ROLE_KEY/SERVICE_ROLE_KEY). El atributo
        # viejo levantaba AttributeError en cualquier llamada real a este
        # endpoint (deprecated, sin cobertura de test porque siempre se
        # override vía app.dependency_overrides).
        return create_client(_settings.supabase_url, _settings.service_role_key)
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

@router.get("/documents/by-receipt/{receipt_id}")
async def get_fiscal_doc_by_receipt(
    receipt_id: str,
    auth: dict = Depends(get_current_user),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Retorna el fiscal_document vinculado a un receipt de suscripción (si existe).

    Usado por el admin en admin/pagos para mostrar el CAE status en vez del botón
    'Enviar al ARCA' en rows ya facturadas (idempotency check on page load).
    Governance: solo admin puede consultar este endpoint.
    v22-admin — PO sign-off 2026-06-24.
    """
    from backend.core.guards import require_platform_admin
    await require_platform_admin(conn, auth)

    # fiscal-emision-segura (G7): punto_de_venta + number son lo que identifica
    # al comprobante ante ARCA ("Factura C 0003-00000002"). Sin ellos acá, el
    # número que G3 persiste no lo ve nadie.
    # (M-4, red team 2026-09-22): cae_submit_unconfirmed_at → is_frozen. Un
    # comprobante CONGELADO (G4) sigue reportando status='pending_cae' — sin
    # esta bandera, /admin/pagos lo muestra "En trámite" para siempre y nadie
    # sabe que necesita revisión manual en ARCA.
    row = await conn.fetchrow(
        """
        SELECT id, status, cae, cae_due_date, comprobante_type, total,
               subscription_payment_id, punto_de_venta, number,
               cae_submit_unconfirmed_at
        FROM   public.fiscal_documents
        WHERE  subscription_payment_id = $1
        LIMIT  1
        """,
        receipt_id,
    )
    if row is None:
        return None
    doc = dict(row)
    return {
        "id":                     str(doc["id"]),
        "status":                 doc["status"],
        "cae":                    doc.get("cae"),
        "cae_due_date":           str(doc["cae_due_date"]) if doc.get("cae_due_date") else None,
        "comprobante_type":       doc["comprobante_type"],
        "total":                  float(doc["total"]),
        "subscription_payment_id": doc["subscription_payment_id"],
        "punto_de_venta":         doc["punto_de_venta"],
        "number":                 doc["number"],
        # B2-3 (segundo red team, 2026-09-22): la bandera vale MIENTRAS el
        # documento siga esperando CAE. `cae_submit_unconfirmed_at` no la limpia
        # ningún camino (todas las escrituras son `COALESCE(..., now())`), así
        # que sin la condición de status un comprobante resuelto a mano —la
        # única salida prevista del congelamiento— seguía mostrándose
        # "Congelado" para siempre, tapando el CAE y el número reales.
        "is_frozen": (
            doc.get("cae_submit_unconfirmed_at") is not None
            and doc["status"] == "pending_cae"
        ),
    }


@router.post("/documents/emit")
async def emit_pending_cae(
    payload: EmitPendingCAERequest,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Emite un comprobante fiscal en pending_cae (OQ-3: solo maquinaria).

    Resuelve el PV efectivo (D11): error P0422 si hay varios y no se especifica.
    No toca AFIP: persiste en pending_cae. El CAE lo obtiene el cron
    (`relay-process-pending-cae`, cada minuto), que es el único camino de
    emisión — fiscal-emision-segura G1 retiró el disparo inmediato.
    """
    return await svc.emit_pending_cae(conn, auth, str(account_id), payload)


@router.post("/documents/emit-subscription-payment", status_code=201)
async def emit_subscription_payment(
    payload: EmitSubscriptionPaymentRequest,
    auth: dict = Depends(get_current_user),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Emite Factura C por un pago de suscripción (flujo admin Aliadata).

    Governance: CRÍTICO — solo admin. El service valida el rol antes de tocar la DB.
    Idempotency: si el receipt_id ya tiene un fiscal_document asociado, retorna el
    existente con already_emitted=True (HTTP 200 → el frontend muestra el badge).

    Pago identificado por receipt_id; receptor por CUIT (DocTipo=80), DNI
    (DocTipo=96) o consumidor final sin identificar (G5, DocTipo=99).
    El CAE lo obtiene el cron — sin disparo inmediato (G1).
    v22-admin — PO sign-off 2026-06-24.
    """
    return await svc.emit_subscription_payment_cae(conn, auth, payload)


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
