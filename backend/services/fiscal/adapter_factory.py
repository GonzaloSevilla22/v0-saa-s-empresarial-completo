"""
C-31 v21-wsfe-homologacion-wiring — Factory del adapter CAE (real vs stub).
v21-wsfe-production-hardening — agrega ticket_cache para la cache del TA (D5).
v22-afip-delegation-billing — gate "platform cert configured?" reemplaza has_cert per-account.

build_cae_adapter(platform_provider, ticket_cache) -> FiscalDocumentPort

  platform_provider configurado  -> WSFEAdapter real (WSAA + WSFEv1)
  platform_provider no config / None -> WSFEStubAdapter (default seguro)

El `ambiente` (homologacion/produccion) viaja en CAERequest.ambiente y lo resuelve
el adapter internamente (D2).

Backward-compat: los parámetros has_cert/service_client/account_id se aceptan pero
son ignorados para el gate principal. El gate ahora es el platform_provider (D4 v22).

Default = stub: si el cert de plataforma no está configurado, el comportamiento
de TODAS las cuentas sigue siendo el mismo (no rompe prod). Esta es la invariante
más importante: sin cert de plataforma, ninguna cuenta intenta llamadas reales a AFIP.

Design ref: D4 (v22 gate), W4 (C-31), D5 (v21-wsfe-production-hardening)
"""
from __future__ import annotations
from typing import TYPE_CHECKING

from backend.services.fiscal.fiscal_document_port import FiscalDocumentPort
from backend.services.fiscal.ticket_cache_port import TicketCache
from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter

if TYPE_CHECKING:
    from backend.services.fiscal.platform_credential_provider import PlatformCredentialProvider


def build_cae_adapter(
    *,
    # v22: nuevo gate (reemplaza has_cert per-account como criterio de real-vs-stub)
    platform_provider: "PlatformCredentialProvider | None" = None,
    ticket_cache: TicketCache | None = None,
    # Backward-compat (C-27/C-31): aceptados pero ignorados para el gate de delegación.
    # Se mantienen para no romper el código de los relay points legacy.
    has_cert: bool = False,
    service_client=None,
    account_id: str | None = None,
) -> FiscalDocumentPort:
    """Fabrica del adapter CAE — v22 gate: "platform cert configured?".

    Args:
        platform_provider: PlatformCredentialProvider del representante de la plataforma.
            Si es None o no configurado (is_configured() == False) → stub.
            Si configurado → WSFEAdapter real con cert de plataforma.
        ticket_cache: puerto de cache del TA (D5). Si es None, el adapter llama
            loginCms en cada invocación (no rompe, pero genera cooldown de WSAA).
            Inyectar PlatformPostgresTicketCache en prod.
        has_cert: (backward-compat, ignorado) era True si la cuenta tenía cert per-account.
        service_client: (backward-compat, ignorado para el gate de delegación).
        account_id: (backward-compat, ignorado).

    Returns:
        WSFEAdapter real si platform_provider está configurado;
        WSFEStubAdapter en cualquier otro caso (default seguro).
    """
    # v22: el gate es "¿hay cert de plataforma configurado?", no "¿la cuenta tiene cert?"
    if platform_provider is not None and platform_provider.is_configured():
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        return WSFEAdapter(
            platform_provider=platform_provider,
            ticket_cache=ticket_cache,
        )

    return WSFEStubAdapter()


def build_cae_adapter_from_settings(
    ticket_cache: TicketCache | None = None,
) -> FiscalDocumentPort:
    """Conveniencia para los relay points: construye el adapter desde la config global.

    Los relay points llaman esto en vez de construir el provider manualmente.
    El provider se crea a partir de `settings` (env vars del proceso actual).

    Returns:
        WSFEAdapter real si AFIP_PLATFORM_CERT/KEY/CUIT están configurados;
        WSFEStubAdapter si no (default seguro).
    """
    try:
        from backend.core.config import settings
        from backend.services.fiscal.platform_credential_provider import PlatformCredentialProvider
        provider = PlatformCredentialProvider(settings=settings)
    except Exception:
        provider = None  # type: ignore[assignment]

    return build_cae_adapter(
        platform_provider=provider,
        ticket_cache=ticket_cache,
    )
