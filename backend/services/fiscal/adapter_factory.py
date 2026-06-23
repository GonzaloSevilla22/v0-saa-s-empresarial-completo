"""
C-31 v21-wsfe-homologacion-wiring — Factory del adapter CAE (real vs stub).

build_cae_adapter(has_cert, service_client) → FiscalDocumentPort

  has_cert=True  + service_client → WSFEAdapter real (WSAA + WSFEv1)
  has_cert=False o sin service_client → WSFEStubAdapter (default seguro)

El `ambiente` (homologacion/produccion) viaja en CAERequest.ambiente y lo resuelve
el adapter internamente — NO es parámetro de la factory (W4).

Default = stub: cuentas sin cert no cambian de comportamiento (no rompe prod).

Design ref: W4 (design.md)
"""
from __future__ import annotations

from backend.services.fiscal.fiscal_document_port import FiscalDocumentPort
from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter


def build_cae_adapter(*, has_cert: bool, service_client=None) -> FiscalDocumentPort:
    """Fábrica del adapter CAE.

    Args:
        has_cert: True si la cuenta tiene certificado_afip_path presente en fiscal_profiles.
        service_client: cliente Supabase con service_role para leer el cert desde Storage.
            Si es None, se usa el stub aunque has_cert sea True (fallback seguro).

    Returns:
        WSFEAdapter real si hay cert + service_client;
        WSFEStubAdapter en cualquier otro caso.
    """
    if has_cert and service_client is not None:
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter
        return WSFEAdapter(supabase_service_client=service_client)
    return WSFEStubAdapter()
