"""
Emisor de un documento comercial (presupuestos-modulo D8), resuelto SIN
bloquear.

A diferencia de la factura fiscal (que levanta `issuer_data_incomplete` ante un
dato faltante), un presupuesto no es un comprobante: en producción sólo 1 de 41
cuentas tiene domicilio cargado, así que exigir el perfil fiscal dejaría al 97 %
sin poder presupuestar. Lo que falta, se omite.

La lectura va por `rpc_commercial_issuer(account_id)` —`SECURITY DEFINER`, con
guard de membresía— y NO por la conexión del request: la única política de
lectura de `profiles` para quien no es administrador es `auth.uid() = id`, así
que el perfil del dueño volvería vacío cuando descarga un vendedor, un
administrador o un cajero que no es el dueño, y el PDF saldría en silencio como
"Mi Negocio". Los datos son los mismos para cualquier miembro de la cuenta.

La cascada del nombre se resuelve acá, en Python (pura y testeable):
fantasía del perfil fiscal -> razón social -> nombre del negocio del dueño ->
"Mi Negocio". Sin email: el perfil no lo guarda y el email de acceso del dueño
no debe aparecer en un documento para terceros.
"""
from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any, Protocol

DEFAULT_ISSUER_NAME = "Mi Negocio"


@dataclass(frozen=True)
class CommercialIssuer:
    """Lo que el encabezado imprime del emisor. Todo es opcional salvo el nombre."""

    name: str
    legal_name: str | None = None
    cuit: str | None = None
    address: str | None = None
    phone: str | None = None


class _IssuerSource(Protocol):
    async def get_commercial_issuer(self, account_id: str) -> Mapping[str, Any] | None: ...


def _clean(value: object) -> str | None:
    """Texto sin espacios sobrantes; vacío o ausente = no hay dato."""
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def issuer_from_rpc(raw: Mapping[str, Any] | None) -> CommercialIssuer:
    """Cascada del nombre y omisión de lo que falta, sobre lo que devolvió
    `rpc_commercial_issuer`. `None` (nunca debería) degrada al nombre por
    defecto en vez de impedir el documento."""
    data = raw or {}
    name = (
        _clean(data.get("nombre_fantasia"))
        or _clean(data.get("razon_social"))
        or _clean(data.get("business_name"))
        or DEFAULT_ISSUER_NAME
    )
    return CommercialIssuer(
        name=name,
        legal_name=_clean(data.get("razon_social")),
        cuit=_clean(data.get("cuit")),
        address=_clean(data.get("domicilio_comercial")),
        phone=_clean(data.get("phone")),
    )


async def resolve_commercial_issuer(repo: _IssuerSource, account_id: str) -> CommercialIssuer:
    """El emisor de la cuenta del documento, leído sólo de la RPC."""
    return issuer_from_rpc(await repo.get_commercial_issuer(account_id))
