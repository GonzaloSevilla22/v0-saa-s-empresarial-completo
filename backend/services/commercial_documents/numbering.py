"""
Numeración interna visible de los documentos comerciales (presupuestos-modulo
D3, capability `internal-document-numbering`).

El número vive en la base (`internal_document_sequences`, asignado por el
disparador genérico de cada tabla); acá sólo está cómo se MUESTRA y cómo se
lee lo que el usuario escribe en el buscador del listado. La definición en
TypeScript es `frontend/lib/internal-document-number.ts`; las dos corren contra
el mismo fixture, `backend/tests/fixtures/internal_document_number_cases.json`.
"""
from __future__ import annotations

import re

# Prefijo visible por TIPO DE SECUENCIA (no por tabla): el remito de venta
# (`delivery_note_sale`) numera con su propia secuencia y su prefijo `R`; el de
# compra (`remitos-compra`) sumará el suyo, DISTINTO de `R` (cada sentido numera
# desde 1: con el mismo prefijo los dos mostrarían `R-00000001`). Un tipo sin
# prefijo declarado se rechaza en vez de inventar uno.
_PREFIX_BY_TYPE = {"quote": "P", "delivery_note_sale": "R"}

_PAD = 8

# El mayor entero que JavaScript representa sin redondear: el fixture compartido
# exige que ninguna de las dos implementaciones compare contra un bigint
# redondeado.
_MAX_SAFE_INTEGER = 9007199254740991

# El buscador de cada listado acepta el número con SU prefijo (o sin prefijo):
# en presupuestos "P-12", "12" o "00000012"; en remitos "R-12", "12" o
# "00000012". El prefijo de otro tipo no es de ese listado: se busca como texto
# (si no, "R-12" en /presupuestos traería P-00000012, un documento distinto del
# que el usuario escribió). Igual en la definición de TypeScript
# (`frontend/lib/internal-document-number.ts`).
_QUERY_BY_TYPE = {
    document_type: re.compile(rf"^(?:{re.escape(prefix)}-)?([0-9]+)$", re.IGNORECASE)
    for document_type, prefix in _PREFIX_BY_TYPE.items()
}


def format_internal_document_number(document_type: str, number: int | None) -> str | None:
    """`quote`, 12 -> `P-00000012`; `delivery_note_sale`, 12 -> `R-00000012`. Un número de más de 8 dígitos no se trunca.

    `None` (documento escrito bajo `session_replication_role = replica`, sin
    número) no tiene etiqueta.
    """
    prefix = _PREFIX_BY_TYPE.get(document_type)
    if prefix is None:
        raise ValueError(f"tipo de documento sin numeración interna: {document_type!r}")
    if number is None:
        return None
    return f"{prefix}-{number:0{_PAD}d}"


def parse_internal_document_number_query(text: str | None, document_type: str) -> int | None:
    """El número que el usuario busca en el listado de `document_type` ("P-12" en
    presupuestos, "R-12" en remitos, "12", "00000012"), o `None` si el texto no es
    un número de documento de ESE tipo (entonces se busca por nombre).

    Un número de documento es un entero positivo: "0", "-5" y los textos mixtos
    ("12a", "P-12-3") no lo son, y el prefijo de otro tipo tampoco.
    """
    pattern = _QUERY_BY_TYPE.get(document_type)
    if pattern is None:
        raise ValueError(f"tipo de documento sin numeración interna: {document_type!r}")
    match = pattern.match((text or "").strip())
    if match is None:
        return None
    value = int(match.group(1))
    if value < 1 or value > _MAX_SAFE_INTEGER:
        return None
    return value
