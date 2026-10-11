"""
Sanitizador de texto para las fuentes core de `fpdf2` (documentos-marca-empresa
D5).

Las fuentes core son de 1 byte (Windows-1252). `fpdf2` rechaza cualquier
carácter fuera de latin-1 ANTES de codificar, pero el guion largo ("—"), las
comillas tipográficas y el euro SÍ entran en cp1252 y la fuente los dibuja con su
codificación WinAnsi. Por eso `pdf_text` convierte a cp1252 y reinterpreta los
bytes como latin-1; lo que ni cp1252 representa (un emoji) se sustituye por `?`
en vez de hacer fallar el documento.

Vivía privado en `pdf.py` (`_pdf_text`); se promueve acá porque el encabezado
compartido (`header.py`), el presupuesto, los remitos y el comprobante interno lo
usan por igual: un nombre comercial con "—" o "€" tiene que imprimirse bien en
todos los papeles. El `_latin1` de `services/receipts.py` convertiría el guion
largo en `?` y se conserva sólo para los textos que ya lo usaban.
"""
from __future__ import annotations


def pdf_text(text: str | None) -> str:
    """Texto seguro para una fuente core (ver el docstring del módulo)."""
    return (text or "").encode("cp1252", "replace").decode("latin-1")
