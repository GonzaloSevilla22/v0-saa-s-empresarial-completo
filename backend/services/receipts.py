"""Generación del PDF del recibo de pago (no es factura fiscal).

Comprobante simple emitido por ALIADATA al aprobarse un pago de MercadoPago.
Usa fpdf2 (fuentes core latin-1): evitar caracteres fuera de latin-1 (no usar
em-dash ni comillas tipográficas) o fpdf lanzará al renderizar.
"""
from __future__ import annotations

import base64
import datetime
from collections.abc import Mapping
from dataclasses import dataclass
from decimal import Decimal

from fpdf import FPDF

PLAN_DISPLAY = {
    "gratis": "Gratis",
    "inicial": "Inicial",
    "avanzado": "Avanzado",
    "pro": "Pro",
}

EMERALD = (16, 185, 129)
SLATE = (51, 65, 85)
GRAY = (107, 114, 128)


@dataclass(frozen=True)
class ReceiptData:
    receipt_number: str
    issued_at: datetime.datetime | datetime.date
    customer_email: str
    plan: str
    amount: Decimal | float | int
    payment_id: str
    customer_name: str | None = None
    currency: str = "ARS"


def _format_amount(amount: Decimal | float | int, currency: str) -> str:
    """1234567.5 -> '$ 1.234.567,50' (formato AR)."""
    s = f"{float(amount):,.2f}"  # '1,234,567.50'
    s = s.replace(",", "X").replace(".", ",").replace("X", ".")  # '1.234.567,50'
    symbol = "$" if currency == "ARS" else currency
    return f"{symbol} {s}"


def _format_date(value: datetime.datetime | datetime.date) -> str:
    if isinstance(value, datetime.datetime):
        value = value.date()
    return value.strftime("%d/%m/%Y")


def build_receipt_pdf(data: ReceiptData) -> bytes:
    """Devuelve los bytes de un PDF de una página con el recibo de pago."""
    plan_label = PLAN_DISPLAY.get(data.plan, data.plan.capitalize())

    pdf = FPDF(orientation="P", unit="mm", format="A4")
    pdf.set_auto_page_break(auto=True, margin=20)
    pdf.add_page()
    pdf.set_margins(20, 20, 20)

    # ── Encabezado ────────────────────────────────────────────────────────────
    pdf.set_font("Helvetica", "B", 24)
    pdf.set_text_color(*EMERALD)
    pdf.cell(0, 12, "ALIADATA", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "", 11)
    pdf.set_text_color(*GRAY)
    pdf.cell(0, 6, "Aliadata", new_x="LMARGIN", new_y="NEXT")

    pdf.ln(6)
    pdf.set_draw_color(*EMERALD)
    pdf.set_line_width(0.6)
    pdf.line(20, pdf.get_y(), 190, pdf.get_y())
    pdf.ln(8)

    # ── Titulo + datos del recibo ─────────────────────────────────────────────
    pdf.set_font("Helvetica", "B", 16)
    pdf.set_text_color(*SLATE)
    pdf.cell(0, 9, "RECIBO DE PAGO", new_x="LMARGIN", new_y="NEXT")

    pdf.set_font("Helvetica", "", 11)
    pdf.set_text_color(*SLATE)
    pdf.cell(95, 7, f"Recibo N: {data.receipt_number}", new_x="RIGHT", new_y="TOP")
    pdf.cell(0, 7, f"Fecha: {_format_date(data.issued_at)}", new_x="LMARGIN", new_y="NEXT")
    pdf.ln(4)

    # ── Cliente ───────────────────────────────────────────────────────────────
    pdf.set_font("Helvetica", "B", 11)
    pdf.cell(0, 7, "Cliente", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "", 11)
    if data.customer_name:
        pdf.cell(0, 6, data.customer_name, new_x="LMARGIN", new_y="NEXT")
    pdf.cell(0, 6, data.customer_email, new_x="LMARGIN", new_y="NEXT")
    pdf.ln(6)

    # ── Detalle ───────────────────────────────────────────────────────────────
    pdf.set_fill_color(*EMERALD)
    pdf.set_text_color(255, 255, 255)
    pdf.set_font("Helvetica", "B", 11)
    pdf.cell(120, 9, "  Concepto", border=0, fill=True, new_x="RIGHT", new_y="TOP")
    pdf.cell(50, 9, "Importe  ", border=0, fill=True, align="R", new_x="LMARGIN", new_y="NEXT")

    pdf.set_text_color(*SLATE)
    pdf.set_font("Helvetica", "", 11)
    concept = f"  Suscripcion mensual - Plan {plan_label}"
    amount_str = _format_amount(data.amount, data.currency)
    pdf.cell(120, 10, concept, border="B", new_x="RIGHT", new_y="TOP")
    pdf.cell(50, 10, f"{amount_str}  ", border="B", align="R", new_x="LMARGIN", new_y="NEXT")

    pdf.set_font("Helvetica", "B", 12)
    pdf.cell(120, 11, "  Total", new_x="RIGHT", new_y="TOP")
    pdf.cell(50, 11, f"{amount_str}  ", align="R", new_x="LMARGIN", new_y="NEXT")
    pdf.ln(8)

    # ── Datos del pago ────────────────────────────────────────────────────────
    pdf.set_font("Helvetica", "", 10)
    pdf.set_text_color(*GRAY)
    pdf.cell(0, 6, "Metodo de pago: MercadoPago", new_x="LMARGIN", new_y="NEXT")
    pdf.cell(0, 6, f"ID de pago: {data.payment_id}", new_x="LMARGIN", new_y="NEXT")
    pdf.ln(10)

    # ── Leyenda + pie ─────────────────────────────────────────────────────────
    pdf.set_font("Helvetica", "I", 9)
    pdf.set_text_color(*GRAY)
    pdf.multi_cell(
        0, 5,
        "Comprobante de pago. No es una factura. "
        "Confirma la acreditacion del pago de tu suscripcion a ALIADATA.",
    )

    out = pdf.output()
    return bytes(out)


def build_receipt_pdf_base64(data: ReceiptData) -> str:
    """Igual que build_receipt_pdf pero devuelve el PDF en base64 (para adjuntar
    en el email_logs.metadata y que la Edge Function lo mande como adjunto)."""
    return base64.b64encode(build_receipt_pdf(data)).decode("ascii")


def _latin1(text: str | None) -> str:
    """fpdf con fuentes core solo soporta latin-1: reemplaza lo que no entra
    (emojis, etc.) por '?' en vez de romper al renderizar."""
    return (text or "").encode("latin-1", "replace").decode("latin-1")


# ── Comprobante de VENTA (el que el comercio le manda a su cliente) ───────────

@dataclass(frozen=True)
class SalesReceiptItem:
    name: str
    quantity: str
    unit_price: Decimal | float | int
    subtotal: Decimal | float | int


@dataclass(frozen=True)
class SalesReceiptData:
    business_name: str
    receipt_number: str
    date_label: str
    items: list[SalesReceiptItem]
    total: Decimal | float | int
    currency: str = "ARS"
    client_name: str | None = None
    business_phone: str | None = None
    business_email: str | None = None


def build_sales_receipt_pdf(data: SalesReceiptData) -> bytes:
    """PDF de una página del comprobante de venta (negocio → cliente final)."""
    biz = _latin1(data.business_name) or "Mi Negocio"

    pdf = FPDF(orientation="P", unit="mm", format="A4")
    pdf.set_auto_page_break(auto=True, margin=18)
    pdf.add_page()
    pdf.set_margins(18, 18, 18)

    # ── Encabezado: negocio + N° de comprobante ───────────────────────────────
    pdf.set_font("Helvetica", "B", 20)
    pdf.set_text_color(*SLATE)
    pdf.cell(120, 10, biz[:38], new_x="RIGHT", new_y="TOP")
    pdf.set_font("Helvetica", "B", 13)
    pdf.set_text_color(*EMERALD)
    pdf.cell(0, 10, f"N {data.receipt_number}", align="R", new_x="LMARGIN", new_y="NEXT")

    pdf.set_font("Helvetica", "", 10)
    pdf.set_text_color(*GRAY)
    contacto = " | ".join(
        p for p in [_latin1(data.business_phone), _latin1(data.business_email)] if p
    )
    if contacto:
        pdf.cell(0, 6, contacto, new_x="LMARGIN", new_y="NEXT")
    pdf.cell(0, 6, "Comprobante de venta", new_x="LMARGIN", new_y="NEXT")

    pdf.ln(4)
    pdf.set_draw_color(*EMERALD)
    pdf.set_line_width(0.6)
    pdf.line(18, pdf.get_y(), 192, pdf.get_y())
    pdf.ln(6)

    # ── Cliente + fecha ───────────────────────────────────────────────────────
    pdf.set_font("Helvetica", "", 11)
    pdf.set_text_color(*SLATE)
    cliente = _latin1(data.client_name) if data.client_name else "Consumidor final"
    pdf.cell(110, 6, f"Cliente: {cliente}", new_x="RIGHT", new_y="TOP")
    pdf.cell(0, 6, _latin1(data.date_label), align="R", new_x="LMARGIN", new_y="NEXT")
    pdf.ln(4)

    # ── Tabla de items ────────────────────────────────────────────────────────
    pdf.set_fill_color(*EMERALD)
    pdf.set_text_color(255, 255, 255)
    pdf.set_font("Helvetica", "B", 10)
    pdf.cell(86, 9, "  Descripcion", fill=True, new_x="RIGHT", new_y="TOP")
    pdf.cell(18, 9, "Cant.", fill=True, align="C", new_x="RIGHT", new_y="TOP")
    pdf.cell(35, 9, "P. unit.", fill=True, align="R", new_x="RIGHT", new_y="TOP")
    pdf.cell(35, 9, "Subtotal  ", fill=True, align="R", new_x="LMARGIN", new_y="NEXT")

    pdf.set_text_color(*SLATE)
    pdf.set_font("Helvetica", "", 10)
    for item in data.items:
        pdf.cell(86, 9, "  " + _latin1(item.name)[:46], border="B", new_x="RIGHT", new_y="TOP")
        pdf.cell(18, 9, str(item.quantity), border="B", align="C", new_x="RIGHT", new_y="TOP")
        pdf.cell(35, 9, _format_amount(item.unit_price, data.currency), border="B", align="R", new_x="RIGHT", new_y="TOP")
        pdf.cell(35, 9, _format_amount(item.subtotal, data.currency) + "  ", border="B", align="R", new_x="LMARGIN", new_y="NEXT")

    # ── Total ─────────────────────────────────────────────────────────────────
    pdf.ln(2)
    pdf.set_font("Helvetica", "B", 13)
    pdf.set_text_color(*SLATE)
    pdf.cell(104, 11, "", new_x="RIGHT", new_y="TOP")
    pdf.cell(35, 11, "TOTAL", align="R", new_x="RIGHT", new_y="TOP")
    pdf.set_text_color(*EMERALD)
    pdf.cell(35, 11, _format_amount(data.total, data.currency) + "  ", align="R", new_x="LMARGIN", new_y="NEXT")

    # ── Pie ───────────────────────────────────────────────────────────────────
    pdf.ln(10)
    pdf.set_font("Helvetica", "B", 11)
    pdf.set_text_color(*SLATE)
    pdf.cell(0, 6, "Gracias por su compra!", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "", 9)
    pdf.set_text_color(*GRAY)
    pdf.cell(0, 5, "Este documento es su comprobante de venta.", new_x="LMARGIN", new_y="NEXT")

    return bytes(pdf.output())


def receipt_data_from_row(row: Mapping) -> ReceiptData:
    """Construye ReceiptData desde una fila de BillingRepository.get_receipt
    (claves: receipt_number, payment_id, plan, amount, created_at,
    customer_email, customer_name, id)."""
    return ReceiptData(
        receipt_number=row["receipt_number"] or f"RC-{row['id']}",
        issued_at=row["created_at"],
        customer_email=row["customer_email"],
        customer_name=row.get("customer_name"),
        plan=row["plan"] or "",
        amount=row["amount"] or 0,
        payment_id=row["payment_id"] or "-",
    )
