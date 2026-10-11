"""
documentos-marca-empresa — task 5.5: el encabezado de emisor compartido
(`commercial_documents/header.py`), que reemplaza a los tres encabezados
dibujados a mano (comprobante interno, presupuesto/remito y Factura C).

  - el alto MEDIDO es igual al alto DIBUJADO (la factura de la tanda B crece
    según lo que mide);
  - con logo, el nombre empieza DEBAJO del logo; sin logo, arriba;
  - ningún texto sale del ancho de la columna (nombre largo, email largo, una
    palabra sin espacios);
  - el logo nunca se deforma y entra en su caja.

Run: python -m pytest backend/tests/test_document_header.py -q -p no:cacheprovider
"""
from __future__ import annotations

import io

import pytest
from fpdf import FPDF
from PIL import Image
from pypdf import PdfReader

from backend.services.commercial_documents.header import (
    NAME_LINE_HEIGHT,
    HeaderLine,
    IssuerBlock,
    draw_issuer_column,
    issuer_block,
    layout_issuer_column,
    measure_issuer_column,
)
from backend.services.commercial_documents.issuer import CommercialIssuer
from backend.services.commercial_documents.logo import LogoImage, normalize_logo
from backend.services.commercial_documents.palette import NEUTRAL, resolve_palette

WIDTH = 105.0
LOGO_BOX = (50.0, 18.0)


def _png(size, color=(200, 30, 30, 255)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGBA", size, color).save(buf, "PNG")
    return buf.getvalue()


def _logo(size=(400, 100)) -> LogoImage:
    return normalize_logo(_png(size))


def _pdf() -> FPDF:
    pdf = FPDF(orientation="P", unit="mm", format="A4")
    pdf.set_margins(18, 18, 18)
    pdf.add_page()
    return pdf


def _issuer(**over) -> CommercialIssuer:
    base = dict(
        name="Sumar", legal_name="Ropa Deportiva SRL", cuit="20-12345678-6", address="Av. San Martín 1234, Mendoza",
        phone="2615550101", iva_legend="IVA RESPONSABLE MONOTRIBUTO", email="ventas@sumar.com.ar", website="sumar.com.ar",
    )
    base.update(over)
    return CommercialIssuer(**base)


def _full_text(pdf: FPDF) -> str:
    return "\n".join(p.extract_text() for p in PdfReader(io.BytesIO(bytes(pdf.output()))).pages)


# ── issuer_block: qué líneas se imprimen y en qué orden ──────────────────────

def test_issuer_block_lists_the_lines_in_the_documented_order():
    block = issuer_block(_issuer(), None)
    assert block.name == "Sumar"
    assert [line.text for line in block.lines] == [
        "Ropa Deportiva SRL", "CUIT: 20-12345678-6", "IVA RESPONSABLE MONOTRIBUTO",
        "Av. San Martín 1234, Mendoza", "Tel: 2615550101", "ventas@sumar.com.ar", "sumar.com.ar",
    ]


def test_the_iva_legend_is_the_only_bold_line():
    block = issuer_block(_issuer(), None)
    assert [line.text for line in block.lines if line.bold] == ["IVA RESPONSABLE MONOTRIBUTO"]


def test_the_legal_name_is_omitted_when_it_is_the_name_ignoring_case():
    assert [l.text for l in issuer_block(_issuer(name="Ropa Deportiva SRL"), None).lines][0] == "CUIT: 20-12345678-6"
    assert "ROPA DEPORTIVA SRL" not in [l.text for l in issuer_block(_issuer(name="ropa deportiva srl", legal_name="ROPA DEPORTIVA SRL"), None).lines]


def test_missing_data_is_omitted_not_printed_empty():
    block = issuer_block(CommercialIssuer(name="Mi Negocio"), None)
    assert block.name == "Mi Negocio" and block.lines == ()


def test_the_block_carries_the_logo():
    logo = _logo()
    assert issuer_block(_issuer(), logo).logo is logo


# ── layout: logo arriba, nombre debajo ───────────────────────────────────────

def test_with_a_logo_the_name_starts_below_the_logo():
    pdf = _pdf()
    layout = layout_issuer_column(pdf, 18, 20, WIDTH, issuer_block(_issuer(), _logo((400, 100))), LOGO_BOX)
    assert layout.logo_rect is not None
    lx, ly, lw, lh = layout.logo_rect
    assert (lx, ly) == (18, 20)
    assert layout.name_y >= ly + lh
    assert layout.name_y == pytest.approx(ly + lh + 2.0)


def test_without_a_logo_the_name_starts_at_the_top():
    pdf = _pdf()
    layout = layout_issuer_column(pdf, 18, 20, WIDTH, issuer_block(_issuer(), None), LOGO_BOX)
    assert layout.logo_rect is None
    assert layout.name_y == 20


@pytest.mark.parametrize("size", [(400, 100), (100, 400), (200, 200), (1000, 120), (60, 60)])
def test_the_logo_is_never_deformed_and_always_fits_the_box(size):
    pdf = _pdf()
    layout = layout_issuer_column(pdf, 18, 20, WIDTH, issuer_block(_issuer(), _logo(size)), LOGO_BOX)
    _, _, lw, lh = layout.logo_rect
    assert lw <= LOGO_BOX[0] + 1e-9 and lh <= LOGO_BOX[1] + 1e-9
    assert lw / lh == pytest.approx(size[0] / size[1], rel=0.01)


# ── medido == dibujado ───────────────────────────────────────────────────────

@pytest.mark.parametrize("with_logo", [False, True])
@pytest.mark.parametrize(
    "issuer",
    [
        _issuer(),
        CommercialIssuer(name="Mi Negocio"),
        _issuer(name="Una razón comercial extremadamente larga que obliga a partir el nombre en varios renglones del encabezado",
                email="un.correo.electronico.realmente.largo.del.negocio@dominio-muy-largo-de-ejemplo.com.ar"),
        _issuer(address="Calle con un domicilio larguísimo, entre calles, barrio, departamento 4 piso 3 oficina 12, Mendoza, Argentina"),
    ],
    ids=["completo", "solo-nombre", "nombre-y-email-largos", "domicilio-largo"],
)
def test_measured_height_equals_drawn_height(issuer, with_logo):
    pdf = _pdf()
    block = issuer_block(issuer, _logo((300, 120)) if with_logo else None)
    y0 = 25.0
    measured = measure_issuer_column(pdf, WIDTH, block, LOGO_BOX)
    pdf.set_xy(18, y0)
    bottom = draw_issuer_column(pdf, 18, y0, WIDTH, block, NEUTRAL, LOGO_BOX)
    assert bottom - y0 == pytest.approx(measured)
    assert measured > 0


def test_measuring_does_not_change_the_pdf_state():
    pdf = _pdf()
    pdf.set_font("Helvetica", "I", 7)
    pdf.set_text_color(1, 2, 3)
    before = (pdf.font_family, pdf.font_style, pdf.font_size_pt, pdf.get_x(), pdf.get_y())
    measure_issuer_column(pdf, WIDTH, issuer_block(_issuer(), _logo()), LOGO_BOX)
    layout_issuer_column(pdf, 18, 20, WIDTH, issuer_block(_issuer(), None), LOGO_BOX)
    assert (pdf.font_family, pdf.font_style, pdf.font_size_pt, pdf.get_x(), pdf.get_y()) == before


def test_a_logo_makes_the_column_taller_by_the_logo_plus_the_gap():
    pdf = _pdf()
    without = measure_issuer_column(pdf, WIDTH, issuer_block(_issuer(), None), LOGO_BOX)
    layout = layout_issuer_column(pdf, 18, 0, WIDTH, issuer_block(_issuer(), _logo((400, 100))), LOGO_BOX)
    assert layout.height == pytest.approx(without + layout.logo_rect[3] + 2.0)


# ── nada sale del ancho de la columna ────────────────────────────────────────

def test_no_wrapped_line_is_wider_than_the_column():
    pdf = _pdf()
    block = issuer_block(
        _issuer(
            name="Una razón comercial extremadamente larga que obliga a partir el nombre en varios renglones",
            email="un.correo.electronico.realmente.largo.del.negocio@dominio-muy-largo-de-ejemplo.com.ar",
            website="https://www.un-sitio-web-con-un-nombre-largo-y-sin-espacios.example.com/catalogo/primavera-2026",
        ),
        None,
    )
    layout = layout_issuer_column(pdf, 18, 20, WIDTH, block, LOGO_BOX)
    assert len(layout.items) >= 4
    for item in layout.items:
        pdf.set_font("Helvetica", "B" if item.bold else "", item.size)
        for line in item.lines:
            assert pdf.get_string_width(line) <= WIDTH + 0.01, line


def test_a_long_name_takes_more_than_one_line():
    pdf = _pdf()
    short = layout_issuer_column(pdf, 18, 20, WIDTH, issuer_block(_issuer(name="Sumar"), None), LOGO_BOX)
    long = layout_issuer_column(
        pdf, 18, 20, WIDTH,
        issuer_block(_issuer(name="Una razón comercial extremadamente larga que obliga a partir el nombre en varios renglones"), None),
        LOGO_BOX,
    )
    assert len(long.items[0].lines) > len(short.items[0].lines) == 1
    assert long.height > short.height


# ── se dibuja de verdad ──────────────────────────────────────────────────────

def test_draw_prints_the_texts_and_the_logo_image():
    pdf = _pdf()
    draw_issuer_column(pdf, 18, 20, WIDTH, issuer_block(_issuer(), _logo()), NEUTRAL, LOGO_BOX)
    reader = PdfReader(io.BytesIO(bytes(pdf.output())))
    text = reader.pages[0].extract_text()
    for needle in ("Sumar", "Ropa Deportiva SRL", "CUIT: 20-12345678-6", "IVA RESPONSABLE MONOTRIBUTO",
                   "Av. San Martín 1234", "Tel: 2615550101", "ventas@sumar.com.ar", "sumar.com.ar"):
        assert needle in text
    assert len(reader.pages[0].images) == 1


def test_draw_without_a_logo_embeds_no_image():
    pdf = _pdf()
    draw_issuer_column(pdf, 18, 20, WIDTH, issuer_block(_issuer(), None), NEUTRAL, LOGO_BOX)
    assert len(PdfReader(io.BytesIO(bytes(pdf.output()))).pages[0].images) == 0


def test_emoji_and_em_dash_in_the_name_do_not_break_the_header():
    pdf = _pdf()
    draw_issuer_column(pdf, 18, 20, WIDTH, issuer_block(_issuer(name="Café — Sabores 🍰 €5"), None), NEUTRAL, LOGO_BOX)
    text = _full_text(pdf)
    assert "Café" in text and "Sabores" in text and "—" in text


def test_text_colors_follow_the_palette():
    """El nombre en la tinta de la paleta y las líneas en el gris: operadores `rg` del flujo."""
    pdf = _pdf()
    draw_issuer_column(pdf, 18, 20, WIDTH, issuer_block(_issuer(), None), resolve_palette("azul", None), LOGO_BOX)
    content = b"".join(page.get_contents().get_data() for page in PdfReader(io.BytesIO(bytes(pdf.output()))).pages)
    ink = b"0.1176 0.1608 0.2314 rg"        # (30, 41, 59)
    muted = b"0.3922 0.4549 0.5451 rg"      # (100, 116, 139)
    assert ink in content and muted in content


def test_header_line_defaults():
    line = HeaderLine("hola")
    assert (line.bold, line.size, line.muted) == (False, 9.0, True)
    assert IssuerBlock(name="x", lines=()).logo is None


# ── la geometría medida es la que se dibuja ──────────────────────────────────

def _origin_y(pdf: FPDF, needle: str) -> float:
    """La y (en puntos del PDF) donde se imprime el primer texto que contiene `needle`."""
    found: list[float] = []

    def visitor(text, cm, tm, font_dict, font_size):
        if needle in text and not found:
            found.append(tm[5] * cm[3] + cm[5])

    PdfReader(io.BytesIO(bytes(pdf.output()))).pages[0].extract_text(visitor_text=visitor)
    assert found, f"no se encontró {needle!r}"
    return found[0]


def test_each_text_is_drawn_exactly_where_the_layout_said():
    """Se compara contra el MISMO texto dibujado a mano en la y que dice el layout:
    si el dibujo se desplazara respecto de lo medido, las y no coincidirían."""
    issuer = _issuer()
    block = issuer_block(issuer, None)

    drawn = _pdf()
    layout = layout_issuer_column(drawn, 18, 25, WIDTH, block, LOGO_BOX)
    draw_issuer_column(drawn, 18, 25, WIDTH, block, NEUTRAL, LOGO_BOX)

    for item, needle in zip(layout.items, ("Sumar", "Ropa Deportiva SRL", "CUIT: 20-12345678-6", "IVA RESPONSABLE")):
        reference = _pdf()
        reference.set_font("Helvetica", "B" if item.bold else "", item.size)
        reference.set_xy(18, item.y)
        reference.multi_cell(WIDTH, item.line_height, needle, align="L", new_x="LEFT", new_y="NEXT")
        assert _origin_y(drawn, needle) == pytest.approx(_origin_y(reference, needle), abs=0.01), needle


# ── alto de renglón propio (documentos-marca-empresa, tanda B: la Factura C) ──
# La columna del emisor de la Factura C ya tenía alturas de renglón fijas (7 mm el nombre de 15 pt, 4,2 mm el
# domicilio de 8,5 pt…); para que SIN marca su diseño no se mueva, el helper acepta una altura propia por
# renglón. Los otros papeles no las usan: el valor por defecto (la mitad del cuerpo) no cambia.

def test_a_line_height_of_its_own_changes_the_measured_height_and_the_y_of_the_next_line():
    block = IssuerBlock(
        name="Sumar", name_size=15.0, name_line_height=7.0,
        lines=(HeaderLine("Av. San Martín 1234", size=8.5, muted=False, line_height=4.2),
               HeaderLine("IVA RESPONSABLE MONOTRIBUTO", bold=True, size=8.5, muted=False, line_height=4.5)),
    )
    layout = layout_issuer_column(_pdf(), 18, 20, WIDTH, block, LOGO_BOX)
    name, address, iva = layout.items

    assert (name.line_height, address.line_height, iva.line_height) == (7.0, 4.2, 4.5)
    assert address.y == pytest.approx(20 + 7.0)
    assert iva.y == pytest.approx(20 + 7.0 + 4.2)
    assert layout.height == pytest.approx(7.0 + 4.2 + 4.5)


def test_without_a_line_height_of_its_own_nothing_changes():
    block = IssuerBlock(name="Sumar", lines=(HeaderLine("Av. San Martín 1234", size=8.5),))
    layout = layout_issuer_column(_pdf(), 18, 20, WIDTH, block, LOGO_BOX)

    assert layout.items[0].line_height == NAME_LINE_HEIGHT == 8.0
    assert layout.items[1].line_height == pytest.approx(8.5 * 0.5)
