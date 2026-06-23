"""
v21-wsfe-production-hardening — Postgres TicketCache implementation (D5).

Implementacion concreta de TicketCache usando la tabla `wsaa_access_tickets`
en Postgres (Supabase). El service_role del cert path tambien tiene acceso
a esta tabla (mismo aislamiento que el cert-read, DEC-13).

La tabla se crea en la migracion:
  supabase/migrations/20260724000001_c31_wsaa_access_tickets.sql

Design ref: D5 (PO decision: Postgres, 2026-06-23)
"""
from __future__ import annotations

import datetime
import logging

from backend.services.fiscal.ticket_cache_port import TicketCache

logger = logging.getLogger(__name__)

# Margen de refresco: si el TA expira en menos de REFRESH_MARGIN, se considera
# "a punto de expirar" y se fuerza un nuevo loginCms.
_REFRESH_MARGIN = datetime.timedelta(minutes=30)


class PostgresTicketCache(TicketCache):
    """Cache del TA de WSAA persistida en la tabla `wsaa_access_tickets` de Postgres.

    Usa el cliente Supabase service_role (mismo que lee el cert, DEC-13).
    Las operaciones son sincrona/blocking (la supabase-py SDK es sync);
    el impacto es minimo (~1 query por invocacion del relay).

    Schema de la tabla (ver migracion):
        wsaa_access_tickets(
            account_id uuid,
            cuit text,
            ambiente text,
            token text,
            sign text,
            expires_at timestamptz,
            updated_at timestamptz,
            PRIMARY KEY (account_id, cuit, ambiente)
        )

    Cache key format: "{account_id}:{cuit}:wsfe:{ambiente}"
    (La implementacion descompone la key para buscar por columnas individuales.)
    """

    def __init__(self, supabase_service_client, account_id: str):
        """
        Args:
            supabase_service_client: cliente Supabase con service_role.
            account_id: UUID de la cuenta (para la clave de RLS).
        """
        self._client = supabase_service_client
        self._account_id = account_id

    def _parse_key(self, key: str) -> tuple[str, str, str]:
        """Parsear cache key '{cuit}:wsfe:{ambiente}' en (cuit, service, ambiente)."""
        parts = key.split(":")
        if len(parts) != 3:
            raise ValueError(f"Cache key invalida: {key!r}. Formato esperado: '{{cuit}}:wsfe:{{ambiente}}'")
        return parts[0], parts[1], parts[2]  # cuit, service, ambiente

    def get(self, key: str) -> tuple[str, str, datetime.datetime] | None:
        """Buscar TA vigente en Postgres.

        Retorna (token, sign, expires_at) si existe y no esta en el margen de refresco.
        """
        try:
            cuit, _service, ambiente = self._parse_key(key)
            now = datetime.datetime.now(datetime.timezone.utc)
            cutoff = now + _REFRESH_MARGIN

            response = (
                self._client
                .schema("public")
                .table("wsaa_access_tickets")
                .select("token, sign, expires_at")
                .eq("account_id", self._account_id)
                .eq("cuit", cuit)
                .eq("ambiente", ambiente)
                .single()
                .execute()
            )

            if not response.data:
                return None

            row = response.data
            expires_at_raw = row["expires_at"]

            # Parsear timestamp de Postgres
            if isinstance(expires_at_raw, str):
                # Remove microseconds suffix if needed; Postgres returns ISO 8601
                expires_at = datetime.datetime.fromisoformat(expires_at_raw.replace("Z", "+00:00"))
            elif isinstance(expires_at_raw, datetime.datetime):
                expires_at = expires_at_raw
            else:
                return None

            if expires_at.tzinfo is None:
                expires_at = expires_at.replace(tzinfo=datetime.timezone.utc)

            # Check if still valid (outside refresh margin)
            if expires_at <= cutoff:
                logger.debug("WSAATicketCache: TA a punto de expirar o expirado (cuit=%s, expira=%s)", cuit, expires_at)
                return None

            return row["token"], row["sign"], expires_at

        except Exception as exc:
            # Cache miss graceful: si hay error de DB, fallback a re-authenticate
            logger.warning("WSAATicketCache.get error (key=%s): %s", key, exc)
            return None

    def set(self, key: str, token: str, sign: str, expires_at: datetime.datetime) -> None:
        """Persistir TA en Postgres via upsert."""
        try:
            cuit, _service, ambiente = self._parse_key(key)

            if expires_at.tzinfo is None:
                expires_at = expires_at.replace(tzinfo=datetime.timezone.utc)

            (
                self._client
                .schema("public")
                .table("wsaa_access_tickets")
                .upsert(
                    {
                        "account_id": self._account_id,
                        "cuit": cuit,
                        "ambiente": ambiente,
                        "token": token,
                        "sign": sign,
                        "expires_at": expires_at.isoformat(),
                        "updated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    },
                    on_conflict="account_id,cuit,ambiente",
                )
                .execute()
            )
        except Exception as exc:
            # Cache set failure is non-fatal: next call will do a fresh loginCms
            logger.warning("WSAATicketCache.set error (key=%s): %s", key, exc)
