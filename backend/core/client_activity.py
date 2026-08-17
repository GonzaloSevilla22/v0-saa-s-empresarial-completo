"""
clientes-frecuentes-historial — Umbrales canónicos de actividad comercial del
cliente (client-activity §"Umbrales canónicos en una única fuente de verdad").

Única fuente de verdad de la clasificación. Ningún otro módulo, capa o
lenguaje (incluido el frontend) SHALL declarar su propia copia de estos
valores — se pasan a las consultas SQL como parámetros, nunca interpolados.

Calibración contra producción (proyecto gxdhpxvdjjkmxhdkkwyb, 2026-08-14,
ver design.md §1): con >=3 compras/90d el tenant principal marca 14 de 86
clientes con compras y discrimina; con >=2 casi un cuarto del padrón deja de
ser señal. 60 días de inactividad deja un bucket accionable de 44 clientes
sobre 127 con compras; a 30 días marcaría el 59%.
"""
from __future__ import annotations

from typing import Literal

ClientActivityStatus = Literal["frecuente", "activo", "inactivo", "sin_compras"]

FRECUENTE_MIN_OPS: int = 3
FRECUENTE_WINDOW_DAYS: int = 90
INACTIVO_MIN_DAYS: int = 60


def classify_activity(
    *,
    ops_total: int,
    ops_window: int,
    days_since_last: int | None,
) -> ClientActivityStatus:
    """Clasifica un cliente en exactamente uno de los 4 estados de actividad.

    Orden de evaluación canónico (client-activity §"Precedencia
    determinística"): `sin_compras` → `inactivo` → `frecuente` → `activo`.
    Es explícito y no depende del orden de las ramas: un cliente que cumple
    simultáneamente `frecuente` e `inactivo` (3+ compras en la ventana, pero
    todas hace >=60 días) se resuelve a `inactivo` — el estado accionable.

    Args:
        ops_total: cantidad total de compras (operaciones) del cliente.
        ops_window: cantidad de compras dentro de `FRECUENTE_WINDOW_DAYS`.
        days_since_last: días transcurridos desde la última compra en día
            calendario argentino, o `None` si el cliente no tiene compras.
    """
    if ops_total == 0 or days_since_last is None:
        return "sin_compras"
    if days_since_last >= INACTIVO_MIN_DAYS:
        return "inactivo"
    if ops_window >= FRECUENTE_MIN_OPS:
        return "frecuente"
    return "activo"
