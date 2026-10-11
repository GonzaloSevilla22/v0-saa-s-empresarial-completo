"""
`DocumentBranding`: todo lo que un papel de la cuenta necesita para llevar su
marca (documentos-marca-empresa D5, capability `document-branding`): el emisor
resuelto por la cascada única, la paleta, el logo ya comprobado, la leyenda al
pie y el contacto que cargó la cuenta en su marca.

Es un valor INMUTABLE que se resuelve una vez por documento y viaja a los
renders (comprobante interno, presupuesto, remitos y, en la tanda B, la Factura
C). Ningún render lee la base ni resuelve colores por su cuenta.

`branding_from_rpc` es PURA (sin I/O, sin imagen): arma la marca de lo que
devolvió `rpc_commercial_issuer`. `resolve_document_branding` (abajo, con I/O)
hace la lectura y baja los bytes del logo sólo si hay huella y no están en caché.
"""
from __future__ import annotations

from collections import OrderedDict
from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Any, Protocol

from backend.services.commercial_documents.issuer import CommercialIssuer, clean_text, issuer_from_rpc
from backend.services.commercial_documents.logo import LogoImage, load_logo_for_render
from backend.services.commercial_documents.palette import NEUTRAL, DocumentPalette, resolve_palette

# Caché en memoria del logo ya comprobado, por (cuenta, huella SHA-256). La clave
# incluye la huella: un logo nuevo invalida solo (no hay riesgo de servir uno
# viejo) y se evita mover hasta 300 KB de la base por cada PDF. Acotado a 32
# entradas (LRU): ~10 MB en el peor caso.
LOGO_CACHE_SIZE = 32
_logo_cache: OrderedDict[tuple[str, str], LogoImage | None] = OrderedDict()


@dataclass(frozen=True)
class BrandContact:
    """Teléfono, email y sitio web cargados EN LA MARCA (sin el respaldo del
    perfil del dueño): lo que la Factura C puede sumar sin que una cuenta que
    nunca configuró su marca reciba una factura distinta de la de hoy."""

    phone: str | None = None
    email: str | None = None
    website: str | None = None


@dataclass(frozen=True)
class DocumentBranding:
    issuer: CommercialIssuer
    palette: DocumentPalette = NEUTRAL
    logo: LogoImage | None = None
    footer_note: str | None = None
    brand_contact: BrandContact = field(default_factory=BrandContact)

    @classmethod
    def neutral(cls, issuer: CommercialIssuer) -> DocumentBranding:
        """La marca por defecto de un emisor: paleta Neutro, sin logo, sin pie.
        Para los tests y para el camino de respaldo."""
        return cls(issuer=issuer)


def branding_from_rpc(raw: Mapping[str, Any] | None, logo: LogoImage | None = None) -> DocumentBranding:
    """La marca de lo que devolvió la RPC (+ el logo, si ya se resolvió)."""
    data = raw or {}
    return DocumentBranding(
        issuer=issuer_from_rpc(data),
        palette=resolve_palette(clean_text(data.get("palette_preset")), clean_text(data.get("accent_color"))),
        logo=logo,
        footer_note=clean_text(data.get("brand_footer_note")),
        brand_contact=BrandContact(
            phone=clean_text(data.get("brand_phone")),
            email=clean_text(data.get("brand_email")),
            website=clean_text(data.get("brand_website")),
        ),
    )


def clear_logo_cache() -> None:
    """Vacía el caché del logo (para los tests)."""
    _logo_cache.clear()


class _BrandingSource(Protocol):
    async def get_commercial_issuer(self, account_id: str) -> Mapping[str, Any] | None: ...

    async def get_document_logo(self, account_id: str) -> Mapping[str, Any] | None: ...


def _remember(key: tuple[str, str], logo: LogoImage | None) -> None:
    _logo_cache[key] = logo
    _logo_cache.move_to_end(key)
    while len(_logo_cache) > LOGO_CACHE_SIZE:
        _logo_cache.popitem(last=False)


async def _resolve_logo(repo: _BrandingSource, account_id: str, fingerprint: str) -> LogoImage | None:
    """El logo de la cuenta para dibujar, o `None`. Los bytes se piden a la base
    SÓLO si la huella no está en el caché; lo ilegible también se recuerda (con la
    misma clave) para no volver a la base en cada papel."""
    key = (account_id, fingerprint)
    if key in _logo_cache:
        _logo_cache.move_to_end(key)
        return _logo_cache[key]
    row = await repo.get_document_logo(account_id)
    if not row or not row.get("logo_image"):
        return None                       # la RPC vio una huella y la fila ya no tiene logo: sin logo
    logo = load_logo_for_render(bytes(row["logo_image"]), row.get("logo_mime"))
    # Si el logo cambió entre las dos lecturas, vale el de la FILA, cacheado con su
    # propia huella (la de los bytes que de verdad se dibujan).
    stored_fingerprint = logo.sha256 if logo is not None else (clean_text(row.get("logo_sha256")) or fingerprint)
    _remember((account_id, stored_fingerprint), logo)
    return logo


async def resolve_document_branding(repo: _BrandingSource, account_id: str) -> DocumentBranding:
    """La marca de la cuenta del documento. UNA llamada a `rpc_commercial_issuer`
    (que devuelve la huella del logo, nunca la imagen) y, sólo si hay huella y no
    está en el caché, la lectura de los bytes. NO consulta la tabla de la marca por
    su cuenta: una RPC anterior a este cambio devuelve las 6 claves legadas, las de
    la marca faltan y el papel sale con Neutro y sin logo (ventana de despliegue,
    design D12)."""
    raw = await repo.get_commercial_issuer(account_id)
    fingerprint = clean_text((raw or {}).get("logo_sha256"))
    logo = await _resolve_logo(repo, account_id, fingerprint) if fingerprint else None
    return branding_from_rpc(raw, logo)
