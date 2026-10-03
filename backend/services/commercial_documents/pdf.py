"""
Render del PDF de un documento comercial (presupuestos-modulo D8, capability
`commercial-document-pdf`).

`build_commercial_document_pdf(view)` dibuja una `CommercialDocumentView` ya
resuelta: sin lógica de negocio, sin I/O. Usa `fpdf2` con fuentes core y la
misma familia visual (paleta y diagramación de tabla) que el comprobante
interno de venta (`services/receipts.py`), de donde se importan —no se copian—
la paleta y los formateadores de importes:

  - `_format_amount`: importes al centavo (`$ 1.234,50`);
  - `_format_unit_price`: el precio UNITARIO con su precisión (RN-24-bis:
    `$ 4,575` por gramo), no cortado a 2 decimales.

Texto fuera de la fuente: las fuentes core son de 1 byte (Windows-1252). El
guion largo de la leyenda ("Presupuesto — documento no válido como factura.")
es parte del texto de la spec y SÍ entra en cp1252, pero `fpdf2` rechaza
cualquier carácter fuera de latin-1 antes de codificar; por eso `_pdf_text`
convierte a cp1252 y reinterpreta los bytes como latin-1 (la fuente los
dibuja con su codificación WinAnsi). Lo que ni siquiera cp1252 representa (un
emoji) se sustituye por `?` en vez de hacer fallar el documento. No se usa
`_latin1` de receipts: éste convertiría el guion largo en `?`.

Tabla: la API de tablas de `fpdf2` envuelve el texto de cada celda y REPITE la
fila de cabecera en cada página cuando las líneas no entran en una.

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

from backend.services.commercial_documents.view import CommercialDocumentView
from backend.services.receipts import EMERALD, GRAY, SLATE, _format_amount, _format_unit_price

_MARGIN = 18
_PAGE_WIDTH = 210.0
_CONTENT_WIDTH = _PAGE_WIDTH - 2 * _MARGIN          # 174 mm
_FOOTER_HEIGHT = 20
_WARNING = (185, 28, 28)                              # rojo del sello (VENCIDO / RECHAZADO)
_CURRENCY = "ARS"

_STAMP_COLORS = {"ACEPTADO": EMERALD}

# Bloque de firma de recepción del remito: título + cuatro renglones.
_SIGNATURE_ROW_HEIGHT = 10
_SIGNATURE_TITLE_HEIGHT = 8
_SIGNATURE_PADDING = 3
_SIGNATURE_HEIGHT = _SIGNATURE_TITLE_HEIGHT + 4 * _SIGNATURE_ROW_HEIGHT + 2 * _SIGNATURE_PADDING
_SIGNATURE_FIELDS = ("Firma:", "Aclaración:", "DNI:", "Fecha:")


def _pdf_text(text: str | None) -> str:
    """Texto seguro para una fuente core (ver el docstring del módulo)."""
    return (text or "").encode("cp1252", "replace").decode("latin-1")


class _CommercialPdf(FPDF):
    """`FPDF` con el pie fijo: la leyenda y el número de página, en TODAS las
    páginas (un documento de varias páginas no pierde la leyenda de "no válido
    como factura" al separarse)."""

    def __init__(self, legend: str) -> None:
        super().__init__(orientation="P", unit="mm", format="A4")
        self._legend = legend
        self.set_margins(_MARGIN, _MARGIN, _MARGIN)
        self.set_auto_page_break(auto=True, margin=_FOOTER_HEIGHT + 4)
        self.alias_nb_pages()

    def footer(self) -> None:
        self.set_y(-_FOOTER_HEIGHT)
        self.set_draw_color(*GRAY)
        self.set_line_width(0.2)
        self.line(_MARGIN, self.get_y(), _PAGE_WIDTH - _MARGIN, self.get_y())
        self.ln(1.5)
        self.set_font("Helvetica", "I", 8)
        self.set_text_color(*GRAY)
        self.multi_cell(0, 4, _pdf_text(self._legend), align=Align.C, new_x="LMARGIN", new_y="NEXT")
        self.set_font("Helvetica", "", 8)
        self.cell(0, 4, f"Página {self.page_no()}/{{nb}}", align=Align.R, new_x="LMARGIN", new_y="NEXT")


def _issuer_block(pdf: _CommercialPdf, view: CommercialDocumentView) -> None:
    issuer = view.issuer
    top = pdf.get_y()

    # Izquierda: el emisor.
    pdf.set_font("Helvetica", "B", 18)
    pdf.set_text_color(*SLATE)
    pdf.multi_cell(105, 8, _pdf_text(issuer.name), new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "", 9)
    pdf.set_text_color(*GRAY)
    if issuer.legal_name and issuer.legal_name.strip().lower() != issuer.name.strip().lower():
        pdf.multi_cell(105, 4.5, _pdf_text(issuer.legal_name), new_x="LMARGIN", new_y="NEXT")
    if issuer.cuit:
        pdf.multi_cell(105, 4.5, _pdf_text(f"CUIT: {issuer.cuit}"), new_x="LMARGIN", new_y="NEXT")
    if issuer.address:
        pdf.multi_cell(105, 4.5, _pdf_text(issuer.address), new_x="LMARGIN", new_y="NEXT")
    if issuer.phone:
        pdf.multi_cell(105, 4.5, _pdf_text(f"Tel: {issuer.phone}"), new_x="LMARGIN", new_y="NEXT")
    left_bottom = pdf.get_y()

    # Derecha: el documento.
    pdf.set_xy(_MARGIN + 110, top)
    pdf.set_font("Helvetica", "B", 17)
    pdf.set_text_color(*EMERALD)
    pdf.cell(_CONTENT_WIDTH - 110, 9, _pdf_text(view.title), align=Align.R, new_x="LEFT", new_y="NEXT")
    pdf.set_font("Helvetica", "B", 11)
    pdf.set_text_color(*SLATE)
    if view.number_label:
        pdf.cell(_CONTENT_WIDTH - 110, 6, _pdf_text(f"N° {view.number_label}"), align=Align.R, new_x="LEFT", new_y="NEXT")
    pdf.set_font("Helvetica", "", 10)
    pdf.cell(_CONTENT_WIDTH - 110, 5.5, f"Fecha: {view.issued_on:%d/%m/%Y}", align=Align.R, new_x="LEFT", new_y="NEXT")
    if view.valid_until is not None:
        pdf.cell(
            _CONTENT_WIDTH - 110, 5.5, _pdf_text(f"Válido hasta: {view.valid_until:%d/%m/%Y}"),
            align=Align.R, new_x="LEFT", new_y="NEXT",
        )
    right_bottom = pdf.get_y()

    pdf.set_xy(_MARGIN, max(left_bottom, right_bottom) + 2)
    pdf.set_draw_color(*EMERALD)
    pdf.set_line_width(0.6)
    pdf.line(_MARGIN, pdf.get_y(), _PAGE_WIDTH - _MARGIN, pdf.get_y())
    pdf.ln(5)


def _recipient_block(pdf: _CommercialPdf, view: CommercialDocumentView) -> None:
    recipient = view.recipient
    top = pdf.get_y()
    pdf.set_font("Helvetica", "B", 10)
    pdf.set_text_color(*GRAY)
    pdf.cell(0, 5, _pdf_text(view.recipient_label), new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "B", 12)
    pdf.set_text_color(*SLATE)
    pdf.multi_cell(115, 6, _pdf_text(recipient.name), new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "", 9.5)
    pdf.set_text_color(*GRAY)
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
            pdf.multi_cell(115, 4.8, _pdf_text(detail), new_x="LMARGIN", new_y="NEXT")
    if view.reference_label:
        pdf.multi_cell(115, 4.8, _pdf_text(view.reference_label), new_x="LMARGIN", new_y="NEXT")
    if view.origin_label:
        pdf.set_font("Helvetica", "B", 9.5)
        pdf.set_text_color(*SLATE)
        pdf.multi_cell(115, 5.2, _pdf_text(view.origin_label), new_x="LMARGIN", new_y="NEXT")
    bottom = pdf.get_y()

    if view.status_stamp:
        color = _STAMP_COLORS.get(view.status_stamp, _WARNING)
        box_w, box_h = 48.0, 12.0
        x = _PAGE_WIDTH - _MARGIN - box_w
        y = top + 2
        pdf.set_draw_color(*color)
        pdf.set_line_width(0.9)
        pdf.rect(x, y, box_w, box_h, style="D", round_corners=True, corner_radius=1.5)
        pdf.set_xy(x, y)
        pdf.set_font("Helvetica", "B", 16)
        pdf.set_text_color(*color)
        pdf.cell(box_w, box_h, _pdf_text(view.status_stamp), align=Align.C)
    pdf.set_xy(_MARGIN, bottom + 4)


def _lines_table(pdf: _CommercialPdf, view: CommercialDocumentView) -> None:
    if view.show_prices:
        widths = (84, 26, 32, 32)
        aligns = ("LEFT", "CENTER", "RIGHT", "RIGHT")
        headings = ("Descripción", "Cant.", "P. unit.", "Subtotal")
    else:
        widths = (140, 34)
        aligns = ("LEFT", "CENTER")
        headings = ("Descripción", "Cant.")

    pdf.set_font("Helvetica", "", 10)
    pdf.set_text_color(*SLATE)
    pdf.set_draw_color(*GRAY)
    pdf.set_line_width(0.2)
    with pdf.table(
        col_widths=widths,
        text_align=aligns,
        width=_CONTENT_WIDTH,
        line_height=5.5,
        padding=1.6,
        borders_layout=TableBordersLayout.HORIZONTAL_LINES,
        headings_style=FontFace(emphasis="BOLD", color=(255, 255, 255), fill_color=EMERALD),
    ) as table:
        header = table.row()
        for text in headings:
            header.cell(_pdf_text(text))
        for line in view.lines:
            row = table.row()
            row.cell(_pdf_text(line.description))
            row.cell(_pdf_text(line.quantity_label))
            if view.show_prices:
                row.cell(_format_unit_price(line.unit_price, _CURRENCY))
                row.cell(_format_amount(line.subtotal, _CURRENCY))


def _total_and_notes(pdf: _CommercialPdf, view: CommercialDocumentView) -> None:
    pdf.set_x(_MARGIN)
    if view.show_prices:
        pdf.ln(3)
        # La fila del total no se parte: si no entra en la página, pasa entera a
        # la siguiente (el pie con la leyenda está en todas).
        if pdf.will_page_break(12):
            pdf.add_page()
        pdf.set_font("Helvetica", "B", 13)
        pdf.set_text_color(*SLATE)
        pdf.cell(_CONTENT_WIDTH - 66, 10, "", new_x="RIGHT", new_y="TOP")
        pdf.cell(30, 10, "TOTAL", align=Align.R, new_x="RIGHT", new_y="TOP")
        pdf.set_text_color(*EMERALD)
        pdf.cell(36, 10, _format_amount(view.total, _CURRENCY), align=Align.R, new_x="LMARGIN", new_y="NEXT")

    if view.notes:
        pdf.ln(4)
        pdf.set_font("Helvetica", "B", 10)
        pdf.set_text_color(*SLATE)
        pdf.cell(0, 6, "Notas", new_x="LMARGIN", new_y="NEXT")
        pdf.set_font("Helvetica", "", 10)
        pdf.set_text_color(*GRAY)
        pdf.multi_cell(_CONTENT_WIDTH, 5, _pdf_text(view.notes), new_x="LMARGIN", new_y="NEXT")


def _signature_block(pdf: _CommercialPdf) -> None:
    """Recuadro "Recibí conforme" del remito. Entero en una página: si no entra
    en lo que queda, pasa completo a la siguiente (el pie con la leyenda está en
    todas)."""
    pdf.ln(6)
    if pdf.will_page_break(_SIGNATURE_HEIGHT):
        pdf.add_page()
    top = pdf.get_y()
    pdf.set_draw_color(*GRAY)
    pdf.set_line_width(0.3)
    pdf.rect(_MARGIN, top, _CONTENT_WIDTH, _SIGNATURE_HEIGHT, style="D")

    pdf.set_xy(_MARGIN + 3, top + _SIGNATURE_PADDING)
    pdf.set_font("Helvetica", "B", 10)
    pdf.set_text_color(*SLATE)
    pdf.cell(_CONTENT_WIDTH - 6, _SIGNATURE_TITLE_HEIGHT - 2, "Recibí conforme", new_x="LMARGIN", new_y="NEXT")

    pdf.set_font("Helvetica", "", 9.5)
    pdf.set_text_color(*GRAY)
    y = top + _SIGNATURE_PADDING + _SIGNATURE_TITLE_HEIGHT
    for label in _SIGNATURE_FIELDS:
        pdf.set_xy(_MARGIN + 3, y)
        pdf.cell(28, _SIGNATURE_ROW_HEIGHT, _pdf_text(label), new_x="RIGHT", new_y="TOP")
        line_y = y + _SIGNATURE_ROW_HEIGHT - 2
        pdf.line(_MARGIN + 32, line_y, _PAGE_WIDTH - _MARGIN - 4, line_y)
        y += _SIGNATURE_ROW_HEIGHT
    pdf.set_xy(_MARGIN, top + _SIGNATURE_HEIGHT)


def build_commercial_document_pdf(view: CommercialDocumentView) -> bytes:
    """Bytes del PDF de un documento comercial no fiscal."""
    pdf = _CommercialPdf(view.legend)
    pdf.add_page()
    _issuer_block(pdf, view)
    _recipient_block(pdf, view)
    _lines_table(pdf, view)
    _total_and_notes(pdf, view)
    if view.signature_block:
        _signature_block(pdf)
    return bytes(pdf.output())
