"""
Tablas y reglas del comprobante fiscal compartidas entre el adapter WSFE (lo
que se le PIDE a ARCA) y la representación impresa (lo que se IMPRIME).

factura-fiscal-imprimible (D4/D8): la factura impresa y su QR tienen que decir
exactamente lo que se mandó a ARCA. Por eso el código de tipo de comprobante y
la resolución del receptor (DocTipo/DocNro) viven en UN solo lugar — antes
estaban dentro de `wsfe_adapter.py`, y copiarlos al generador del PDF habría
abierto la puerta a que diverjan (regla "reutilización antes que repetición").

Módulo puro: sin zeep, sin I/O.
"""
from __future__ import annotations

# Mapping de comprobante_type a código ARCA (CbteTipo).
COMPROBANTE_AFIP_CODE: dict[str, int] = {
    "factura_a": 1,
    "factura_b": 6,
    "factura_c": 11,
    "nota_debito_a": 2,
    "nota_credito_a": 3,
    "nota_debito_b": 7,
    "nota_credito_b": 8,
}

# Letra de cada tipo de factura (la tabla queda lista para A/B; la impresión
# hoy acepta sólo `factura_c` — ver invoice_pdf.PRINTABLE_TYPES).
COMPROBANTE_LETTER: dict[str, str] = {
    "factura_a": "A",
    "factura_b": "B",
    "factura_c": "C",
}

# DocTipo de ARCA para el receptor.
DOC_TIPO_CUIT = 80
DOC_TIPO_DNI = 96
DOC_TIPO_SIN_IDENTIFICAR = 99


def resolve_receptor_doc(
    doc_tipo: int | None,
    doc_nro: object,
    cuit_receptor: object = None,
) -> tuple[int, int]:
    """(DocTipo, DocNro) que se manda a ARCA — fiscal-receptor-iva-relay (D2).

    Precedencia: receptor_doc_tipo/receptor_doc_nro explícitos (80=CUIT,
    96=DNI) → cuit_receptor legacy (→ 80) → sin identificar (99, DocNro=0).
    Regla AFIP: DocTipo=99 ⇒ DocNro=0 (un 99 con DocNro no nulo es
    inconsistente). Un 80/96 SIN número también cae a 99/0.
    """
    if doc_tipo in (DOC_TIPO_CUIT, DOC_TIPO_DNI) and doc_nro:
        return int(doc_tipo), int(str(doc_nro).replace("-", ""))
    if cuit_receptor:
        return DOC_TIPO_CUIT, int(str(cuit_receptor).replace("-", ""))
    return DOC_TIPO_SIN_IDENTIFICAR, 0
