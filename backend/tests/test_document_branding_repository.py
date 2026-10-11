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
