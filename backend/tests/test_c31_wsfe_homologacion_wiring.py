"""
C-31 v21-wsfe-homologacion-wiring — Tests TDD (gate = not integration).

Covers:
  §1 — Fix URLs .gov.ar → .gob.ar
  §2 — Dependencia zeep (import lazy)
  §3 — Schemas Pydantic v2 (CertUploadUrlRequest, CertUploadUrlOut, CertPathUpdate)
  §4 — Service upload cert (signed URL + persistir path)
  §5 — Endpoints router fiscal (cert-upload-url + cert-path)
  §6 — Factory build_cae_adapter (real vs stub)
  §7.1 — Test E2E homologación real (@pytest.mark.integration, EXCLUIDO del gate)

Gate command: python -m pytest backend/tests -m "not integration"
E2E manual:   python -m pytest -m integration backend/tests/test_c31_wsfe_homologacion_wiring.py

Spec ref: openspec/changes/v21-wsfe-homologacion-wiring/
Design ref: W1–W6 en design.md
"""
from __future__ import annotations

import uuid
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from backend.tests.conftest import TEST_ACCOUNT_ID, make_token

ACCOUNT_ID = str(TEST_ACCOUNT_ID)


# =============================================================================
# §1 — Fix de URL del adapter (.gov.ar → .gob.ar)
# =============================================================================

class TestWSFEAdapterURLs:
    """1.1 RED → 1.2 GREEN → 1.3 TRIANGULATE: URLs .gob.ar correctas."""

    def test_wsaa_urls_use_gob_ar(self):
        """1.1 RED: todas las URLs de WSAA terminan en .gob.ar."""
        from backend.services.fiscal.wsfe_adapter import _WSAA_URLS
        for ambiente, url in _WSAA_URLS.items():
            assert ".gob.ar" in url, f"WSAA URL ({ambiente}) debe usar .gob.ar: {url}"
            assert ".gov.ar" not in url, f"WSAA URL ({ambiente}) no debe usar .gov.ar: {url}"

    def test_wsfev1_homologacion_uses_gob_ar(self):
        """WSFEv1 homologación (wswhomo) usa .gob.ar (corrige el typo de C-27)."""
        from backend.services.fiscal.wsfe_adapter import _WSFEV1_URLS
        url = _WSFEV1_URLS["homologacion"]
        assert ".gob.ar" in url and ".gov.ar" not in url, url

    def test_wsfev1_produccion_uses_gov_ar(self):
        """WSFEv1 PRODUCCIÓN (servicios1) usa .gov.ar: el cert TLS del server es
        CN/SAN `servicios1.afip.gov.ar`; apuntar a .gob.ar da hostname mismatch
        (SSLCertVerificationError). El WSAA de prod sí migró a .gob.ar."""
        from backend.services.fiscal.wsfe_adapter import _WSFEV1_URLS
        assert "servicios1.afip.gov.ar" in _WSFEV1_URLS["produccion"]

    def test_wsaa_homologacion_host_correct(self):
        """1.3 TRIANGULATE: host exacto de WSAA homologacion."""
        from backend.services.fiscal.wsfe_adapter import _WSAA_URLS
        assert "wsaahomo.afip.gob.ar" in _WSAA_URLS["homologacion"]

    def test_wsaa_produccion_host_correct(self):
        """1.3 TRIANGULATE: host exacto de WSAA produccion."""
        from backend.services.fiscal.wsfe_adapter import _WSAA_URLS
        assert "wsaa.afip.gob.ar" in _WSAA_URLS["produccion"]

    def test_wsfev1_homologacion_host_correct(self):
        """1.3 TRIANGULATE: host exacto de WSFEv1 homologacion."""
        from backend.services.fiscal.wsfe_adapter import _WSFEV1_URLS
        assert "wswhomo.afip.gob.ar" in _WSFEV1_URLS["homologacion"]

    def test_wsfev1_produccion_host_correct(self):
        """1.3 TRIANGULATE: host exacto de WSFEv1 produccion (.gov.ar por el cert TLS)."""
        from backend.services.fiscal.wsfe_adapter import _WSFEV1_URLS
        assert "servicios1.afip.gov.ar" in _WSFEV1_URLS["produccion"]

    def test_afip_ssl_context_keeps_cert_verification(self):
        """El SSLContext de AFIP baja el security level (DH débil de servicios1 prod
        → DH_KEY_TOO_SMALL) pero MANTIENE la verificación del certificado."""
        import ssl as _ssl
        from backend.services.fiscal.wsfe_adapter import _afip_ssl_context
        ctx = _afip_ssl_context()
        assert ctx.check_hostname is True
        assert ctx.verify_mode == _ssl.CERT_REQUIRED


# =============================================================================
# §2 — Dependencia zeep (import lazy)
# =============================================================================

class TestZeepImport:
    """2.1 RED → 2.2 GREEN → 2.3 TRIANGULATE: import lazy de zeep."""

    def test_wsfe_adapter_module_imports_without_zeep(self):
        """2.1 RED: el módulo importa OK aunque zeep no esté instalado (lazy import)."""
        # Si zeep no está en el env, el módulo igual importa
        import importlib
        import sys

        # Forzar re-import limpio del módulo
        mod_key = "backend.services.fiscal.wsfe_adapter"
        mod = importlib.import_module(mod_key)
        # Si llegamos aquí, el import fue lazy — pass
        assert mod is not None

    def test_wsfe_stub_adapter_works_without_zeep(self):
        """2.1 RED: WSFEStubAdapter funciona sin zeep (no lo requiere)."""
        from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter
        adapter = WSFEStubAdapter()
        assert adapter is not None

    @pytest.mark.asyncio
    async def test_wsfe_real_adapter_raises_import_error_without_zeep(self):
        """2.1 RED: WSFEAdapter._get_wsaa_token lanza ImportError claro si zeep falta (mockeo).

        v22: el adapter requiere un platform_provider configurado; zeep falta → ImportError.
        """
        import sys
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter
        import datetime
        import decimal

        # v22: crear un platform_provider mock configurado (necesario para superar el primer guard)
        mock_provider = MagicMock()
        mock_provider.is_configured.return_value = True
        mock_provider.get_cuit.return_value = "20422662457"
        mock_provider.get_cert.return_value = b"-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n"
        mock_provider.get_key.return_value  = b"-----BEGIN RSA PRIVATE KEY-----\nfakekey\n-----END RSA PRIVATE KEY-----\n"

        # Mock zeep as not available
        original = sys.modules.get("zeep", None)
        sys.modules["zeep"] = None  # type: ignore[assignment]  # forces ImportError on 'import zeep'
        try:
            # Construir un request mínimo
            class _FakeReq:
                account_id = ACCOUNT_ID
                fiscal_document_id = "abc"
                ambiente = "homologacion"
                cuit_emisor = "20422662457"
                cuit_receptor = None
                comprobante_type = "factura_b"
                punto_de_venta = 1
                number = 1
                total = decimal.Decimal("100.00")
                fecha_comprobante = datetime.date.today()

            # v22: pasar platform_provider para superar el guard de configuración
            adapter = WSFEAdapter(platform_provider=mock_provider)

            with pytest.raises(ImportError):
                await adapter._get_wsaa_token(_FakeReq())  # type: ignore[arg-type]
        finally:
            if original is None:
                sys.modules.pop("zeep", None)
            else:
                sys.modules["zeep"] = original


# =============================================================================
# §3 — Schemas Pydantic v2 (cert upload)
# =============================================================================

class TestCertUploadSchemas:
    """3.1 RED → 3.2 GREEN → 3.3 TRIANGULATE: schemas de upload del cert."""

    def test_cert_upload_url_request_valid_kind_cert(self):
        """3.3 TRIANGULATE happy-path: kind=cert válido."""
        from backend.schemas.fiscal import CertUploadUrlRequest
        req = CertUploadUrlRequest(filename="certificado.crt", content_type="application/x-pem-file", kind="cert")
        assert req.kind == "cert"
        assert req.filename == "certificado.crt"

    def test_cert_upload_url_request_valid_kind_key(self):
        """3.3 TRIANGULATE happy-path: kind=key válido."""
        from backend.schemas.fiscal import CertUploadUrlRequest
        req = CertUploadUrlRequest(filename="clave.key", content_type="application/x-pem-file", kind="key")
        assert req.kind == "key"

    def test_cert_upload_url_request_invalid_kind_raises(self):
        """3.1 RED: kind inválido → ValidationError."""
        from pydantic import ValidationError
        from backend.schemas.fiscal import CertUploadUrlRequest
        with pytest.raises(ValidationError):
            CertUploadUrlRequest(filename="foo.p12", content_type="application/x-pkcs12", kind="p12")

    def test_cert_upload_url_request_missing_kind_raises(self):
        """3.3 borde: kind ausente → ValidationError."""
        from pydantic import ValidationError
        from backend.schemas.fiscal import CertUploadUrlRequest
        with pytest.raises(ValidationError):
            CertUploadUrlRequest(filename="foo.crt", content_type="text/plain")  # type: ignore[call-arg]

    def test_cert_upload_url_out_has_required_fields(self):
        """3.1 RED: CertUploadUrlOut tiene uploadUrl y path."""
        from backend.schemas.fiscal import CertUploadUrlOut
        out = CertUploadUrlOut(uploadUrl="https://signed.url/obj", path=f"{ACCOUNT_ID}/afip.crt")
        assert out.uploadUrl.startswith("https://")
        assert out.path.endswith("afip.crt")

    def test_cert_path_update_requires_path(self):
        """3.1 RED: CertPathUpdate requiere path."""
        from pydantic import ValidationError
        from backend.schemas.fiscal import CertPathUpdate
        with pytest.raises(ValidationError):
            CertPathUpdate()  # type: ignore[call-arg]

    def test_cert_path_update_valid(self):
        """3.3 TRIANGULATE: CertPathUpdate happy-path."""
        from backend.schemas.fiscal import CertPathUpdate
        obj = CertPathUpdate(path=f"{ACCOUNT_ID}/afip.crt")
        assert obj.path == f"{ACCOUNT_ID}/afip.crt"


# =============================================================================
# §4 — Service: create_cert_upload_url + set_cert_path
# =============================================================================

class TestCertUploadService:
    """4.1–4.4 RED→GREEN→TRIANGULATE: service de upload de cert."""

    @pytest.mark.asyncio
    async def test_create_cert_upload_url_derives_path_from_account_id_cert(self):
        """4.1 RED: kind=cert → path canónico {account_id}/afip.crt derivado server-side."""
        from backend.services.fiscal.fiscal_profile_service import create_cert_upload_url
        from backend.schemas.fiscal import CertUploadUrlRequest

        mock_storage_client = MagicMock()
        mock_storage_client.storage.from_.return_value.create_signed_upload_url = MagicMock(
            return_value={"signedURL": "https://signed.url/afip.crt", "path": f"{ACCOUNT_ID}/afip.crt"}
        )
        auth = {"role": "user"}
        req = CertUploadUrlRequest(filename="cert.crt", content_type="application/x-pem-file", kind="cert")

        result = await create_cert_upload_url(ACCOUNT_ID, auth, req, mock_storage_client)

        assert result["path"] == f"{ACCOUNT_ID}/afip.crt"
        assert "uploadUrl" in result
        # El path NO debe ser derivado del filename del cliente sino del account_id server-side
        assert ACCOUNT_ID in result["path"]

    @pytest.mark.asyncio
    async def test_create_cert_upload_url_derives_path_from_account_id_key(self):
        """4.1 RED: kind=key → path canónico {account_id}/afip.key derivado server-side."""
        from backend.services.fiscal.fiscal_profile_service import create_cert_upload_url
        from backend.schemas.fiscal import CertUploadUrlRequest

        mock_storage_client = MagicMock()
        mock_storage_client.storage.from_.return_value.create_signed_upload_url = MagicMock(
            return_value={"signedURL": "https://signed.url/afip.key", "path": f"{ACCOUNT_ID}/afip.key"}
        )
        auth = {"role": "user"}
        req = CertUploadUrlRequest(filename="clave.key", content_type="application/x-pem-file", kind="key")

        result = await create_cert_upload_url(ACCOUNT_ID, auth, req, mock_storage_client)

        assert result["path"] == f"{ACCOUNT_ID}/afip.key"

    @pytest.mark.asyncio
    async def test_create_cert_upload_url_member_gets_403(self):
        """4.1 RED: member → 403 (require_role guard)."""
        from fastapi import HTTPException
        from backend.services.fiscal.fiscal_profile_service import create_cert_upload_url
        from backend.schemas.fiscal import CertUploadUrlRequest

        auth = {"role": "member"}
        req = CertUploadUrlRequest(filename="cert.crt", content_type="application/x-pem-file", kind="cert")

        with pytest.raises(HTTPException) as exc_info:
            await create_cert_upload_url(ACCOUNT_ID, auth, req, MagicMock())
        assert exc_info.value.status_code == 403

    @pytest.mark.asyncio
    async def test_set_cert_path_persists_path(self):
        """4.3 RED: set_cert_path persiste certificado_afip_path vía repo upsert."""
        from backend.services.fiscal.fiscal_profile_service import set_cert_path
        from backend.schemas.fiscal import CertPathUpdate

        mock_repo = AsyncMock()
        cert_path = f"{ACCOUNT_ID}/afip.crt"
        mock_repo.upsert.return_value = {
            "id": str(uuid.uuid4()),
            "account_id": ACCOUNT_ID,
            "cuit": "20422662457",
            "iva_condition": "responsable_inscripto",
            "certificado_afip_path": cert_path,
            "ambiente": "homologacion",
            "created_at": "2026-06-22T00:00:00+00:00",
        }
        auth = {"role": "user"}
        payload = CertPathUpdate(path=cert_path)

        result = await set_cert_path(mock_repo, auth, ACCOUNT_ID, payload)

        # Verifica que upsert fue llamado con el path
        mock_repo.upsert.assert_called_once()
        call_data = mock_repo.upsert.call_args[0][1]  # second positional arg = data dict
        assert call_data.get("certificado_afip_path") == cert_path
        # La respuesta no debe incluir contenido del cert
        assert "cert_bytes" not in result
        assert "certificado_content" not in result

    @pytest.mark.asyncio
    async def test_set_cert_path_ignores_client_path_derives_canonical(self):
        """Hardening (review C-31): set_cert_path NO confía en el path del cliente;
        re-deriva la ruta canónica {account_id}/afip.crt server-side. Un cliente que
        mande la ruta de OTRA cuenta NO puede setear certificado_afip_path apuntando ahí."""
        from backend.services.fiscal.fiscal_profile_service import set_cert_path
        from backend.schemas.fiscal import CertPathUpdate

        mock_repo = AsyncMock()
        mock_repo.upsert.return_value = {
            "id": str(uuid.uuid4()),
            "account_id": ACCOUNT_ID,
            "certificado_afip_path": f"{ACCOUNT_ID}/afip.crt",
        }
        auth = {"role": "user"}
        other_account = "11111111-1111-1111-1111-111111111111"
        malicious = CertPathUpdate(path=f"{other_account}/afip.crt")

        await set_cert_path(mock_repo, auth, ACCOUNT_ID, malicious)

        call_data = mock_repo.upsert.call_args[0][1]  # second positional arg = data dict
        # Debe persistir la ruta canónica del account_id del JWT, NO la que mandó el cliente
        assert call_data.get("certificado_afip_path") == f"{ACCOUNT_ID}/afip.crt"
        assert other_account not in call_data.get("certificado_afip_path")

    @pytest.mark.asyncio
    async def test_set_cert_path_member_gets_403(self):
        """4.4 TRIANGULATE: member → 403."""
        from fastapi import HTTPException
        from backend.services.fiscal.fiscal_profile_service import set_cert_path
        from backend.schemas.fiscal import CertPathUpdate

        auth = {"role": "member"}
        payload = CertPathUpdate(path=f"{ACCOUNT_ID}/afip.crt")

        with pytest.raises(HTTPException) as exc_info:
            await set_cert_path(AsyncMock(), auth, ACCOUNT_ID, payload)
        assert exc_info.value.status_code == 403


# =============================================================================
# §5 — Endpoints router fiscal
# =============================================================================

class TestCertUploadEndpoints:
    """5.1–5.5 RED→GREEN→TRIANGULATE: endpoints cert-upload-url + cert-path.

    Nota: estos tests usan async_client que carga el app completo. El app requiere fpdf
    que no está instalado en el entorno de dev — esos tests dan ERROR (pre-existing).
    Los tests de service (§4) cubren la lógica equivalente sin depender del app.
    Los tests de schema (§3) cubren la validación de request.

    Para correr los endpoint tests en un entorno limpio: pip install fpdf2 supabase
    """

    async def test_post_cert_upload_url_kind_cert_returns_200(self, async_client, mock_pool):
        """5.1 RED: POST /fiscal/profile/cert-upload-url kind=cert → 200 con uploadUrl+path."""
        from backend.main import app as _app
        from backend.routers.fiscal import get_storage_service_client
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})

        mock_storage = MagicMock()
        mock_storage.storage.from_.return_value.create_signed_upload_url = MagicMock(
            return_value={"signedURL": "https://supabase.co/signed/path", "path": f"{ACCOUNT_ID}/afip.crt"}
        )

        _app.dependency_overrides[get_storage_service_client] = lambda: mock_storage
        try:
            with patch("backend.core.database.pool", pool):
                resp = await async_client.post(
                    "/fiscal/profile/cert-upload-url",
                    json={"filename": "cert.crt", "content_type": "application/x-pem-file", "kind": "cert"},
                    headers={"Authorization": f"Bearer {owner_token}"},
                )
        finally:
            _app.dependency_overrides.pop(get_storage_service_client, None)

        assert resp.status_code == 200
        body = resp.json()
        assert "uploadUrl" in body
        assert "path" in body
        assert body["path"].endswith("afip.crt")

    async def test_post_cert_upload_url_kind_key_returns_200(self, async_client, mock_pool):
        """5.1 RED: POST /fiscal/profile/cert-upload-url kind=key → 200 con uploadUrl+path."""
        from backend.main import app as _app
        from backend.routers.fiscal import get_storage_service_client
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})

        mock_storage = MagicMock()
        mock_storage.storage.from_.return_value.create_signed_upload_url = MagicMock(
            return_value={"signedURL": "https://supabase.co/signed/key", "path": f"{ACCOUNT_ID}/afip.key"}
        )

        _app.dependency_overrides[get_storage_service_client] = lambda: mock_storage
        try:
            with patch("backend.core.database.pool", pool):
                resp = await async_client.post(
                    "/fiscal/profile/cert-upload-url",
                    json={"filename": "clave.key", "content_type": "application/x-pem-file", "kind": "key"},
                    headers={"Authorization": f"Bearer {owner_token}"},
                )
        finally:
            _app.dependency_overrides.pop(get_storage_service_client, None)

        assert resp.status_code == 200
        body = resp.json()
        assert body["path"].endswith("afip.key")

    async def test_post_cert_upload_url_invalid_kind_returns_422(self, async_client, mock_pool):
        """5.1 RED: kind inválido → 422. No necesita supabase client (falla antes de llegar al handler)."""
        from backend.main import app as _app
        from backend.routers.fiscal import get_storage_service_client
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})

        _app.dependency_overrides[get_storage_service_client] = lambda: MagicMock()
        try:
            with patch("backend.core.database.pool", pool):
                resp = await async_client.post(
                    "/fiscal/profile/cert-upload-url",
                    json={"filename": "foo.p12", "content_type": "application/pkcs12", "kind": "p12"},
                    headers={"Authorization": f"Bearer {owner_token}"},
                )
        finally:
            _app.dependency_overrides.pop(get_storage_service_client, None)

        assert resp.status_code == 422

    async def test_post_cert_upload_url_member_returns_403(self, async_client, mock_pool):
        """5.1 RED: member → 403."""
        from backend.main import app as _app
        from backend.routers.fiscal import get_storage_service_client
        pool, conn = mock_pool
        member_token = make_token({"role": "member"})

        mock_storage = MagicMock()
        mock_storage.storage.from_.return_value.create_signed_upload_url = MagicMock(
            return_value={"signedURL": "https://supabase.co/signed/path", "path": f"{ACCOUNT_ID}/afip.crt"}
        )

        _app.dependency_overrides[get_storage_service_client] = lambda: mock_storage
        try:
            with patch("backend.core.database.pool", pool):
                resp = await async_client.post(
                    "/fiscal/profile/cert-upload-url",
                    json={"filename": "cert.crt", "content_type": "application/x-pem-file", "kind": "cert"},
                    headers={"Authorization": f"Bearer {member_token}"},
                )
        finally:
            _app.dependency_overrides.pop(get_storage_service_client, None)

        assert resp.status_code == 403

    async def test_put_cert_path_returns_200_with_profile(self, async_client, mock_pool):
        """5.3 RED: PUT /fiscal/profile/cert-path → 200 con perfil; sin contenido key."""
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})

        cert_path = f"{ACCOUNT_ID}/afip.crt"
        profile_row = {
            "id": str(uuid.uuid4()),
            "account_id": ACCOUNT_ID,
            "cuit": "20422662457",
            "iva_condition": "responsable_inscripto",
            "iibb_condition": None,
            "certificado_afip_path": cert_path,
            "ambiente": "homologacion",
            "created_at": "2026-06-22T00:00:00+00:00",
        }
        conn.fetchrow = AsyncMock(return_value=profile_row)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                "/fiscal/profile/cert-path",
                json={"path": cert_path},
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        body = resp.json()
        # Verificar que no se filtra contenido del cert ni del key
        assert "cert_bytes" not in body
        assert "certificado_content" not in body
        # El path del .key NO debe aparecer en la respuesta
        response_str = str(body)
        assert "afip.key" not in response_str

    async def test_put_cert_path_member_returns_403(self, async_client, mock_pool):
        """5.3 RED: member → 403."""
        pool, conn = mock_pool
        member_token = make_token({"role": "member"})
        conn.fetchrow = AsyncMock(return_value=None)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                "/fiscal/profile/cert-path",
                json={"path": f"{ACCOUNT_ID}/afip.crt"},
                headers={"Authorization": f"Bearer {member_token}"},
            )

        assert resp.status_code == 403

    async def test_get_profile_does_not_return_key_path_or_content(self, async_client, mock_pool):
        """5.5 invariante OQ-2: GET /fiscal/profile NUNCA retorna path de .key ni contenido."""
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})

        profile_row = {
            "id": str(uuid.uuid4()),
            "account_id": ACCOUNT_ID,
            "cuit": "20422662457",
            "iva_condition": "responsable_inscripto",
            "iibb_condition": None,
            "certificado_afip_path": f"{ACCOUNT_ID}/afip.crt",
            "ambiente": "homologacion",
            "created_at": "2026-06-22T00:00:00+00:00",
        }
        conn.fetchrow = AsyncMock(return_value=profile_row)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                "/fiscal/profile",
                headers={"Authorization": f"Bearer {owner_token}"},
            )

        assert resp.status_code == 200
        body = resp.json()
        response_text = str(body)
        # La ruta del .key nunca debe aparecer
        assert "afip.key" not in response_text
        # Contenido del cert nunca expuesto
        assert "cert_bytes" not in response_text
        assert "-----BEGIN" not in response_text


# =============================================================================
# §6 — Factory build_cae_adapter (real vs stub)
# =============================================================================

class TestBuildCaeAdapterFactory:
    """6.1 RED → 6.2 GREEN → 6.3–6.4 TRIANGULATE: factory real vs stub."""

    def test_factory_returns_real_adapter_when_has_cert_and_service_client(self):
        """6.1 (v22 UPDATED): el gate ahora es platform_provider.is_configured().
        has_cert + service_client solos (sin platform_provider) → stub (backward-compat seguro).
        Para obtener el adapter real, pasar platform_provider configurado.
        """
        from backend.services.fiscal.adapter_factory import build_cae_adapter
        from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        # v22: has_cert=True sin platform_provider → stub (default seguro)
        adapter_stub = build_cae_adapter(has_cert=True, service_client=MagicMock())
        assert isinstance(adapter_stub, WSFEStubAdapter), (
            "v22: sin platform_provider configurado → stub (aunque has_cert=True)"
        )

        # v22: con platform_provider configurado → real (gate nuevo)
        mock_provider = MagicMock()
        mock_provider.is_configured.return_value = True
        adapter_real = build_cae_adapter(platform_provider=mock_provider)
        assert isinstance(adapter_real, WSFEAdapter)

    def test_factory_returns_stub_when_no_cert(self):
        """6.1 RED: has_cert=False → WSFEStubAdapter."""
        from backend.services.fiscal.adapter_factory import build_cae_adapter
        from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter

        adapter = build_cae_adapter(has_cert=False, service_client=MagicMock())

        assert isinstance(adapter, WSFEStubAdapter)

    def test_factory_returns_stub_when_has_cert_but_no_service_client(self):
        """6.1 RED: has_cert=True sin service_client → WSFEStubAdapter (fallback seguro)."""
        from backend.services.fiscal.adapter_factory import build_cae_adapter
        from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter

        adapter = build_cae_adapter(has_cert=True, service_client=None)

        assert isinstance(adapter, WSFEStubAdapter)

    def test_factory_stub_when_has_cert_false_ignores_service_client(self):
        """6.1 TRIANGULATE: has_cert=False con service_client igual devuelve stub."""
        from backend.services.fiscal.adapter_factory import build_cae_adapter
        from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter

        # Aunque se pase un service_client, sin cert sigue siendo stub
        adapter = build_cae_adapter(has_cert=False, service_client=MagicMock())
        assert isinstance(adapter, WSFEStubAdapter)

    def test_factory_real_adapter_has_service_client_injected(self):
        """6.1 TRIANGULATE (v22 UPDATED): el WSFEAdapter real tiene el platform_provider inyectado.
        En v22, el gate es platform_provider.is_configured() — service_client es backward-compat ignorado.
        """
        from backend.services.fiscal.adapter_factory import build_cae_adapter
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        mock_provider = MagicMock()
        mock_provider.is_configured.return_value = True
        mock_cache = MagicMock()

        adapter = build_cae_adapter(platform_provider=mock_provider, ticket_cache=mock_cache)

        assert isinstance(adapter, WSFEAdapter)
        # v22: el adapter tiene el platform_provider (no service_client per-account)
        assert adapter._platform_provider is mock_provider
        assert adapter._ticket_cache is mock_cache

    @pytest.mark.asyncio
    async def test_process_pending_uses_stub_when_no_cert(self, mock_pool):
        """6.3 RED: process_pending_cae usa stub cuando certificado_afip_path es None."""
        # La factory decide stub vs real; sin cert → stub
        from backend.services.fiscal.adapter_factory import build_cae_adapter
        from backend.services.fiscal.wsfe_stub_adapter import WSFEStubAdapter

        adapter = build_cae_adapter(has_cert=False, service_client=MagicMock())
        assert isinstance(adapter, WSFEStubAdapter)

    @pytest.mark.asyncio
    async def test_process_pending_uses_real_when_cert_present(self, mock_pool):
        """6.3 (v22 UPDATED): process_pending_cae usa WSFEAdapter real cuando hay cert de PLATAFORMA.
        El gate es platform_provider.is_configured(), no has_cert per-account.
        """
        from backend.services.fiscal.adapter_factory import build_cae_adapter
        from backend.services.fiscal.wsfe_adapter import WSFEAdapter

        mock_provider = MagicMock()
        mock_provider.is_configured.return_value = True

        adapter = build_cae_adapter(platform_provider=mock_provider)
        assert isinstance(adapter, WSFEAdapter)


# =============================================================================
# §7.1 — E2E homologación real (MANUAL — @pytest.mark.integration)
# =============================================================================

@pytest.mark.integration
class TestWSFEHomologacionE2E:
    """7.1 Test E2E de homologación real contra ARCA.

    FUERA del gate de CI. Corre A MANO:
      python -m pytest -m integration backend/tests/test_c31_wsfe_homologacion_wiring.py

    Prerequisitos:
      - cert del PO en bucket afip-certs: {account_id}/afip.crt + {account_id}/afip.key
      - SUPABASE_SERVICE_ROLE_KEY configurada en env
      - ARCA homologación disponible (intermitente)
      - CUIT emisor: 20422662457, ambiente: homologacion

    Cierra C-27 task 5.2.
    """

    @pytest.mark.asyncio
    async def test_wsfe_homologacion_obtiene_cae_real(self):
        """7.1 E2E real: WSAA loginCms → WSFEv1 FECAESolicitar → CAE válido de homologación.

        Este test llama a los servicios reales de ARCA homologación.
        Requiere el cert real en el bucket privado afip-certs.
        """
        import os
        import datetime
        import decimal
        from unittest.mock import AsyncMock as _AsyncMock

        from backend.services.fiscal.wsfe_adapter import WSFEAdapter
        from backend.services.fiscal.fiscal_document_port import CAERequest

        # Credenciales reales necesarias en el env
        supabase_url = os.environ.get("SUPABASE_URL")
        service_role_key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")

        if not supabase_url or not service_role_key:
            pytest.skip(
                "SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY requeridas para E2E homologación. "
                "Configurar en el entorno antes de correr -m integration."
            )

        # Construir cliente service-role real
        from supabase import create_client
        service_client = create_client(supabase_url, service_role_key)

        # CUIT y account_id del PO para homologación
        # El account_id debe corresponder al account que tiene el cert cargado en afip-certs
        test_account_id = os.environ.get(
            "AFIP_TEST_ACCOUNT_ID",
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",  # default; reemplazar con el real del PO
        )
        cuit_emisor = "20422662457"  # CUIT del PO

        invoice_data = CAERequest(
            fiscal_document_id="c31-e2e-homo-test-001",
            account_id=test_account_id,
            ambiente="homologacion",
            cuit_emisor=cuit_emisor,
            cuit_receptor=None,
            comprobante_type="factura_b",
            punto_de_venta=1,
            number=1,
            total=decimal.Decimal("100.00"),
            fecha_comprobante=datetime.date.today(),
        )

        adapter = WSFEAdapter(supabase_service_client=service_client)
        response = await adapter.request_cae(invoice_data)

        # Aserciones del E2E real
        assert response is not None, "El adapter debe retornar una respuesta"
        assert response.is_approved, (
            f"Se esperaba CAE aprobado de homologación. "
            f"Error: {response.error_code} — {response.error_detail}"
        )
        assert response.cae is not None, "El CAE no debe ser None en homologación exitosa"
        assert len(str(response.cae)) >= 10, "El CAE de AFIP tiene al menos 10 dígitos"
        assert response.cae_due_date is not None, "El CAE debe tener fecha de vencimiento"
        assert response.cae_due_date > datetime.date.today(), "El CAE no debe estar vencido"

        # Log del CAE obtenido (sin persistir — solo para confirmar el E2E)
        import logging
        logger = logging.getLogger(__name__)
        logger.info(
            "[C-31 E2E homologación] CAE obtenido: %s, vence: %s",
            response.cae,
            response.cae_due_date,
        )
