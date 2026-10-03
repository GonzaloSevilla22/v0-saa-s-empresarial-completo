"""
presupuestos-modulo (tanda A, grupo 3) — PDF del documento comercial.

Capability `commercial-document-pdf`: un constructor compartido que dibuja una
vista YA resuelta (sin lógica de negocio), el emisor resuelto sin bloquear y el
endpoint `GET /quotes/{id}/pdf` con tenencia. Tres piezas separadas a propósito
(como `factura-fiscal-imprimible`):

  1. `build_quote_view(...)` — función PURA: número, sello por estado (incluido
     el vencido derivado), símbolo de la unidad y leyenda.
  2. `resolve_commercial_issuer(...)` — el emisor sin bloquear (cascada del
     nombre), leído SÓLO de `rpc_commercial_issuer`.
  3. `build_commercial_document_pdf(view)` — el render, leído de vuelta con
     `pypdf`.

Strict TDD: escrito antes que `backend/services/commercial_documents/{view,
issuer,pdf}.py` y que la ruta `GET /quotes/{id}/pdf`.
"""
from __future__ import annotations

import datetime
import io
import re
import uuid
from decimal import Decimal
from unittest.mock import AsyncMock, patch

import pytest
from fastapi import HTTPException
from pypdf import PdfReader

from backend.tests.conftest import TEST_ACCOUNT_ID, make_token

ACCOUNT_ID = str(TEST_ACCOUNT_ID)
QUOTE_ID = "dddddddd-dddd-dddd-dddd-dddddddddddd"
TODAY = datetime.date(2026, 10, 1)


def _quote(**over) -> dict:
    base = {
        "id": QUOTE_ID,
        "account_id": ACCOUNT_ID,
        "status": "sent",
        "number": 12,
        "valid_until": datetime.date(2026, 10, 14),
        # 01:30 UTC del 2 de octubre = 22:30 del 1 de octubre en Argentina
        "created_at": datetime.datetime(2026, 10, 2, 1, 30, tzinfo=datetime.timezone.utc),
        "notes": None,
        "total": Decimal("1800.50"),
        "client_name": "Ana Pérez",
        "client_phone": "2615550000",
        "client_tax_id": "20123456786",
    }
    base.update(over)
    return base


def _line(name="Tornillo", qty="2", price="750", subtotal="1500", unit_symbol=None, **over) -> dict:
    base = {
        "name_snapshot": name,
        "quantity": Decimal(qty),
        "price": Decimal(price),
        "subtotal": Decimal(subtotal),
        "unit_symbol": unit_symbol,
    }
    base.update(over)
    return base


CLIENT = {"name": "Ana Pérez", "tax_id": "20123456786", "phone": "2615550000"}


def _issuer(**over):
    from backend.services.commercial_documents.issuer import CommercialIssuer

    base = {"name": "Almacén Don José", "legal_name": None, "cuit": None, "address": None, "phone": "2615550101"}
    base.update(over)
    return CommercialIssuer(**base)


def _view(quote=None, lines=None, client=None, issuer=None, today=TODAY):
    from backend.services.commercial_documents.view import build_quote_view

    return build_quote_view(
        quote or _quote(), lines if lines is not None else [_line()], client or CLIENT, issuer or _issuer(), today,
    )


def _pdf_text(pdf: bytes) -> str:
    assert pdf.startswith(b"%PDF"), "no es un PDF"
    return "\n".join(page.extract_text() for page in PdfReader(io.BytesIO(pdf)).pages)


def _pages(pdf: bytes) -> list[str]:
    return [page.extract_text() for page in PdfReader(io.BytesIO(pdf)).pages]


# ══════════════════════════════════════════════════════════════════════════════
# 3.1 build_quote_view — función pura
# ══════════════════════════════════════════════════════════════════════════════

class TestBuildQuoteView:
    def test_title_number_and_issue_date_in_argentina(self):
        view = _view()

        assert view.kind == "quote" and view.title == "PRESUPUESTO"
        assert view.number_label == "P-00000012"
        # la fecha de emisión es la del día en Argentina, no la del reloj UTC
        assert view.issued_on == datetime.date(2026, 10, 1)
        assert view.valid_until == datetime.date(2026, 10, 14)
        assert view.show_prices is True
        assert view.total == Decimal("1800.50")

    def test_number_label_of_another_number_and_missing_number(self):
        assert _view(_quote(number=7)).number_label == "P-00000007"
        assert _view(_quote(number=None)).number_label is None

    @pytest.mark.parametrize(
        "status,valid_until,expected",
        [
            ("draft", datetime.date(2026, 10, 20), None),
            ("sent", datetime.date(2026, 10, 1), None),            # vence HOY: todavía válido
            ("sent", datetime.date(2026, 9, 30), "VENCIDO"),       # abierto ya vencido (barrido sin correr)
            ("draft", datetime.date(2026, 9, 1), "VENCIDO"),
            ("expired", datetime.date(2026, 9, 1), "VENCIDO"),
            ("rejected", datetime.date(2026, 10, 20), "RECHAZADO"),
            ("rejected", datetime.date(2026, 9, 1), "RECHAZADO"),  # el rechazo gana sobre la fecha
            ("accepted", datetime.date(2026, 9, 1), "ACEPTADO"),   # convertido: no es "vencido"
            ("accepted", datetime.date(2026, 10, 20), "ACEPTADO"),
        ],
    )
    def test_status_stamp(self, status, valid_until, expected):
        assert _view(_quote(status=status, valid_until=valid_until)).status_stamp == expected

    def test_stamp_for_an_open_quote_without_validity(self):
        assert _view(_quote(status="sent", valid_until=None)).status_stamp is None

    @pytest.mark.parametrize(
        "qty,symbol,expected",
        [
            ("2.0000", None, "2"),
            ("2", "kg", "2 kg"),
            ("0.5000", "kg", "0,5 kg"),
            ("0.1250", "kg", "0,125 kg"),
            ("1250", "g", "1.250 g"),
            ("3", "u", "3 u"),
        ],
    )
    def test_quantity_label_with_the_unit_symbol(self, qty, symbol, expected):
        view = _view(lines=[_line(qty=qty, unit_symbol=symbol)])
        assert view.lines[0].quantity_label == expected

    def test_line_keeps_the_exact_unit_price_and_the_snapshot_name(self):
        view = _view(lines=[_line(name="Harina 000", qty="100", price="4.575", subtotal="457.50", unit_symbol="g")])

        line = view.lines[0]
        assert line.description == "Harina 000"
        assert line.unit_price == Decimal("4.575")  # RN-24-bis: sin redondear
        assert line.subtotal == Decimal("457.50")

    def test_service_line_description_and_missing_snapshot(self):
        view = _view(lines=[_line(name="Instalación", product_id=None), _line(name=None)])
        assert view.lines[0].description == "Instalación"
        assert view.lines[1].description  # nunca vacío

    def test_legend_with_and_without_validity(self):
        with_validity = _view(_quote(valid_until=datetime.date(2026, 10, 14)))
        assert with_validity.legend == (
            "Presupuesto — documento no válido como factura. Precios válidos hasta el 14/10/2026."
        )
        without = _view(_quote(valid_until=None))
        assert without.legend == "Presupuesto — documento no válido como factura."

    def test_recipient_and_notes(self):
        view = _view(_quote(notes="Entrega en 48 hs"))

        assert view.recipient.name == "Ana Pérez"
        assert view.recipient.tax_id == "20123456786"
        assert view.recipient.phone == "2615550000"
        assert view.notes == "Entrega en 48 hs"

    def test_quote_without_client(self):
        view = _view(client={"name": None, "tax_id": None, "phone": None})
        assert view.recipient.name == "Sin cliente"

    def test_the_view_is_immutable(self):
        view = _view()
        with pytest.raises(Exception):
            view.title = "OTRA COSA"  # type: ignore[misc]


# ══════════════════════════════════════════════════════════════════════════════
# 3.1 resolve_commercial_issuer — sin bloquear, sólo desde la RPC
# ══════════════════════════════════════════════════════════════════════════════

RAW_FULL = {
    "nombre_fantasia": "Sumar",
    "razon_social": "PEREZ MARIA LAURA",
    "cuit": "20123456786",
    "domicilio_comercial": "Av. San Martín 1234, Mendoza",
    "business_name": "Almacén Don José",
    "phone": "2615550101",
}


class TestResolveCommercialIssuer:
    @pytest.mark.asyncio
    async def test_complete_fiscal_profile(self):
        from backend.services.commercial_documents.issuer import resolve_commercial_issuer

        repo = AsyncMock()
        repo.get_commercial_issuer.return_value = dict(RAW_FULL)

        issuer = await resolve_commercial_issuer(repo, ACCOUNT_ID)

        assert issuer.name == "Sumar"
        assert issuer.legal_name == "PEREZ MARIA LAURA"
        assert issuer.cuit == "20123456786"
        assert issuer.address == "Av. San Martín 1234, Mendoza"
        assert issuer.phone == "2615550101"
        repo.get_commercial_issuer.assert_awaited_once_with(ACCOUNT_ID)

    @pytest.mark.asyncio
    @pytest.mark.parametrize(
        "raw,expected_name",
        [
            (RAW_FULL, "Sumar"),                                                         # fantasía
            ({**RAW_FULL, "nombre_fantasia": None}, "PEREZ MARIA LAURA"),                # razón social
            ({**RAW_FULL, "nombre_fantasia": "  ", "razon_social": ""}, "Almacén Don José"),  # negocio del dueño
            ({"nombre_fantasia": None, "razon_social": None, "cuit": None, "domicilio_comercial": None,
              "business_name": None, "phone": None}, "Mi Negocio"),                      # último recurso
        ],
    )
    async def test_name_cascade(self, raw, expected_name):
        from backend.services.commercial_documents.issuer import resolve_commercial_issuer

        repo = AsyncMock()
        repo.get_commercial_issuer.return_value = raw

        assert (await resolve_commercial_issuer(repo, ACCOUNT_ID)).name == expected_name

    @pytest.mark.asyncio
    async def test_account_without_fiscal_profile_never_blocks(self):
        """Un dato faltante se omite: ni CUIT ni domicilio, pero hay documento."""
        from backend.services.commercial_documents.issuer import resolve_commercial_issuer

        repo = AsyncMock()
        repo.get_commercial_issuer.return_value = {
            "nombre_fantasia": None, "razon_social": None, "cuit": None, "domicilio_comercial": None,
            "business_name": "Almacén Don José", "phone": "2615550101",
        }

        issuer = await resolve_commercial_issuer(repo, ACCOUNT_ID)

        assert issuer.name == "Almacén Don José"
        assert issuer.legal_name is None and issuer.cuit is None and issuer.address is None

    @pytest.mark.asyncio
    async def test_empty_rpc_answer_degrades_to_the_default_name(self):
        from backend.services.commercial_documents.issuer import resolve_commercial_issuer

        repo = AsyncMock()
        repo.get_commercial_issuer.return_value = None

        issuer = await resolve_commercial_issuer(repo, ACCOUNT_ID)

        assert issuer.name == "Mi Negocio"

    @pytest.mark.asyncio
    async def test_the_same_issuer_for_whoever_downloads(self):
        """El emisor viene de la RPC por cuenta, no del perfil de quien
        descarga: el service sólo la llama con el id de la cuenta, y la RPC
        (definer) devuelve el perfil DEL DUEÑO aunque descargue un vendedor."""
        from backend.services.commercial_documents.issuer import resolve_commercial_issuer

        repo = AsyncMock()
        repo.get_commercial_issuer.return_value = {
            "nombre_fantasia": None, "razon_social": None, "cuit": None, "domicilio_comercial": None,
            "business_name": "Almacén Don José", "phone": "2615550101",
        }

        issuer = await resolve_commercial_issuer(repo, ACCOUNT_ID)

        assert issuer.name == "Almacén Don José" and issuer.phone == "2615550101"
        assert [call[0] for call in repo.method_calls] == ["get_commercial_issuer"]

    def test_the_issuer_never_carries_an_email(self):
        """El email de acceso del dueño no se imprime en un documento para
        terceros: el emisor no tiene ese campo."""
        from backend.services.commercial_documents.issuer import CommercialIssuer

        assert "email" not in {f for f in CommercialIssuer.__dataclass_fields__}


# ══════════════════════════════════════════════════════════════════════════════
# 3.1 build_commercial_document_pdf — leído con pypdf
# ══════════════════════════════════════════════════════════════════════════════

def _pdf(view) -> bytes:
    from backend.services.commercial_documents.pdf import build_commercial_document_pdf

    return build_commercial_document_pdf(view)


class TestBuildCommercialDocumentPdf:
    def test_one_page_quote_has_title_number_client_lines_total_and_legend(self):
        view = _view(
            _quote(total=Decimal("1800.50"), notes="Entrega en 48 hs"),
            lines=[
                _line("Tornillo", "2", "750", "1500"),
                _line("Instalación", "1", "300.50", "300.50"),
                _line("Pintura", "3", "100", "300", unit_symbol="u"),
            ],
        )

        pdf = _pdf(view)
        text = _pdf_text(pdf)

        assert len(PdfReader(io.BytesIO(pdf)).pages) == 1
        assert "PRESUPUESTO" in text
        assert "P-00000012" in text
        assert "Ana Pérez" in text
        for name in ("Tornillo", "Instalación", "Pintura"):
            assert name in text
        assert "$ 1.800,50" in text
        assert "Entrega en 48 hs" in text
        assert "no válido como factura" in text
        assert "Precios válidos hasta el 14/10/2026." in text
        assert "Almacén Don José" in text

    def test_issuer_with_fiscal_data_prints_it_and_without_omits_it(self):
        full = _pdf_text(_pdf(_view(issuer=_issuer(
            name="Sumar", legal_name="PEREZ MARIA LAURA", cuit="20123456786", address="Av. San Martín 1234, Mendoza"))))
        assert "Sumar" in full and "PEREZ MARIA LAURA" in full
        assert "CUIT" in full and "20123456786" in full
        assert "Av. San Martín 1234, Mendoza" in full

        bare = _pdf_text(_pdf(_view(issuer=_issuer(name="Mi Negocio", phone=None))))
        assert "Mi Negocio" in bare
        assert "CUIT" not in bare.split("Ana")[0]  # sin CUIT del emisor (el del cliente va aparte)

    def test_the_legend_prints_its_em_dash(self):
        text = _pdf_text(_pdf(_view()))
        assert "Presupuesto — documento no válido como factura." in " ".join(text.split())

    def test_no_validity_no_validity_sentence(self):
        text = _pdf_text(_pdf(_view(_quote(valid_until=None))))
        assert "no válido como factura" in text
        assert "Precios válidos hasta" not in text

    @pytest.mark.parametrize("stamp_status,stamp_until,word", [
        ("sent", datetime.date(2026, 9, 1), "VENCIDO"),
        ("rejected", datetime.date(2026, 10, 20), "RECHAZADO"),
        ("accepted", datetime.date(2026, 10, 20), "ACEPTADO"),
    ])
    def test_status_stamp_is_printed(self, stamp_status, stamp_until, word):
        text = _pdf_text(_pdf(_view(_quote(status=stamp_status, valid_until=stamp_until))))
        assert word in text

    def test_open_valid_quote_has_no_stamp(self):
        text = _pdf_text(_pdf(_view(_quote(status="sent"))))
        for word in ("VENCIDO", "RECHAZADO", "ACEPTADO"):
            assert word not in text

    def test_eighty_lines_paginate_and_every_page_repeats_the_table_header(self):
        lines = [_line(f"Artículo {i:03d}", "1", "10", "10") for i in range(80)]
        pdf = _pdf(_view(_quote(total=Decimal("800")), lines=lines))

        pages = _pages(pdf)

        assert len(pages) >= 2, "80 líneas deben ocupar más de una página"
        for number, page in enumerate(pages, start=1):
            assert "Descripción" in page, f"la página {number} no repite la cabecera de la tabla"
        everything = "\n".join(pages)
        assert "Artículo 000" in everything and "Artículo 079" in everything
        assert "$ 800,00" in pages[-1], "el total va al final"

    def test_emoji_is_substituted_instead_of_failing(self):
        pdf = _pdf(_view(lines=[_line("Torta de cumpleaños 🎂", "1", "100", "100")]))

        text = _pdf_text(pdf)

        assert "Torta de cumpleaños" in text
        assert "🎂" not in text

    def test_sub_cent_unit_price_keeps_its_decimals_and_the_subtotal_is_to_the_cent(self):
        pdf = _pdf(_view(
            _quote(total=Decimal("457.50")),
            lines=[_line("Harina 000", "100", "4.575", "457.50", unit_symbol="g")],
        ))

        text = _pdf_text(pdf)

        assert "$ 4,575" in text
        assert "$ 457,50" in text
        assert "100 g" in text

    def test_long_description_wraps_instead_of_overflowing(self):
        name = "Perfil de aluminio anodizado natural reforzado para cerramientos de gran luz " * 3
        pdf = _pdf(_view(lines=[_line(name.strip(), "1", "100", "100")]))

        text = " ".join(_pdf_text(pdf).split())

        assert "cerramientos de gran luz" in text
        assert "$ 100,00" in text

    def test_document_without_any_issuer_data_is_still_generated(self):
        from backend.services.commercial_documents.issuer import CommercialIssuer

        bare = CommercialIssuer(name="Mi Negocio", legal_name=None, cuit=None, address=None, phone=None)
        pdf = _pdf(_view(issuer=bare))
        assert "Mi Negocio" in _pdf_text(pdf)

    def test_hidden_prices_option_omits_the_price_columns(self):
        """`show_prices` es la opción que el remito necesita: el presupuesto
        siempre muestra precios, pero el render la respeta."""
        import dataclasses

        view = dataclasses.replace(_view(lines=[_line("Tornillo", "2", "750", "1500")]), show_prices=False)

        text = _pdf_text(_pdf(view))

        assert "Tornillo" in text
        assert "$ 750,00" not in text and "$ 1.500,00" not in text


# ══════════════════════════════════════════════════════════════════════════════
# service get_quote_pdf y endpoint GET /quotes/{id}/pdf
# ══════════════════════════════════════════════════════════════════════════════

def _record(**over) -> dict:
    base = {**_quote(), "is_expired": False, "revision": 1, "items": [_line()], "history": [],
            "branch_id": None, "client_id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
            "created_by": "11111111-1111-1111-1111-111111111111"}
    base.update(over)
    return base


def _repo(record=None) -> AsyncMock:
    repo = AsyncMock()
    repo.get_quote.return_value = _record() if record is None else record
    repo.get_commercial_issuer.return_value = dict(RAW_FULL)
    return repo


class TestGetQuotePdfService:
    @pytest.mark.asyncio
    async def test_returns_the_pdf_and_the_file_name(self):
        from backend.services import quotes as svc

        repo = _repo()

        pdf, filename = await svc.get_quote_pdf(repo, ACCOUNT_ID, QUOTE_ID, today=TODAY)

        assert filename == "presupuesto-P-00000012.pdf"
        text = _pdf_text(pdf)
        assert "P-00000012" in text and "Ana Pérez" in text and "Sumar" in text
        # el contenido sale de la base por la cuenta del caller, nunca del request
        repo.get_quote.assert_awaited_once_with(QUOTE_ID, ACCOUNT_ID)
        repo.get_commercial_issuer.assert_awaited_once_with(ACCOUNT_ID)

    @pytest.mark.asyncio
    async def test_missing_or_foreign_quote_is_the_same_404(self):
        from backend.services import quotes as svc

        repo = _repo()
        repo.get_quote.return_value = None

        with pytest.raises(HTTPException) as info:
            await svc.get_quote_pdf(repo, ACCOUNT_ID, QUOTE_ID, today=TODAY)

        assert (info.value.status_code, info.value.code) == (404, "quote_not_found")

    @pytest.mark.asyncio
    async def test_file_name_without_number_falls_back_to_the_id(self):
        from backend.services import quotes as svc

        _, filename = await svc.get_quote_pdf(_repo(_record(number=None)), ACCOUNT_ID, QUOTE_ID, today=TODAY)

        assert filename == "presupuesto-dddddddd.pdf"

    @pytest.mark.asyncio
    async def test_any_state_can_be_downloaded_with_its_stamp(self):
        from backend.services import quotes as svc

        for status, word in (("rejected", "RECHAZADO"), ("accepted", "ACEPTADO"), ("expired", "VENCIDO")):
            pdf, _ = await svc.get_quote_pdf(_repo(_record(status=status)), ACCOUNT_ID, QUOTE_ID, today=TODAY)
            assert word in _pdf_text(pdf), status

    @pytest.mark.asyncio
    async def test_uses_the_argentine_business_day_when_today_is_not_given(self):
        from backend.core import timezone
        from backend.services import quotes as svc

        # 02:00 UTC del 2/10 = 23:00 ART del 1/10: una validez al 1/10 sigue vigente
        frozen = datetime.datetime(2026, 10, 2, 2, 0, tzinfo=datetime.timezone.utc)
        with patch.object(timezone, "_utcnow", return_value=frozen):
            pdf, _ = await svc.get_quote_pdf(
                _repo(_record(status="sent", valid_until=datetime.date(2026, 10, 1))), ACCOUNT_ID, QUOTE_ID)

        assert "VENCIDO" not in _pdf_text(pdf)


def _headers(*roles: str) -> dict:
    return {"Authorization": f"Bearer {make_token({'app_metadata': {'account_roles': list(roles)}})}"}


@pytest.fixture
def repo_override(mock_pool):
    from backend.main import app
    from backend.routers.quotes import get_quote_repo

    repo = _repo()
    app.dependency_overrides[get_quote_repo] = lambda: repo
    try:
        yield repo, mock_pool
    finally:
        app.dependency_overrides.pop(get_quote_repo, None)


class TestPdfEndpoint:
    async def test_inline_by_default(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(f"/quotes/{QUOTE_ID}/pdf", headers=_headers("seller"))

        assert resp.status_code == 200, resp.text
        assert resp.headers["content-type"] == "application/pdf"
        assert resp.headers["content-disposition"] == 'inline; filename="presupuesto-P-00000012.pdf"'
        assert "no-store" in resp.headers["cache-control"]
        assert resp.content.startswith(b"%PDF")

    async def test_attachment(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/quotes/{QUOTE_ID}/pdf?disposition=attachment", headers=_headers("seller"))

        assert resp.status_code == 200
        assert resp.headers["content-disposition"] == 'attachment; filename="presupuesto-P-00000012.pdf"'

    async def test_any_member_can_download_even_a_cashier(self, async_client, repo_override):
        """Lectura libre para cualquier miembro: el PDF no exige CAN_QUOTE."""
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(f"/quotes/{QUOTE_ID}/pdf", headers=_headers("cashier"))

        assert resp.status_code == 200

    async def test_foreign_and_missing_quotes_get_the_same_404(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        repo.get_quote.return_value = None
        with patch("backend.core.database.pool", pool):
            foreign = await async_client.get(f"/quotes/{QUOTE_ID}/pdf", headers=_headers("seller"))
            missing = await async_client.get(f"/quotes/{uuid.uuid4()}/pdf", headers=_headers("seller"))

        assert foreign.status_code == missing.status_code == 404
        assert foreign.json() == missing.json()
        assert foreign.json()["code"] == "quote_not_found"
        assert foreign.headers["content-type"].startswith("application/problem+json")

    async def test_invalid_disposition_is_422(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/quotes/{QUOTE_ID}/pdf?disposition=download", headers=_headers("seller"))

        assert resp.status_code == 422
        repo.get_quote.assert_not_awaited()

    async def test_non_uuid_id_is_422(self, async_client, repo_override):
        repo, (pool, conn) = repo_override
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/quotes/no-es-un-uuid/pdf", headers=_headers("seller"))
        assert resp.status_code == 422

    async def test_without_a_session_it_is_401(self, async_client, repo_override):
        resp = await async_client.get(f"/quotes/{QUOTE_ID}/pdf")
        assert resp.status_code == 401


# ══════════════════════════════════════════════════════════════════════════════
# remitos-venta (tanda A, grupo 3) — el remito sobre el MISMO constructor
#
# Strict TDD: escritos antes que `build_delivery_note_view`, que los campos
# aditivos `signature_block` / `origin_label` de la vista y que su dibujo en el
# render. Los casos de presupuesto de arriba NO se tocan: son el safety net de
# que el cambio es aditivo.
# ══════════════════════════════════════════════════════════════════════════════

def _dn(**over) -> dict:
    base = {
        "id": "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
        "account_id": ACCOUNT_ID,
        "direction": "sale",
        "status": "issued",
        "number": 12,
        "issued_on": datetime.date(2026, 10, 2),
        "delivery_address": "San Martín 123, Mendoza",
        "notes": None,
        "total": Decimal("1800.50"),
    }
    base.update(over)
    return base


BRANCH = {"name": "Sucursal Centro"}


def _dn_view(dn=None, lines=None, client=None, branch=None, issuer=None, show_prices=False, today=TODAY):
    from backend.services.commercial_documents.view import build_delivery_note_view

    return build_delivery_note_view(
        dn or _dn(),
        lines if lines is not None else [_line("Tornillo", "2", "750", "1500", unit_symbol="kg")],
        client or CLIENT,
        branch or BRANCH,
        issuer or _issuer(),
        show_prices,
        today,
    )


class TestBuildDeliveryNoteView:
    def test_title_number_origin_and_date(self):
        view = _dn_view()

        assert view.kind == "delivery_note" and view.title == "REMITO"
        assert view.number_label == "R-00000012"
        assert view.issued_on == datetime.date(2026, 10, 2)
        assert view.valid_until is None
        assert view.origin_label == "Sale de: Sucursal Centro"
        assert view.signature_block is True

    def test_prices_are_hidden_by_default_and_shown_on_request(self):
        assert _dn_view().show_prices is False
        assert _dn_view(show_prices=True).show_prices is True

    def test_the_legend_is_the_delivery_note_one(self):
        assert _dn_view().legend == "Remito — documento no válido como factura."

    def test_the_delivery_address_is_the_recipients_address(self):
        view = _dn_view()
        assert view.recipient.address == "San Martín 123, Mendoza"
        assert view.recipient.name == "Ana Pérez" and view.recipient.phone == "2615550000"
        assert _dn_view(_dn(delivery_address=None)).recipient.address is None
        assert _dn_view(_dn(delivery_address="   ")).recipient.address is None

    @pytest.mark.parametrize("status,stamp", [("issued", None), ("converted", None), ("canceled", "ANULADO")])
    def test_only_a_canceled_note_is_stamped(self, status, stamp):
        assert _dn_view(_dn(status=status)).status_stamp == stamp

    def test_lines_carry_quantity_with_unit_symbol(self):
        view = _dn_view(lines=[_line("Harina", "0.45", "1000", "450", unit_symbol="kg"), _line("Tornillo", "3", "10", "30")])
        assert [(l.description, l.quantity_label) for l in view.lines] == [("Harina", "0,45 kg"), ("Tornillo", "3")]

    def test_number_label_follows_the_direction_not_a_fixed_prefix(self):
        assert _dn_view(_dn(number=7)).number_label == "R-00000007"
        assert _dn_view(_dn(number=None)).number_label is None

    def test_total_and_notes_are_carried(self):
        view = _dn_view(_dn(notes="Dejar con el encargado", total=Decimal("99.90")))
        assert view.total == Decimal("99.90") and view.notes == "Dejar con el encargado"

    def test_a_branch_without_name_has_no_origin_label(self):
        assert _dn_view(branch={"name": None}).origin_label is None


class TestQuoteViewIsUnchangedByTheAdditiveFields:
    def test_quote_defaults(self):
        view = _view()
        assert view.signature_block is False and view.origin_label is None

    def test_quote_pdf_has_no_signature_block_nor_origin(self):
        text = _pdf_text(_pdf(_view()))
        assert "Recibí conforme" not in text and "Sale de:" not in text
        assert "Firma" not in text and "Aclaración" not in text


def _flat(text: str) -> str:
    return " ".join(text.split())


class TestBuildDeliveryNotePdf:
    def test_default_pdf_has_the_required_content_and_no_prices(self):
        pdf = _pdf(_dn_view(_dn(notes="Dejar con el encargado")))
        text = _pdf_text(pdf)
        flat = _flat(text)

        assert len(PdfReader(io.BytesIO(pdf)).pages) == 1
        assert "REMITO" in text and "R-00000012" in text
        assert "Sale de: Sucursal Centro" in flat
        assert "Ana Pérez" in text and "San Martín 123, Mendoza" in flat
        assert "Tornillo" in text and "2 kg" in flat
        assert "02/10/2026" in text
        assert "Dejar con el encargado" in text
        for word in ("Recibí conforme", "Firma", "Aclaración", "DNI", "Fecha"):
            assert word in flat, word
        assert "Remito — documento no válido como factura." in flat
        # sin precios: ni columnas, ni importes, ni total
        assert "$" not in text and "TOTAL" not in text and "P. unit." not in text and "Subtotal" not in text

    def test_with_prices_the_unit_price_subtotal_and_total_are_printed(self):
        text = _pdf_text(_pdf(_dn_view(show_prices=True)))
        assert "$ 750,00" in text and "$ 1.500,00" in text
        assert "TOTAL" in text and "$ 1.800,50" in text
        assert "P. unit." in text and "Subtotal" in text

    def test_a_canceled_note_carries_the_stamp_and_an_issued_one_does_not(self):
        assert "ANULADO" in _pdf_text(_pdf(_dn_view(_dn(status="canceled"))))
        for status in ("issued", "converted"):
            assert "ANULADO" not in _pdf_text(_pdf(_dn_view(_dn(status=status)))), status

    def test_a_note_without_delivery_address_or_origin_is_still_generated(self):
        text = _pdf_text(_pdf(_dn_view(_dn(delivery_address=None), branch={"name": None})))
        assert "REMITO" in text and "Sale de:" not in text and "Recibí conforme" in text

    @pytest.mark.parametrize("count", [1, 12, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 80])
    def test_the_signature_block_never_splits_across_pages(self, count):
        """Con cualquier cantidad de líneas el bloque de firma queda ENTERO en
        una página (si no entra, pasa completo a la siguiente), y el pie con la
        leyenda está en todas."""
        lines = [_line(f"Artículo {i:03d}", "1", "10", "10") for i in range(count)]
        pages = _pages(_pdf(_dn_view(lines=lines)))
        words = ("Recibí conforme", "Firma", "Aclaración", "DNI")

        holders = [n for n, page in enumerate(pages) if "Recibí conforme" in page]
        assert len(holders) == 1, f"el bloque de firma aparece {len(holders)} veces"
        page = _flat(pages[holders[0]])
        for word in words:
            assert word in page, f"{word!r} quedó en otra página que 'Recibí conforme' (líneas={count})"
        for number, text in enumerate(pages, start=1):
            assert "no válido como factura" in _flat(text), f"la página {number} perdió la leyenda"
        everything = "\n".join(pages)
        assert "Artículo 000" in everything and f"Artículo {count - 1:03d}" in everything

    def test_eighty_lines_without_prices_repeat_the_table_header(self):
        lines = [_line(f"Artículo {i:03d}", "1", "10", "10") for i in range(80)]
        pages = _pages(_pdf(_dn_view(lines=lines)))
        assert len(pages) >= 2
        for number, page in enumerate(pages, start=1):
            assert "Descripción" in page and "Cant." in page, f"la página {number} no repite la cabecera"

    def test_quantity_label_keeps_the_unit_for_fractional_quantities(self):
        text = _pdf_text(_pdf(_dn_view(lines=[_line("Harina 000", "0.45", "1000", "450", unit_symbol="kg")])))
        assert "0,45 kg" in _flat(text)
