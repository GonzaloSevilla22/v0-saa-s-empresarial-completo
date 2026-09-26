"""ventas-unidades-conversion — cuarta revisión del PR #584 (D-F′).

El precio de una línea es por unidad DE LA LÍNEA: $4.575/kg vendido en gramos
es $4,575/g. El PDF del comprobante lo imprimía con `_format_amount` (2
decimales): "100 g × $ 4,58 = $ 457,50" (100 × 4,58 = 458) y "333 g × $ 1,00 =
$ 332,67". El precio UNITARIO sale con su precisión (hasta 5 decimales, la que
conserva roundUnitPrice); un precio al centavo sale igual que antes. Los
importes (subtotal y total) siguen al centavo.
"""
from __future__ import annotations

from decimal import Decimal

from backend.services import receipts
from backend.services.receipts import (
    SalesReceiptData,
    SalesReceiptItem,
    _format_amount,
    _format_unit_price,
    build_sales_receipt_pdf,
)


def test_sub_cent_unit_price_keeps_its_precision():
    assert _format_unit_price(Decimal("4.575"), "ARS") == "$ 4,575"
    assert _format_unit_price(Decimal("1.23456"), "ARS") == "$ 1,23456"
    assert _format_unit_price(Decimal("0.999"), "ARS") == "$ 0,999"


def test_cent_unit_price_is_formatted_like_an_amount():
    for value in (Decimal("1800"), Decimal("1.8"), Decimal("1234.56"), 34900, 0):
        assert _format_unit_price(value, "ARS") == _format_amount(value, "ARS")


def test_binary_noise_and_more_than_five_decimals_are_capped():
    assert _format_unit_price(4.575 * 0.9, "ARS") == "$ 4,1175"
    assert _format_unit_price(Decimal("1.234567"), "ARS") == "$ 1,23457"
    assert _format_unit_price(Decimal("1234.5678"), "USD") == "USD 1.234,5678"


def test_sales_receipt_pdf_prints_the_unit_price_with_its_precision(monkeypatch):
    seen: list[tuple[object, str]] = []
    original = receipts._format_unit_price

    def spy(amount, currency):
        seen.append((amount, currency))
        return original(amount, currency)

    monkeypatch.setattr(receipts, "_format_unit_price", spy)
    pdf = build_sales_receipt_pdf(
        SalesReceiptData(
            business_name="Fiambrería",
            receipt_number="0001",
            date_label="Jueves 25 de septiembre de 2026",
            items=[SalesReceiptItem(name="Jamón", quantity="100 g", unit_price=Decimal("4.575"), subtotal=Decimal("457.5"))],
            total=Decimal("457.5"),
        )
    )
    assert pdf.startswith(b"%PDF")
    assert seen == [(Decimal("4.575"), "ARS")]
