"""
Paleta de colores de los papeles de la cuenta (documentos-marca-empresa D3,
capability `document-branding`).

Una sola fuente de los colores que dibujan el comprobante interno de venta, el
presupuesto, los remitos y (tanda B) los elementos NO fiscales de la Factura C.
Antes la paleta estaba repetida cuatro veces (`receipts.py`, `invoice_pdf.py`,
`lib/receipt.ts` y las plantillas de email) y el verde de los papeles
(16,185,129) ni siquiera pasaba AA: texto blanco sobre ese verde mide 2,54:1.

Catálogo cerrado —Neutro (por defecto, "blanco"), Azul, Verde, Grafito, Bordó— y
"Personalizado" con un color elegido por la cuenta. Toda paleta comparte la BASE
de la Factura C (tinta pizarra oscura, gris para lo secundario, regla gris,
superficie gris muy clara); lo único que cambia es el ACENTO:

  - Neutro: sin acento. Título, regla del encabezado, total y sello en tinta; la
    cabecera de la tabla en la superficie clara con texto en tinta. Es el
    "blanco" que pidió el PO y unifica los papeles con la factura.
  - Con acento: título, regla del encabezado, banda de la cabecera de la tabla,
    total y sello "ACEPTADO" en el acento; el texto sobre la banda es el blanco o
    la tinta, el que dé MÁS contraste (`best_text_on`).

Regla de contraste: todo acento >= 4,5:1 contra blanco (WCAG 2.1 AA, texto
normal). El acento se usa como texto sobre el papel blanco (título, total) y
como fondo de texto blanco (cabecera), y con esa regla los dos usos pasan. El
servicio rechaza un personalizado que no cumple (422
`branding_accent_low_contrast`) y `resolve_palette` cae a NEUTRO —y loguea— ante
un valor guardado inválido o ilegible: la tabla no calcula contraste, así que
una escritura directa por PostgREST nunca produce un papel ilegible.

Este módulo es la AUTORIDAD del cálculo. El frontend lo espeja
(`frontend/lib/color-contrast.ts`) sólo para el aviso en vivo; los dos se atan
con el fixture `backend/tests/fixtures/document_palette_cases.json`.

Módulo puro: sin I/O.
"""
from __future__ import annotations

import logging
import re
from dataclasses import dataclass

logger = logging.getLogger(__name__)

RGB = tuple[int, int, int]

WHITE: RGB = (255, 255, 255)
MIN_ACCENT_CONTRAST = 4.5

# Base compartida por todas las paletas = la tinta de la Factura C
# (`invoice_pdf._INK/_MUTED/_RULE/_HEAD_FILL`, que pasan a importarla en la
# tanda B). #1e293b sobre blanco mide 14,63:1; #64748b, 4,76:1.
_INK: RGB = (30, 41, 59)
_MUTED: RGB = (100, 116, 139)
_RULE: RGB = (148, 163, 184)
_SURFACE: RGB = (241, 245, 249)

_HEX_COLOR = re.compile(r"[#][0-9a-f]{6}")

CUSTOM_PALETTE_KEY = "personalizado"


def hex_to_rgb(value: str) -> RGB:
    """`#rrggbb` en minúsculas -> (r, g, b). Cualquier otra forma (mayúsculas,
    3 dígitos, sin almohadilla, con canal alfa) lanza `ValueError`: es la misma
    forma que exige el CHECK de la tabla y el esquema de la API."""
    if not isinstance(value, str) or _HEX_COLOR.fullmatch(value) is None:
        raise ValueError(f"color inválido: {value!r} (se espera #rrggbb en minúsculas)")
    return int(value[1:3], 16), int(value[3:5], 16), int(value[5:7], 16)


def _linear(channel: int) -> float:
    c = channel / 255
    return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4


def relative_luminance(rgb: RGB) -> float:
    """Luminancia relativa WCAG 2.1 (0 = negro, 1 = blanco)."""
    r, g, b = rgb
    return 0.2126 * _linear(r) + 0.7152 * _linear(g) + 0.0722 * _linear(b)


def contrast_ratio(a: RGB, b: RGB) -> float:
    """Contraste WCAG entre dos colores (1 a 21), simétrico."""
    la, lb = relative_luminance(a), relative_luminance(b)
    hi, lo = (la, lb) if la >= lb else (lb, la)
    return (hi + 0.05) / (lo + 0.05)


def best_text_on(background: RGB) -> RGB:
    """El texto —blanco o la tinta— de MAYOR contraste sobre `background`
    (empate: blanco)."""
    return WHITE if contrast_ratio(WHITE, background) >= contrast_ratio(_INK, background) else _INK


def display_contrast(ratio: float) -> float:
    """El contraste como se le muestra a la persona: 2 decimales. Un valor por
    debajo del mínimo NUNCA se muestra como 4,50 (4,49976 redondea a 4,50 pero se
    rechaza): el aviso no puede contradecir el rechazo."""
    shown = round(ratio + 1e-12, 2)
    if ratio < MIN_ACCENT_CONTRAST and shown >= MIN_ACCENT_CONTRAST:
        return 4.49
    return shown


def is_valid_accent(value: str) -> bool:
    """¿Es `value` un `#rrggbb` que se lee sobre blanco (>= 4,5:1)? El umbral
    se aplica al valor EXACTO, no al redondeado."""
    try:
        return contrast_ratio(hex_to_rgb(value), WHITE) >= MIN_ACCENT_CONTRAST
    except ValueError:
        return False


@dataclass(frozen=True)
class PaletteSpec:
    """Una entrada del catálogo: clave estable, rótulo y acento (`None` = sin acento)."""

    key: str
    label: str
    accent_hex: str | None


PALETTE_CATALOG: dict[str, PaletteSpec] = {
    spec.key: spec
    for spec in (
        PaletteSpec("neutro", "Neutro (blanco)", None),
        PaletteSpec("azul", "Azul", "#1d4ed8"),
        PaletteSpec("verde", "Verde", "#047857"),
        PaletteSpec("grafito", "Grafito", "#334155"),
        PaletteSpec("bordo", "Bordó", "#9f1239"),
    )
}


@dataclass(frozen=True)
class DocumentPalette:
    """Los colores con los que se dibuja un papel. Inmutable: se resuelve una
    vez por documento y se pasa al render."""

    key: str
    ink: RGB
    muted: RGB
    rule: RGB
    surface: RGB
    accent: RGB | None

    @property
    def heading(self) -> RGB:
        """Título del documento (PRESUPUESTO, REMITO, N°…)."""
        return self.accent or self.ink

    @property
    def strong_rule(self) -> RGB:
        """Regla gruesa bajo el encabezado."""
        return self.accent or self.ink

    @property
    def table_head_fill(self) -> RGB:
        """Relleno de la cabecera de la tabla de líneas."""
        return self.accent or self.surface

    @property
    def table_head_text(self) -> RGB:
        """Texto de la cabecera de la tabla: el de mayor contraste sobre el relleno."""
        return best_text_on(self.table_head_fill)

    @property
    def total(self) -> RGB:
        """Importe total."""
        return self.accent or self.ink

    @property
    def accepted_stamp(self) -> RGB:
        """Sello "ACEPTADO" de un presupuesto (los de advertencia conservan su rojo)."""
        return self.accent or self.ink


NEUTRAL = DocumentPalette(
    key="neutro", ink=_INK, muted=_MUTED, rule=_RULE, surface=_SURFACE, accent=None
)


def _with_accent(key: str, accent: RGB) -> DocumentPalette:
    return DocumentPalette(key=key, ink=_INK, muted=_MUTED, rule=_RULE, surface=_SURFACE, accent=accent)


def resolve_palette(preset: str | None, accent_color: str | None) -> DocumentPalette:
    """La paleta que se dibuja para lo guardado en la cuenta. Nunca falla: ante
    un preset desconocido, un personalizado sin color, con un color mal formado o
    ilegible, devuelve NEUTRO y lo registra (un papel siempre sale legible)."""
    if preset is None or preset == "neutro":
        return NEUTRAL
    spec = PALETTE_CATALOG.get(preset)
    if spec is not None and spec.accent_hex is not None:
        # Un preset del catálogo usa SU acento: un color suelto guardado al lado
        # (incoherente; la tabla lo rechaza) se ignora.
        return _with_accent(spec.key, hex_to_rgb(spec.accent_hex))
    if preset == CUSTOM_PALETTE_KEY and accent_color is not None and is_valid_accent(accent_color):
        return _with_accent(CUSTOM_PALETTE_KEY, hex_to_rgb(accent_color))
    logger.warning(
        "document-branding: paleta %r con color %r inválida o ilegible; se usa Neutro", preset, accent_color
    )
    return NEUTRAL


def palette_catalog_for_api() -> list[dict[str, str | None]]:
    """El catálogo para `GET /document-branding`: las 6 opciones, con su
    acento (el de "Personalizado" lo elige la cuenta)."""
    listing: list[dict[str, str | None]] = [
        {"key": spec.key, "label": spec.label, "accent": spec.accent_hex}
        for spec in PALETTE_CATALOG.values()
    ]
    listing.append({"key": CUSTOM_PALETTE_KEY, "label": "Personalizado", "accent": None})
    return listing
