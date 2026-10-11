"""
documentos-marca-empresa — grupo 3: paleta de colores de los papeles y su
contraste verificable (tasks 3.1 RED, 3.2 GREEN, 3.3 triangulación).

Criterio de aceptación: spec `document-branding`, requirement "Paleta de colores
de los papeles con contraste verificable" (design D3).

El cálculo de contraste de Python es la AUTORIDAD (el servidor rechaza un acento
ilegible y el render cae a Neutro); el frontend lo espeja en
`frontend/lib/color-contrast.ts` para el aviso en vivo. Los dos se atan con el
fixture compartido `backend/tests/fixtures/document_palette_cases.json`, que
este archivo LEE (no copia) y que vitest lee también.

Run: python -m pytest backend/tests/test_document_palette.py -q -p no:cacheprovider
"""
from __future__ import annotations

import json
import logging
from pathlib import Path

import pytest

from backend.services.commercial_documents.palette import (
    MIN_ACCENT_CONTRAST,
    NEUTRAL,
    PALETTE_CATALOG,
    WHITE,
    DocumentPalette,
    best_text_on,
    contrast_ratio,
    display_contrast,
    hex_to_rgb,
    is_valid_accent,
    palette_catalog_for_api,
    relative_luminance,
    resolve_palette,
)

_FIXTURE = json.loads(
    (Path(__file__).parent / "fixtures" / "document_palette_cases.json").read_text(encoding="utf-8")
)
_CASES = _FIXTURE["cases"]
_RESOLVE = _FIXTURE["resolve"]
_INK = hex_to_rgb(_FIXTURE["ink"])


def _text_rgb(name: str):
    return WHITE if name == "white" else _INK


# ── contraste (fixture compartido) ────────────────────────────────────────────

@pytest.mark.parametrize("case", _CASES, ids=[c["color"] for c in _CASES])
def test_contrast_against_the_shared_fixture(case):
    rgb = hex_to_rgb(case["color"])
    ratio = contrast_ratio(rgb, WHITE)
    assert display_contrast(ratio) == case["contrast"], case["note"]
    assert (ratio >= MIN_ACCENT_CONTRAST) == case["accepted"], case["note"]
    assert is_valid_accent(case["color"]) is case["accepted"], case["note"]
    assert best_text_on(rgb) == _text_rgb(case["text_on"]), case["note"]


def test_min_accent_contrast_is_the_wcag_aa_threshold_of_the_fixture():
    assert MIN_ACCENT_CONTRAST == _FIXTURE["min_accent_contrast"] == 4.5


def test_the_old_green_of_the_papers_is_not_selectable():
    """El verde de hoy (16,185,129) mide 2,54:1 contra blanco: no pasa AA."""
    assert not is_valid_accent("#10b981")
    assert display_contrast(contrast_ratio((16, 185, 129), WHITE)) == 2.54


def test_luminance_extremes():
    assert relative_luminance((0, 0, 0)) == 0.0
    assert relative_luminance((255, 255, 255)) == pytest.approx(1.0)
    assert contrast_ratio((0, 0, 0), WHITE) == pytest.approx(21.0)


def test_contrast_is_symmetric():
    assert contrast_ratio(WHITE, _INK) == pytest.approx(contrast_ratio(_INK, WHITE))


def test_display_never_shows_4_50_for_a_rejected_color():
    """4,49976 redondea a 4,50 pero se rechaza: el aviso muestra 4,49."""
    ratio = contrast_ratio(hex_to_rgb("#ac5e80"), WHITE)
    assert ratio < MIN_ACCENT_CONTRAST
    assert round(ratio, 2) == 4.50
    assert display_contrast(ratio) == 4.49


# ── catálogo ──────────────────────────────────────────────────────────────────

def test_catalog_matches_the_fixture_and_every_accent_reads_on_white():
    assert {k: spec.accent_hex for k, spec in PALETTE_CATALOG.items() if spec.accent_hex} == _FIXTURE["catalog"]
    for key, spec in PALETTE_CATALOG.items():
        if spec.accent_hex is None:
            continue
        assert contrast_ratio(hex_to_rgb(spec.accent_hex), WHITE) >= MIN_ACCENT_CONTRAST, key


def test_catalog_text_on_the_accent_is_always_readable():
    """El texto de la cabecera de la tabla (blanco o tinta) cumple AA sobre cada acento."""
    for key, spec in PALETTE_CATALOG.items():
        if spec.accent_hex is None:
            continue
        accent = hex_to_rgb(spec.accent_hex)
        assert contrast_ratio(best_text_on(accent), accent) >= MIN_ACCENT_CONTRAST, key


def test_catalog_keys_and_default():
    assert list(PALETTE_CATALOG) == ["neutro", "azul", "verde", "grafito", "bordo"]
    assert NEUTRAL.key == "neutro"


def test_catalog_for_api_lists_the_six_choices_with_labels():
    listing = palette_catalog_for_api()
    assert [p["key"] for p in listing] == ["neutro", "azul", "verde", "grafito", "bordo", "personalizado"]
    by_key = {p["key"]: p for p in listing}
    assert by_key["neutro"]["accent"] is None and by_key["neutro"]["label"].startswith("Neutro")
    assert by_key["azul"]["accent"] == "#1d4ed8"
    assert by_key["personalizado"]["accent"] is None


# ── Neutro: "blanco", sin rellenos de color, la tinta de la Factura C ─────────

def test_neutral_has_no_accent_and_uses_the_invoice_ink():
    assert NEUTRAL.accent is None
    assert NEUTRAL.ink == (30, 41, 59)          # _INK de invoice_pdf.py
    assert NEUTRAL.muted == (100, 116, 139)     # _MUTED
    assert NEUTRAL.rule == (148, 163, 184)      # _RULE
    assert NEUTRAL.surface == (241, 245, 249)   # _HEAD_FILL


def test_neutral_roles_never_use_a_color_fill():
    assert NEUTRAL.heading == NEUTRAL.ink
    assert NEUTRAL.strong_rule == NEUTRAL.ink
    assert NEUTRAL.total == NEUTRAL.ink
    assert NEUTRAL.accepted_stamp == NEUTRAL.ink
    assert NEUTRAL.table_head_fill == NEUTRAL.surface
    assert NEUTRAL.table_head_text == NEUTRAL.ink
    # La tinta se lee sobre la superficie de la cabecera.
    assert contrast_ratio(NEUTRAL.table_head_text, NEUTRAL.table_head_fill) >= MIN_ACCENT_CONTRAST


def test_neutral_never_carries_the_old_green():
    palette_colors = {NEUTRAL.ink, NEUTRAL.muted, NEUTRAL.rule, NEUTRAL.surface, NEUTRAL.heading,
                      NEUTRAL.strong_rule, NEUTRAL.total, NEUTRAL.accepted_stamp,
                      NEUTRAL.table_head_fill, NEUTRAL.table_head_text}
    assert (16, 185, 129) not in palette_colors


# ── con acento: título, regla, cabecera, total y sello ────────────────────────

def test_accent_palette_roles():
    azul = resolve_palette("azul", None)
    accent = hex_to_rgb("#1d4ed8")
    assert azul.accent == accent
    assert azul.heading == accent
    assert azul.strong_rule == accent
    assert azul.total == accent
    assert azul.accepted_stamp == accent
    assert azul.table_head_fill == accent
    assert azul.table_head_text == WHITE            # blanco sobre azul
    # La base (tinta, gris, regla) es la de Neutro en todas las paletas.
    assert (azul.ink, azul.muted, azul.rule, azul.surface) == (NEUTRAL.ink, NEUTRAL.muted, NEUTRAL.rule, NEUTRAL.surface)


def test_header_text_is_white_on_every_valid_accent_and_the_ink_only_on_light_fills():
    """Todo acento aceptado (>= 4,5 contra blanco) es oscuro, así que la cabecera lleva texto
    blanco; best_text_on devuelve la tinta sólo para fondos claros (p. ej. la superficie)."""
    assert resolve_palette("personalizado", "#7c2d12").table_head_text == WHITE
    assert resolve_palette("grafito", None).table_head_text == WHITE
    assert best_text_on(hex_to_rgb("#facc15")) == _INK
    assert best_text_on(NEUTRAL.surface) == _INK


# ── resolve_palette: cae a Neutro ante cualquier valor guardado inválido ──────

@pytest.mark.parametrize(
    "case", _RESOLVE, ids=[f"{c['preset']}/{c['accent']}" for c in _RESOLVE]
)
def test_resolve_palette_against_the_shared_fixture(case):
    palette = resolve_palette(case["preset"], case["accent"])
    assert isinstance(palette, DocumentPalette)
    assert palette.key == case["key"]
    expected = hex_to_rgb(case["accent_hex"]) if case["accent_hex"] else None
    assert palette.accent == expected


def test_resolve_palette_logs_when_it_falls_back(caplog):
    with caplog.at_level(logging.WARNING, logger="backend.services.commercial_documents.palette"):
        resolve_palette("personalizado", "#10b981")
    assert any("Neutro" in r.getMessage() for r in caplog.records)


def test_resolve_palette_is_silent_for_valid_values(caplog):
    with caplog.at_level(logging.WARNING, logger="backend.services.commercial_documents.palette"):
        resolve_palette("bordo", None)
        resolve_palette("neutro", None)
        resolve_palette(None, None)
    assert not caplog.records


# ── hex_to_rgb ────────────────────────────────────────────────────────────────

def test_hex_to_rgb_parses_lowercase_six_digit_colors():
    assert hex_to_rgb("#1d4ed8") == (29, 78, 216)
    assert hex_to_rgb("#000000") == (0, 0, 0)


@pytest.mark.parametrize("bad", ["", "1d4ed8", "#1d4", "#1D4ED8", "#1d4ed8ff", "#gggggg", "rgb(1,2,3)", None, 7])
def test_hex_to_rgb_rejects_anything_that_is_not_a_lowercase_6_digit_hex(bad):
    with pytest.raises(ValueError):
        hex_to_rgb(bad)  # type: ignore[arg-type]
    assert is_valid_accent(bad) is False  # type: ignore[arg-type]
