"""
documentos-marca-empresa — acceso a datos de la marca (tasks 5.4 y 8.2).

Dos piezas: `CommercialIssuerMixin.get_document_logo` (lo comparten los
repositorios de presupuesto y remito) y `DocumentBrandingRepository`
(`GET/PUT /document-branding`). Regla dura desde el incidente de fuga
multi-tenant #446: TODA consulta filtra EXPLÍCITAMENTE por `account_id` además
de la RLS.

Run: python -m pytest backend/tests/test_document_branding_repository.py -q -p no:cacheprovider
"""
from __future__ import annotations

from unittest.mock import AsyncMock

import pytest

ACCOUNT = "11111111-1111-1111-1111-111111111111"
USER = "33333333-3333-3333-3333-333333333333"


class _Repo:
    """Un repositorio mínimo que usa el mixin, con una conexión falsa."""

    def __init__(self, conn):
        self._conn = conn


def _mixin_repo(conn):
    from backend.repositories.commercial_document_support import CommercialIssuerMixin

    class Repo(CommercialIssuerMixin, _Repo):
        pass

    return Repo(conn)


# ── get_document_logo (mixin) ────────────────────────────────────────────────

async def test_get_document_logo_filters_explicitly_by_account_and_only_asks_for_the_logo_columns():
    conn = AsyncMock()
    conn.fetchrow.return_value = {"logo_image": b"\x89PNG", "logo_mime": "image/png", "logo_sha256": "a" * 64}

    row = await _mixin_repo(conn).get_document_logo(ACCOUNT)

    sql, *params = conn.fetchrow.await_args.args
    assert "public.account_branding" in sql
    assert "account_id = $1" in sql
    assert "logo_image IS NOT NULL" in sql
    assert params == [ACCOUNT]
    assert "logo_image" in sql and "logo_mime" in sql and "logo_sha256" in sql
    # nada más que lo necesario para dibujar (ni emails, ni datos de otras columnas)
    for column in ("email", "phone", "website", "footer_note"):
        assert column not in sql
    assert row == {"logo_image": b"\x89PNG", "logo_mime": "image/png", "logo_sha256": "a" * 64}


async def test_get_document_logo_returns_none_when_the_account_has_no_logo():
    conn = AsyncMock()
    conn.fetchrow.return_value = None
    assert await _mixin_repo(conn).get_document_logo(ACCOUNT) is None


# ── DocumentBrandingRepository ───────────────────────────────────────────────

DATA = {
    "display_name": "Sumar", "legal_name": None, "tax_id": "20-12345678-6", "address": None, "phone": "2615550999",
    "email": "ventas@sumar.com.ar", "website": None, "footer_note": "Alias: sumar.ropa",
    "palette_preset": "personalizado", "accent_color": "#7c2d12",
}


def _repo(conn):
    from backend.repositories.document_branding_repository import DocumentBrandingRepository

    return DocumentBrandingRepository(conn)


class TestDocumentBrandingRepository:
    async def test_get_filters_by_account_and_never_selects_the_image_bytes(self):
        conn = AsyncMock()
        conn.fetchrow.return_value = None

        assert await _repo(conn).get(ACCOUNT) is None

        sql, *params = conn.fetchrow.await_args.args
        assert "FROM public.account_branding" in sql and "account_id = $1" in sql
        assert params == [ACCOUNT]
        assert "logo_image" not in sql                      # los bytes se piden aparte y sólo con huella
        for column in ("logo_mime", "logo_sha256", "logo_width", "logo_height", "updated_at", "updated_by"):
            assert column in sql

    async def test_get_returns_a_plain_dict(self):
        conn = AsyncMock()
        conn.fetchrow.return_value = {"account_id": ACCOUNT, "display_name": "Sumar"}
        row = await _repo(conn).get(ACCOUNT)
        assert isinstance(row, dict) and row["display_name"] == "Sumar"

    async def test_upsert_is_one_statement_filtered_by_account_and_leaves_the_logo_alone(self):
        conn = AsyncMock()
        conn.fetchrow.return_value = {"account_id": ACCOUNT, **DATA}

        row = await _repo(conn).upsert(ACCOUNT, DATA, USER)

        sql, *params = conn.fetchrow.await_args.args
        assert "INSERT INTO public.account_branding" in sql
        assert "ON CONFLICT (account_id) DO UPDATE" in sql
        assert "WHERE public.account_branding.account_id = $1" in sql
        assert "logo_" not in sql.split("RETURNING")[0]     # ni en el INSERT ni en el SET: el PUT de datos no toca el logo
        assert params[0] == ACCOUNT and params[-1] == USER
        assert list(DATA.values()) == params[1:-1]          # los 10 campos de datos, en orden
        assert row["display_name"] == "Sumar"

    async def test_set_logo_creates_the_row_if_missing_and_filters_by_account(self):
        from backend.services.commercial_documents.logo import LogoImage

        conn = AsyncMock()
        logo = LogoImage(data=b"\x89PNG\r\n\x1a\n00", mime="image/png", width=1000, height=250, sha256="a" * 64)

        await _repo(conn).set_logo(ACCOUNT, logo, USER)

        sql, *params = conn.execute.await_args.args
        assert "INSERT INTO public.account_branding" in sql and "ON CONFLICT (account_id) DO UPDATE" in sql
        assert "WHERE public.account_branding.account_id = $1" in sql
        assert params[0] == ACCOUNT
        assert logo.data in params and "image/png" in params and "a" * 64 in params and 1000 in params and 250 in params
        assert params[-1] == USER
        for untouched in ("display_name", "palette_preset", "email"):
            assert untouched not in sql.split("ON CONFLICT")[1]     # el SET del conflicto sólo toca el logo

    async def test_clear_logo_updates_only_that_account_and_reports_whether_anything_changed(self):
        conn = AsyncMock()
        conn.execute.return_value = "UPDATE 1"
        assert await _repo(conn).clear_logo(ACCOUNT, USER) == 1

        sql, *params = conn.execute.await_args.args
        assert sql.lstrip().startswith("UPDATE public.account_branding")
        assert "account_id = $1" in sql and "logo_image IS NOT NULL" in sql
        assert params == [ACCOUNT, USER]
        for column in ("logo_image = NULL", "logo_mime = NULL", "logo_sha256 = NULL", "logo_width = NULL",
                       "logo_height = NULL", "logo_updated_at = NULL"):
            assert column in sql

        conn.execute.return_value = "UPDATE 0"
        assert await _repo(conn).clear_logo(ACCOUNT, USER) == 0

    async def test_nothing_in_the_repository_deletes_a_row(self):
        from pathlib import Path

        import backend.repositories.document_branding_repository as module

        source = Path(module.__file__).read_text(encoding="utf-8").upper()
        assert "DELETE FROM" not in source and "TRUNCATE" not in source
