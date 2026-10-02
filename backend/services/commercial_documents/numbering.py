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

# Prefijo visible por tipo de documento. El remito suma el suyo de forma
# aditiva; un tipo sin prefijo declarado se rechaza en vez de inventar uno.
_PREFIX_BY_TYPE = {"quote": "P"}

_PAD = 8

# El mayor entero que JavaScript representa sin redondear: el fixture compartido
# exige que ninguna de las dos implementaciones compare contra un bigint
# redondeado.
_MAX_SAFE_INTEGER = 9007199254740991

_QUERY = re.compile(r"^(?:p-)?([0-9]+)$", re.IGNORECASE)


def format_internal_document_number(document_type: str, number: int | None) -> str | None:
    """`quote`, 12 -> `P-00000012`. Un número de más de 8 dígitos no se trunca.

    `None` (documento escrito bajo `session_replication_role = replica`, sin
    número) no tiene etiqueta.
    """
    prefix = _PREFIX_BY_TYPE.get(document_type)
    if prefix is None:
        raise ValueError(f"tipo de documento sin numeración interna: {document_type!r}")
    if number is None:
        return None
    return f"{prefix}-{number:0{_PAD}d}"


def parse_internal_document_number_query(text: str | None) -> int | None:
    """El número que el usuario busca ("P-12", "12", "00000012"), o `None` si
    el texto no es un número de documento (entonces se busca por nombre).

    Un número de documento es un entero positivo: "0", "-5" y los textos mixtos
    ("12a", "P-12-3") no lo son.
    """
    match = _QUERY.match((text or "").strip())
    if match is None:
        return None
    value = int(match.group(1))
    if value < 1 or value > _MAX_SAFE_INTEGER:
        return None
    return value
