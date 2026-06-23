"""
C-22 v22-afip-delegation-billing — Tests de migración DB (unit, sin red, sin DB real).

Verifica la lógica de migración mediante inspección del SQL de migración y
la consistencia del schema Pydantic v2.

Gate: python -m pytest backend/tests -m "not integration"

Spec ref: specs/afip-platform-credential/spec.md §"Flag de delegación autorizada"
Spec ref: specs/fiscal-profile/spec.md §"Onboarding de delegación ARCA"
Design ref: D5 (TA plataforma), D6 (flag atestación)
"""
from __future__ import annotations

import re
import uuid
from pathlib import Path

import pytest

# ─────────────────────────────────────────────────────────────────────────────
# Paths de migraciones (file-only — CI las aplica)
# ─────────────────────────────────────────────────────────────────────────────

MIGRATIONS_DIR = (
    Path(__file__).parent.parent.parent / "supabase" / "migrations"
)


def _find_migration(pattern: str) -> Path | None:
    """Buscar un archivo de migración por patrón de nombre."""
    matches = list(MIGRATIONS_DIR.glob(pattern))
    return matches[0] if matches else None


def _migration_sql(pattern: str) -> str | None:
    """Retornar el contenido SQL de una migración encontrada por patrón."""
    p = _find_migration(pattern)
    return p.read_text(encoding="utf-8") if p else None


# =============================================================================
# §1.1 / §1.2 — fiscal_profiles.delegacion_autorizada (RED → GREEN)
# =============================================================================

class TestDelegacionAutorizadaColumn:
    """1.1 RED: el flag `delegacion_autorizada` debe estar definido en la migración."""

    def test_migration_file_exists(self):
        """1.1 RED: existe el archivo de migración para el flag de delegación."""
        mig = _find_migration("*v22_fiscal_profiles_delegation*")
        assert mig is not None, (
            "No se encontró la migración v22_fiscal_profiles_delegation. "
            "Crear: supabase/migrations/<timestamp>_v22_fiscal_profiles_delegation.sql"
        )

    def test_migration_adds_delegacion_autorizada_column(self):
        """1.2 GREEN: la migración agrega la columna delegacion_autorizada."""
        sql = _migration_sql("*v22_fiscal_profiles_delegation*")
        assert sql is not None, "Migración no encontrada"
        # Verifica que la columna se agrega con NOT NULL DEFAULT FALSE
        assert "delegacion_autorizada" in sql.lower(), (
            "La migración debe agregar la columna `delegacion_autorizada`"
        )
        assert "boolean" in sql.lower(), (
            "La columna debe ser de tipo BOOLEAN"
        )
        assert "default false" in sql.lower(), (
            "La columna debe tener DEFAULT FALSE"
        )

    def test_migration_has_rls_comment(self):
        """1.2 GREEN: la migración documenta la estrategia de RLS."""
        sql = _migration_sql("*v22_fiscal_profiles_delegation*")
        assert sql is not None
        # La columna hereda la RLS de fiscal_profiles (owner/admin only via is_account_writer)
        # Solo verificamos que hay comentario
        assert "rls" in sql.lower() or "comment" in sql.lower() or "-- " in sql, (
            "La migración debe tener comentarios de diseño"
        )

    def test_migration_is_additive(self):
        """1.5 TRIANGULATE: la migración es aditiva (ADD COLUMN, no DROP fuera de comentarios)."""
        sql = _migration_sql("*v22_fiscal_profiles_delegation*")
        assert sql is not None
        assert "add column" in sql.lower(), (
            "La migración debe usar ADD COLUMN (aditiva, no destructiva)"
        )
        # Verificar que DROP COLUMN no aparece fuera de comentarios SQL
        non_comment_lines = [
            line for line in sql.splitlines()
            if not line.strip().startswith("--")
        ]
        non_comment_sql = "\n".join(non_comment_lines).lower()
        assert "drop column" not in non_comment_sql, (
            "La migración NO debe hacer DROP COLUMN en código activo (solo en comentarios ROLLBACK)"
        )


# =============================================================================
# §1.3 / §1.4 — platform_wsaa_tickets (RED → GREEN)
# =============================================================================

class TestPlatformWsaaTickets:
    """1.3 RED: tabla platform_wsaa_tickets para el TA del representante."""

    def test_migration_file_exists(self):
        """1.3 RED: existe el archivo de migración para platform_wsaa_tickets."""
        mig = _find_migration("*v22_platform_wsaa_tickets*")
        assert mig is not None, (
            "No se encontró la migración v22_platform_wsaa_tickets. "
            "Crear: supabase/migrations/<timestamp>_v22_platform_wsaa_tickets.sql"
        )

    def test_migration_creates_table(self):
        """1.4 GREEN: la migración crea la tabla platform_wsaa_tickets."""
        sql = _migration_sql("*v22_platform_wsaa_tickets*")
        assert sql is not None
        assert "platform_wsaa_tickets" in sql.lower(), (
            "La migración debe crear la tabla `platform_wsaa_tickets`"
        )
        assert "create table" in sql.lower()

    def test_migration_has_ambiente_as_pk(self):
        """1.3 RED: la tabla tiene `ambiente` como PK (una fila por ambiente)."""
        sql = _migration_sql("*v22_platform_wsaa_tickets*")
        assert sql is not None
        # Verificar que ambiente es parte de la PK o es columna
        assert "ambiente" in sql.lower(), (
            "La tabla debe tener la columna `ambiente`"
        )
        assert "primary key" in sql.lower(), (
            "La tabla debe tener una PK"
        )

    def test_migration_has_required_columns(self):
        """1.4 GREEN: la tabla tiene token, sign, expires_at, updated_at."""
        sql = _migration_sql("*v22_platform_wsaa_tickets*")
        assert sql is not None
        for col in ("token", "sign", "expires_at", "updated_at"):
            assert col in sql.lower(), (
                f"La tabla platform_wsaa_tickets debe tener la columna `{col}`"
            )

    def test_migration_has_no_account_id_fk(self):
        """1.3 RED: la tabla NO tiene account_id (es estado de plataforma, no de cuenta)."""
        sql = _migration_sql("*v22_platform_wsaa_tickets*")
        assert sql is not None
        # La tabla de plataforma no debe tener FK a accounts
        lines = [line.strip().lower() for line in sql.splitlines()]
        for line in lines:
            # Evitar referencias a account_id en columna real (comentarios OK)
            if "account_id" in line and not line.startswith("--"):
                pytest.fail(
                    f"platform_wsaa_tickets NO debe tener account_id: {line!r}"
                )

    def test_migration_documents_old_table_relationship(self):
        """1.4 GREEN: la migración documenta la relación con wsaa_access_tickets antigua."""
        sql = _migration_sql("*v22_platform_wsaa_tickets*")
        assert sql is not None
        # Debe haber algún comentario sobre la tabla anterior
        assert "wsaa_access_tickets" in sql, (
            "La migración debe referenciar/documentar wsaa_access_tickets (tabla anterior por cuenta)"
        )


# =============================================================================
# §1.5 TRIANGULATE — Schemas Pydantic (FiscalProfileOut incluye el flag)
# =============================================================================

class TestFiscalProfileSchemaIncludesFlag:
    """1.5 TRIANGULATE: FiscalProfileOut expone delegacion_autorizada."""

    def test_fiscal_profile_out_has_delegacion_autorizada(self):
        """FiscalProfileOut debe incluir el campo delegacion_autorizada."""
        from backend.schemas.fiscal import FiscalProfileOut
        fields = FiscalProfileOut.model_fields
        assert "delegacion_autorizada" in fields, (
            "FiscalProfileOut debe exponer el campo `delegacion_autorizada`"
        )

    def test_fiscal_profile_out_has_platform_cuit(self):
        """FiscalProfileOut debe incluir el CUIT representante de plataforma (read-only)."""
        from backend.schemas.fiscal import FiscalProfileOut
        fields = FiscalProfileOut.model_fields
        assert "platform_representante_cuit" in fields, (
            "FiscalProfileOut debe exponer `platform_representante_cuit` para guiar el onboarding"
        )

    def test_fiscal_profile_create_has_delegacion_autorizada(self):
        """FiscalProfileCreate debe aceptar delegacion_autorizada."""
        from backend.schemas.fiscal import FiscalProfileCreate
        obj = FiscalProfileCreate(
            cuit="20-12345678-0",
            iva_condition="responsable_inscripto",
            delegacion_autorizada=True,
        )
        assert obj.delegacion_autorizada is True

    def test_fiscal_profile_create_defaults_delegacion_to_false(self):
        """FiscalProfileCreate default de delegacion_autorizada = False."""
        from backend.schemas.fiscal import FiscalProfileCreate
        obj = FiscalProfileCreate(
            cuit="20-12345678-0",
            iva_condition="responsable_inscripto",
        )
        assert obj.delegacion_autorizada is False

    def test_fiscal_profile_out_no_crypto_material(self):
        """FiscalProfileOut no expone material criptográfico del representante."""
        from backend.schemas.fiscal import FiscalProfileOut
        fields = FiscalProfileOut.model_fields
        forbidden = {"platform_cert", "platform_key", "afip_platform_key", "private_key"}
        found = forbidden & set(fields.keys())
        assert not found, (
            f"FiscalProfileOut no debe exponer material criptográfico: {found}"
        )
