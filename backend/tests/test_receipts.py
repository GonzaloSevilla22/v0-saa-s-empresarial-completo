"""Tests del generador de PDF del recibo de pago (#4 comprobante)."""
from __future__ import annotations

import datetime
from decimal import Decimal

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
        business_name="Sumar Ropa Deportiva",
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
        business_phone="2617175072",
        business_email="susanacavagnola@gmail.com",
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
            business_name="Tienda 😀",
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


async def test_sales_receipt_pdf_endpoint_returns_pdf(async_client):
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
    resp = await async_client.post(
        "/sales/receipt-pdf",
        json=payload,
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "application/pdf"
    assert resp.content.startswith(b"%PDF")
