"""
Encabezado de emisor compartido por los papeles de la cuenta
(documentos-marca-empresa D5, capability `document-branding`).

Antes había TRES encabezados dibujados a mano sin base común: inline en
`receipts.py` (comprobante interno), `_issuer_block` en `pdf.py` (presupuesto y
remitos) y `_draw_header` en `invoice_pdf.py` (Factura C, con un recuadro de alto
fijo). Este módulo es el único que sabe dibujar la COLUMNA DEL EMISOR:

    logo (arriba a la izquierda, sin deformarse, dentro de una caja)
    nombre (grande, en la tinta de la paleta)
    líneas (razón social si difiere, CUIT, leyenda de IVA, domicilio, Tel, email, web)

Cada generador arma SU `IssuerBlock` (el comercial y el comprobante interno desde
`CommercialIssuer` con `issuer_block`; la factura, desde la foto fiscal más el
contacto de la marca) y el helper sólo dibuja: tres consumidores reales, Regla de
Tres cumplida.

Dos pasos separados a propósito:

  - `layout_issuer_column` MIDE: parte el texto en renglones con el ancho real de
    la columna (`multi_cell(dry_run=True, output="LINES")`) y devuelve la
    geometría —rectángulo del logo, `y` del nombre, renglones y alto total— sin
    tocar el documento. `measure_issuer_column` es su alto.
  - `draw_issuer_column` DIBUJA exactamente esa geometría, así que el alto medido
    es igual al dibujado (la Factura C de la tanda B ensancha su recuadro según lo
    que mide) y los tests asertan con las coordenadas que devuelve el helper.

Todo texto pasa por `pdf_text` (cp1252): "—" y "€" en un nombre comercial se
imprimen bien, y lo que ni cp1252 representa (un emoji) se sustituye por `?` en
vez de hacer fallar el papel.
"""
from __future__ import annotations

import io
from dataclasses import dataclass

from fpdf import FPDF
from fpdf.enums import Align, XPos, YPos

from backend.services.commercial_documents.issuer import CommercialIssuer
from backend.services.commercial_documents.logo import LogoImage, fit_box
from backend.services.commercial_documents.palette import DocumentPalette
from backend.services.commercial_documents.text import pdf_text

LOGO_GAP = 2.0               # mm entre el logo y el nombre
NAME_SIZE = 18.0             # pt
NAME_LINE_HEIGHT = 8.0       # mm
DEFAULT_LINE_SIZE = 9.0      # pt; el alto de renglón es la mitad (9 pt -> 4,5 mm)


@dataclass(frozen=True)
class HeaderLine:
    text: str
    bold: bool = False
    size: float = DEFAULT_LINE_SIZE
    muted: bool = True        # gris de la paleta; False = la tinta
    line_height: float | None = None   # mm; por defecto, la mitad del cuerpo en pt


@dataclass(frozen=True)
class IssuerBlock:
    name: str
    lines: tuple[HeaderLine, ...] = ()
    logo: LogoImage | None = None
    name_size: float = NAME_SIZE
    name_line_height: float = NAME_LINE_HEIGHT


@dataclass(frozen=True)
class LayoutItem:
    """Un texto de la columna ya partido en renglones (con la y del primero)."""

    lines: tuple[str, ...]
    bold: bool
    size: float
    line_height: float
    muted: bool
    y: float

    @property
    def height(self) -> float:
        return len(self.lines) * self.line_height


@dataclass(frozen=True)
class ColumnLayout:
    x: float
    y: float
    width: float
    logo_rect: tuple[float, float, float, float] | None   # (x, y, ancho, alto) en mm
    name_y: float
    items: tuple[LayoutItem, ...]                         # el primero es el nombre
    height: float


def issuer_block(issuer: CommercialIssuer, logo: LogoImage | None) -> IssuerBlock:
    """El bloque del encabezado de un papel no fiscal. Lo que falta se omite; la
    razón social sólo se imprime si difiere del nombre."""
    lines: list[HeaderLine] = []
    if issuer.legal_name and issuer.legal_name.strip().lower() != issuer.name.strip().lower():
        lines.append(HeaderLine(issuer.legal_name))
    if issuer.cuit:
        lines.append(HeaderLine(f"CUIT: {issuer.cuit}"))
    if issuer.iva_legend:
        lines.append(HeaderLine(issuer.iva_legend, bold=True, muted=False))
    if issuer.address:
        lines.append(HeaderLine(issuer.address))
    if issuer.phone:
        lines.append(HeaderLine(f"Tel: {issuer.phone}"))
    if issuer.email:
        lines.append(HeaderLine(issuer.email))
    if issuer.website:
        lines.append(HeaderLine(issuer.website))
    return IssuerBlock(name=issuer.name, lines=tuple(lines), logo=logo)


def _wrap(pdf: FPDF, width: float, line_height: float, text: str) -> tuple[str, ...]:
    """Los renglones en que `multi_cell` parte el texto con el ancho dado (sin dibujar)."""
    lines = pdf.multi_cell(
        width, line_height, text, align=Align.L, dry_run=True, output="LINES",
        new_x=XPos.LEFT, new_y=YPos.NEXT,
    )
    return tuple(lines) if lines else ("",)


def layout_issuer_column(
    pdf: FPDF,
    x: float,
    y: float,
    width: float,
    block: IssuerBlock,
    logo_box: tuple[float, float],
) -> ColumnLayout:
    """Mide la columna sin dibujar ni cambiar el estado del PDF (fuente, posición)."""
    saved_font = (pdf.font_family, pdf.font_style, pdf.font_size_pt)
    try:
        cursor = y
        logo_rect: tuple[float, float, float, float] | None = None
        if block.logo is not None:
            w, h = fit_box(block.logo.width, block.logo.height, logo_box[0], logo_box[1])
            logo_rect = (x, y, w, h)
            cursor = y + h + LOGO_GAP

        name_y = cursor
        items: list[LayoutItem] = []

        pdf.set_font("Helvetica", "B", block.name_size)
        name_lines = _wrap(pdf, width, block.name_line_height, pdf_text(block.name))
        items.append(LayoutItem(name_lines, True, block.name_size, block.name_line_height, False, cursor))
        cursor += len(name_lines) * block.name_line_height

        for line in block.lines:
            pdf.set_font("Helvetica", "B" if line.bold else "", line.size)
            line_height = line.line_height if line.line_height is not None else line.size * 0.5
            wrapped = _wrap(pdf, width, line_height, pdf_text(line.text))
            items.append(LayoutItem(wrapped, line.bold, line.size, line_height, line.muted, cursor))
            cursor += len(wrapped) * line_height

        return ColumnLayout(x, y, width, logo_rect, name_y, tuple(items), cursor - y)
    finally:
        if saved_font[0]:
            pdf.set_font(*saved_font)


def measure_issuer_column(
    pdf: FPDF, width: float, block: IssuerBlock, logo_box: tuple[float, float]
) -> float:
    """El alto (mm) que ocupa la columna del emisor con ese ancho."""
    return layout_issuer_column(pdf, pdf.get_x(), pdf.get_y(), width, block, logo_box).height


def draw_issuer_column(
    pdf: FPDF,
    x: float,
    y: float,
    width: float,
    block: IssuerBlock,
    palette: DocumentPalette,
    logo_box: tuple[float, float],
) -> float:
    """Dibuja la columna del emisor en (x, y) y devuelve la `y` donde termina
    (= y + el alto medido). Deja el cursor en `x`, al final de la columna."""
    layout = layout_issuer_column(pdf, x, y, width, block, logo_box)
    if layout.logo_rect is not None and block.logo is not None:
        lx, ly, lw, lh = layout.logo_rect
        # Siempre BYTES: nunca una URL (fpdf2 acepta remotas).
        pdf.image(io.BytesIO(block.logo.data), x=lx, y=ly, w=lw, h=lh)

    for item in layout.items:
        pdf.set_font("Helvetica", "B" if item.bold else "", item.size)
        pdf.set_text_color(*(palette.muted if item.muted else palette.ink))
        pdf.set_xy(x, item.y)
        pdf.multi_cell(
            width, item.line_height, "\n".join(item.lines), align=Align.L,
            new_x=XPos.LEFT, new_y=YPos.NEXT,
        )
    pdf.set_xy(x, y + layout.height)
    return y + layout.height
