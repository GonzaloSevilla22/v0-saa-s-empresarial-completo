"""
Repositorio de la marca de la cuenta (documentos-marca-empresa D1/D9): una fila
por cuenta en `public.account_branding`.

Arquitectura 3 capas: sólo acceso a datos, sin lógica de negocio.

  - TODA consulta filtra EXPLÍCITAMENTE por `account_id` además de la RLS (regla
    dura desde el incidente de fuga multi-tenant #446: la RLS es red, no guard
    único). La escritura además la sostiene la base: RLS `is_account_writer` +
    el disparador owner/admin (P0401); el service da el 403 legible antes.
  - Los BYTES del logo nunca salen de `get`: se piden aparte
    (`get_document_logo`, del mixin), sólo cuando hace falta dibujarlos o
    servirlos.
  - El PUT de datos (`upsert`) NO toca el logo, y viceversa (`set_logo`,
    `clear_logo` sólo tocan las columnas `logo_*`): dos escrituras seguidas no se
    pisan.
  - No hay DELETE: retirar el logo o volver a los valores por defecto es un
    UPDATE (el privilegio de DELETE está revocado para `authenticated`).
"""
from __future__ import annotations

from backend.repositories.base import BaseRepository
from backend.repositories.commercial_document_support import CommercialIssuerMixin
from backend.services.commercial_documents.logo import LogoImage

# Las diez columnas de datos, en el orden en que viajan los parámetros del upsert.
DATA_COLUMNS = (
    "display_name", "legal_name", "tax_id", "address", "phone", "email", "website", "footer_note",
    "palette_preset", "accent_color",
)

_READ_COLUMNS = (
    "account_id, display_name, legal_name, tax_id, address, phone, email, website, footer_note, "
    "palette_preset, accent_color, logo_mime, logo_sha256, logo_width, logo_height, logo_updated_at, "
    "updated_at, updated_by"
)


class DocumentBrandingRepository(CommercialIssuerMixin, BaseRepository):
    async def get(self, account_id: str) -> dict | None:
        """La fila de la cuenta SIN los bytes del logo (sólo su descriptor)."""
        row = await self.fetchrow(
            f"SELECT {_READ_COLUMNS} FROM public.account_branding WHERE account_id = $1::uuid",
            account_id,
        )
        return dict(row) if row else None

    async def upsert(self, account_id: str, data: dict, user_id: str) -> dict | None:
        """Reemplaza los datos y la paleta de la marca (inserta si la cuenta no tiene
        fila). No toca el logo."""
        placeholders = ", ".join(f"${i + 2}" for i in range(len(DATA_COLUMNS)))
        sets = ", ".join(f"{column} = EXCLUDED.{column}" for column in DATA_COLUMNS)
        row = await self.fetchrow(
            f"""
            INSERT INTO public.account_branding (account_id, {", ".join(DATA_COLUMNS)}, updated_at, updated_by)
            VALUES ($1::uuid, {placeholders}, now(), ${len(DATA_COLUMNS) + 2}::uuid)
            ON CONFLICT (account_id) DO UPDATE
               SET {sets},
                   updated_at = now(),
                   updated_by = EXCLUDED.updated_by
             WHERE public.account_branding.account_id = $1::uuid
            RETURNING {_READ_COLUMNS}
            """,
            account_id,
            *(data[column] for column in DATA_COLUMNS),
            user_id,
        )
        return dict(row) if row else None

    async def set_logo(self, account_id: str, logo: LogoImage, user_id: str) -> None:
        """Guarda el logo normalizado; si la cuenta no tiene fila la crea con los valores
        por defecto (Neutro, sin datos). No toca los datos ni la paleta."""
        await self.execute(
            """
            INSERT INTO public.account_branding
                   (account_id, logo_image, logo_mime, logo_sha256, logo_width, logo_height,
                    logo_updated_at, updated_at, updated_by)
            VALUES ($1::uuid, $2, $3, $4, $5, $6, now(), now(), $7::uuid)
            ON CONFLICT (account_id) DO UPDATE
               SET logo_image      = EXCLUDED.logo_image,
                   logo_mime       = EXCLUDED.logo_mime,
                   logo_sha256     = EXCLUDED.logo_sha256,
                   logo_width      = EXCLUDED.logo_width,
                   logo_height     = EXCLUDED.logo_height,
                   logo_updated_at = now(),
                   updated_at      = now(),
                   updated_by      = EXCLUDED.updated_by
             WHERE public.account_branding.account_id = $1::uuid
            """,
            account_id,
            logo.data,
            logo.mime,
            logo.sha256,
            logo.width,
            logo.height,
            user_id,
        )

    async def clear_logo(self, account_id: str, user_id: str) -> int:
        """Quita el logo. Devuelve cuántas filas cambiaron (0 si no había logo: idempotente)."""
        status = await self.execute(
            """
            UPDATE public.account_branding
               SET logo_image = NULL, logo_mime = NULL, logo_sha256 = NULL, logo_width = NULL,
                   logo_height = NULL, logo_updated_at = NULL, updated_at = now(), updated_by = $2::uuid
             WHERE account_id = $1::uuid AND logo_image IS NOT NULL
            """,
            account_id,
            user_id,
        )
        # asyncpg devuelve "UPDATE <n>".
        return int(status.rsplit(" ", 1)[-1])
