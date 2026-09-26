"""
factura-fiscal-imprimible — representación impresa de la Factura C autorizada.

Tres piezas separadas a propósito (D2):

  1. `build_invoice_view(doc, profile, lines, sale_condition_kind, copy)` —
     función PURA que resuelve todos los textos desde lo AUTORIZADO
     (`fiscal_documents`: número, fecha que ARCA confirmó, tipo, total,
     receptor declarado, CAE) y levanta `InvoiceNotPrintable` antes que
     imprimir un dato inferido.
  2. `build_qr_url(qr)` — el texto del QR de ARCA (RG 4892/2020): JSON v1 con
     los numéricos como números, claves en el orden de la especificación,
     serializado sin espacios, en Base64. Con esa serialización el ejemplo
     oficial se reproduce byte a byte (test).
  3. `render_invoice_pdf(view)` — dibuja con `fpdf2` (fuentes core, latin-1) y
     el QR como rectángulos a partir de la matriz de `segno` (vectorial, sin
     imágenes ni archivos temporales). Sin lógica de negocio.

Normativa: RG 1415/2003 (contenido de la factura), RG 4892/2020 (QR).
Decisiones firmadas por el PO el 2026-09-26 (design.md): OQ-1 datos del emisor,
OQ-2 ORIGINAL/DUPLICADO, OQ-3 fantasía grande + razón social siempre, OQ-5 sin
el nombre del cliente si fue consumidor final sin identificar, OQ-8 dominio
afip.gob.ar del ejemplo oficial.
"""
from __future__ import annotations

import base64
import datetime
import json
import logging
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from decimal import Decimal

import segno
from fpdf import FPDF

from backend.services.fiscal.comprobante import (
    COMPROBANTE_AFIP_CODE,
    COMPROBANTE_LETTER,
    DOC_TIPO_CUIT,
    DOC_TIPO_DNI,
    DOC_TIPO_SIN_IDENTIFICAR,
    resolve_receptor_doc,
)
from backend.services.receipts import _format_amount, _format_unit_price, _latin1

logger = logging.getLogger(__name__)

# OQ-8: el dominio del ejemplo oficial de la especificación (el que leen todas
# las apps de cámara). `arca.gob.ar` también responde, pero no se usa.
QR_BASE_URL = "https://www.afip.gob.ar/fe/qr/"

# Constatación pública de comprobantes con CAE.
CONSTATACION_URL = "https://servicioscf.afip.gob.ar/publico/comprobantes/cae.aspx"

# Hoy sólo se emite Factura C en pesos. A/B quedan preparadas en las tablas
# pero se rechazan hasta que exista un emisor RI (falta el desglose por
# alícuota y la leyenda del Régimen de Transparencia Fiscal al Consumidor).
PRINTABLE_TYPES = frozenset({"factura_c"})

_COPY_LABELS = {"original": "ORIGINAL", "duplicado": "DUPLICADO"}

_ISSUER_IVA_LEGEND = {
    "monotributista": "IVA RESPONSABLE MONOTRIBUTO",
    "exento": "IVA EXENTO",
    "responsable_inscripto": "IVA RESPONSABLE INSCRIPTO",
}

_RECEPTOR_IVA_LABEL = {
    "responsable_inscripto": "IVA Responsable Inscripto",
    "monotributista": "Responsable Monotributo",
    "exento": "IVA Sujeto Exento",
    "consumidor_final": "Consumidor Final",
}

_ISSUER_FIELDS = (
    "cuit",
    "razon_social",
    "nombre_fantasia",
    "domicilio_comercial",
    "iva_condition",
    "iibb_condition",
    "iibb_numero",
    "inicio_actividades",
    "ambiente",
)

# Tolerancia entre la suma de las líneas y el total autorizado (redondeo).
_LINES_TOLERANCE = Decimal("0.01")


class InvoiceNotPrintable(Exception):
    """La factura no se puede imprimir sin inventar un dato.

    `code` es el código estable que viaja en el 409 RFC 7807; `missing`, la
    lista de datos del emisor que faltan (sólo para `issuer_data_incomplete`).
    """

    def __init__(self, code: str, detail: str, missing: list[str] | None = None) -> None:
        super().__init__(detail)
        self.code = code
        self.detail = detail
        self.missing = missing or []


@dataclass(frozen=True)
class QrData:
    """Los datos del QR, en el orden y con los nombres de la especificación."""

    fecha: datetime.date
    cuit: int
    pto_vta: int
    tipo_cmp: int
    nro_cmp: int
    importe: Decimal
    moneda: str
    ctz: Decimal
    tipo_doc_rec: int
    nro_doc_rec: int
    tipo_cod_aut: str
    cod_aut: int


@dataclass(frozen=True)
class InvoiceLineView:
    description: str
    quantity: str
    unit_price: str
    subtotal: str


@dataclass(frozen=True)
class InvoiceView:
    copy_label: str
    title: str
    letter: str
    code: str
    is_homologacion: bool
    issuer_display_name: str | None
    issuer_legal_name: str
    issuer_address: str
    issuer_iva_legend: str
    issuer_cuit: str
    issuer_iibb: str
    issuer_start_date: str
    punto_de_venta: str
    numero: str
    comprobante_number: str
    issue_date: str
    receptor_lines: tuple[str, ...]
    sale_condition: str
    lines: tuple[InvoiceLineView, ...]
    subtotal: str
    total: str
    cae: str
    cae_due_date: str
    qr_url: str
    filename: str


# ── Helpers de formato ────────────────────────────────────────────────────────

def _json_number(value: Decimal | int) -> int | float:
    """Número JSON: entero si no tiene decimales (32500), si no el decimal
    mínimo (32500.5). Nunca texto: la especificación lo exige numérico."""
    dec = Decimal(str(value))
    if dec == dec.to_integral_value():
        return int(dec)
    return float(dec.normalize())


def _format_cuit(value: object) -> str:
    digits = str(value or "").replace("-", "").strip()
    if len(digits) == 11 and digits.isdigit():
        return f"{digits[:2]}-{digits[2:10]}-{digits[10]}"
    return digits


def _format_thousands(digits: str) -> str:
    return f"{int(digits):,}".replace(",", ".") if digits.isdigit() else digits


def _format_date(value: datetime.date) -> str:
    return value.strftime("%d/%m/%Y")


def _format_quantity(quantity: object, unit_symbol: object) -> str:
    """1.000 → "1"; 0.450 → "0,45"; 1500 → "1.500"; con la unidad si la hay."""
    dec = Decimal(str(quantity)).quantize(Decimal("0.0001")).normalize()
    text = format(dec, "f")
    integer, _, fraction = text.partition(".")
    sign = "-" if integer.startswith("-") else ""
    integer = integer.lstrip("-")
    out = sign + _format_thousands(integer) + (f",{fraction}" if fraction else "")
    symbol = str(unit_symbol).strip() if unit_symbol else ""
    return f"{out} {symbol}" if symbol else out


def _as_date(value: object) -> datetime.date | None:
    if value is None or value == "":
        return None
    if isinstance(value, datetime.datetime):
        return value.date()
    if isinstance(value, datetime.date):
        return value
    try:
        return datetime.date.fromisoformat(str(value)[:10])
    except ValueError:
        return None


def _blank(value: object) -> bool:
    return value is None or (isinstance(value, str) and not value.strip())


def _snapshot(doc: Mapping) -> dict:
    """`emisor_snapshot` llega como dict o como texto JSON (asyncpg sin codec
    de jsonb). Una foto ilegible se trata como ausente (se completa del perfil)."""
    raw = doc.get("emisor_snapshot")
    if raw is None:
        return {}
    if isinstance(raw, Mapping):
        return dict(raw)
    try:
        parsed = json.loads(raw)
    except (TypeError, ValueError):
        logger.warning("invoice_pdf: emisor_snapshot ilegible en el comprobante %s", doc.get("id"))
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _issuer(doc: Mapping, profile: Mapping | None) -> dict:
    """La foto del emisor, completada CAMPO POR CAMPO desde el perfil actual
    (D6: concesión explícita para los comprobantes anteriores a la foto)."""
    snap = _snapshot(doc)
    current = dict(profile or {})
    merged: dict = {}
    for field in _ISSUER_FIELDS:
        value = snap.get(field)
        merged[field] = current.get(field) if _blank(value) else value
    return merged


def _missing_issuer_fields(issuer: Mapping) -> list[str]:
    missing = []
    if _blank(issuer.get("razon_social")):
        missing.append("razon_social")
    if _blank(issuer.get("domicilio_comercial")):
        missing.append("domicilio_comercial")
    if _blank(issuer.get("cuit")):
        missing.append("cuit")
    if _blank(issuer.get("iva_condition")):
        missing.append("iva_condition")
    if _blank(issuer.get("iibb_numero")) and _blank(issuer.get("iibb_condition")):
        missing.append("iibb")
    if _as_date(issuer.get("inicio_actividades")) is None:
        missing.append("inicio_actividades")
    return missing


def _receptor_lines(doc: Mapping, doc_tipo: int, doc_nro: int) -> tuple[str, ...]:
    """Sólo lo declarado a ARCA (OQ-5): sin identificar → "Consumidor Final",
    nunca el nombre del cliente de la venta."""
    if doc_tipo == DOC_TIPO_SIN_IDENTIFICAR:
        return ("Consumidor Final",)
    if doc_tipo == DOC_TIPO_CUIT:
        ident = f"CUIT: {_format_cuit(doc_nro)}"
    elif doc_tipo == DOC_TIPO_DNI:
        ident = f"DNI: {_format_thousands(str(doc_nro))}"
    else:
        ident = f"Documento ({doc_tipo}): {doc_nro}"
    lines = [ident]
    legal_name = doc.get("receptor_legal_name")
    if not _blank(legal_name):
        lines.append(str(legal_name).strip())
    condition = _RECEPTOR_IVA_LABEL.get(doc.get("receptor_iva_condition") or "consumidor_final",
                                        "Consumidor Final")
    lines.append(f"Condición frente al IVA: {condition}")
    return tuple(lines)


# ── 1. Modelo de vista ────────────────────────────────────────────────────────

def build_invoice_view(
    doc: Mapping,
    profile: Mapping | None,
    lines: Sequence[Mapping],
    sale_condition_kind: str | None,
    copy: str = "original",
) -> InvoiceView:
    """Todos los textos de la factura, desde lo autorizado. Levanta
    `InvoiceNotPrintable` antes que imprimir un dato adivinado."""
    if copy not in _COPY_LABELS:
        raise ValueError(f"copia inválida: {copy!r} (original | duplicado)")

    if doc.get("status") != "authorized":
        raise InvoiceNotPrintable(
            "fiscal_document_not_authorized",
            "El comprobante no está autorizado por ARCA: todavía no es una factura.",
        )

    comprobante_type = doc.get("comprobante_type")
    if comprobante_type not in PRINTABLE_TYPES:
        raise InvoiceNotPrintable(
            "invoice_type_not_printable",
            f"Todavía no se puede imprimir un comprobante de tipo {comprobante_type}.",
        )

    fecha = _as_date(doc.get("fecha_comprobante"))
    if fecha is None:
        raise InvoiceNotPrintable(
            "invoice_date_unknown",
            (
                "Todavía no se puede imprimir: falta confirmar con ARCA la fecha de este comprobante "
                "(es anterior a la factura imprimible; la completa el administrador)."
            ),
        )

    cae = doc.get("cae")
    cae_due = _as_date(doc.get("cae_due_date"))
    if _blank(cae) or cae_due is None:
        raise InvoiceNotPrintable(
            "invoice_cae_missing",
            "El comprobante autorizado no tiene el CAE o su vencimiento guardados.",
        )

    issuer = _issuer(doc, profile)
    missing = _missing_issuer_fields(issuer)
    if missing:
        raise InvoiceNotPrintable(
            "issuer_data_incomplete",
            "Faltan datos del emisor para imprimir la factura: " + ", ".join(missing) + ".",
            missing=missing,
        )

    total = Decimal(str(doc.get("total") or 0))
    line_sum = sum((Decimal(str(line.get("subtotal") or 0)) for line in lines), Decimal("0"))
    if not lines or abs(line_sum - total) > _LINES_TOLERANCE:
        raise InvoiceNotPrintable(
            "invoice_lines_mismatch",
            f"El detalle del comprobante suma {line_sum} y lo autorizado es {total}: "
            "no se imprime una factura cuyo detalle no coincide con ARCA.",
        )

    letter = COMPROBANTE_LETTER[comprobante_type]
    tipo_cmp = COMPROBANTE_AFIP_CODE[comprobante_type]
    punto_de_venta = int(doc["punto_de_venta"])
    numero = int(doc["number"])
    pv_text = str(punto_de_venta).zfill(4)
    numero_text = str(numero).zfill(8)
    doc_tipo, doc_nro = resolve_receptor_doc(doc.get("receptor_doc_tipo"), doc.get("receptor_doc_nro"))
    cuit_digits = str(issuer["cuit"]).replace("-", "").strip()

    qr_url = build_qr_url(QrData(
        fecha=fecha,
        cuit=int(cuit_digits),
        pto_vta=punto_de_venta,
        tipo_cmp=tipo_cmp,
        nro_cmp=numero,
        importe=total,
        moneda="PES",
        ctz=Decimal("1"),
        tipo_doc_rec=doc_tipo,
        nro_doc_rec=doc_nro,
        tipo_cod_aut="E",
        cod_aut=int(str(cae).strip()),
    ))

    iibb = issuer.get("iibb_numero")
    if _blank(iibb):
        iibb = issuer.get("iibb_condition")

    display_name = issuer.get("nombre_fantasia")
    return InvoiceView(
        copy_label=_COPY_LABELS[copy],
        title="FACTURA",
        letter=letter,
        code=str(tipo_cmp).zfill(3),
        is_homologacion=issuer.get("ambiente") == "homologacion",
        issuer_display_name=None if _blank(display_name) else str(display_name).strip(),
        issuer_legal_name=str(issuer["razon_social"]).strip(),
        issuer_address=str(issuer["domicilio_comercial"]).strip(),
        issuer_iva_legend=_ISSUER_IVA_LEGEND.get(issuer.get("iva_condition"), "IVA RESPONSABLE MONOTRIBUTO"),
        issuer_cuit=_format_cuit(cuit_digits),
        issuer_iibb=str(iibb).strip(),
        issuer_start_date=_format_date(_as_date(issuer.get("inicio_actividades"))),
        punto_de_venta=pv_text,
        numero=numero_text,
        comprobante_number=f"{pv_text}-{numero_text}",
        issue_date=_format_date(fecha),
        receptor_lines=_receptor_lines(doc, doc_tipo, doc_nro),
        sale_condition="Cuenta Corriente" if sale_condition_kind == "credit" else "Contado",
        lines=tuple(
            InvoiceLineView(
                description=str(line.get("name_snapshot") or "").strip() or "Sin descripción",
                quantity=_format_quantity(line.get("quantity") or 0, line.get("unit_symbol")),
                unit_price=_format_unit_price(Decimal(str(line.get("price") or 0)), "ARS"),
                subtotal=_format_amount(Decimal(str(line.get("subtotal") or 0)), "ARS"),
            )
            for line in lines
        ),
        subtotal=_format_amount(total, "ARS"),
        total=_format_amount(total, "ARS"),
        cae=str(cae).strip(),
        cae_due_date=_format_date(cae_due),
        qr_url=qr_url,
        filename=f"factura-{letter}-{pv_text}-{numero_text}.pdf",
    )


# ── 2. QR de ARCA ─────────────────────────────────────────────────────────────

def build_qr_url(qr: QrData) -> str:
    """`https://www.afip.gob.ar/fe/qr/?p=<Base64 del JSON v1>` (RG 4892).

    Claves en el orden de la tabla de la especificación y serialización sin
    espacios: con eso el ejemplo oficial se reproduce byte a byte.
    """
    payload = {
        "ver": 1,
        "fecha": qr.fecha.isoformat(),
        "cuit": int(qr.cuit),
        "ptoVta": int(qr.pto_vta),
        "tipoCmp": int(qr.tipo_cmp),
        "nroCmp": int(qr.nro_cmp),
        "importe": _json_number(qr.importe),
        "moneda": qr.moneda,
        "ctz": _json_number(qr.ctz),
        "tipoDocRec": int(qr.tipo_doc_rec),
        "nroDocRec": int(qr.nro_doc_rec),
        "tipoCodAut": qr.tipo_cod_aut,
        "codAut": int(qr.cod_aut),
    }
    raw = json.dumps(payload, separators=(",", ":"), ensure_ascii=True)
    return f"{QR_BASE_URL}?p={base64.b64encode(raw.encode('ascii')).decode('ascii')}"


# ── 3. Render ─────────────────────────────────────────────────────────────────

_MARGIN = 12.0
_WIDTH = 186.0          # 210 - 2 × 12
_INK = (30, 41, 59)
_MUTED = (100, 116, 139)
_RULE = (148, 163, 184)
_HEAD_FILL = (241, 245, 249)
_WATERMARK = (226, 232, 240)
_QR_SIZE = 30.0         # mm — muy por encima del mínimo legible por una cámara
_QR_QUIET = 4           # módulos de zona de silencio
_COLUMNS = (("Descripción", 96.0, "L"), ("Cantidad", 24.0, "R"),
            ("Precio unitario", 33.0, "R"), ("Subtotal", 33.0, "R"))
_ROW_LINE = 4.6
# Alto de los totales + el bloque del CAE y el QR: van JUNTOS en la última
# página (un total sin su CAE al lado no se entiende como factura).
_TOTALS_H = 18.0
_AUTH_H = _QR_SIZE + 8


class _InvoicePDF(FPDF):
    """FPDF con el encabezado de la factura repetido en cada página."""

    def __init__(self, view: InvoiceView) -> None:
        super().__init__(orientation="P", unit="mm", format="A4")
        self.view = view
        self.in_table = False
        self.set_margins(_MARGIN, _MARGIN, _MARGIN)
        self.set_auto_page_break(auto=True, margin=16)

    # fpdf2 llama header() al abrir cada página, incluido el salto de la tabla.
    def header(self) -> None:  # noqa: D401 - API de fpdf2
        if self.view.is_homologacion:
            _draw_watermark(self)
        _draw_header(self, self.view)
        if self.in_table:
            _draw_table_head(self)

    def footer(self) -> None:  # noqa: D401 - API de fpdf2
        self.set_y(-12)
        self.set_font("Helvetica", "", 7)
        self.set_text_color(*_MUTED)
        self.cell(0, 5, _latin1(
            f"{self.view.title} {self.view.letter} {self.view.comprobante_number} - "
            f"Página {self.page_no()}/{{nb}}"
        ), align="R")


def _draw_watermark(pdf: _InvoicePDF) -> None:
    with pdf.local_context():
        pdf.set_font("Helvetica", "B", 24)
        pdf.set_text_color(*_WATERMARK)
        with pdf.rotation(angle=35, x=105, y=150):
            pdf.set_xy(0, 144)
            pdf.cell(210, 12, "COMPROBANTE DE PRUEBA - SIN VALIDEZ FISCAL", align="C")


def _draw_header(pdf: _InvoicePDF, view: InvoiceView) -> None:
    top = _MARGIN
    pdf.set_draw_color(*_RULE)
    pdf.set_line_width(0.3)
    pdf.set_text_color(*_INK)

    # Leyenda de copia (OQ-2)
    pdf.set_xy(_MARGIN, top)
    pdf.set_font("Helvetica", "B", 11)
    pdf.cell(_WIDTH, 7, view.copy_label, border=1, align="C")

    box_top = top + 7
    box_h = 42.0
    pdf.rect(_MARGIN, box_top, _WIDTH, box_h)
    mid = _MARGIN + _WIDTH / 2
    pdf.line(mid, box_top + 15, mid, box_top + box_h)

    # Recuadro de la letra, centrado sobre la división
    pdf.set_fill_color(255, 255, 255)
    pdf.rect(mid - 8, box_top, 16, 15, style="DF")
    pdf.set_xy(mid - 8, box_top + 0.5)
    pdf.set_font("Helvetica", "B", 22)
    pdf.cell(16, 10, view.letter, align="C")
    pdf.set_xy(mid - 8, box_top + 10)
    pdf.set_font("Helvetica", "B", 6.5)
    pdf.cell(16, 4, f"COD. {view.code}", align="C")

    # Emisor (izquierda). OQ-3: fantasía grande arriba, razón social SIEMPRE.
    left_w = _WIDTH / 2 - 12
    pdf.set_xy(_MARGIN + 2, box_top + 3)
    if view.issuer_display_name:
        pdf.set_font("Helvetica", "B", 15)
        pdf.multi_cell(left_w, 7, _latin1(view.issuer_display_name), new_x="LMARGIN", new_y="NEXT")
        pdf.set_x(_MARGIN + 2)
        pdf.set_font("Helvetica", "B", 9)
        pdf.multi_cell(left_w, 4.5, _latin1(view.issuer_legal_name), new_x="LMARGIN", new_y="NEXT")
    else:
        pdf.set_font("Helvetica", "B", 13)
        pdf.multi_cell(left_w, 6, _latin1(view.issuer_legal_name), new_x="LMARGIN", new_y="NEXT")
    pdf.set_x(_MARGIN + 2)
    pdf.set_font("Helvetica", "", 8.5)
    pdf.multi_cell(left_w, 4.2, _latin1(view.issuer_address), new_x="LMARGIN", new_y="NEXT")
    pdf.set_x(_MARGIN + 2)
    pdf.set_font("Helvetica", "B", 8.5)
    pdf.multi_cell(left_w, 4.5, view.issuer_iva_legend, new_x="LMARGIN", new_y="NEXT")

    # Comprobante (derecha)
    right_x = mid + 10
    right_w = _MARGIN + _WIDTH - right_x - 2
    pdf.set_xy(right_x, box_top + 3)
    pdf.set_font("Helvetica", "B", 15)
    pdf.cell(right_w, 7, view.title, new_x="LMARGIN", new_y="NEXT")
    if view.is_homologacion:
        pdf.set_x(right_x)
        pdf.set_font("Helvetica", "B", 8)
        pdf.cell(right_w, 4, "(HOMOLOGACION)", new_x="LMARGIN", new_y="NEXT")
    rows = (
        ("Punto de venta:", f"{view.punto_de_venta}   Comp. Nro: {view.numero}"),
        ("Fecha de emisión:", view.issue_date),
        ("CUIT:", view.issuer_cuit),
        ("Ingresos Brutos:", view.issuer_iibb),
        ("Inicio de actividades:", view.issuer_start_date),
    )
    for label, value in rows:
        pdf.set_x(right_x)
        pdf.set_font("Helvetica", "B", 8.5)
        label_w = pdf.get_string_width(_latin1(label)) + 1.5
        pdf.cell(label_w, 5, _latin1(label))
        pdf.set_font("Helvetica", "", 8.5)
        pdf.cell(right_w - label_w, 5, _latin1(value), new_x="LMARGIN", new_y="NEXT")

    pdf.set_y(box_top + box_h + 3)


def _draw_receptor(pdf: _InvoicePDF, view: InvoiceView) -> None:
    top = pdf.get_y()
    lines = view.receptor_lines
    height = 7 + 4.5 * (len(lines) + 1)
    pdf.rect(_MARGIN, top, _WIDTH, height)
    pdf.set_xy(_MARGIN + 2, top + 1.5)
    pdf.set_font("Helvetica", "B", 8.5)
    pdf.cell(_WIDTH - 4, 4.5, "Receptor", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "", 8.5)
    for line in lines:
        pdf.set_x(_MARGIN + 2)
        pdf.cell(_WIDTH - 4, 4.5, _latin1(line), new_x="LMARGIN", new_y="NEXT")
    pdf.set_x(_MARGIN + 2)
    pdf.set_font("Helvetica", "B", 8.5)
    pdf.cell(pdf.get_string_width(_latin1("Condición de venta:")) + 1.5, 4.5,
             _latin1("Condición de venta:"))
    pdf.set_font("Helvetica", "", 8.5)
    pdf.cell(60, 4.5, _latin1(view.sale_condition), new_x="LMARGIN", new_y="NEXT")
    pdf.set_y(top + height + 3)


def _draw_table_head(pdf: _InvoicePDF) -> None:
    pdf.set_fill_color(*_HEAD_FILL)
    pdf.set_text_color(*_INK)
    pdf.set_font("Helvetica", "B", 8.5)
    pdf.set_x(_MARGIN)
    for label, width, align in _COLUMNS:
        pdf.cell(width, 7, _latin1(label), border="TB", fill=True, align=align)
    pdf.ln(7)


def _draw_line(pdf: _InvoicePDF, line: InvoiceLineView) -> None:
    desc_w = _COLUMNS[0][1]
    pdf.set_font("Helvetica", "", 8.5)
    wrapped = pdf.multi_cell(desc_w - 2, _ROW_LINE, _latin1(line.description),
                             dry_run=True, output="LINES")
    height = _ROW_LINE * max(1, len(wrapped)) + 2
    if pdf.get_y() + height > pdf.page_break_trigger:
        pdf.add_page()
    top = pdf.get_y()
    pdf.set_xy(_MARGIN + 1, top + 1)
    pdf.multi_cell(desc_w - 2, _ROW_LINE, _latin1(line.description))
    pdf.set_xy(_MARGIN + desc_w, top)
    for text, (_, width, align) in zip(
        (line.quantity, line.unit_price, line.subtotal), _COLUMNS[1:]
    ):
        pdf.cell(width, _ROW_LINE + 2, _latin1(text), align=align)
    pdf.set_draw_color(*_RULE)
    pdf.line(_MARGIN, top + height, _MARGIN + _WIDTH, top + height)
    pdf.set_y(top + height)


def _draw_totals(pdf: _InvoicePDF, view: InvoiceView) -> None:
    if pdf.get_y() + _TOTALS_H + _AUTH_H > pdf.page_break_trigger:
        pdf.add_page()
    pdf.ln(2)
    label_w = 40.0
    value_w = 40.0
    x = _MARGIN + _WIDTH - label_w - value_w
    pdf.set_x(x)
    pdf.set_font("Helvetica", "", 9)
    pdf.cell(label_w, 6, "Subtotal:", align="R")
    pdf.cell(value_w, 6, _latin1(view.subtotal), align="R", new_x="LMARGIN", new_y="NEXT")
    pdf.set_x(x)
    pdf.set_font("Helvetica", "B", 11)
    pdf.cell(label_w, 8, "Importe Total:", align="R")
    pdf.cell(value_w, 8, _latin1(view.total), align="R", new_x="LMARGIN", new_y="NEXT")


def _draw_qr(pdf: _InvoicePDF, url: str, x: float, y: float) -> None:
    """El QR como rectángulos (vectorial). Una corrida horizontal de módulos
    oscuros = un solo rectángulo, para no inflar el PDF."""
    qr = segno.make(url, error="m", micro=False)
    rows = [list(row) for row in qr.matrix_iter(scale=1, border=_QR_QUIET)]
    module = _QR_SIZE / len(rows)
    pdf.set_fill_color(0, 0, 0)
    for r, row in enumerate(rows):
        c = 0
        while c < len(row):
            if row[c]:
                start = c
                while c < len(row) and row[c]:
                    c += 1
                pdf.rect(x + start * module, y + r * module, (c - start) * module, module, style="F")
            else:
                c += 1


def _draw_authorization(pdf: _InvoicePDF, view: InvoiceView) -> None:
    if pdf.get_y() + _AUTH_H > pdf.page_break_trigger:
        pdf.add_page()
    top = pdf.get_y() + 4
    pdf.set_draw_color(*_RULE)
    pdf.line(_MARGIN, top - 1, _MARGIN + _WIDTH, top - 1)
    _draw_qr(pdf, view.qr_url, _MARGIN, top)

    text_x = _MARGIN + _QR_SIZE + 6
    text_w = _WIDTH - _QR_SIZE - 6
    pdf.set_text_color(*_INK)
    pdf.set_xy(text_x, top + 3)
    pdf.set_font("Helvetica", "B", 11)
    pdf.cell(text_w, 6, "Comprobante Autorizado", new_x="LMARGIN", new_y="NEXT")
    for label, value in (("CAE N°:", view.cae), ("Fecha de Vto. de CAE:", view.cae_due_date)):
        pdf.set_x(text_x)
        pdf.set_font("Helvetica", "B", 9)
        label_w = pdf.get_string_width(_latin1(label)) + 1.5
        pdf.cell(label_w, 5.5, _latin1(label))
        pdf.set_font("Helvetica", "", 9)
        pdf.cell(text_w - label_w, 5.5, _latin1(value), new_x="LMARGIN", new_y="NEXT")
    pdf.set_x(text_x)
    pdf.set_font("Helvetica", "", 7.5)
    pdf.set_text_color(*_MUTED)
    pdf.multi_cell(
        text_w, 3.8,
        _latin1(
            "Verificá este comprobante escaneando el código QR o en "
            "servicioscf.afip.gob.ar/publico/comprobantes/cae.aspx"
        ),
        new_x="LMARGIN", new_y="NEXT",
    )
    pdf.set_y(max(pdf.get_y(), top + _QR_SIZE))


def render_invoice_pdf(view: InvoiceView) -> bytes:
    """Dibuja la factura (A4). Sin lógica de negocio: todo sale de `view`."""
    pdf = _InvoicePDF(view)
    pdf.set_title(_latin1(f"{view.title} {view.letter} {view.comprobante_number}"))
    pdf.set_creator("Aliadata")
    pdf.add_page()
    _draw_receptor(pdf, view)
    pdf.in_table = True
    _draw_table_head(pdf)
    for line in view.lines:
        _draw_line(pdf, line)
    pdf.in_table = False
    _draw_totals(pdf, view)
    _draw_authorization(pdf, view)
    return bytes(pdf.output())
