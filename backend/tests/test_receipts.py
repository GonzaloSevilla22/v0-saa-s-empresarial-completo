"""Tests del generador de PDF del recibo de pago (#4 comprobante)."""
from __future__ import annotations

import datetime
from decimal import Decimal

from backend.services.commercial_documents.branding import DocumentBranding
from backend.services.commercial_documents.issuer import CommercialIssuer
from backend.services.receipts import (
    ReceiptData,
    SalesReceiptData,
    SalesReceiptItem,
    _format_amount,
    build_receipt_pdf,
    build_sales_receipt_pdf,
)
from backend.tests.conftest import make_token


def test_format_amount_ars():
    assert _format_amount(34900, "ARS") == "$ 34.900,00"
    assert _format_amount(Decimal("69900.00"), "ARS") == "$ 69.900,00"
    assert _format_amount(1234567.5, "ARS") == "$ 1.234.567,50"


def test_format_amount_other_currency():
    # Todos los pagos reales son ARS; para otra moneda solo cambia el simbolo.
    assert _format_amount(100, "USD") == "USD 100,00"


def _sample(**overrides) -> ReceiptData:
    base = dict(
        receipt_number="RC-2026-000001",
        issued_at=datetime.date(2026, 6, 13),
        customer_email="cliente@example.com",
        plan="pro",
        amount=Decimal("69900.00"),
        payment_id="163134506523",
    )
    base.update(overrides)
    return ReceiptData(**base)


def test_build_receipt_pdf_returns_valid_pdf_bytes():
    pdf = build_receipt_pdf(_sample())
    assert isinstance(pdf, bytes)
    assert pdf.startswith(b"%PDF")          # firma de archivo PDF
    assert pdf.rstrip().endswith(b"%%EOF")  # cierre de PDF
    assert len(pdf) > 800                    # contenido real, no vacío


def test_build_receipt_pdf_accepts_datetime_and_name():
    pdf = build_receipt_pdf(
        _sample(
            issued_at=datetime.datetime(2026, 6, 13, 16, 33, 40, tzinfo=datetime.timezone.utc),
            customer_name="Roberto Daniel Sevilla",
            plan="avanzado",
            amount=34900,
        )
    )
    assert pdf.startswith(b"%PDF")


def test_build_receipt_pdf_unknown_plan_does_not_crash():
    # Un plan no mapeado debe capitalizarse, no romper.
    pdf = build_receipt_pdf(_sample(plan="enterprise"))
    assert pdf.startswith(b"%PDF")


# ── Comprobante de venta (WhatsApp) ───────────────────────────────────────────

def _sale_sample(**overrides) -> SalesReceiptData:
    base = dict(
        branding=DocumentBranding.neutral(CommercialIssuer(name="Sumar Ropa Deportiva", phone="2617175072")),
        receipt_number="25D8135F",
        date_label="Sabado, 13 de junio de 2026",
        items=[
            SalesReceiptItem(
                name="Calza Melia Talle L Marron",
                quantity="1",
                unit_price=Decimal("40750"),
                subtotal=Decimal("40750"),
            )
        ],
        total=Decimal("40750"),
        currency="ARS",
        client_name="Fiorentini",
    )
    base.update(overrides)
    return SalesReceiptData(**base)


def test_build_sales_receipt_pdf_returns_valid_pdf():
    pdf = build_sales_receipt_pdf(_sale_sample())
    assert pdf.startswith(b"%PDF")
    assert pdf.rstrip().endswith(b"%%EOF")
    assert len(pdf) > 800


def test_build_sales_receipt_pdf_sanitizes_emoji_and_long_name():
    pdf = build_sales_receipt_pdf(
        _sale_sample(
            branding=DocumentBranding.neutral(CommercialIssuer(name="Tienda 😀")),
            client_name=None,
            items=[
                SalesReceiptItem(
                    name="Producto con un nombre larguisimo que excede el ancho de la celda del PDF",
                    quantity="2",
                    unit_price=10,
                    subtotal=20,
                )
            ],
            total=20,
        )
    )
    assert pdf.startswith(b"%PDF")


async def test_sales_receipt_pdf_endpoint_returns_pdf(async_client, receipt_repo):
    """Contrato original (con los campos de negocio del frontend anterior): sigue devolviendo
    el PDF. documentos-marca-empresa: ahora necesita la cuenta, así que usa el repositorio falso."""
    repo, (pool, conn) = receipt_repo
    token = make_token({"role": "user"})
    payload = {
        "business_name": "Sumar Ropa Deportiva",
        "receipt_number": "25D8135F",
        "date_label": "Sabado, 13 de junio de 2026",
        "items": [
            {"name": "Calza Melia", "quantity": "1", "unit_price": "40750", "subtotal": "40750"}
        ],
        "total": "40750",
        "currency": "ARS",
        "client_name": "Fiorentini",
    }
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/sales/receipt-pdf",
            json=payload,
            headers={"Authorization": f"Bearer {token}"},
        )
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "application/pdf"
    assert resp.content.startswith(b"%PDF")


# ══════════════════════════════════════════════════════════════════════════════
# documentos-marca-empresa (tanda A, grupo 7) — el comprobante interno de venta
# lleva la MARCA de la cuenta resuelta en el servidor (nunca el perfil, el avatar
# ni el email de acceso de quien lo descarga), con la paleta de la cuenta.
#
# Strict TDD: escritos antes que `SalesReceiptData.branding`, el nuevo dibujo de
# `build_sales_receipt_pdf` y `services/sales_receipt.py`.
# ══════════════════════════════════════════════════════════════════════════════

import io
import re
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from PIL import Image
from pypdf import PdfReader

from backend.services.commercial_documents.branding import branding_from_rpc, clear_logo_cache
from backend.services.commercial_documents.logo import normalize_logo
from backend.tests.conftest import TEST_ACCOUNT_ID

OLD_GREEN = "0.0627 0.7255 0.5059"       # (16, 185, 129): el EMERALD de hoy

_RPC_EMPTY = {
    "nombre_fantasia": None, "razon_social": None, "cuit": None, "domicilio_comercial": None,
    "business_name": None, "phone": None, "iva_condition": None,
    "brand_display_name": None, "brand_legal_name": None, "brand_tax_id": None, "brand_address": None,
    "brand_phone": None, "brand_email": None, "brand_website": None, "brand_footer_note": None,
    "palette_preset": None, "accent_color": None, "logo_sha256": None,
}


def _logo(size=(400, 100)):
    buf = io.BytesIO()
    Image.new("RGBA", size, (200, 30, 30, 255)).save(buf, "PNG")
    return normalize_logo(buf.getvalue())


def _brand(*, logo=None, **rpc_over):
    raw = {**_RPC_EMPTY, "business_name": "Almacén Don José", "phone": "2615550101", **rpc_over}
    return branding_from_rpc(raw, logo)


def _content(pdf: bytes) -> str:
    return "\n".join(p.get_contents().get_data().decode("latin-1") for p in PdfReader(io.BytesIO(pdf)).pages)


def _text(pdf: bytes) -> str:
    return "\n".join(p.extract_text() for p in PdfReader(io.BytesIO(pdf)).pages)


def _images(pdf: bytes) -> int:
    return sum(len(p.images) for p in PdfReader(io.BytesIO(pdf)).pages)


def _ops(rgb) -> str:
    return " ".join(f"{c / 255:.4f}" for c in rgb)


_TOKEN = re.compile(r"(\bq\b|\bQ\b|[0-9.]+ [0-9.]+ [0-9.]+ rg|\((?:\\.|[^)])*\) Tj)")


def _drawn_texts(content: str) -> list[tuple[str, str]]:
    """(texto, color de relleno `r g b`) de cada `(texto) Tj` del flujo de contenido, respetando
    el alcance `q … Q`: fpdf2 escribe el color dentro del grupo cuando difiere del de relleno y,
    si no, queda el último `rg` global que fijó `set_text_color`."""
    stack: list[str | None] = []
    color: str | None = None
    drawn: list[tuple[str, str]] = []
    for token in _TOKEN.findall(content):
        if token == "q":
            stack.append(color)
        elif token == "Q":
            color = stack.pop() if stack else color
        elif token.endswith(" rg"):
            color = token[:-3]
        else:
            drawn.append((token[1:-4], color or ""))
    return drawn


def _text_color_before(content: str, word: str, *, last: bool = False) -> str:
    """El color con que se dibuja `word` (la primera o, con `last`, la última vez)."""
    matches = [color for text, color in _drawn_texts(content) if text == word]
    assert matches, f"no se encontró {word!r}"
    return matches[-1] if last else matches[0]


class TestSalesReceiptPdfBranding:
    def test_it_carries_the_name_the_logo_the_business_email_and_the_palette(self):
        branding = _brand(logo=_logo(), brand_display_name="Sumar", brand_email="ventas@sumar.com.ar",
                          brand_phone="2615550999", palette_preset="azul")
        pdf = build_sales_receipt_pdf(_sale_sample(branding=branding))

        text = _text(pdf)
        assert "Sumar" in text and "ventas@sumar.com.ar" in text and "Tel: 2615550999" in text
        assert _images(pdf) == 1
        content = _content(pdf)
        assert f"{_ops((29, 78, 216))} rg" in content                       # azul
        assert OLD_GREEN not in content

    def test_without_a_brand_it_is_neutral_and_has_no_green_and_no_image(self):
        pdf = build_sales_receipt_pdf(_sale_sample())
        content = _content(pdf)
        assert OLD_GREEN not in content and _images(pdf) == 0
        assert f"{_ops((30, 41, 59))} rg" in content                          # la tinta de la factura

    @pytest.mark.parametrize("preset", ["azul", "verde", "grafito", "bordo", None])
    def test_no_palette_prints_the_old_green(self, preset):
        pdf = build_sales_receipt_pdf(_sale_sample(branding=_brand(palette_preset=preset)))
        assert OLD_GREEN not in _content(pdf)

    def test_the_title_and_the_total_take_the_accent_and_the_number_stays_in_ink(self):
        content = _content(build_sales_receipt_pdf(_sale_sample(branding=_brand(palette_preset="bordo"))))
        assert _text_color_before(content, "Comprobante de venta") == _ops((159, 18, 57))
        assert _text_color_before(content, "$ 40.750,00  ", last=True) == _ops((159, 18, 57))     # el TOTAL: la última vez
        assert _text_color_before(content, "N° 25D8135F") == _ops((30, 41, 59))

    def test_neutral_prints_title_and_total_in_ink(self):
        content = _content(build_sales_receipt_pdf(_sale_sample()))
        assert _text_color_before(content, "Comprobante de venta") == _ops((30, 41, 59))
        assert _text_color_before(content, "$ 40.750,00  ", last=True) == _ops((30, 41, 59))

    def test_the_account_footer_note_is_printed(self):
        pdf = build_sales_receipt_pdf(_sale_sample(branding=_brand(brand_footer_note="Alias: sumar.ropa")))
        assert "Alias: sumar.ropa" in _text(pdf)

    def test_it_is_still_labeled_as_a_sales_receipt_without_fiscal_validity(self):
        text = " ".join(_text(build_sales_receipt_pdf(_sale_sample())).split())
        assert "Comprobante de venta" in text
        assert "Este documento es su comprobante de venta." in text
        assert "Gracias por su compra" in text

    def test_the_full_identity_of_the_account_is_printed(self):
        branding = _brand(brand_display_name="Kiosco Lola", brand_tax_id="20111111112", brand_address="Calle Marca 123",
                          iva_condition="monotributista")
        text = _text(build_sales_receipt_pdf(_sale_sample(branding=branding)))
        for needle in ("Kiosco Lola", "CUIT: 20-11111111-2", "IVA RESPONSABLE MONOTRIBUTO", "Calle Marca 123"):
            assert needle in text, needle

    def test_the_access_email_is_never_printed(self):
        branding = _brand(email="duenio@example.com", owner_email="duenio@example.com")
        assert "duenio@example.com" not in _text(build_sales_receipt_pdf(_sale_sample(branding=branding)))

    def test_an_em_dash_and_an_euro_sign_survive_in_the_name_and_the_client(self):
        sample = _sale_sample(branding=_brand(brand_display_name="Café — Sabores €"), client_name="Ana — Pérez")
        text = _text(build_sales_receipt_pdf(sample))
        assert "Café — Sabores €" in text and "Ana — Pérez" in text

    def test_a_sale_without_client_says_consumidor_final(self):
        assert "Consumidor final" in _text(build_sales_receipt_pdf(_sale_sample(client_name=None)))

    def test_the_subscription_receipt_keeps_its_own_platform_green_and_name(self):
        """El recibo de suscripción de ALIADATA NO es un papel de la cuenta: marca de plataforma."""
        pdf = build_receipt_pdf(_sample())
        assert OLD_GREEN in _content(pdf)
        assert "ALIADATA" in _text(pdf)


# ── POST /sales/receipt-pdf: la marca se resuelve en el servidor por la cuenta del JWT ──

PAYLOAD = {
    "receipt_number": "25D8135F",
    "date_label": "Sabado, 13 de junio de 2026",
    "items": [{"name": "Calza Melia", "quantity": "1", "unit_price": "40750", "subtotal": "40750"}],
    "total": "40750",
    "currency": "ARS",
    "client_name": "Fiorentini",
}


@pytest.fixture
def receipt_repo(mock_pool):
    from backend.main import app
    from backend.routers.sales import get_repo

    clear_logo_cache()
    repo = AsyncMock()
    repo.get_commercial_issuer.return_value = {**_RPC_EMPTY, "business_name": "Almacén Don José", "phone": "2615550101",
                                              "brand_display_name": "Marca Gate", "brand_email": "ventas@marcagate.test",
                                              "palette_preset": "bordo"}
    app.dependency_overrides[get_repo] = lambda: repo
    try:
        yield repo, mock_pool
    finally:
        app.dependency_overrides.pop(get_repo, None)
        clear_logo_cache()


def _auth():
    return {"Authorization": f"Bearer {make_token({'role': 'user'})}"}


class TestSalesReceiptPdfEndpoint:
    async def test_it_prints_the_account_issuer_not_what_the_browser_sends(self, async_client, receipt_repo):
        repo, (pool, conn) = receipt_repo
        legacy_body = {**PAYLOAD, "business_name": "Otro Nombre", "business_email": "login@example.com",
                       "business_phone": "1111111111"}
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post("/sales/receipt-pdf", json=legacy_body, headers=_auth())

        assert resp.status_code == 200, resp.text
        assert resp.headers["content-type"] == "application/pdf"
        text = _text(resp.content)
        assert "Marca Gate" in text and "ventas@marcagate.test" in text
        assert "Otro Nombre" not in text and "login@example.com" not in text and "1111111111" not in text
        assert OLD_GREEN not in _content(resp.content)
        repo.get_commercial_issuer.assert_awaited_once_with(str(TEST_ACCOUNT_ID))

    async def test_a_payload_without_the_business_fields_is_accepted(self, async_client, receipt_repo):
        repo, (pool, conn) = receipt_repo
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post("/sales/receipt-pdf", json=PAYLOAD, headers=_auth())
        assert resp.status_code == 200 and resp.content.startswith(b"%PDF")

    async def test_an_old_browser_that_sends_only_business_name_still_works(self, async_client, receipt_repo):
        repo, (pool, conn) = receipt_repo
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/sales/receipt-pdf", json={**PAYLOAD, "business_name": "Sumar Ropa Deportiva"}, headers=_auth())
        assert resp.status_code == 200

    async def test_without_a_session_it_is_401(self, async_client, receipt_repo):
        resp = await async_client.post("/sales/receipt-pdf", json=PAYLOAD)
        assert resp.status_code == 401

    async def test_invalid_items_are_still_a_422(self, async_client, receipt_repo):
        repo, (pool, conn) = receipt_repo
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post("/sales/receipt-pdf", json={"receipt_number": "1"}, headers=_auth())
        assert resp.status_code == 422

    async def test_the_file_name_is_safe_whatever_the_number_says(self, async_client, receipt_repo):
        repo, (pool, conn) = receipt_repo
        with patch("backend.core.database.pool", pool):
            ok = await async_client.post("/sales/receipt-pdf", json=PAYLOAD, headers=_auth())
            odd = await async_client.post(
                "/sales/receipt-pdf", json={**PAYLOAD, "receipt_number": 'A"B/../C D'}, headers=_auth())
        assert ok.headers["content-disposition"] == 'inline; filename="comprobante-25D8135F.pdf"'
        assert odd.status_code == 200
        assert odd.headers["content-disposition"] == 'inline; filename="comprobante-ABCD.pdf"'

    async def test_the_logo_is_included_when_the_account_has_one(self, async_client, receipt_repo):
        repo, (pool, conn) = receipt_repo
        stored = _logo()
        repo.get_commercial_issuer.return_value = {**repo.get_commercial_issuer.return_value, "logo_sha256": stored.sha256}
        repo.get_document_logo.return_value = {
            "logo_image": stored.data, "logo_mime": stored.mime, "logo_sha256": stored.sha256}
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post("/sales/receipt-pdf", json=PAYLOAD, headers=_auth())
        assert resp.status_code == 200 and _images(resp.content) == 1

    async def test_the_receipt_is_the_same_for_whoever_downloads_it(self, async_client, receipt_repo):
        """La marca es de la cuenta: no cambia con el perfil del usuario que lo genera."""
        repo, (pool, conn) = receipt_repo
        with patch("backend.core.database.pool", pool):
            first = await async_client.post(
                "/sales/receipt-pdf", json={**PAYLOAD, "business_name": "Vendedor A"},
                headers={"Authorization": f"Bearer {make_token({'role': 'user', 'sub': '11111111-1111-1111-1111-111111111111'})}"})
            second = await async_client.post(
                "/sales/receipt-pdf", json={**PAYLOAD, "business_name": "Vendedor B"}, headers=_auth())
        assert _text(first.content) == _text(second.content)
