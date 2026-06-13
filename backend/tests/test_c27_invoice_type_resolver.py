"""
C-27 v21-fiscal-profile — resolve_invoice_type (Domain Service puro).

TDD RED→GREEN:
  2.1 RED: tests que describen el comportamiento esperado del resolvedor
      RI→RI=A, RI→CF=B, RI→monotributo=B, RI→exento=B, monotributista=C.
  2.2 GREEN: services/fiscal/invoice_type_resolver.py

Spec refs: afip-fiscal-document/spec.md §"Resolución del tipo de comprobante"
"""
from __future__ import annotations

import pytest

from backend.services.fiscal.invoice_type_resolver import DocumentType, resolve_invoice_type


class TestResolveInvoiceType:
    """2.1 RED → 2.2 GREEN: función pura sin I/O."""

    # ── Happy path: RI emisor ─────────────────────────────────────────────────

    def test_ri_to_ri_returns_type_a(self):
        """RI emisor + RI receptor → tipo A (Factura A)."""
        result = resolve_invoice_type(
            emisor_iva_condition="responsable_inscripto",
            receptor_iva_condition="responsable_inscripto",
        )
        assert result == DocumentType.FACTURA_A

    def test_ri_to_consumidor_final_returns_type_b(self):
        """RI emisor + consumidor_final receptor → tipo B (Factura B)."""
        result = resolve_invoice_type(
            emisor_iva_condition="responsable_inscripto",
            receptor_iva_condition="consumidor_final",
        )
        assert result == DocumentType.FACTURA_B

    def test_ri_to_monotributista_returns_type_b(self):
        """RI emisor + monotributista receptor → tipo B."""
        result = resolve_invoice_type(
            emisor_iva_condition="responsable_inscripto",
            receptor_iva_condition="monotributista",
        )
        assert result == DocumentType.FACTURA_B

    def test_ri_to_exento_returns_type_b(self):
        """RI emisor + exento receptor → tipo B."""
        result = resolve_invoice_type(
            emisor_iva_condition="responsable_inscripto",
            receptor_iva_condition="exento",
        )
        assert result == DocumentType.FACTURA_B

    # ── Monotributista emisor: siempre C ─────────────────────────────────────

    def test_monotributista_to_any_returns_type_c(self):
        """Monotributista emisor → tipo C, independiente del receptor."""
        for receptor in ("responsable_inscripto", "consumidor_final", "exento", "monotributista"):
            result = resolve_invoice_type(
                emisor_iva_condition="monotributista",
                receptor_iva_condition=receptor,
            )
            assert result == DocumentType.FACTURA_C, (
                f"monotributista → {receptor} should be C, got {result}"
            )

    # ── Triangulación: edge cases ─────────────────────────────────────────────

    def test_ri_to_none_receptor_returns_type_b(self):
        """RI emisor + None receptor (sin datos del receptor) → tipo B (consumidor final por defecto)."""
        result = resolve_invoice_type(
            emisor_iva_condition="responsable_inscripto",
            receptor_iva_condition=None,
        )
        assert result == DocumentType.FACTURA_B

    def test_exento_emisor_returns_type_b(self):
        """Exento emisor → tipo B (trato como no RI)."""
        result = resolve_invoice_type(
            emisor_iva_condition="exento",
            receptor_iva_condition="responsable_inscripto",
        )
        assert result == DocumentType.FACTURA_B

    def test_document_type_values_are_string_literals(self):
        """DocumentType mantiene sus valores de cadena estables."""
        assert DocumentType.FACTURA_A.value == "factura_a"
        assert DocumentType.FACTURA_B.value == "factura_b"
        assert DocumentType.FACTURA_C.value == "factura_c"
