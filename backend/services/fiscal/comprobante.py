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

import re

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

# Leyenda de la condición frente al IVA del EMISOR tal como se imprime en el
# encabezado de un comprobante. documentos-marca-empresa (D4): sale de
# `invoice_pdf.py` porque el encabezado de los papeles no fiscales (presupuesto,
# remitos, comprobante interno) imprime la misma leyenda, una sola vez definida.
ISSUER_IVA_LEGEND: dict[str, str] = {
    "monotributista": "IVA RESPONSABLE MONOTRIBUTO",
    "exento": "IVA EXENTO",
    "responsable_inscripto": "IVA RESPONSABLE INSCRIPTO",
}


def format_cuit(value: object) -> str:
    """`20123456786` / `20-12345678-6` -> `20-12345678-6`. Un valor que no tiene
    11 dígitos se devuelve sin guiones, tal cual (no se inventa un formato)."""
    digits = str(value or "").replace("-", "").strip()
    if len(digits) == 11 and digits.isdigit():
        return f"{digits[:2]}-{digits[2:10]}-{digits[10]}"
    return digits


_CUIT_WEIGHTS = (5, 4, 3, 2, 7, 6, 5, 4, 3, 2)


def is_valid_cuit(value: object) -> bool:
    """¿Es un CUIT válido? 11 dígitos (con o sin guiones en `NN-NNNNNNNN-N`) y dígito
    verificador módulo 11 (pesos 5,4,3,2,7,6,5,4,3,2; 11 -> 0 y 10 -> 9). Espeja
    `isValidCuit` de `frontend/lib/cuit-utils.ts`."""
    text = str(value or "").strip()
    if not re.fullmatch(r"\d{2}-?\d{8}-?\d", text):
        return False
    digits = [int(char) for char in text.replace("-", "")]
    check = 11 - (sum(d * w for d, w in zip(digits[:10], _CUIT_WEIGHTS)) % 11)
    if check == 11:
        check = 0
    elif check == 10:
        check = 9
    return check == digits[10]


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
