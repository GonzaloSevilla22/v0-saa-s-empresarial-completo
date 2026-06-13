"""Tests del generador de PDF del recibo de pago (#4 comprobante)."""
from __future__ import annotations

import datetime
from decimal import Decimal

from backend.services.receipts import ReceiptData, _format_amount, build_receipt_pdf


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
