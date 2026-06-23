"""
C-27 v21-fiscal-profile — Fiscal service: FiscalProfile + PointOfSale + emisión.
C-31 v21-wsfe-homologacion-wiring — servicios de upload del cert AFIP + factory.

Capa de servicio (lógica de negocio + guards). Sin lógica en los routers.
Design ref: D9 (require_role), D10 (multi-PV), D11 (P0422 ambiguous_point_of_sale)
C-31 Design ref: W1 (dos PEM), W2 (signed PUT, key nunca devuelta), W4 (factory)
"""
from __future__ import annotations

import logging

from fastapi import HTTPException

import backend.core.database as _db
from backend.core.guards import require_role
from backend.repositories.fiscal_profile_repository import FiscalProfileRepository
from backend.repositories.fiscal_document_repository import FiscalDocumentRepository
from backend.repositories.point_of_sale_repository import PointOfSaleRepository
from backend.schemas.fiscal import (
    CertPathUpdate,
    CertUploadUrlRequest,
    EmitPendingCAERequest,
    FiscalProfileCreate,
    PointOfSaleCreate,
)
from backend.services.fiscal.cae_relay_processor import CAERelayProcessor
from backend.services.fiscal.fiscal_document_port import FiscalDocumentPort
from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter

logger = logging.getLogger(__name__)


# ── Cert upload service (C-31) ────────────────────────────────────────────────

# Mapping canónico: kind → nombre de objeto en bucket afip-certs (W1)
# El path SIEMPRE se deriva del account_id server-side, nunca del filename del cliente.
_CERT_OBJECT_NAME = {
    "cert": "afip.crt",
    "key":  "afip.key",
}


async def create_cert_upload_url(
    account_id: str,
    auth: dict,
    payload: CertUploadUrlRequest,
    storage_service_client,
) -> dict:
    """Genera una signed upload URL para subir el cert/key al bucket privado afip-certs.

    El path canónico se deriva siempre del account_id del JWT (W2 — el cliente
    NO elige la ruta para evitar que un usuario A apunte al path de B).

    Seguridad (OQ-2 / W2):
      - La .key viaja SOLO en el body del signed PUT al bucket privado.
      - Nunca se loguea, nunca se devuelve en ningún GET.

    Returns: dict {uploadUrl: str, path: str}
    """
    require_role(auth, ["user", "admin"])

    object_name = _CERT_OBJECT_NAME[payload.kind]
    canonical_path = f"{account_id}/{object_name}"

    # Generar signed upload URL server-side vía service_role (aislado — D7/DEC-13)
    response = storage_service_client.storage.from_("afip-certs").create_signed_upload_url(
        canonical_path
    )

    signed_url = response.get("signedURL") or response.get("signed_url") or response.get("url", "")

    return {
        "uploadUrl": signed_url,
        "path": canonical_path,
    }


async def set_cert_path(
    repo: FiscalProfileRepository,
    auth: dict,
    account_id: str,
    payload: CertPathUpdate,
) -> dict:
    """Persiste el path del certificado .crt en fiscal_profiles.certificado_afip_path.

    Solo el .crt dispara este PUT (la .key no toca este campo — W2).
    Usa el upsert existente del repo (COALESCE — no sobrescribe si ya existe
    un path y se pasa None).

    Seguridad: la respuesta NO incluye contenido del cert/key.
    """
    require_role(auth, ["user", "admin"])

    result = await repo.upsert(account_id, {"certificado_afip_path": payload.path})
    if result is None:
        raise HTTPException(status_code=500, detail="Error al persistir el path del certificado")
    return result


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
    Usado por el endpoint de usuario POST /fiscal/documents/process-pending (JWT-scoped,
    single account). No usa claim_pending — el endpoint de usuario ya es single-threaded.
    """
    docs = await doc_repo.list_pending(limit=limit)
    processor = CAERelayProcessor(adapter=adapter, repo=doc_repo)

    processed = 0
    for doc in docs:
        await processor.process_document(doc)
        processed += 1

    return {"processed": processed, "total_found": len(docs)}


async def process_all_pending_documents(
    doc_repo: FiscalDocumentRepository,
    adapter: FiscalDocumentPort | None = None,
    limit: int = 50,
    service_client=None,
) -> dict:
    """Procesa documentos pending_cae de TODAS las cuentas (cross-account, sin RLS).

    Usado exclusivamente por el machine endpoint POST /fiscal/documents/process-pending-cron
    (pg_cron) con service-role connection.

    C-31 (W4 factory): si `adapter` es None, selecciona el adapter por doc/cuenta:
      - cuenta con certificado_afip_path → WSFEAdapter real (service_client requerido)
      - sin cert → WSFEStubAdapter (default seguro, no rompe prod)

    Anti-double-CAE guard (D6, OQ-1=A):
      Para cada doc encontrado con list_pending_all, se llama claim_pending antes de
      procesar. Si claim_pending retorna None (otro trigger — fire-and-forget — ya reclamó
      el doc), este caller lo saltea. Esto garantiza que request_cae se llama exactamente
      una vez por documento por intento, incluso si el pg_cron y el fire-and-forget se
      superponen.

    Nota: FOR UPDATE SKIP LOCKED no se mantiene durante la llamada SOAP (larga);
    el lease de 5 minutos en next_attempt_at es el mecanismo de concurrencia.
    """
    from backend.services.fiscal.adapter_factory import build_cae_adapter

    docs = await doc_repo.list_pending_all(limit=limit)

    processed = 0
    authorized = 0
    retried = 0
    rejected = 0

    for doc in docs:
        doc_id = doc["id"]
        # Intenta reclamar el doc atómicamente. Si otro trigger ya lo reclamó → skip.
        claimed = await doc_repo.claim_pending(doc_id)
        if claimed is None:
            logger.debug(
                "[process_all_pending_documents] doc %s already claimed by concurrent trigger — skipping",
                doc_id,
            )
            continue

        # C-31 (W4): elegir adapter por cuenta/doc — real si hay cert, stub si no
        if adapter is not None:
            # Legacy: adapter inyectado explícitamente (tests de C-27)
            _adapter = adapter
        else:
            cert_path = claimed.get("certificado_afip_path") if isinstance(claimed, dict) else None
            _adapter = build_cae_adapter(
                has_cert=bool(cert_path),
                service_client=service_client,
            )

        processor = CAERelayProcessor(adapter=_adapter, repo=doc_repo)
        await processor.process_document(claimed)
        processed += 1

    return {
        "processed": processed,
        "authorized": authorized,
        "retried": retried,
        "rejected": rejected,
    }


async def process_doc_by_id_background(doc_id: str) -> None:
    """BackgroundTask: procesa un único doc por id abriendo su propia conexión service.

    Diseñado para ser disparado como fire-and-forget inmediatamente después de
    que emit_pending_cae persiste el documento (OQ-1=A, D6).

    Flujo:
      1. Adquiere una conexión BYPASSRLS del pool service (postgres user).
         La conexión del request ya fue liberada al responder.
      2. Intenta claim_pending en el doc_id — si ya fue reclamado por el cron
         coincidente, es un no-op seguro.
      3. Si gana el claim, llama process_document (que llama request_cae).

    C-31 (W4): el adapter es el stub por defecto (safe) — la cuenta siempre tiene
    el pg_cron como backstop con la factory real. El fire-and-forget usa stub para
    no bloquear la respuesta del usuario con una llamada SOAP potencialmente lenta.
    Si el stub falla, el cron lo reintenta con el adapter correcto.
    """
    if _db.pool is None:
        logger.warning("[process_doc_by_id_background] pool not initialized — skipping doc %s", doc_id)
        return

    try:
        async with _db.pool.acquire() as conn:
            repo = FiscalDocumentRepository(conn)
            adapter = WSFEStubAdapter()
            processor = CAERelayProcessor(adapter=adapter, repo=repo)
            await processor.process_document_by_id(doc_id)
    except Exception:
        # Background tasks must not crash the caller — log and swallow.
        # The pg_cron backstop will retry on the next minute.
        logger.exception(
            "[process_doc_by_id_background] error processing doc %s — cron backstop will retry",
            doc_id,
        )
