"""
Marca de la cuenta para sus papeles (documentos-marca-empresa D9, capability
`document-branding`): lectura, escritura de los datos y la paleta, y el ciclo del
logo (subir, quitar, servir).

  - Lectura (`get_branding`): cualquier miembro. Devuelve lo guardado, lo que se
    IMPRIME (el emisor por la cascada única, con el origen de cada dato), los
    datos fiscales de sólo lectura, el respaldo del perfil del dueño, la paleta
    resuelta y el catálogo. Nunca la imagen ni un email de acceso.
  - Escritura (`save_branding`, `save_logo`, `delete_logo`): sólo owner/admin
    (`CAN_CONFIGURE`, capacidad sensible: la base es la autoridad del rol). Defensa
    en dos capas: este 403 legible ANTES de leer el cuerpo o escribir + el
    disparador P0401 de la tabla.
  - El contraste del color personalizado lo decide acá, con la aritmética de
    `palette.py` (422 `branding_accent_low_contrast`): la base no calcula
    contraste.
  - El logo lo valida y normaliza el servidor (`logo.py`): los rechazos salen como
    RFC 7807 con su código estable (413/415/422). La normalización decodifica una
    imagen (CPU), así que corre en un hilo para no bloquear el event loop.
"""
from __future__ import annotations

import asyncio
import contextlib
from collections.abc import Awaitable, Callable, Mapping
from typing import Any

import asyncpg

from backend.core.errors import ProblemHTTPException, problem_from_pg_error
from backend.core.guards import require_account_role
from backend.core.rbac import CAN_CONFIGURE
from backend.repositories.document_branding_repository import DATA_COLUMNS, DocumentBrandingRepository
from backend.schemas.document_branding import DocumentBrandingIn
from backend.services.commercial_documents.branding import branding_from_rpc
from backend.services.commercial_documents.issuer import clean_text
from backend.services.commercial_documents.logo import LogoError, normalize_logo
from backend.services.commercial_documents.palette import (
    is_valid_accent,
    palette_as_hex,
    palette_catalog_for_api,
    resolve_palette,
)
from backend.services.fiscal.comprobante import format_cuit

ACCENT_LOW_CONTRAST_CODE = "branding_accent_low_contrast"
LOGO_NOT_FOUND_CODE = "branding_logo_not_found"

_DEFAULT_SETTINGS: dict[str, Any] = {column: None for column in DATA_COLUMNS} | {"palette_preset": "neutro"}


@contextlib.contextmanager
def _pg_errors_as_problems():
    """Traduce los errores de negocio de la base a RFC 7807 (mismo patrón que presupuesto y remito)."""
    try:
        yield
    except asyncpg.PostgresError as exc:
        problem = problem_from_pg_error(exc)
        if problem is None:
            raise
        raise problem from exc


def _settings(row: Mapping[str, Any] | None) -> dict[str, Any]:
    if row is None:
        return dict(_DEFAULT_SETTINGS)
    return {column: row.get(column, _DEFAULT_SETTINGS[column]) for column in DATA_COLUMNS}


def _logo_descriptor(row: Mapping[str, Any] | None) -> dict[str, Any] | None:
    if row is None or not row.get("logo_sha256"):
        return None
    return {
        "sha256": row["logo_sha256"],
        "mime": row["logo_mime"],
        "width": row["logo_width"],
        "height": row["logo_height"],
    }


def _fiscal(raw: Mapping[str, Any]) -> dict[str, Any] | None:
    """Los datos que vienen del perfil fiscal. Una cuenta sin perfil fiscal (el alta exige
    CUIT y condición de IVA) no tiene ninguno."""
    cuit = clean_text(raw.get("cuit"))
    if cuit is None:
        return None
    return {
        "razon_social": clean_text(raw.get("razon_social")),
        "nombre_fantasia": clean_text(raw.get("nombre_fantasia")),
        "cuit": format_cuit(cuit),
        "domicilio_comercial": clean_text(raw.get("domicilio_comercial")),
        "iva_condition": clean_text(raw.get("iva_condition")),
    }


def _present(row: Mapping[str, Any] | None, raw: Mapping[str, Any] | None) -> dict[str, Any]:
    """La respuesta de `GET /document-branding` a partir de la fila guardada (`None` = nunca
    guardó) y de lo que devolvió `rpc_commercial_issuer` (perfil fiscal + perfil del dueño)."""
    data = raw or {}
    settings = _settings(row)
    # El emisor impreso y el origen de cada dato salen de la MISMA cascada que usan los papeles.
    branding = branding_from_rpc(data)
    issuer = branding.issuer
    return {
        "settings": settings,
        "is_default": row is None,
        "logo": _logo_descriptor(row),
        "issuer": {
            "name": issuer.name, "legal_name": issuer.legal_name, "cuit": issuer.cuit, "iva_legend": issuer.iva_legend,
            "address": issuer.address, "phone": issuer.phone, "email": issuer.email, "website": issuer.website,
        },
        "sources": dict(issuer.sources),
        "fiscal": _fiscal(data),
        "owner_fallback": {
            "business_name": clean_text(data.get("business_name")),
            "phone": clean_text(data.get("phone")),
        },
        "footer_note": settings["footer_note"],
        # La paleta que se dibuja es la de lo GUARDADO (una inválida o ilegible cae a Neutro).
        "palette": palette_as_hex(resolve_palette(settings["palette_preset"], settings["accent_color"])),
        "palettes": palette_catalog_for_api(),
        "updated_at": row.get("updated_at") if row else None,
        "updated_by": row.get("updated_by") if row else None,
    }


async def get_branding(repo: DocumentBrandingRepository, account_id: str) -> dict[str, Any]:
    """Cualquier miembro lee la marca. Sin fila = valores por defecto (`is_default`)."""
    with _pg_errors_as_problems():
        row = await repo.get(account_id)
        raw = await repo.get_commercial_issuer(account_id)
    return _present(row, raw)


async def save_branding(
    repo: DocumentBrandingRepository,
    auth: dict,
    account_id: str,
    payload: DocumentBrandingIn,
    *,
    conn,
) -> dict[str, Any]:
    """Reemplaza los datos y la paleta (sólo owner/admin). El logo no se toca."""
    await require_account_role(conn, auth, CAN_CONFIGURE)
    data = payload.model_dump()
    if data["palette_preset"] == "personalizado" and not is_valid_accent(data["accent_color"]):
        raise ProblemHTTPException(
            status_code=422,
            detail="El color elegido no se lee bien sobre blanco: probá con uno más oscuro (contraste mínimo 4,5:1).",
            code=ACCENT_LOW_CONTRAST_CODE,
            field="accent_color",
        )
    with _pg_errors_as_problems():
        row = await repo.upsert(account_id, {column: data[column] for column in DATA_COLUMNS}, auth["user_id"])
        raw = await repo.get_commercial_issuer(account_id)
    return _present(row, raw)


def _logo_problem(exc: LogoError) -> ProblemHTTPException:
    return ProblemHTTPException(status_code=exc.status_code, detail=exc.detail, code=exc.code)


async def save_logo(
    repo: DocumentBrandingRepository,
    auth: dict,
    account_id: str,
    read_body: Callable[[], Awaitable[bytes]],
    *,
    conn,
) -> dict[str, Any]:
    """Sube el logo (sólo owner/admin). El guard corre ANTES de leer el cuerpo: un vendedor
    que manda 100 MB recibe 403 sin que el servidor los lea."""
    await require_account_role(conn, auth, CAN_CONFIGURE)
    raw = await read_body()
    try:
        logo = await asyncio.to_thread(normalize_logo, raw)
    except LogoError as exc:
        raise _logo_problem(exc) from exc
    with _pg_errors_as_problems():
        await repo.set_logo(account_id, logo, auth["user_id"])
    return {"logo": {"sha256": logo.sha256, "mime": logo.mime, "width": logo.width, "height": logo.height}}


async def delete_logo(repo: DocumentBrandingRepository, auth: dict, account_id: str, *, conn) -> None:
    """Quita el logo (sólo owner/admin). Idempotente: sin logo no hay nada que cambiar."""
    await require_account_role(conn, auth, CAN_CONFIGURE)
    with _pg_errors_as_problems():
        await repo.clear_logo(account_id, auth["user_id"])


async def get_logo(repo: DocumentBrandingRepository, account_id: str) -> dict[str, Any]:
    """La imagen normalizada de la cuenta (cualquier miembro) o 404 `branding_logo_not_found`."""
    with _pg_errors_as_problems():
        row = await repo.get_document_logo(account_id)
    if not row or not row.get("logo_image"):
        raise ProblemHTTPException(
            status_code=404, detail="La cuenta no tiene logo.", code=LOGO_NOT_FOUND_CODE
        )
    return {"data": bytes(row["logo_image"]), "mime": row["logo_mime"], "sha256": row["logo_sha256"]}
