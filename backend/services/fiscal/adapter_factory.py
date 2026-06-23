"""
C-31 v21-wsfe-homologacion-wiring — Factory del adapter CAE (real vs stub).
v21-wsfe-production-hardening — agrega ticket_cache para la cache del TA (D5).

build_cae_adapter(has_cert, service_client, ticket_cache, account_id) -> FiscalDocumentPort

  has_cert=True  + service_client -> WSFEAdapter real (WSAA + WSFEv1)
  has_cert=False o sin service_client -> WSFEStubAdapter (default seguro)

El `ambiente` (homologacion/produccion) viaja en CAERequest.ambiente y lo resuelve
el adapter internamente (W4).

Default = stub: cuentas sin cert no cambian de comportamiento (no rompe prod).

Design ref: W4 (C-31), D5 (v21-wsfe-production-hardening)
"""
from __future__ import annotations

from backend.services.fiscal.fiscal_document_port import FiscalDocumentPort
from backend.services.fiscal.ticket_cache_port import TicketCache
from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter


def build_cae_adapter(
    *,
    has_cert: bool,
    service_client=None,
    ticket_cache: TicketCache | None = None,
    account_id: str | None = None,
) -> FiscalDocumentPort:
    """Fabrica del adapter CAE.

    Args:
        has_cert: True si la cuenta tiene certificado_afip_path presente en fiscal_profiles.
        service_client: cliente Supabase con service_role para leer el cert desde Storage
            y para la cache del TA (D5/D7). Si es None, se usa el stub.
        ticket_cache: puerto de cache del TA (D5). Si es None se crea PostgresTicketCache
            usando service_client si esta disponible; None deshabilita la cache (seguro
            pero llama a loginCms en cada invocacion).
        account_id: UUID de la cuenta — necesario para PostgresTicketCache (filtra por RLS).

    Returns:
        WSFEAdapter real si hay cert + service_client;
        WSFEStubAdapter en cualquier otro caso.
    """
    if has_cert and service_client is not None:
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        # Crear PostgresTicketCache si no se inyecto uno (y tenemos service_client)
        resolved_cache = ticket_cache
        if resolved_cache is None and account_id is not None:
            try:
                from backend.services.fiscal.wsaa_ticket_cache import PostgresTicketCache
                resolved_cache = PostgresTicketCache(
                    supabase_service_client=service_client,
                    account_id=account_id,
                )
            except Exception:
                # No fatal: sin cache el adapter funciona (solo llama loginCms cada vez)
                resolved_cache = None

        return WSFEAdapter(
            supabase_service_client=service_client,
            ticket_cache=resolved_cache,
        )
    return WSFEStubAdapter()
