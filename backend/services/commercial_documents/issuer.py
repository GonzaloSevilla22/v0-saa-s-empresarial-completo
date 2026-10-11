"""
Emisor de un papel de la cuenta (presupuestos-modulo D8 + documentos-marca-empresa
D4), resuelto SIN bloquear.

A diferencia de la factura fiscal (que levanta `issuer_data_incomplete` ante un
dato faltante), un presupuesto no es un comprobante: en producción sólo 2 de 41
cuentas tienen perfil fiscal, así que exigirlo dejaría al 95 % sin poder
presupuestar. Lo que falta, se omite.

La lectura va por `rpc_commercial_issuer(account_id)` —`SECURITY DEFINER`, con
guard de membresía— y NO por la conexión del request: la única política de
lectura de `profiles` para quien no es administrador es `auth.uid() = id`, así
que el perfil del dueño volvería vacío cuando descarga un vendedor, un
administrador o un cajero que no es el dueño, y el PDF saldría en silencio como
"Mi Negocio". Los datos son los mismos para cualquier miembro de la cuenta.

CASCADA ÚNICA, campo por campo (pura y testeable; atada al frontend por el
fixture `backend/tests/fixtures/document_issuer_cascade_cases.json`):

  | Dato             | Orden                                                              |
  |------------------|--------------------------------------------------------------------|
  | nombre visible   | marca `display_name` -> fiscal `nombre_fantasia` -> fiscal         |
  |                  | `razon_social` -> marca `legal_name` -> dueño `business_name` ->   |
  |                  | "Mi Negocio"                                                       |
  | razón social     | fiscal -> marca                                                    |
  | CUIT             | fiscal -> marca; `NN-NNNNNNNN-N` si tiene 11 dígitos               |
  | condición de IVA | sólo fiscal (`ISSUER_IVA_LEGEND`)                                  |
  | domicilio        | fiscal `domicilio_comercial` -> marca                              |
  | teléfono         | marca -> dueño                                                     |
  | email            | SÓLO el email del negocio de la marca                              |
  | web / pie        | sólo la marca                                                      |

El perfil fiscal manda en la identidad fiscal (lo registrado ante ARCA, lo que
imprime la factura: un presupuesto no puede contradecirla); la marca manda en el
nombre comercial y el contacto (presentación); el perfil del dueño es el
respaldo para que, sin marca, cada papel siga diciendo lo mismo que hoy.

El email de ACCESO de ningún usuario se imprime nunca: la RPC no lee `auth.users`
y esta función sólo lee las claves enumeradas, así que aunque la respuesta traiga
otra clave con un email (`email`, `owner_email`…) no llega al papel.
"""
from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from types import MappingProxyType
from typing import Any, Protocol

from backend.services.fiscal.comprobante import ISSUER_IVA_LEGEND, format_cuit

DEFAULT_ISSUER_NAME = "Mi Negocio"

# Origen de un dato impreso (para `GET /document-branding` y la pestaña).
SOURCE_BRAND = "brand"
SOURCE_FISCAL = "fiscal"
SOURCE_OWNER = "owner"
SOURCE_DEFAULT = "default"

_NO_SOURCES: Mapping[str, str] = MappingProxyType({})


@dataclass(frozen=True)
class CommercialIssuer:
    """Lo que el encabezado imprime del emisor. Todo es opcional salvo el nombre."""

    name: str
    legal_name: str | None = None
    cuit: str | None = None
    address: str | None = None
    phone: str | None = None
    iva_legend: str | None = None
    email: str | None = None            # SÓLO el email del negocio de la marca
    website: str | None = None
    # De dónde salió cada dato (brand|fiscal|owner|default). No participa de la
    # igualdad: dos emisores con los mismos textos son el mismo emisor.
    sources: Mapping[str, str] = field(default=_NO_SOURCES, compare=False)


class _IssuerSource(Protocol):
    async def get_commercial_issuer(self, account_id: str) -> Mapping[str, Any] | None: ...


def clean_text(value: object) -> str | None:
    """Texto sin espacios sobrantes; vacío o ausente = no hay dato."""
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _first(*candidates: tuple[str | None, str]) -> tuple[str | None, str]:
    """El primer valor presente y de dónde salió; `(None, 'default')` si ninguno."""
    for value, source in candidates:
        if value is not None:
            return value, source
    return None, SOURCE_DEFAULT


def issuer_from_rpc(raw: Mapping[str, Any] | None) -> CommercialIssuer:
    """Cascada del emisor y omisión de lo que falta, sobre lo que devolvió
    `rpc_commercial_issuer`. `None` (nunca debería) degrada al nombre por
    defecto en vez de impedir el documento. Una respuesta de la RPC anterior a
    `documentos-marca-empresa` (sólo 6 claves) se lee igual: las claves de la
    marca faltan y valen "sin dato"."""
    data = raw or {}

    brand_name = clean_text(data.get("brand_display_name"))
    fantasy = clean_text(data.get("nombre_fantasia"))
    fiscal_legal = clean_text(data.get("razon_social"))
    brand_legal = clean_text(data.get("brand_legal_name"))
    owner_name = clean_text(data.get("business_name"))

    name, name_source = _first(
        (brand_name, SOURCE_BRAND),
        (fantasy, SOURCE_FISCAL),
        (fiscal_legal, SOURCE_FISCAL),
        (brand_legal, SOURCE_BRAND),
        (owner_name, SOURCE_OWNER),
    )
    legal_name, legal_source = _first((fiscal_legal, SOURCE_FISCAL), (brand_legal, SOURCE_BRAND))
    cuit_raw, cuit_source = _first(
        (clean_text(data.get("cuit")), SOURCE_FISCAL), (clean_text(data.get("brand_tax_id")), SOURCE_BRAND)
    )
    address, address_source = _first(
        (clean_text(data.get("domicilio_comercial")), SOURCE_FISCAL), (clean_text(data.get("brand_address")), SOURCE_BRAND)
    )
    phone, phone_source = _first(
        (clean_text(data.get("brand_phone")), SOURCE_BRAND), (clean_text(data.get("phone")), SOURCE_OWNER)
    )
    iva_legend = ISSUER_IVA_LEGEND.get(clean_text(data.get("iva_condition")) or "")
    email = clean_text(data.get("brand_email"))
    website = clean_text(data.get("brand_website"))
    footer = clean_text(data.get("brand_footer_note"))

    return CommercialIssuer(
        name=name or DEFAULT_ISSUER_NAME,
        legal_name=legal_name,
        cuit=format_cuit(cuit_raw) if cuit_raw else None,
        address=address,
        phone=phone,
        iva_legend=iva_legend,
        email=email,
        website=website,
        sources=MappingProxyType(
            {
                "name": name_source if name else SOURCE_DEFAULT,
                "legal_name": legal_source,
                "cuit": cuit_source,
                "iva": SOURCE_FISCAL if iva_legend else SOURCE_DEFAULT,
                "address": address_source,
                "phone": phone_source,
                "email": SOURCE_BRAND if email else SOURCE_DEFAULT,
                "website": SOURCE_BRAND if website else SOURCE_DEFAULT,
                "footer_note": SOURCE_BRAND if footer else SOURCE_DEFAULT,
            }
        ),
    )


async def resolve_commercial_issuer(repo: _IssuerSource, account_id: str) -> CommercialIssuer:
    """El emisor de la cuenta del documento, leído sólo de la RPC."""
    return issuer_from_rpc(await repo.get_commercial_issuer(account_id))
