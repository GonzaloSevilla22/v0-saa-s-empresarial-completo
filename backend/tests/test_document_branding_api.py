"""
documentos-marca-empresa — grupo 8: API `/document-branding` en 3 capas
(tasks 8.1 RED, 8.2 GREEN, 8.3 triangulación).

Criterio de aceptación: spec `document-branding`, requirements "Marca de los
papeles por cuenta", "Sólo owner y admin cambian la marca", "Logo validado y
normalizado por el servidor", "Paleta de colores…" y "API de la marca de
documentos".

El repositorio se reemplaza por un doble (el router, el service y los esquemas
son lo que se prueba); sus consultas se prueban aparte en
`test_document_branding_repository.py`.

Run: python -m pytest backend/tests/test_document_branding_api.py -q -p no:cacheprovider
"""
from __future__ import annotations

import datetime
import io
import json
import struct
import zlib
from unittest.mock import AsyncMock, patch

import pytest
from PIL import Image

from backend.services.commercial_documents.branding import clear_logo_cache
from backend.services.commercial_documents.logo import MAX_UPLOAD_BYTES, normalize_logo
from backend.tests.conftest import TEST_ACCOUNT_ID, TEST_USER_ID, account_roles_fetchval, make_token

ACCOUNT = str(TEST_ACCOUNT_ID)
OWNER_LOGIN_EMAIL = "duenio@example.com"
NOW = datetime.datetime(2026, 10, 11, 12, 0, tzinfo=datetime.timezone.utc)

RPC_EMPTY = {
    "nombre_fantasia": None, "razon_social": None, "cuit": None, "domicilio_comercial": None,
    "business_name": "Almacén Don José", "phone": "2615550101", "iva_condition": None,
    "brand_display_name": None, "brand_legal_name": None, "brand_tax_id": None, "brand_address": None,
    "brand_phone": None, "brand_email": None, "brand_website": None, "brand_footer_note": None,
    "palette_preset": None, "accent_color": None, "logo_sha256": None,
}

SETTINGS_BODY = {
    "display_name": "Sumar", "legal_name": "Ropa Deportiva SRL", "tax_id": "20-12345678-6",
    "address": "Av. San Martín 1234, Mendoza", "phone": "2615550999", "email": "ventas@sumar.com.ar",
    "website": "sumar.com.ar", "footer_note": "Alias: sumar.ropa", "palette_preset": "grafito", "accent_color": None,
}


def _stored_row(**over) -> dict:
    base = {
        "account_id": ACCOUNT, "display_name": None, "legal_name": None, "tax_id": None, "address": None,
        "phone": None, "email": None, "website": None, "footer_note": None, "palette_preset": "neutro",
        "accent_color": None, "logo_mime": None, "logo_sha256": None, "logo_width": None, "logo_height": None,
        "logo_updated_at": None, "updated_at": NOW, "updated_by": TEST_USER_ID,
    }
    base.update(over)
    return base


def _png(size=(400, 100), color=(200, 30, 30, 255)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGBA", size, color).save(buf, "PNG")
    return buf.getvalue()


def _png_declaring(width: int, height: int) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00")) + chunk(b"IEND", b"")


def _token(role: str) -> str:
    return make_token({"role": "user", "app_metadata": {"account_role": role}})


def _headers(role: str = "owner", **extra) -> dict:
    return {"Authorization": f"Bearer {_token(role)}", **extra}


@pytest.fixture
def api(mock_pool):
    """Un repositorio falso inyectado en el router + la conexión simulada (para el guard de rol)."""
    from backend.main import app
    from backend.routers.document_branding import get_repo

    clear_logo_cache()
    repo = AsyncMock()
    repo.get.return_value = None
    repo.get_commercial_issuer.return_value = {
        **RPC_EMPTY, "email": OWNER_LOGIN_EMAIL, "owner_email": OWNER_LOGIN_EMAIL, "auth_email": OWNER_LOGIN_EMAIL,
    }
    repo.upsert.side_effect = lambda account_id, data, user_id: _stored_row(**data, updated_by=user_id)
    repo.set_logo.return_value = None
    repo.clear_logo.return_value = 1
    repo.get_document_logo.return_value = None
    app.dependency_overrides[get_repo] = lambda: repo
    pool, conn = mock_pool
    try:
        yield repo, pool, conn
    finally:
        app.dependency_overrides.pop(get_repo, None)
        clear_logo_cache()


def _allow(conn, *roles):
    conn.fetchval = account_roles_fetchval(list(roles))


# ═════════════════════════════════════════════════════════════════════════════
# GET /document-branding
# ═════════════════════════════════════════════════════════════════════════════

class TestGetBranding:
    async def test_an_account_without_a_row_gets_the_defaults(self, async_client, api):
        repo, pool, conn = api
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/document-branding", headers=_headers("seller"))

        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["is_default"] is True
        assert body["settings"] == {
            "display_name": None, "legal_name": None, "tax_id": None, "address": None, "phone": None,
            "email": None, "website": None, "footer_note": None, "palette_preset": "neutro", "accent_color": None,
        }
        assert body["logo"] is None
        assert body["palette"]["key"] == "neutro" and body["palette"]["accent"] is None
        assert body["updated_at"] is None
        repo.get.assert_awaited_once_with(ACCOUNT)

    async def test_the_catalog_lists_the_six_palettes(self, async_client, api):
        repo, pool, conn = api
        with patch("backend.core.database.pool", pool):
            body = (await async_client.get("/document-branding", headers=_headers("viewer"))).json()
        assert [p["key"] for p in body["palettes"]] == ["neutro", "azul", "verde", "grafito", "bordo", "personalizado"]
        assert {p["key"]: p["accent"] for p in body["palettes"]}["azul"] == "#1d4ed8"

    async def test_the_issuer_is_the_printed_one_with_its_sources(self, async_client, api):
        repo, pool, conn = api
        repo.get_commercial_issuer.return_value = {
            **RPC_EMPTY, "nombre_fantasia": "Sumar", "razon_social": "Ropa Deportiva SRL", "cuit": "20123456786",
            "iva_condition": "monotributista", "brand_email": "ventas@sumar.com.ar",
        }
        with patch("backend.core.database.pool", pool):
            body = (await async_client.get("/document-branding", headers=_headers("seller"))).json()
        issuer = body["issuer"]
        assert issuer["name"] == "Sumar" and issuer["legal_name"] == "Ropa Deportiva SRL"
        assert issuer["cuit"] == "20-12345678-6" and issuer["iva_legend"] == "IVA RESPONSABLE MONOTRIBUTO"
        assert issuer["email"] == "ventas@sumar.com.ar" and issuer["phone"] == "2615550101"
        assert body["sources"]["name"] == "fiscal" and body["sources"]["phone"] == "owner"
        assert body["sources"]["email"] == "brand" and body["sources"]["iva"] == "fiscal"

    async def test_fiscal_data_is_exposed_read_only_only_when_there_is_a_fiscal_profile(self, async_client, api):
        repo, pool, conn = api
        with patch("backend.core.database.pool", pool):
            without = (await async_client.get("/document-branding", headers=_headers("seller"))).json()
        assert without["fiscal"] is None

        repo.get_commercial_issuer.return_value = {
            **RPC_EMPTY, "razon_social": "Ropa Deportiva SRL", "nombre_fantasia": "Sumar", "cuit": "20123456786",
            "domicilio_comercial": "Av. San Martín 1234", "iva_condition": "monotributista",
        }
        with patch("backend.core.database.pool", pool):
            with_profile = (await async_client.get("/document-branding", headers=_headers("seller"))).json()
        assert with_profile["fiscal"] == {
            "razon_social": "Ropa Deportiva SRL", "nombre_fantasia": "Sumar", "cuit": "20-12345678-6",
            "domicilio_comercial": "Av. San Martín 1234", "iva_condition": "monotributista",
        }

    async def test_the_owner_profile_fallback_is_exposed_for_the_live_preview(self, async_client, api):
        repo, pool, conn = api
        with patch("backend.core.database.pool", pool):
            body = (await async_client.get("/document-branding", headers=_headers("seller"))).json()
        assert body["owner_fallback"] == {"business_name": "Almacén Don José", "phone": "2615550101"}

    async def test_a_saved_row_is_reflected_with_the_logo_descriptor(self, async_client, api):
        repo, pool, conn = api
        repo.get.return_value = _stored_row(
            display_name="Sumar", palette_preset="personalizado", accent_color="#7c2d12",
            logo_mime="image/png", logo_sha256="a" * 64, logo_width=1000, logo_height=250, logo_updated_at=NOW,
        )
        repo.get_commercial_issuer.return_value = {**RPC_EMPTY, "brand_display_name": "Sumar", "palette_preset": "personalizado",
                                                   "accent_color": "#7c2d12", "logo_sha256": "a" * 64}
        with patch("backend.core.database.pool", pool):
            body = (await async_client.get("/document-branding", headers=_headers("viewer"))).json()
        assert body["is_default"] is False
        assert body["settings"]["display_name"] == "Sumar" and body["settings"]["accent_color"] == "#7c2d12"
        assert body["logo"] == {"sha256": "a" * 64, "mime": "image/png", "width": 1000, "height": 250}
        assert body["palette"]["key"] == "personalizado" and body["palette"]["accent"] == "#7c2d12"
        assert body["updated_by"] == TEST_USER_ID

    async def test_nothing_in_the_response_is_an_access_email(self, async_client, api):
        repo, pool, conn = api
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/document-branding", headers=_headers("owner"))
        assert OWNER_LOGIN_EMAIL not in resp.text

    async def test_no_binary_image_travels_in_the_json(self, async_client, api):
        repo, pool, conn = api
        repo.get.return_value = _stored_row(logo_mime="image/png", logo_sha256="a" * 64, logo_width=10, logo_height=10,
                                            logo_updated_at=NOW)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/document-branding", headers=_headers("owner"))
        assert "logo_image" not in resp.text and len(resp.text) < 5000

    async def test_it_requires_a_session(self, async_client, api):
        repo, pool, conn = api
        resp = await async_client.get("/document-branding")
        assert resp.status_code == 401


# ═════════════════════════════════════════════════════════════════════════════
# PUT /document-branding
# ═════════════════════════════════════════════════════════════════════════════

class TestPutBranding:
    @pytest.mark.parametrize("role", ["owner", "admin"])
    async def test_owner_and_admin_save_and_the_response_reflects_it(self, async_client, api, role):
        repo, pool, conn = api
        _allow(conn, role)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put("/document-branding", json=SETTINGS_BODY, headers=_headers(role))

        assert resp.status_code == 200, resp.text
        account_id, data, user_id = repo.upsert.await_args.args
        assert account_id == ACCOUNT and user_id == TEST_USER_ID
        assert data["display_name"] == "Sumar" and data["palette_preset"] == "grafito" and data["accent_color"] is None
        body = resp.json()
        assert body["settings"]["display_name"] == "Sumar" and body["settings"]["palette_preset"] == "grafito"
        assert body["is_default"] is False

    @pytest.mark.parametrize("role", ["seller", "cashier", "viewer", "accountant"])
    async def test_other_roles_get_403_before_anything_is_written(self, async_client, api, role):
        repo, pool, conn = api
        _allow(conn, role)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put("/document-branding", json=SETTINGS_BODY, headers=_headers(role))
        assert resp.status_code == 403
        repo.upsert.assert_not_awaited()

    async def test_the_token_says_owner_but_the_database_says_seller(self, async_client, api):
        """CAN_CONFIGURE es capacidad sensible: la base es la autoridad."""
        repo, pool, conn = api
        _allow(conn, "seller")
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put("/document-branding", json=SETTINGS_BODY, headers=_headers("owner"))
        assert resp.status_code == 403
        repo.upsert.assert_not_awaited()

    async def test_it_requires_a_session(self, async_client, api):
        assert (await async_client.put("/document-branding", json=SETTINGS_BODY)).status_code == 401

    async def test_blank_texts_are_saved_as_null(self, async_client, api):
        repo, pool, conn = api
        _allow(conn, "owner")
        body = {**SETTINGS_BODY, "phone": "   ", "website": "", "address": "\t\n", "footer_note": None}
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put("/document-branding", json=body, headers=_headers("owner"))
        assert resp.status_code == 200
        data = repo.upsert.await_args.args[1]
        assert data["phone"] is None and data["website"] is None and data["address"] is None and data["footer_note"] is None

    async def test_texts_are_trimmed_the_cuit_is_stored_with_dashes_and_the_color_in_lowercase(self, async_client, api):
        repo, pool, conn = api
        _allow(conn, "owner")
        body = {**SETTINGS_BODY, "display_name": "  Sumar  ", "tax_id": "20123456786",
                "palette_preset": "personalizado", "accent_color": "#7C2D12"}
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put("/document-branding", json=body, headers=_headers("owner"))
        assert resp.status_code == 200, resp.text
        data = repo.upsert.await_args.args[1]
        assert data["display_name"] == "Sumar" and data["tax_id"] == "20-12345678-6" and data["accent_color"] == "#7c2d12"

    async def test_a_body_without_fields_resets_the_brand_to_the_defaults(self, async_client, api):
        repo, pool, conn = api
        _allow(conn, "owner")
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put("/document-branding", json={}, headers=_headers("owner"))
        assert resp.status_code == 200
        data = repo.upsert.await_args.args[1]
        assert data["palette_preset"] == "neutro" and all(data[k] is None for k in ("display_name", "email", "tax_id"))

    @pytest.mark.parametrize(
        "patch_body,field",
        [
            ({"display_name": "x" * 81}, "display_name"),
            ({"legal_name": "x" * 121}, "legal_name"),
            ({"address": "x" * 201}, "address"),
            ({"phone": "1" * 41}, "phone"),
            ({"footer_note": "x" * 281}, "footer_note"),
            ({"email": "no-es-un-email"}, "email"),
            ({"email": "con espacio@dominio.com"}, "email"),
            ({"email": "a@b"}, "email"),
            ({"email": "x" * 109 + "@sumar.com.ar"}, "email"),
            ({"tax_id": "20-12345678-7"}, "tax_id"),            # dígito verificador
            ({"tax_id": "123"}, "tax_id"),
            ({"website": "sumar com.ar"}, "website"),
            ({"website": "sumar.com<script>"}, "website"),
            ({"website": "x" * 121}, "website"),
            ({"palette_preset": "rosa"}, "palette_preset"),
            ({"palette_preset": "personalizado", "accent_color": None}, "accent_color"),
            ({"palette_preset": "azul", "accent_color": "#112233"}, "accent_color"),
            ({"palette_preset": "personalizado", "accent_color": "azul"}, "accent_color"),
            ({"palette_preset": "personalizado", "accent_color": "#abc"}, "accent_color"),
            ({"palette_preset": "personalizado", "accent_color": "#12345g"}, "accent_color"),
        ],
    )
    async def test_invalid_values_are_422_naming_the_field_and_nothing_is_written(self, async_client, api, patch_body, field):
        repo, pool, conn = api
        _allow(conn, "owner")
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put("/document-branding", json={**SETTINGS_BODY, **patch_body}, headers=_headers("owner"))
        assert resp.status_code == 422, resp.text
        assert field in resp.text
        repo.upsert.assert_not_awaited()

    @pytest.mark.parametrize("color", ["#10b981", "#facc15", "#ffffff", "#a96081"])
    async def test_an_illegible_custom_color_is_422_branding_accent_low_contrast(self, async_client, api, color):
        repo, pool, conn = api
        _allow(conn, "owner")
        body = {**SETTINGS_BODY, "palette_preset": "personalizado", "accent_color": color}
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put("/document-branding", json=body, headers=_headers("owner"))
        assert resp.status_code == 422, resp.text
        problem = resp.json()
        assert problem["code"] == "branding_accent_low_contrast"
        assert resp.headers["content-type"].startswith("application/problem+json")
        repo.upsert.assert_not_awaited()

    async def test_a_legible_custom_color_is_accepted(self, async_client, api):
        repo, pool, conn = api
        _allow(conn, "owner")
        body = {**SETTINGS_BODY, "palette_preset": "personalizado", "accent_color": "#7c2d12"}
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put("/document-branding", json=body, headers=_headers("owner"))
        assert resp.status_code == 200
        assert resp.json()["palette"]["accent"] == "#7c2d12"

    async def test_two_puts_in_a_row_never_touch_the_logo(self, async_client, api):
        """El PUT de datos NO incluye el logo: el service sólo pasa campos de datos."""
        repo, pool, conn = api
        _allow(conn, "owner")
        with patch("backend.core.database.pool", pool):
            await async_client.put("/document-branding", json=SETTINGS_BODY, headers=_headers("owner"))
            await async_client.put("/document-branding", json={**SETTINGS_BODY, "display_name": "Otro"}, headers=_headers("owner"))
        for call in repo.upsert.await_args_list:
            assert not any(key.startswith("logo") for key in call.args[1])
        repo.set_logo.assert_not_awaited()
        repo.clear_logo.assert_not_awaited()


# ═════════════════════════════════════════════════════════════════════════════
# PUT / DELETE / GET /document-branding/logo
# ═════════════════════════════════════════════════════════════════════════════

def _logo_headers(role="owner", content_type="image/png", **extra):
    return {**_headers(role), "Content-Type": content_type, **extra}


class TestPutLogo:
    async def test_owner_uploads_and_gets_the_normalized_descriptor(self, async_client, api):
        repo, pool, conn = api
        _allow(conn, "owner")
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put("/document-branding/logo", content=_png((2400, 600)), headers=_logo_headers())

        assert resp.status_code == 200, resp.text
        logo = resp.json()["logo"]
        assert (logo["mime"], logo["width"], logo["height"]) == ("image/png", 1000, 250)
        assert len(logo["sha256"]) == 64
        stored = repo.set_logo.await_args.args
        assert stored[0] == ACCOUNT and stored[1].sha256 == logo["sha256"] and stored[2] == TEST_USER_ID

    async def test_admin_can_upload(self, async_client, api):
        repo, pool, conn = api
        _allow(conn, "admin")
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put("/document-branding/logo", content=_png(), headers=_logo_headers("admin"))
        assert resp.status_code == 200

    @pytest.mark.parametrize("role", ["seller", "cashier"])
    async def test_other_roles_get_403_and_the_logo_does_not_change(self, async_client, api, role):
        repo, pool, conn = api
        _allow(conn, role)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put("/document-branding/logo", content=_png(), headers=_logo_headers(role))
        assert resp.status_code == 403
        repo.set_logo.assert_not_awaited()

    async def test_the_declared_content_length_over_2_mib_is_413_without_reading_the_body(self, async_client, api):
        repo, pool, conn = api
        _allow(conn, "owner")
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put(
                "/document-branding/logo", content=b"\x89PNG\r\n\x1a\n" + b"\x00" * (MAX_UPLOAD_BYTES + 10),
                headers=_logo_headers(),
            )
        assert resp.status_code == 413, resp.text
        assert resp.json()["code"] == "branding_logo_too_large"
        repo.set_logo.assert_not_awaited()

    async def test_a_chunked_upload_over_2_mib_is_413_as_soon_as_the_limit_is_crossed(self, async_client, api):
        repo, pool, conn = api
        _allow(conn, "owner")
        chunk = b"\x00" * (256 * 1024)
        sent = {"chunks": 0}

        async def body():
            for _ in range(200):                      # 50 MiB si alguien los leyera todos
                sent["chunks"] += 1
                yield chunk

        with patch("backend.core.database.pool", pool):
            resp = await async_client.put("/document-branding/logo", content=body(), headers=_logo_headers())
        assert resp.status_code == 413
        assert resp.json()["code"] == "branding_logo_too_large"
        repo.set_logo.assert_not_awaited()

    async def test_the_role_guard_runs_before_the_body_is_read(self, async_client, api):
        """Un vendedor que manda un cuerpo enorme recibe 403 sin que el servidor lo lea."""
        repo, pool, conn = api
        _allow(conn, "seller")
        sent = {"chunks": 0}

        async def body():
            for _ in range(200):
                sent["chunks"] += 1
                yield b"\x00" * (256 * 1024)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.put("/document-branding/logo", content=body(), headers=_logo_headers("seller"))
        assert resp.status_code == 403
        assert sent["chunks"] < 10                    # no se leyeron los 50 MiB
        repo.set_logo.assert_not_awaited()

    async def test_an_svg_is_415_even_if_the_content_type_says_png(self, async_client, api):
        repo, pool, conn = api
        _allow(conn, "owner")
        svg = b'<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put("/document-branding/logo", content=svg, headers=_logo_headers(content_type="image/png"))
        assert resp.status_code == 415
        assert resp.json()["code"] == "branding_logo_unsupported_type"
        repo.set_logo.assert_not_awaited()

    async def test_a_decompression_bomb_is_422(self, async_client, api):
        repo, pool, conn = api
        _allow(conn, "owner")
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put("/document-branding/logo", content=_png_declaring(20000, 20000), headers=_logo_headers())
        assert resp.status_code == 422
        assert resp.json()["code"] == "branding_logo_invalid"
        repo.set_logo.assert_not_awaited()

    async def test_corrupt_bytes_are_422(self, async_client, api):
        repo, pool, conn = api
        _allow(conn, "owner")
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put("/document-branding/logo", content=_png()[:200], headers=_logo_headers())
        assert resp.status_code == 422
        assert resp.json()["code"] == "branding_logo_invalid"

    async def test_an_empty_body_is_415(self, async_client, api):
        repo, pool, conn = api
        _allow(conn, "owner")
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put("/document-branding/logo", content=b"", headers=_logo_headers())
        assert resp.status_code == 415

    async def test_it_requires_a_session(self, async_client, api):
        assert (await async_client.put("/document-branding/logo", content=_png())).status_code == 401

    async def test_a_logo_upload_on_an_account_without_a_row_is_a_single_upsert(self, async_client, api):
        """`set_logo` es el que crea la fila (con Neutro) si no existe: el service no hace dos pasos."""
        repo, pool, conn = api
        _allow(conn, "owner")
        with patch("backend.core.database.pool", pool):
            resp = await async_client.put("/document-branding/logo", content=_png(), headers=_logo_headers())
        assert resp.status_code == 200
        repo.set_logo.assert_awaited_once()
        repo.upsert.assert_not_awaited()


class TestDeleteLogo:
    async def test_owner_removes_the_logo_and_it_is_idempotent(self, async_client, api):
        repo, pool, conn = api
        _allow(conn, "owner")
        with patch("backend.core.database.pool", pool):
            first = await async_client.delete("/document-branding/logo", headers=_headers("owner"))
            repo.clear_logo.return_value = 0                                  # ya no había logo
            second = await async_client.delete("/document-branding/logo", headers=_headers("owner"))
        assert first.status_code == 204 and second.status_code == 204
        assert repo.clear_logo.await_args.args == (ACCOUNT, TEST_USER_ID)

    @pytest.mark.parametrize("role", ["seller", "cashier"])
    async def test_other_roles_get_403(self, async_client, api, role):
        repo, pool, conn = api
        _allow(conn, role)
        with patch("backend.core.database.pool", pool):
            resp = await async_client.delete("/document-branding/logo", headers=_headers(role))
        assert resp.status_code == 403
        repo.clear_logo.assert_not_awaited()

    async def test_it_requires_a_session(self, async_client, api):
        assert (await async_client.delete("/document-branding/logo")).status_code == 401


class TestGetLogo:
    async def test_an_account_without_a_logo_is_404_with_a_stable_code(self, async_client, api):
        repo, pool, conn = api
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/document-branding/logo", headers=_headers("seller"))
        assert resp.status_code == 404
        assert resp.json()["code"] == "branding_logo_not_found"
        repo.get_document_logo.assert_awaited_once_with(ACCOUNT)

    async def test_any_member_gets_the_image_with_type_etag_and_private_cache(self, async_client, api):
        repo, pool, conn = api
        stored = normalize_logo(_png())
        repo.get_document_logo.return_value = {"logo_image": stored.data, "logo_mime": stored.mime, "logo_sha256": stored.sha256}
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/document-branding/logo", headers=_headers("viewer"))
        assert resp.status_code == 200
        assert resp.headers["content-type"] == "image/png"
        assert resp.headers["etag"] == f'"{stored.sha256}"'
        assert "private" in resp.headers["cache-control"] and "max-age=86400" in resp.headers["cache-control"]
        assert resp.headers["x-content-type-options"] == "nosniff"
        assert resp.content == stored.data

    async def test_a_matching_if_none_match_is_304_without_a_body(self, async_client, api):
        repo, pool, conn = api
        stored = normalize_logo(_png())
        repo.get_document_logo.return_value = {"logo_image": stored.data, "logo_mime": stored.mime, "logo_sha256": stored.sha256}
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/document-branding/logo", headers=_headers("viewer", **{"If-None-Match": f'"{stored.sha256}"'}))
        assert resp.status_code == 304 and resp.content == b""

    async def test_it_requires_a_session(self, async_client, api):
        assert (await async_client.get("/document-branding/logo")).status_code == 401


def test_all_five_routes_are_registered():
    from backend.main import app
    from backend.tests.conftest import effective_routes

    routes = {(method, route.path) for route in effective_routes(app) for method in route.methods}
    for expected in (("GET", "/document-branding"), ("PUT", "/document-branding"), ("PUT", "/document-branding/logo"),
                     ("DELETE", "/document-branding/logo"), ("GET", "/document-branding/logo")):
        assert expected in routes, expected


# ── helpers de dominio que usa la API ────────────────────────────────────────

@pytest.mark.parametrize("value,ok", [
    ("20123456786", True), ("20-12345678-6", True), ("20111111112", True), ("30712345671", True),
    ("20-12345678-7", False), ("20123456787", False), ("123", False), ("", False), (None, False),
    ("20-1234567-86", False), ("2012345678a", False),
])
def test_is_valid_cuit(value, ok):
    from backend.services.fiscal.comprobante import is_valid_cuit

    assert is_valid_cuit(value) is ok


def test_palette_hex_helpers_round_trip():
    from backend.services.commercial_documents.palette import NEUTRAL, hex_to_rgb, palette_as_hex, resolve_palette, rgb_to_hex

    assert rgb_to_hex((29, 78, 216)) == "#1d4ed8" and hex_to_rgb(rgb_to_hex((9, 0, 255))) == (9, 0, 255)
    neutral = palette_as_hex(NEUTRAL)
    assert neutral["key"] == "neutro" and neutral["accent"] is None
    assert neutral["heading"] == neutral["ink"] == "#1e293b" and neutral["table_head_fill"] == neutral["surface"] == "#f1f5f9"
    azul = palette_as_hex(resolve_palette("azul", None))
    assert azul["accent"] == azul["heading"] == azul["total"] == azul["table_head_fill"] == "#1d4ed8"
    assert azul["table_head_text"] == "#ffffff"
