"""
C-27 v21-fiscal-profile — Resolución del tipo de comprobante AFIP (Domain Service puro).

Domain Service puro: sin I/O, sin dependencias externas. Testeable directamente.

Reglas AFIP (Argentina):
  - Emisor RI + Receptor RI          → Factura A
  - Emisor RI + Receptor no-RI       → Factura B (consumidor_final / monotributista / exento / None)
  - Emisor monotributista            → Factura C (independiente del receptor)
  - Emisor exento / consumidor_final → Factura B (trato como no-RI a efectos de emisión)

Spec ref: openspec/changes/v21-fiscal-profile/specs/afip-fiscal-document/spec.md
Design ref: D8
"""
from __future__ import annotations

from enum import Enum


class DocumentType(str, Enum):
    """Tipo de comprobante AFIP emitido por el sistema."""

    FACTURA_A = "factura_a"
    FACTURA_B = "factura_b"
    FACTURA_C = "factura_c"


def resolve_invoice_type(
    emisor_iva_condition: str,
    receptor_iva_condition: str | None,
) -> DocumentType:
    """Determina el tipo de comprobante AFIP (A/B/C) según las condiciones IVA.

    Función pura: sin I/O, sin efectos secundarios. Usada en el service de emisión.

    Args:
        emisor_iva_condition: condición IVA del emisor (de fiscal_profiles.iva_condition).
        receptor_iva_condition: condición IVA del receptor (de clients.iva_condition).
            None → se trata como consumidor_final.

    Returns:
        DocumentType con el tipo de comprobante correspondiente.
    """
    # Monotributista emisor → siempre tipo C (D8, spec §Resolución)
    if emisor_iva_condition == "monotributista":
        return DocumentType.FACTURA_C

    # Responsable inscripto emisor: depende del receptor
    if emisor_iva_condition == "responsable_inscripto":
        if receptor_iva_condition == "responsable_inscripto":
            return DocumentType.FACTURA_A
        # consumidor_final, monotributista, exento, None → B
        return DocumentType.FACTURA_B

    # Exento, consumidor_final u otra condición del emisor → tipo B
    return DocumentType.FACTURA_B
