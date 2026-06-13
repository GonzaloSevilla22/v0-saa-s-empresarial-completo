"""
C-27 v21-fiscal-profile — FiscalProfileRepository.

Acceso a datos de fiscal_profiles vía JWT-passthrough (NUNCA service_role).
La excepción de service_role para el cert está en WSFEAdapter._read_cert_from_storage.

Design ref: D9 (RLS por account_id), D1 (1:1 con accounts)
"""
from __future__ import annotations

import asyncpg

from backend.repositories.base import BaseRepository


class FiscalProfileRepository(BaseRepository):
    """Repository para operaciones de lectura/escritura de fiscal_profiles."""

    async def get_by_account_id(self, account_id: str) -> dict | None:
        """Lee el perfil fiscal de la cuenta. Retorna None si no existe."""
        row = await self.fetchrow(
            "SELECT * FROM public.fiscal_profiles WHERE account_id = $1",
            account_id,
        )
        return dict(row) if row else None

    async def upsert(self, account_id: str, data: dict) -> dict | None:
        """Crea o actualiza el perfil fiscal de la cuenta.

        Usa INSERT … ON CONFLICT (account_id) DO UPDATE (seguro: no hay CHECK
        que pueda disparar el gotcha — la constraint es UNIQUE, no CHECK de valor).
        Retorna el perfil actualizado.
        """
        row = await self.fetchrow(
            """
            INSERT INTO public.fiscal_profiles
              (account_id, cuit, iva_condition, iibb_condition, ambiente, certificado_afip_path)
            VALUES ($1, $2, $3, $4, $5, $6)
            ON CONFLICT (account_id) DO UPDATE
              SET cuit                  = EXCLUDED.cuit,
                  iva_condition         = EXCLUDED.iva_condition,
                  iibb_condition        = EXCLUDED.iibb_condition,
                  ambiente              = EXCLUDED.ambiente,
                  certificado_afip_path = COALESCE(EXCLUDED.certificado_afip_path, fiscal_profiles.certificado_afip_path)
            RETURNING *
            """,
            account_id,
            data.get("cuit"),
            data.get("iva_condition"),
            data.get("iibb_condition"),
            data.get("ambiente", "homologacion"),
            data.get("certificado_afip_path"),
        )
        return dict(row) if row else None
