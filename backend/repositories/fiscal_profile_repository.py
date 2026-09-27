"""
C-27 v21-fiscal-profile — FiscalProfileRepository.

Acceso a datos de fiscal_profiles vía JWT-passthrough (NUNCA service_role).
La excepción de service_role para el cert está en WSFEAdapter._read_cert_from_storage.

Design ref: D9 (RLS por account_id), D1 (1:1 con accounts)
"""
from __future__ import annotations

import asyncpg

from backend.repositories.base import BaseRepository


# factura-fiscal-imprimible (D7): columnas con semántica PATCH tri-estado en el
# upsert. Presente en `data` (aunque sea None) = escribir ese valor; ausente =
# conservar el guardado. Antes `iibb_condition` se pisaba con NULL cada vez que
# el payload no lo traía.
PROFILE_TRI_STATE_FIELDS: tuple[str, ...] = (
    "iibb_condition",
    "razon_social",
    "nombre_fantasia",
    "domicilio_comercial",
    "iibb_numero",
    "inicio_actividades",
)


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

        factura-fiscal-imprimible (D7): las columnas de PROFILE_TRI_STATE_FIELDS
        se actualizan SÓLO si vienen en `data` (aunque sea con None, que borra);
        `$13` lleva la lista de las presentes.
        """
        present = [field for field in PROFILE_TRI_STATE_FIELDS if field in data]
        row = await self.fetchrow(
            """
            INSERT INTO public.fiscal_profiles
              (account_id, cuit, iva_condition, iibb_condition, ambiente, certificado_afip_path,
               delegacion_autorizada, razon_social, nombre_fantasia, domicilio_comercial,
               iibb_numero, inicio_actividades)
            VALUES ($1, $2, $3, $4, $5, $6, COALESCE($7::boolean, false), $8, $9, $10, $11, $12::date)
            ON CONFLICT (account_id) DO UPDATE
              SET cuit                  = EXCLUDED.cuit,
                  iva_condition         = EXCLUDED.iva_condition,
                  iibb_condition = CASE WHEN 'iibb_condition' = ANY($13::text[]) THEN EXCLUDED.iibb_condition ELSE fiscal_profiles.iibb_condition END,
                  ambiente              = EXCLUDED.ambiente,
                  certificado_afip_path = COALESCE(EXCLUDED.certificado_afip_path, fiscal_profiles.certificado_afip_path),
                  -- v22: la atestación sólo viaja cuando el payload la trae (semántica PATCH);
                  -- NULL conserva el valor vivo en vez de resetearlo a false.
                  delegacion_autorizada = COALESCE($7::boolean, fiscal_profiles.delegacion_autorizada),
                  -- factura-fiscal-imprimible (D7): tri-estado (ausente = conservar).
                  razon_social = CASE WHEN 'razon_social' = ANY($13::text[]) THEN EXCLUDED.razon_social ELSE fiscal_profiles.razon_social END,
                  nombre_fantasia = CASE WHEN 'nombre_fantasia' = ANY($13::text[]) THEN EXCLUDED.nombre_fantasia ELSE fiscal_profiles.nombre_fantasia END,
                  domicilio_comercial = CASE WHEN 'domicilio_comercial' = ANY($13::text[]) THEN EXCLUDED.domicilio_comercial ELSE fiscal_profiles.domicilio_comercial END,
                  iibb_numero = CASE WHEN 'iibb_numero' = ANY($13::text[]) THEN EXCLUDED.iibb_numero ELSE fiscal_profiles.iibb_numero END,
                  inicio_actividades = CASE WHEN 'inicio_actividades' = ANY($13::text[]) THEN EXCLUDED.inicio_actividades ELSE fiscal_profiles.inicio_actividades END
            RETURNING *
            """,
            account_id,
            data.get("cuit"),
            data.get("iva_condition"),
            data.get("iibb_condition"),
            data.get("ambiente", "homologacion"),
            data.get("certificado_afip_path"),
            data.get("delegacion_autorizada"),
            data.get("razon_social"),
            data.get("nombre_fantasia"),
            data.get("domicilio_comercial"),
            data.get("iibb_numero"),
            data.get("inicio_actividades"),
            present,
        )
        return dict(row) if row else None
