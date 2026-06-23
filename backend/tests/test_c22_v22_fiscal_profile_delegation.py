"""
v22-afip-delegation-billing — Tests TDD para el perfil fiscal con delegación.

Verifica:
  §7.1 RED → §7.2 GREEN: GET /fiscal/profile expone delegacion_autorizada + platform_representante_cuit.
  §7.2 GREEN: POST /fiscal/profile persiste delegacion_autorizada; guard owner/admin.
  §7.3 GREEN: endpoints de cert-upload marcados deprecados (no los usa el flujo de delegación).
  §7.4 TRIANGULATE: owner ok / member 403 / Out contiene flag + CUIT sin material cripto.

Gate: python -m pytest backend/tests -m "not integration"
Design ref: D6 (flag atestación), D8 (onboarding UX), OQ-3 (env vars, no cripto en Out).
"""
from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock, patch
from uuid import UUID

import pytest


# =============================================================================
# §7.1 RED → §7.2 GREEN — GET /fiscal/profile expone delegacion_autorizada + platform_representante_cuit
# =============================================================================

class TestGetFiscalProfileExposesDelegationFlag:
    """7.1 RED → 7.2 GREEN: GET retorna el flag de delegación y CUIT del representante."""

    @pytest.mark.asyncio
    async def test_get_profile_includes_delegacion_autorizada(self):
        """7.1 RED: get_fiscal_profile expone delegacion_autorizada en la respuesta."""
        from backend.services.fiscal import fiscal_profile_service as svc
        from unittest.mock import AsyncMock

        mock_repo = AsyncMock()
        mock_repo.get_by_account_id.return_value = {
            "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "account_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            "cuit": "20111111111",
            "iva_condition": "responsable_inscripto",
            "ambiente": "homologacion",
            "certificado_afip_path": None,
            "created_at": "2026-06-23T00:00:00Z",
            "delegacion_autorizada": True,
        }

        result = await svc.get_fiscal_profile(mock_repo, "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")

        assert result is not None
        # El servicio debe incluir o propagar delegacion_autorizada
        assert "delegacion_autorizada" in result or result.get("delegacion_autorizada") is not None, (
            "get_fiscal_profile debe incluir delegacion_autorizada en la respuesta"
        )

    @pytest.mark.asyncio
    async def test_get_profile_includes_platform_representante_cuit_from_settings(self):
        """7.2 GREEN: get_fiscal_profile inyecta platform_representante_cuit desde config."""
        from backend.services.fiscal import fiscal_profile_service as svc

        mock_repo = AsyncMock()
        mock_repo.get_by_account_id.return_value = {
            "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "account_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            "cuit": "20111111111",
            "iva_condition": "responsable_inscripto",
            "ambiente": "homologacion",
            "certificado_afip_path": None,
            "created_at": "2026-06-23T00:00:00Z",
            "delegacion_autorizada": False,
        }

        with patch.dict("os.environ", {
            "AFIP_PLATFORM_CUIT": "20422662457",
        }, clear=False):
            from importlib import reload
            import backend.core.config as cfg_mod
            reload(cfg_mod)
            import backend.services.fiscal.fiscal_profile_service as svc_mod
            reload(svc_mod)

            result = await svc_mod.get_fiscal_profile(mock_repo, "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")

        # El servicio inyecta el CUIT del representante en la respuesta
        assert result.get("platform_representante_cuit") == "20422662457", (
            f"get_fiscal_profile debe inyectar platform_representante_cuit='20422662457'. "
            f"Obtenido: {result.get('platform_representante_cuit')!r}"
        )

    @pytest.mark.asyncio
    async def test_get_profile_platform_cuit_none_when_not_configured(self):
        """7.2 GREEN: platform_representante_cuit = None cuando no hay cert de plataforma."""
        mock_repo = AsyncMock()
        mock_repo.get_by_account_id.return_value = {
            "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "account_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            "cuit": "20111111111",
            "iva_condition": "responsable_inscripto",
            "ambiente": "homologacion",
            "certificado_afip_path": None,
            "created_at": "2026-06-23T00:00:00Z",
            "delegacion_autorizada": False,
        }

        with patch.dict("os.environ", {
            "AFIP_PLATFORM_CUIT": "",
            "AFIP_PLATFORM_CERT": "",
            "AFIP_PLATFORM_KEY": "",
        }, clear=False):
            from importlib import reload
            import backend.core.config as cfg_mod
            reload(cfg_mod)
            import backend.services.fiscal.fiscal_profile_service as svc_mod
            reload(svc_mod)

            result = await svc_mod.get_fiscal_profile(mock_repo, "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")

        # Sin cert de plataforma, el CUIT representante no se expone
        platform_cuit = result.get("platform_representante_cuit")
        assert platform_cuit is None or platform_cuit == "", (
            "Sin cert de plataforma, platform_representante_cuit debe ser None o vacío"
        )


# =============================================================================
# §7.2 GREEN — POST /fiscal/profile persiste delegacion_autorizada
# =============================================================================

class TestUpsertFiscalProfilePersistsDelegationFlag:
    """7.2 GREEN: POST upsert persiste delegacion_autorizada."""

    @pytest.mark.asyncio
    async def test_upsert_persists_delegacion_autorizada_true(self):
        """7.2 GREEN: upsert_fiscal_profile incluye delegacion_autorizada=True en el payload al repo."""
        from backend.services.fiscal import fiscal_profile_service as svc
        from backend.schemas.fiscal import FiscalProfileCreate

        mock_repo = AsyncMock()
        mock_repo.upsert.return_value = {
            "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "account_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            "cuit": "20111111111",
            "iva_condition": "responsable_inscripto",
            "ambiente": "homologacion",
            "delegacion_autorizada": True,
        }

        auth = {"role": "admin"}
        payload = FiscalProfileCreate(
            cuit="20111111111",
            iva_condition="responsable_inscripto",
            delegacion_autorizada=True,
        )

        result = await svc.upsert_fiscal_profile(mock_repo, auth, "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", payload)

        # Verificar que el repo recibió delegacion_autorizada
        call_kwargs = mock_repo.upsert.call_args
        upsert_data = call_kwargs[0][1] if call_kwargs[0] else call_kwargs[1].get("data", {})
        assert "delegacion_autorizada" in upsert_data, (
            f"El repo.upsert debe recibir delegacion_autorizada. Data: {upsert_data}"
        )
        assert upsert_data["delegacion_autorizada"] is True

    @pytest.mark.asyncio
    async def test_upsert_does_not_overwrite_delegation_when_not_sent(self):
        """7.2 GREEN (v22 PATCH-like behavior): si delegacion_autorizada NO se envía en el payload,
        el repo.upsert NO la recibe → no sobreescribe el valor existente en la DB.
        Este comportamiento es intencional: el FiscalProfileForm solo actualiza datos básicos
        (CUIT, IVA, ambiente) sin tocar el flag de delegación.
        """
        from backend.services.fiscal import fiscal_profile_service as svc
        from backend.schemas.fiscal import FiscalProfileCreate

        mock_repo = AsyncMock()
        mock_repo.upsert.return_value = {"id": "aaa", "account_id": "bbb", "cuit": "20111111111",
                                          "iva_condition": "responsable_inscripto", "ambiente": "homologacion",
                                          "delegacion_autorizada": True}  # valor existente en DB

        auth = {"role": "admin"}
        # El FiscalProfileForm solo envía cuit + iva_condition (no delegacion_autorizada)
        payload = FiscalProfileCreate(
            cuit="20111111111",
            iva_condition="responsable_inscripto",
            # delegacion_autorizada NO especificado → exclude_unset lo omite
        )

        await svc.upsert_fiscal_profile(mock_repo, auth, "bbb", payload)

        call_kwargs = mock_repo.upsert.call_args
        upsert_data = call_kwargs[0][1] if call_kwargs[0] else call_kwargs[1].get("data", {})
        # Con exclude_unset=True, delegacion_autorizada NO debe estar en el payload del upsert
        # → el repo conserva el valor existente en la DB (True en este caso).
        assert "delegacion_autorizada" not in upsert_data, (
            "Si delegacion_autorizada no fue enviado en el payload, no debe incluirse en el upsert "
            "(para no sobreescribir el valor existente en la DB)"
        )


# =============================================================================
# §7.4 TRIANGULATE — owner ok / member 403 / Out sin material cripto
# =============================================================================

class TestDelegationFlagRoleGuard:
    """7.4 TRIANGULATE: owner/admin setea flag (ok); member → 403."""

    @pytest.mark.asyncio
    async def test_member_cannot_set_delegacion_autorizada(self):
        """7.4 TRIANGULATE: member intenta setear delegacion_autorizada → 403."""
        from backend.services.fiscal import fiscal_profile_service as svc
        from backend.schemas.fiscal import FiscalProfileCreate
        from fastapi import HTTPException

        mock_repo = AsyncMock()
        # El guard require_role debe lanzar HTTPException 403 antes de llamar al repo
        auth = {"role": "member"}

        payload = FiscalProfileCreate(
            cuit="20111111111",
            iva_condition="responsable_inscripto",
            delegacion_autorizada=True,
        )

        with pytest.raises(HTTPException) as exc_info:
            await svc.upsert_fiscal_profile(mock_repo, auth, "bbb", payload)

        assert exc_info.value.status_code == 403, (
            f"Member debe recibir 403 al intentar upsert. Status: {exc_info.value.status_code}"
        )
        # El repo NO debe ser llamado
        mock_repo.upsert.assert_not_called()

    @pytest.mark.asyncio
    async def test_admin_can_set_delegacion_autorizada(self):
        """7.4 TRIANGULATE: admin puede setear delegacion_autorizada=True."""
        from backend.services.fiscal import fiscal_profile_service as svc
        from backend.schemas.fiscal import FiscalProfileCreate

        mock_repo = AsyncMock()
        mock_repo.upsert.return_value = {
            "id": "aaa", "account_id": "bbb", "cuit": "20111111111",
            "iva_condition": "responsable_inscripto", "ambiente": "homologacion",
            "delegacion_autorizada": True,
        }
        auth = {"role": "admin"}

        payload = FiscalProfileCreate(
            cuit="20111111111",
            iva_condition="responsable_inscripto",
            delegacion_autorizada=True,
        )

        result = await svc.upsert_fiscal_profile(mock_repo, auth, "bbb", payload)
        assert result is not None
        mock_repo.upsert.assert_called_once()

    def test_fiscal_profile_out_schema_no_crypto_material(self):
        """7.4 TRIANGULATE: FiscalProfileOut contiene flag + CUIT representante, SIN material cripto."""
        from backend.schemas.fiscal import FiscalProfileOut

        # El schema Out no debe tener campos de cert o key del representante
        fields = FiscalProfileOut.model_fields
        assert "delegacion_autorizada" in fields, "FiscalProfileOut debe incluir delegacion_autorizada"
        assert "platform_representante_cuit" in fields, "FiscalProfileOut debe incluir platform_representante_cuit"

        # No debe exponer material criptográfico
        for field_name in fields:
            assert "key" not in field_name.lower() or "cuit" in field_name.lower(), (
                f"FiscalProfileOut no debe exponer campo '{field_name}' con material de key"
            )
        assert "platform_cert" not in fields, "FiscalProfileOut NO debe exponer el cert del representante"
        assert "platform_key" not in fields, "FiscalProfileOut NO debe exponer la key del representante"
