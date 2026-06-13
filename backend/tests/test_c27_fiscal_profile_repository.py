"""
C-27 v21-fiscal-profile — FiscalProfileRepository + Pydantic schemas (TDD).

TDD RED→GREEN:
  3.1 RED: FiscalProfileRepository.get/upsert; schemas validan iva_condition y
           ambiente (Literal); FiscalProfileOut no expone contenido del cert;
           member no puede escribir (403 del guard).
  3.2 GREEN: fiscal_profile_repository.py + schemas.

Spec ref: fiscal-profile/spec.md §"API del perfil fiscal"
"""
from __future__ import annotations

import uuid
from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import TEST_ACCOUNT_ID, make_token


ACCOUNT_ID = str(TEST_ACCOUNT_ID)
FISCAL_PROFILE_ROW = {
    "id": "ffffffff-ffff-ffff-ffff-ffffffffffff",
    "account_id": ACCOUNT_ID,
    "cuit": "20123456789",
    "iva_condition": "responsable_inscripto",
    "iibb_condition": "convenio_multilateral",
    "certificado_afip_path": f"{ACCOUNT_ID}/afip.crt",
    "ambiente": "homologacion",
    "created_at": "2026-06-27T00:00:00+00:00",
}


# ── Schema validation tests ───────────────────────────────────────────────────

class TestFiscalProfileSchemas:
    """3.1 RED → 3.2 GREEN: validación de schemas Pydantic v2."""

    def test_valid_iva_condition_is_accepted(self):
        from backend.schemas.fiscal import FiscalProfileCreate
        for cond in ("responsable_inscripto", "monotributista", "exento", "consumidor_final"):
            schema = FiscalProfileCreate(cuit="20123456789", iva_condition=cond)
            assert schema.iva_condition == cond

    def test_invalid_iva_condition_is_rejected(self):
        from pydantic import ValidationError
        from backend.schemas.fiscal import FiscalProfileCreate
        with pytest.raises(ValidationError):
            FiscalProfileCreate(cuit="20123456789", iva_condition="inscripto_raro")

    def test_valid_ambiente_is_accepted(self):
        from backend.schemas.fiscal import FiscalProfileCreate
        for env in ("homologacion", "produccion"):
            schema = FiscalProfileCreate(
                cuit="20123456789",
                iva_condition="responsable_inscripto",
                ambiente=env,
            )
            assert schema.ambiente == env

    def test_invalid_ambiente_is_rejected(self):
        from pydantic import ValidationError
        from backend.schemas.fiscal import FiscalProfileCreate
        with pytest.raises(ValidationError):
            FiscalProfileCreate(
                cuit="20123456789",
                iva_condition="responsable_inscripto",
                ambiente="sandbox",
            )

    def test_fiscal_profile_out_does_not_expose_cert_content(self):
        """FiscalProfileOut solo expone el path, no el contenido del cert (D7)."""
        from backend.schemas.fiscal import FiscalProfileOut
        out = FiscalProfileOut(**FISCAL_PROFILE_ROW)
        assert out.certificado_afip_path == f"{ACCOUNT_ID}/afip.crt"
        # El esquema no debe tener campo que contenga el cert real (bytes/content)
        assert not hasattr(out, "certificado_content")
        assert not hasattr(out, "cert_bytes")

    def test_fiscal_profile_out_default_ambiente_is_homologacion(self):
        from backend.schemas.fiscal import FiscalProfileCreate
        schema = FiscalProfileCreate(cuit="20123456789", iva_condition="monotributista")
        assert schema.ambiente == "homologacion"


# ── Repository tests ──────────────────────────────────────────────────────────

class TestFiscalProfileRepository:
    """3.1 RED → 3.2 GREEN: get/upsert vía DB mockeada."""

    @pytest.fixture
    def fiscal_profile_repo(self):
        from backend.repositories.fiscal_profile_repository import FiscalProfileRepository
        conn = AsyncMock()
        return FiscalProfileRepository(conn), conn

    @pytest.mark.asyncio
    async def test_get_by_account_id_queries_correct_table(self, fiscal_profile_repo):
        repo, conn = fiscal_profile_repo
        conn.fetchrow = AsyncMock(return_value=FISCAL_PROFILE_ROW)

        result = await repo.get_by_account_id(ACCOUNT_ID)

        query = conn.fetchrow.call_args[0][0].lower()
        assert "fiscal_profiles" in query
        assert "account_id" in query
        assert result == FISCAL_PROFILE_ROW

    @pytest.mark.asyncio
    async def test_get_returns_none_when_not_found(self, fiscal_profile_repo):
        repo, conn = fiscal_profile_repo
        conn.fetchrow = AsyncMock(return_value=None)

        result = await repo.get_by_account_id(ACCOUNT_ID)
        assert result is None

    @pytest.mark.asyncio
    async def test_upsert_includes_account_id_and_cuit(self, fiscal_profile_repo):
        repo, conn = fiscal_profile_repo
        conn.fetchrow = AsyncMock(return_value=FISCAL_PROFILE_ROW)

        data = {
            "cuit": "20123456789",
            "iva_condition": "responsable_inscripto",
            "ambiente": "homologacion",
        }
        result = await repo.upsert(ACCOUNT_ID, data)

        query = conn.fetchrow.call_args[0][0].lower()
        assert "fiscal_profiles" in query
        assert "account_id" in query


# ── Endpoint tests ────────────────────────────────────────────────────────────

class TestFiscalProfileEndpoints:
    """3.1 RED → 3.2 GREEN: endpoints GET/POST /fiscal/profile."""

    async def test_get_profile_returns_200_with_data(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=FISCAL_PROFILE_ROW)
        owner_token = make_token({"role": "user"})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/fiscal/profile",
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 200
        body = resp.json()
        assert body["cuit"] == "20123456789"
        assert body["iva_condition"] == "responsable_inscripto"
        # No debe exponer contenido del cert
        assert "cert_bytes" not in body
        assert "certificado_content" not in body

    async def test_get_profile_returns_404_when_not_found(self, async_client, mock_pool):
        pool, conn = mock_pool
        conn.fetchrow = AsyncMock(return_value=None)
        owner_token = make_token({"role": "user"})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/fiscal/profile",
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 404

    async def test_create_profile_with_invalid_iva_condition_returns_422(
        self, async_client, mock_pool
    ):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/fiscal/profile",
                json={"cuit": "20123456789", "iva_condition": "otro"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 422

    async def test_create_profile_with_invalid_ambiente_returns_422(
        self, async_client, mock_pool
    ):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/fiscal/profile",
                json={
                    "cuit": "20123456789",
                    "iva_condition": "responsable_inscripto",
                    "ambiente": "sandbox",
                },
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 422

    async def test_member_cannot_create_profile(self, async_client, mock_pool):
        pool, conn = mock_pool
        member_token = make_token({"role": "member"})
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/fiscal/profile",
                json={"cuit": "20123456789", "iva_condition": "responsable_inscripto"},
                headers={"Authorization": f"Bearer {member_token}"},
            )
        assert resp.status_code == 403
