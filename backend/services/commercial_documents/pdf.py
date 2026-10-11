"""
Render del PDF de un documento comercial (presupuestos-modulo D8, capability
`commercial-document-pdf`).

`build_commercial_document_pdf(view)` dibuja una `CommercialDocumentView` ya
resuelta: sin lógica de negocio, sin I/O. Usa `fpdf2` con fuentes core y, de
`services/receipts.py`, sólo los formateadores de importes —no se copian—:

  - `_format_amount`: importes al centavo (`$ 1.234,50`);
  - `_format_unit_price`: el precio UNITARIO con su precisión (RN-24-bis:
    `$ 4,575` por gramo), no cortado a 2 decimales.

Marca de la cuenta (documentos-marca-empresa D5/D6): la vista trae su
`DocumentBranding` —emisor resuelto por la cascada única, paleta, logo ya
comprobado y leyenda al pie—. El encabezado del emisor lo dibuja el helper
compartido (`header.py`, el mismo que usan el comprobante interno y la Factura C);
la paleta de la cuenta —Neutro por defecto— pinta el título, la regla del
encabezado, la cabecera de la tabla, el total y el sello "ACEPTADO". Los sellos de
advertencia (VENCIDO, RECHAZADO, ANULADO) conservan su rojo. Este módulo ya NO
importa la paleta verde de `receipts.py` (que la conserva sólo para el recibo de
suscripción de ALIADATA, marca de plataforma).

Texto fuera de la fuente: las fuentes core son de 1 byte (Windows-1252). El
guion largo de la leyenda ("Presupuesto — documento no válido como factura.")
es parte del texto de la spec y SÍ entra en cp1252, pero `fpdf2` rechaza
cualquier carácter fuera de latin-1 antes de codificar; por eso `pdf_text` (módulo
`text.py`) convierte a cp1252 y reinterpreta los bytes como latin-1 (la fuente los
dibuja con su codificación WinAnsi). Lo que ni siquiera cp1252 representa (un
emoji) se sustituye por `?` en vez de hacer fallar el documento. No se usa
`_latin1` de receipts: éste convertiría el guion largo en `?`.

Tabla: la API de tablas de `fpdf2` envuelve el texto de cada celda y REPITE la
fila de cabecera en cada página cuando las líneas no entran en una.

Pie: la leyenda del documento y, si la cuenta la cargó, su leyenda al pie (hasta 3
renglones; lo que exceda se corta con "…"), más el número de página, en TODAS las
páginas. El alto del pie se calcula UNA vez al construir el PDF: el margen de salto
de página depende de él, así que la tabla nunca pisa el pie.

Remito (remitos-venta D8): la vista suma `origin_label` ("Sale de: …", bajo los
datos del cliente) y `signature_block` (recuadro "Recibí conforme" con Firma,
Aclaración, DNI y Fecha, que NO se parte entre páginas: si no entra en lo que
queda de la página, pasa entero a la siguiente). Sin precios (`show_prices`
falso) la tabla queda con descripción y cantidad y no hay total. Ambos campos
tienen default retrocompatible: el presupuesto se dibuja igual que antes.

Remito de compra (remitos-compra D10): el bloque de la contraparte lleva el
rótulo de la vista (`recipient_label`: "Cliente" o "Recibido de") y, si la vista
la trae, la línea `reference_label` ("Remito del proveedor N° …"). Con los
defaults el dibujo es el de siempre.
"""
from __future__ import annotations

from fpdf import FPDF
from fpdf.enums import Align, TableBordersLayout
from fpdf.fonts import FontFace

from backend.services.commercial_documents.header import draw_issuer_column, issuer_block
from backend.services.commercial_documents.palette import DocumentPalette
from backend.services.commercial_documents.text import pdf_text
from backend.services.commercial_documents.view import CommercialDocumentView
from backend.services.receipts import _format_amount, _format_unit_price

_MARGIN = 18
_PAGE_WIDTH = 210.0
_CONTENT_WIDTH = _PAGE_WIDTH - 2 * _MARGIN          # 174 mm
_FOOTER_HEIGHT = 20                                   # mínimo; crece con una leyenda larga
_FOOTER_LINE = 4.0                                    # mm por renglón del pie (8 pt)
_FOOTER_NOTE_MAX_LINES = 3
_ISSUER_COLUMN_WIDTH = 105.0
_LOGO_BOX = (50.0, 18.0)                              # mm máximos del logo en el encabezado
_WARNING = (185, 28, 28)                              # rojo del sello (VENCIDO / RECHAZADO / ANULADO)
_CURRENCY = "ARS"

# Bloque de firma de recepción del remito: título + cuatro renglones.
_SIGNATURE_ROW_HEIGHT = 10
_SIGNATURE_TITLE_HEIGHT = 8
_SIGNATURE_PADDING = 3
_SIGNATURE_HEIGHT = _SIGNATURE_TITLE_HEIGHT + 4 * _SIGNATURE_ROW_HEIGHT + 2 * _SIGNATURE_PADDING
_SIGNATURE_FIELDS = ("Firma:", "Aclaración:", "DNI:", "Fecha:")


class _CommercialPdf(FPDF):
    """`FPDF` con el pie fijo: la leyenda del documento, la leyenda al pie de la
    cuenta y el número de página, en TODAS las páginas (un documento de varias
    páginas no pierde la leyenda de "no válido como factura" al separarse)."""

    def __init__(self, legend: str, palette: DocumentPalette, footer_note: str | None = None) -> None:
        super().__init__(orientation="P", unit="mm", format="A4")
        self._palette = palette
        self.set_margins(_MARGIN, _MARGIN, _MARGIN)
        self.alias_nb_pages()
        # La primera página se abre acá: `multi_cell(dry_run=True)` necesita una página
        # abierta para medir, y el pie se mide UNA vez porque el margen de salto de
        # página depende de su alto (el encabezado y el cuerpo se dibujan después).
        self.add_page()
        self._legend_lines = self._wrap_footer(pdf_text(legend), "I")
        self._note_lines = self._wrap_note(footer_note)
        self.footer_height = max(
            float(_FOOTER_HEIGHT),
            1.7 + _FOOTER_LINE * (len(self._note_lines) + len(self._legend_lines)) + _FOOTER_LINE + 1.0,
        )
        self.set_auto_page_break(auto=True, margin=self.footer_height + 4)

    def _wrap_footer(self, text: str, style: str) -> tuple[str, ...]:
        self.set_font("Helvetica", style, 8)
        lines = self.multi_cell(_CONTENT_WIDTH, _FOOTER_LINE, text, align=Align.C, dry_run=True, output="LINES")
        return tuple(lines) if lines else ("",)

    def _wrap_note(self, note: str | None) -> tuple[str, ...]:
        """La leyenda al pie de la cuenta partida en renglones: hasta 3; si hay más,
        el último se recorta y termina en "…"."""
        text = pdf_text((note or "").strip())
        if not text:
            return ()
        lines = list(self._wrap_footer(text, ""))
        if len(lines) <= _FOOTER_NOTE_MAX_LINES:
            return tuple(lines)
        last = lines[_FOOTER_NOTE_MAX_LINES - 1].rstrip()
        ellipsis = pdf_text("…")
        self.set_font("Helvetica", "", 8)
        while last and self.get_string_width(last + ellipsis) > _CONTENT_WIDTH:
            last = last[:-1].rstrip()
        return (*lines[: _FOOTER_NOTE_MAX_LINES - 1], last + ellipsis)

    def footer(self) -> None:
        palette = self._palette
        self.set_y(-self.footer_height)
        self.set_draw_color(*palette.rule)
        self.set_line_width(0.2)
        self.line(_MARGIN, self.get_y(), _PAGE_WIDTH - _MARGIN, self.get_y())
        self.ln(1.5)
        self.set_text_color(*palette.muted)
        if self._note_lines:
            self.set_font("Helvetica", "", 8)
            self.multi_cell(0, _FOOTER_LINE, "\n".join(self._note_lines), align=Align.C, new_x="LMARGIN", new_y="NEXT")
        self.set_font("Helvetica", "I", 8)
        self.multi_cell(0, _FOOTER_LINE, "\n".join(self._legend_lines), align=Align.C, new_x="LMARGIN", new_y="NEXT")
        self.set_font("Helvetica", "", 8)
        self.cell(0, _FOOTER_LINE, f"Página {self.page_no()}/{{nb}}", align=Align.R, new_x="LMARGIN", new_y="NEXT")


def _issuer_block(pdf: _CommercialPdf, view: CommercialDocumentView) -> None:
    palette = view.branding.palette
    top = pdf.get_y()

    # Izquierda: el emisor (logo, nombre y datos), con el helper compartido.
    left_bottom = draw_issuer_column(
        pdf, _MARGIN, top, _ISSUER_COLUMN_WIDTH, issuer_block(view.issuer, view.branding.logo), palette, _LOGO_BOX
    )

    # Derecha: el documento.
    right_x = _MARGIN + 110
    right_w = _CONTENT_WIDTH - 110
    pdf.set_xy(right_x, top)
    pdf.set_font("Helvetica", "B", 17)
    pdf.set_text_color(*palette.heading)
    pdf.cell(right_w, 9, pdf_text(view.title), align=Align.R, new_x="LEFT", new_y="NEXT")
    pdf.set_font("Helvetica", "B", 11)
    pdf.set_text_color(*palette.ink)
    if view.number_label:
        pdf.cell(right_w, 6, pdf_text(f"N° {view.number_label}"), align=Align.R, new_x="LEFT", new_y="NEXT")
    pdf.set_font("Helvetica", "", 10)
    pdf.cell(right_w, 5.5, f"Fecha: {view.issued_on:%d/%m/%Y}", align=Align.R, new_x="LEFT", new_y="NEXT")
    if view.valid_until is not None:
        pdf.cell(
            right_w, 5.5, pdf_text(f"Válido hasta: {view.valid_until:%d/%m/%Y}"),
            align=Align.R, new_x="LEFT", new_y="NEXT",
        )
    right_bottom = pdf.get_y()

    pdf.set_xy(_MARGIN, max(left_bottom, right_bottom) + 2)
    pdf.set_draw_color(*palette.strong_rule)
    pdf.set_line_width(0.6)
    pdf.line(_MARGIN, pdf.get_y(), _PAGE_WIDTH - _MARGIN, pdf.get_y())
    pdf.ln(5)


def _recipient_block(pdf: _CommercialPdf, view: CommercialDocumentView) -> None:
    palette = view.branding.palette
    recipient = view.recipient
    top = pdf.get_y()
    pdf.set_font("Helvetica", "B", 10)
    pdf.set_text_color(*palette.muted)
    pdf.cell(0, 5, pdf_text(view.recipient_label), new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "B", 12)
    pdf.set_text_color(*palette.ink)
    pdf.multi_cell(115, 6, pdf_text(recipient.name), new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "", 9.5)
    pdf.set_text_color(*palette.muted)
    address = recipient.address
    if address and view.kind == "delivery_note":
        address = f"Entrega: {address}"
    details = [
        f"CUIT/DNI: {recipient.tax_id}" if recipient.tax_id else None,
        f"Tel: {recipient.phone}" if recipient.phone else None,
        address,
    ]
    for detail in details:
        if detail:
            pdf.multi_cell(115, 4.8, pdf_text(detail), new_x="LMARGIN", new_y="NEXT")
    if view.reference_label:
        pdf.multi_cell(115, 4.8, pdf_text(view.reference_label), new_x="LMARGIN", new_y="NEXT")
    if view.origin_label:
        pdf.set_font("Helvetica", "B", 9.5)
        pdf.set_text_color(*palette.ink)
        pdf.multi_cell(115, 5.2, pdf_text(view.origin_label), new_x="LMARGIN", new_y="NEXT")
    bottom = pdf.get_y()

    if view.status_stamp:
        # Sólo el sello "ACEPTADO" toma el color de la cuenta; los de advertencia
        # (VENCIDO, RECHAZADO, ANULADO) conservan su rojo.
        color = palette.accepted_stamp if view.status_stamp == "ACEPTADO" else _WARNING
        box_w, box_h = 48.0, 12.0
        x = _PAGE_WIDTH - _MARGIN - box_w
        y = top + 2
        pdf.set_draw_color(*color)
        pdf.set_line_width(0.9)
        pdf.rect(x, y, box_w, box_h, style="D", round_corners=True, corner_radius=1.5)
        pdf.set_xy(x, y)
        pdf.set_font("Helvetica", "B", 16)
        pdf.set_text_color(*color)
        pdf.cell(box_w, box_h, pdf_text(view.status_stamp), align=Align.C)
    pdf.set_xy(_MARGIN, bottom + 4)


def _lines_table(pdf: _CommercialPdf, view: CommercialDocumentView) -> None:
    palette = view.branding.palette
    if view.show_prices:
        widths = (84, 26, 32, 32)
        aligns = ("LEFT", "CENTER", "RIGHT", "RIGHT")
        headings = ("Descripción", "Cant.", "P. unit.", "Subtotal")
    else:
        widths = (140, 34)
        aligns = ("LEFT", "CENTER")
        headings = ("Descripción", "Cant.")

    pdf.set_font("Helvetica", "", 10)
    pdf.set_text_color(*palette.ink)
    pdf.set_draw_color(*palette.rule)
    pdf.set_line_width(0.2)
    with pdf.table(
        col_widths=widths,
        text_align=aligns,
        width=_CONTENT_WIDTH,
        line_height=5.5,
        padding=1.6,
        borders_layout=TableBordersLayout.HORIZONTAL_LINES,
        headings_style=FontFace(
            emphasis="BOLD", color=palette.table_head_text, fill_color=palette.table_head_fill
        ),
    ) as table:
        header = table.row()
        for text in headings:
            header.cell(pdf_text(text))
        for line in view.lines:
            row = table.row()
            row.cell(pdf_text(line.description))
            row.cell(pdf_text(line.quantity_label))
            if view.show_prices:
                row.cell(_format_unit_price(line.unit_price, _CURRENCY))
                row.cell(_format_amount(line.subtotal, _CURRENCY))


def _total_and_notes(pdf: _CommercialPdf, view: CommercialDocumentView) -> None:
    palette = view.branding.palette
    pdf.set_x(_MARGIN)
    if view.show_prices:
        pdf.ln(3)
        # La fila del total no se parte: si no entra en la página, pasa entera a la
        # siguiente (el pie con la leyenda está en todas).
        if pdf.will_page_break(12):
            pdf.add_page()
        pdf.set_font("Helvetica", "B", 13)
        pdf.set_text_color(*palette.ink)
        pdf.cell(_CONTENT_WIDTH - 66, 10, "", new_x="RIGHT", new_y="TOP")
        pdf.cell(30, 10, "TOTAL", align=Align.R, new_x="RIGHT", new_y="TOP")
        pdf.set_text_color(*palette.total)
        pdf.cell(36, 10, _format_amount(view.total, _CURRENCY), align=Align.R, new_x="LMARGIN", new_y="NEXT")

    if view.notes:
        pdf.ln(4)
        pdf.set_font("Helvetica", "B", 10)
        pdf.set_text_color(*palette.ink)
        pdf.cell(0, 6, "Notas", new_x="LMARGIN", new_y="NEXT")
        pdf.set_font("Helvetica", "", 10)
        pdf.set_text_color(*palette.muted)
        pdf.multi_cell(_CONTENT_WIDTH, 5, pdf_text(view.notes), new_x="LMARGIN", new_y="NEXT")


def _signature_block(pdf: _CommercialPdf, view: CommercialDocumentView) -> None:
    """Recuadro "Recibí conforme" del remito. Entero en una página: si no entra
    en lo que queda, pasa completo a la siguiente (el pie con la leyenda está en
    todas)."""
    palette = view.branding.palette
    pdf.ln(6)
    if pdf.will_page_break(_SIGNATURE_HEIGHT):
        pdf.add_page()
    top = pdf.get_y()
    pdf.set_draw_color(*palette.rule)
    pdf.set_line_width(0.3)
    pdf.rect(_MARGIN, top, _CONTENT_WIDTH, _SIGNATURE_HEIGHT, style="D")

    pdf.set_xy(_MARGIN + 3, top + _SIGNATURE_PADDING)
    pdf.set_font("Helvetica", "B", 10)
    pdf.set_text_color(*palette.ink)
    pdf.cell(_CONTENT_WIDTH - 6, _SIGNATURE_TITLE_HEIGHT - 2, "Recibí conforme", new_x="LMARGIN", new_y="NEXT")

    pdf.set_font("Helvetica", "", 9.5)
    pdf.set_text_color(*palette.muted)
    y = top + _SIGNATURE_PADDING + _SIGNATURE_TITLE_HEIGHT
    for label in _SIGNATURE_FIELDS:
        pdf.set_xy(_MARGIN + 3, y)
        pdf.cell(28, _SIGNATURE_ROW_HEIGHT, pdf_text(label), new_x="RIGHT", new_y="TOP")
        line_y = y + _SIGNATURE_ROW_HEIGHT - 2
        pdf.line(_MARGIN + 32, line_y, _PAGE_WIDTH - _MARGIN - 4, line_y)
        y += _SIGNATURE_ROW_HEIGHT
    pdf.set_xy(_MARGIN, top + _SIGNATURE_HEIGHT)


def build_commercial_document_pdf(view: CommercialDocumentView) -> bytes:
    """Bytes del PDF de un documento comercial no fiscal."""
    pdf = _CommercialPdf(view.legend, view.branding.palette, view.branding.footer_note)
    _issuer_block(pdf, view)
    _recipient_block(pdf, view)
    _lines_table(pdf, view)
    _total_and_notes(pdf, view)
    if view.signature_block:
        _signature_block(pdf, view)
    return bytes(pdf.output())
