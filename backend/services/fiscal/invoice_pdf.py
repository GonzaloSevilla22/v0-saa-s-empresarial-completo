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
  3. `render_invoice_pdf(view, branding=None)` — dibuja con `fpdf2` (fuentes
     core, latin-1) y el QR como rectángulos a partir de la matriz de `segno`
     (vectorial; la única imagen de la factura es el logo de la cuenta, si lo
     tiene). Sin lógica de negocio.

Normativa: RG 1415/2003 (contenido de la factura), RG 4892/2020 (QR).
Decisiones firmadas por el PO el 2026-09-26 (design.md): OQ-1 datos del emisor,
OQ-2 ORIGINAL/DUPLICADO, OQ-3 fantasía grande + razón social siempre, OQ-5 sin
el nombre del cliente si fue consumidor final sin identificar, OQ-8 dominio
afip.gob.ar del ejemplo oficial.

MARCA DE LA CUENTA (documentos-marca-empresa, tanda B, design D11). La factura
suma, EN VIVO y sin entrar jamás en `emisor_snapshot`: el LOGO y las líneas de
CONTACTO (teléfono, email del negocio, web) que la cuenta cargó en su marca, y
el color de dos elementos NO fiscales —la banda de la cabecera de la tabla y el
título "FACTURA"—. Todo lo fiscal (recuadro de la letra, datos del emisor, CUIT,
receptor, totales, CAE y su vencimiento) queda en tinta y el QR de ARCA se
dibuja siempre negro sobre blanco. El contacto sale SÓLO de la marca, sin el
respaldo del teléfono del dueño que sí usan los papeles no fiscales: una cuenta
que nunca configuró su marca recibe la misma factura de siempre. La leyenda al
pie de la marca NO va (un "precios con IVA incluido" en una Factura C engaña).

Esto SUPERA OQ-1 (sin teléfono, email ni web) y OQ-4 de `factura-fiscal-imprimible`
por el pedido del PO del 2026-10-11: "toda la información de la empresa y el logo"
en todos los papeles, facturas incluidas. La RG 1415/2003 fija el CONTENIDO de la
factura y la RG 4892/2020 el QR; ninguna fija colores ni prohíbe un logo o datos
de contacto.
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

from backend.services.commercial_documents.branding import BrandContact, DocumentBranding
from backend.services.commercial_documents.header import (
    ColumnLayout,
    HeaderLine,
    IssuerBlock,
    draw_issuer_column,
    layout_issuer_column,
)
from backend.services.commercial_documents.palette import NEUTRAL, DocumentPalette
from backend.services.fiscal.comprobante import (
    COMPROBANTE_AFIP_CODE,
    COMPROBANTE_LETTER,
    DOC_TIPO_CUIT,
    DOC_TIPO_DNI,
    DOC_TIPO_SIN_IDENTIFICAR,
    ISSUER_IVA_LEGEND,
    format_cuit,
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
        ident = f"CUIT: {format_cuit(doc_nro)}"
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
        issuer_iva_legend=ISSUER_IVA_LEGEND.get(issuer.get("iva_condition"), "IVA RESPONSABLE MONOTRIBUTO"),
        issuer_cuit=format_cuit(cuit_digits),
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
# La tinta, el gris y la regla de la factura son la BASE de toda paleta (`palette.NEUTRAL`): una sola
# fuente para los papeles de la cuenta y la Factura C. El relleno de la banda de la tabla ya no es una
# constante: lo da la paleta (`table_head_fill`; con Neutro, la superficie gris de siempre).
_INK = NEUTRAL.ink
_MUTED = NEUTRAL.muted
_RULE = NEUTRAL.rule
_WATERMARK = (226, 232, 240)
# Encabezado: la columna del emisor (izquierda) y el recuadro que la contiene.
_LOGO_BOX = (40.0, 16.0)            # mm máximos del logo, sin deformarse
_COPY_H = 7.0                       # leyenda ORIGINAL / DUPLICADO sobre el recuadro
_BOX_MIN_H = 42.0                   # alto del recuadro cuando no hay logo ni contacto (el de siempre)
_BOX_PAD = 3.0                      # aire arriba y abajo de lo que contiene
_LEFT_X = _MARGIN + 2
_LEFT_W = _WIDTH / 2 - 12
_QR_SIZE = 30.0         # mm — muy por encima del mínimo legible por una cámara
_QR_QUIET = 4           # módulos de zona de silencio
_COLUMNS = (("Descripción", 96.0, "L"), ("Cantidad", 24.0, "R"),
            ("Precio unitario", 33.0, "R"), ("Subtotal", 33.0, "R"))
_ROW_LINE = 4.6
_HEAD_H = 7.0           # alto de la banda de la cabecera de la tabla
# Alto de los totales + el bloque del CAE y el QR: van JUNTOS en la última
# página (un total sin su CAE al lado no se entiende como factura).
_TOTALS_H = 18.0
_AUTH_H = _QR_SIZE + 8


class _InvoicePDF(FPDF):
    """FPDF con el encabezado de la factura repetido en cada página."""

    def __init__(self, view: InvoiceView, branding: DocumentBranding | None = None) -> None:
        super().__init__(orientation="P", unit="mm", format="A4")
        self.view = view
        self.branding = branding
        self.palette: DocumentPalette = branding.palette if branding is not None else NEUTRAL
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


def _issuer_block(view: InvoiceView, branding: DocumentBranding | None) -> IssuerBlock:
    """La columna izquierda: lo FISCAL (foto congelada; conserva su sanitizador `_latin1` de siempre y las
    alturas de renglón de siempre, para que sin marca el diseño no se mueva) y, de la marca, el logo y las
    líneas de contacto cargadas en ella. OQ-3 de la factura intacta: fantasía grande arriba y razón social
    SIEMPRE."""
    contact = branding.brand_contact if branding is not None else BrandContact()
    logo = branding.logo if branding is not None else None

    def line(text: str, *, bold: bool = False, size: float = 8.5, height: float = 4.2) -> HeaderLine:
        return HeaderLine(text, bold=bold, size=size, muted=False, line_height=height)

    lines: list[HeaderLine] = []
    if view.issuer_display_name:
        name, name_size, name_height = _latin1(view.issuer_display_name), 15.0, 7.0
        lines.append(line(_latin1(view.issuer_legal_name), bold=True, size=9.0, height=4.5))
    else:
        name, name_size, name_height = _latin1(view.issuer_legal_name), 13.0, 6.0
    lines.append(line(_latin1(view.issuer_address)))
    lines.append(line(view.issuer_iva_legend, bold=True, height=4.5))
    if contact.phone:
        lines.append(line(f"Tel: {contact.phone}"))
    if contact.email:
        lines.append(line(contact.email))
    if contact.website:
        lines.append(line(contact.website))
    return IssuerBlock(name=name, lines=tuple(lines), logo=logo, name_size=name_size,
                       name_line_height=name_height)


def _right_height(view: InvoiceView) -> float:
    """Alto de la columna derecha (título, leyenda de homologación y cinco renglones de datos)."""
    return 7.0 + (4.0 if view.is_homologacion else 0.0) + 5 * 5.0


@dataclass(frozen=True)
class InvoiceHeaderLayout:
    """La geometría del encabezado, medida ANTES de dibujar: dónde queda el recuadro y la columna del emisor."""

    box_top: float
    box_height: float
    left: ColumnLayout

    @property
    def box_bottom(self) -> float:
        return self.box_top + self.box_height


def layout_invoice_header(
    pdf: FPDF, view: InvoiceView, branding: DocumentBranding | None = None
) -> InvoiceHeaderLayout:
    """Mide el encabezado: el recuadro toma `max(42 mm, columna izquierda + aire, columna derecha + aire)`.
    Es determinístico (depende sólo de la vista y de la marca), así que todas las páginas —el encabezado se
    repite en cada una— tienen el MISMO alto y la tabla arranca siempre debajo."""
    box_top = _MARGIN + _COPY_H
    left = layout_issuer_column(
        pdf, _LEFT_X, box_top + _BOX_PAD, _LEFT_W, _issuer_block(view, branding), _LOGO_BOX
    )
    box_height = max(_BOX_MIN_H, left.height + 2 * _BOX_PAD, _right_height(view) + 2 * _BOX_PAD)
    return InvoiceHeaderLayout(box_top=box_top, box_height=box_height, left=left)


def _draw_header(pdf: _InvoicePDF, view: InvoiceView) -> None:
    top = _MARGIN
    layout = layout_invoice_header(pdf, view, pdf.branding)
    box_top, box_h = layout.box_top, layout.box_height
    pdf.set_draw_color(*_RULE)
    pdf.set_line_width(0.3)
    pdf.set_text_color(*_INK)

    # Leyenda de copia (OQ-2)
    pdf.set_xy(_MARGIN, top)
    pdf.set_font("Helvetica", "B", 11)
    pdf.cell(_WIDTH, _COPY_H, view.copy_label, border=1, align="C")

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

    # Emisor (izquierda): logo, nombre, razón social, domicilio, leyenda de IVA y contacto de la marca.
    draw_issuer_column(
        pdf, _LEFT_X, box_top + _BOX_PAD, _LEFT_W, _issuer_block(view, pdf.branding), pdf.palette, _LOGO_BOX
    )

    # Comprobante (derecha). El título lleva el color de la paleta; todo lo demás, la tinta.
    right_x = mid + 10
    right_w = _MARGIN + _WIDTH - right_x - 2
    pdf.set_xy(right_x, box_top + 3)
    pdf.set_font("Helvetica", "B", 15)
    pdf.set_text_color(*pdf.palette.heading)
    pdf.cell(right_w, 7, view.title, new_x="LMARGIN", new_y="NEXT")
    pdf.set_text_color(*_INK)
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
    """La banda de la cabecera de la tabla: el único relleno de color de la factura (con Neutro, la
    superficie gris de siempre). El texto toma el color de mayor contraste sobre ella; al terminar, el color
    del texto vuelve a la tinta para que el cuerpo de la tabla no herede el blanco de una banda con acento."""
    palette = pdf.palette
    pdf.set_fill_color(*palette.table_head_fill)
    pdf.set_text_color(*palette.table_head_text)
    pdf.set_font("Helvetica", "B", 8.5)
    pdf.set_x(_MARGIN)
    # Un solo relleno de punta a punta: rellenar cada celda por separado deja una línea clara en cada unión
    # (se nota al verlo en pantalla con un acento). Los rótulos van sobre él, con sus bordes superior e inferior.
    pdf.rect(_MARGIN, pdf.get_y(), _WIDTH, _HEAD_H, style="F")
    for label, width, align in _COLUMNS:
        pdf.cell(width, _HEAD_H, _latin1(label), border="TB", align=align)
    pdf.ln(_HEAD_H)
    pdf.set_text_color(*_INK)


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


def render_invoice_pdf(view: InvoiceView, branding: DocumentBranding | None = None) -> bytes:
    """Dibuja la factura (A4). Sin lógica de negocio: lo fiscal sale de `view`; la marca de la cuenta
    (`branding`, opcional) suma el logo, el contacto y el color de la banda y del título. Sin marca,
    dibuja exactamente lo de siempre."""
    pdf = _InvoicePDF(view, branding)
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
