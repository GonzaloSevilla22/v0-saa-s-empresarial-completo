"""
`/document-branding` — la marca de la cuenta para sus papeles
(documentos-marca-empresa D9, capability `document-branding`).

Router delgado: validación + inyección de dependencias; toda la lógica vive en
`services/document_branding.py`.

  GET    /document-branding        cualquier miembro: lo guardado + lo que se imprime
  PUT    /document-branding        owner/admin: datos y paleta (el logo no cambia)
  PUT    /document-branding/logo   owner/admin: la imagen como CUERPO BINARIO
  DELETE /document-branding/logo   owner/admin: quita el logo (204, idempotente)
  GET    /document-branding/logo   cualquier miembro: la imagen, con ETag = su huella

El cuerpo del logo se lee por `request.stream()` con un contador (sin
`python-multipart`: una dependencia nueva para un solo archivo no se justifica):
más de 2 MiB corta con 413 sin leer el resto, y un `Content-Length` declarado
mayor se rechaza antes de leer nada.
"""
from __future__ import annotations

import uuid

import asyncpg
from fastapi import APIRouter, Depends, Request, Response

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.core.deps import get_account_id
from backend.core.errors import ProblemHTTPException
from backend.repositories.document_branding_repository import DocumentBrandingRepository
from backend.schemas.document_branding import DocumentBrandingIn, DocumentBrandingOut, LogoUploadOut
from backend.services import document_branding as branding_service
from backend.services.commercial_documents.logo import MAX_UPLOAD_BYTES, LogoTooLarge

router = APIRouter(prefix="/document-branding", tags=["document-branding"])


def get_repo(conn: asyncpg.Connection = Depends(get_db_conn)) -> DocumentBrandingRepository:
    return DocumentBrandingRepository(conn)


def _too_large() -> ProblemHTTPException:
    return ProblemHTTPException(
        status_code=LogoTooLarge.status_code, detail=LogoTooLarge.message, code=LogoTooLarge.code
    )


def _body_reader(request: Request):
    """Lector del cuerpo binario con tope: se le pasa al service, que lo invoca recién
    DESPUÉS del guard de rol."""

    async def read() -> bytes:
        declared = request.headers.get("content-length")
        if declared and declared.isdigit() and int(declared) > MAX_UPLOAD_BYTES:
            raise _too_large()
        chunks: list[bytes] = []
        total = 0
        async for chunk in request.stream():
            total += len(chunk)
            if total > MAX_UPLOAD_BYTES:
                raise _too_large()               # sin leer el resto
            chunks.append(chunk)
        return b"".join(chunks)

    return read


def _etag_matches(header: str | None, sha256: str) -> bool:
    if not header:
        return False
    candidates = [part.strip().removeprefix("W/").strip('"') for part in header.split(",")]
    return "*" in candidates or sha256 in candidates


@router.get("", response_model=DocumentBrandingOut)
async def get_document_branding(
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: DocumentBrandingRepository = Depends(get_repo),
):
    """Cualquier miembro. Sin fila → valores por defecto (Neutro, sin logo)."""
    return await branding_service.get_branding(repo, str(account_id))


@router.put("", response_model=DocumentBrandingOut)
async def put_document_branding(
    payload: DocumentBrandingIn,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: DocumentBrandingRepository = Depends(get_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Sólo owner/admin: reemplaza los datos y la paleta. El logo no cambia."""
    return await branding_service.save_branding(repo, auth, str(account_id), payload, conn=conn)


@router.put("/logo", response_model=LogoUploadOut)
async def put_document_logo(
    request: Request,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: DocumentBrandingRepository = Depends(get_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
):
    """Sólo owner/admin: la imagen como cuerpo binario (PNG, JPEG o WebP; se normaliza)."""
    return await branding_service.save_logo(repo, auth, str(account_id), _body_reader(request), conn=conn)


@router.delete("/logo", status_code=204)
async def delete_document_logo(
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: DocumentBrandingRepository = Depends(get_repo),
    conn: asyncpg.Connection = Depends(get_db_conn),
) -> Response:
    """Sólo owner/admin. Idempotente."""
    await branding_service.delete_logo(repo, auth, str(account_id), conn=conn)
    return Response(status_code=204)


@router.get("/logo")
async def get_document_logo(
    request: Request,
    auth: dict = Depends(get_current_user),
    account_id: uuid.UUID = Depends(get_account_id),
    repo: DocumentBrandingRepository = Depends(get_repo),
) -> Response:
    """Cualquier miembro: la imagen normalizada. `ETag` = su huella SHA-256 (el frontend pide
    `?v=<huella>`, así que un logo nuevo es una URL nueva); caché privada de un día."""
    logo = await branding_service.get_logo(repo, str(account_id))
    headers = {
        "ETag": f'"{logo["sha256"]}"',
        "Cache-Control": "private, max-age=86400",
        "X-Content-Type-Options": "nosniff",
    }
    if _etag_matches(request.headers.get("if-none-match"), logo["sha256"]):
        return Response(status_code=304, headers=headers)
    return Response(content=logo["data"], media_type=logo["mime"], headers=headers)
