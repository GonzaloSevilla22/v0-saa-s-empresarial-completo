"""balanza-etiquetas-pos (D3/D4): configuración de la balanza etiquetadora.

Cada formato (venta por peso, por unidad, varios) se describe como la pantalla
"Formato de código de barras" de la balanza: una lista ORDENADA de hasta
cuatro campos A–D con su tipo y su cantidad de dígitos. Las reglas D4 viven
en `layout_errors()` — una sola definición en el backend, espejada en zod por
`frontend/lib/scale-layout.ts`; el contrato entre las dos lo sostienen los
casos compartidos de `backend/tests/fixtures/scale_layout_cases.json`.
"""
from __future__ import annotations

import datetime
import uuid
from typing import Literal

from pydantic import BaseModel, Field, field_validator
from pydantic_core import PydanticCustomError

ScaleField = Literal["fixed", "plu", "amount", "quantity", "ignored"]
LayoutKind = Literal["weighed", "unit", "multi"]

LAYOUT_KINDS: tuple[LayoutKind, ...] = ("weighed", "unit", "multi")
EAN_PAYLOAD_DIGITS = 12
MAX_SEGMENTS = 4
HEADER_MAX_DIGITS = 3
PLU_MAX_DIGITS = 6
MAX_DECIMALS = 3
LAYOUT_ERROR_TYPE = "scale_layout_invalid"

_KIND_LABELS: dict[str, str] = {
    "weighed": "Venta por peso",
    "unit": "Venta por unidad",
    "multi": "Varios",
}
_FIELD_LETTERS = "ABCD"
_VALUE_FIELDS = ("amount", "quantity")


def _segment(field: str, digits: int, *, value: str | None = None, decimals: int | None = None) -> dict:
    return {"field": field, "digits": digits, "value": value, "decimals": decimals}


# Valores de fábrica de la Systel Cuora Neo (manual págs. 134-135). Sin fila
# en scale_settings la cuenta se comporta así, con la lectura DESHABILITADA.
FACTORY_SCALE_SETTINGS: dict = {
    "enabled": False,
    "layouts": [
        {"kind": "weighed", "enabled": True, "segments": [
            _segment("fixed", 2, value="20"), _segment("plu", 4), _segment("amount", 6, decimals=2),
        ]},
        {"kind": "unit", "enabled": True, "segments": [
            _segment("fixed", 2, value="21"), _segment("plu", 4), _segment("amount", 6, decimals=2),
        ]},
        {"kind": "multi", "enabled": True, "segments": [
            _segment("fixed", 2, value="22"), _segment("ignored", 2), _segment("ignored", 8),
        ]},
    ],
}


class ScaleSegment(BaseModel):
    field: ScaleField
    digits: int = Field(ge=0)
    value: str | None = None
    decimals: int | None = None


class ScaleLayout(BaseModel):
    kind: LayoutKind
    enabled: bool
    segments: list[ScaleSegment] = Field(default_factory=list)


class LayoutError(BaseModel):
    """Un incumplimiento de D4: el código es estable (lo usan los tests), el
    mensaje nombra el formato y el campo para mostrarlo tal cual."""

    code: str
    layout_index: int
    message: str


def _default_decimals(kind: str, field: str) -> int:
    if field == "amount":
        return 2
    return 3 if kind == "weighed" else 0


def header_of(layout: ScaleLayout) -> str | None:
    """Cabecera (valor del campo A) de un formato, o None si no la tiene."""
    if not layout.segments or layout.segments[0].field != "fixed":
        return None
    return layout.segments[0].value


def _single_layout_errors(index: int, layout: ScaleLayout) -> list[LayoutError]:
    label = _KIND_LABELS[layout.kind]
    errors: list[LayoutError] = []

    def fail(code: str, detail: str) -> None:
        errors.append(LayoutError(code=code, layout_index=index, message=f"{label}: {detail}"))

    segments = layout.segments
    # Regla 1: 1 a 4 campos que suman exactamente 12 dígitos.
    if not 1 <= len(segments) <= MAX_SEGMENTS:
        fail("segment_count_invalid", f"el formato tiene que tener entre 1 y {MAX_SEGMENTS} campos (A a D).")
        return errors
    total = sum(s.digits for s in segments)
    if total != EAN_PAYLOAD_DIGITS:
        fail("digits_sum_not_12",
             f"los campos deben sumar {EAN_PAYLOAD_DIGITS} dígitos (suman {total}); el 13.º es el verificador.")

    # Regla 2: el campo A es un número fijo de 1 a 3 dígitos que empieza con 2.
    head = segments[0]
    if head.field != "fixed":
        fail("field_a_not_fixed", "campo A: tiene que ser un número fijo (la cabecera de la etiqueta).")
    else:
        value = head.value or ""
        if not 1 <= head.digits <= HEADER_MAX_DIGITS or len(value) != head.digits or not value.isdigit():
            fail("header_length_invalid",
                 f"campo A: el número fijo tiene que tener entre 1 y {HEADER_MAX_DIGITS} dígitos "
                 "y su valor, exactamente esa cantidad de dígitos.")
        elif not value.startswith("2"):
            fail("header_not_starting_with_2",
                 "campo A: el número fijo tiene que empezar con 2 (los demás chocarían con los "
                 "códigos de productos envasados).")

    # Regla 3: PLU y campo de valor.
    live = [(i, s) for i, s in enumerate(segments) if s.digits > 0]
    plus = [(i, s) for i, s in live if s.field == "plu"]
    values = [(i, s) for i, s in live if s.field in _VALUE_FIELDS]
    if layout.kind == "multi":
        if plus:
            i, _ = plus[0]
            fail("plu_not_allowed", f"campo {_FIELD_LETTERS[i]}: el formato de varios no lleva código PLU.")
    else:
        if len(plus) != 1:
            fail("plu_missing", "tiene que haber exactamente un campo Código (PLU).")
        else:
            i, plu = plus[0]
            if plu.digits > PLU_MAX_DIGITS:
                fail("plu_digits_out_of_range",
                     f"campo {_FIELD_LETTERS[i]}: el código (PLU) admite de 1 a {PLU_MAX_DIGITS} dígitos.")
        if len(values) != 1:
            fail("value_field_count_invalid",
                 "tiene que haber exactamente un campo de valor: Importe o Cantidad.")
        else:
            # Regla 4: decimales 0–3; cantidad por unidad sin decimales.
            i, seg = values[0]
            decimals = seg.decimals if seg.decimals is not None else _default_decimals(layout.kind, seg.field)
            letter = _FIELD_LETTERS[i]
            if not 0 <= decimals <= MAX_DECIMALS:
                fail("decimals_out_of_range", f"campo {letter}: los decimales van de 0 a {MAX_DECIMALS}.")
            elif layout.kind == "unit" and seg.field == "quantity" and decimals != 0:
                fail("unit_quantity_decimals_invalid",
                     f"campo {letter}: en la venta por unidad la cantidad no lleva decimales "
                     "(una cantidad fraccionaria no se vende por unidades).")
    return errors


def layout_errors(layouts: list[ScaleLayout]) -> list[LayoutError]:
    """Reglas D4 sobre los formatos HABILITADOS (uno deshabilitado no se valida)."""
    errors: list[LayoutError] = []
    for index, layout in enumerate(layouts):
        if layout.enabled:
            errors.extend(_single_layout_errors(index, layout))

    # Regla 5: ninguna cabecera habilitada es prefijo de otra.
    headers = [(i, layouts[i], header_of(layouts[i])) for i in range(len(layouts)) if layouts[i].enabled]
    headers = [(i, lay, h) for i, lay, h in headers if h]
    for a in range(len(headers)):
        for b in range(a + 1, len(headers)):
            ia, la, ha = headers[a]
            ib, lb, hb = headers[b]
            if ha.startswith(hb) or hb.startswith(ha):
                errors.append(LayoutError(
                    code="header_prefix_conflict", layout_index=ib,
                    message=(f"{_KIND_LABELS[lb.kind]}: campo A: la cabecera {hb} se pisa con la "
                             f"{ha} de {_KIND_LABELS[la.kind]} (una es prefijo de la otra)."),
                ))
    return errors


class ScaleSettingsIn(BaseModel):
    """Payload completo de `PUT /scale-settings`."""

    enabled: bool
    layouts: list[ScaleLayout]

    @field_validator("layouts")
    @classmethod
    def _validate_layouts(cls, layouts: list[ScaleLayout]) -> list[ScaleLayout]:
        kinds = tuple(layout.kind for layout in layouts)
        if kinds != LAYOUT_KINDS:
            raise PydanticCustomError(
                LAYOUT_ERROR_TYPE,
                "Tienen que venir los tres formatos en orden: venta por peso, por unidad y varios.",
                {"error_code": "layouts_shape_invalid"},
            )
        errors = layout_errors(layouts)
        if errors:
            first = errors[0]
            raise PydanticCustomError(
                LAYOUT_ERROR_TYPE,
                "{message}",
                {"message": first.message, "error_code": first.code, "layout_index": first.layout_index},
            )
        return layouts


class ScaleSettingsOut(BaseModel):
    enabled: bool
    layouts: list[ScaleLayout]
    # True cuando la cuenta nunca guardó la configuración (valores de fábrica).
    is_default: bool
    updated_at: datetime.datetime | None = None
    updated_by: uuid.UUID | None = None
