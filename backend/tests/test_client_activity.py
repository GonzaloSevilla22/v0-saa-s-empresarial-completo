"""
clientes-frecuentes-historial — TDD tests para backend/core/client_activity.py
(tasks 2.1 RED / 2.3 TRIANGULATE).

`classify_activity` es la única fuente de verdad de la clasificación de
actividad comercial del cliente (client-activity §"Umbrales canónicos en una
única fuente de verdad"). Se testea como función pura: nada de asyncpg acá.

Precedencia canónica: sin_compras → inactivo → frecuente → activo
(client-activity §"Precedencia determinística").
"""
from __future__ import annotations

import pytest

from backend.core.client_activity import (
    FRECUENTE_MIN_OPS,
    FRECUENTE_WINDOW_DAYS,
    INACTIVO_MIN_DAYS,
    classify_activity,
)


# ── 2.1 RED — los 4 estados ──────────────────────────────────────────────────


def test_no_purchases_is_sin_compras():
    """Cliente sin ninguna venta registrada → sin_compras, nunca inactivo."""
    assert classify_activity(ops_total=0, ops_window=0, days_since_last=None) == "sin_compras"


def test_frequent_customer():
    """>=3 operaciones en la ventana y última compra dentro del umbral de
    inactividad → frecuente."""
    assert classify_activity(ops_total=5, ops_window=3, days_since_last=10) == "frecuente"


def test_stale_last_purchase_is_inactivo():
    """Última compra hace 60 días o más → inactivo."""
    assert classify_activity(ops_total=1, ops_window=0, days_since_last=60) == "inactivo"


def test_normal_activity_is_activo():
    """Al menos una compra, última compra hace menos de 60 días, y menos de 3
    operaciones en la ventana → activo."""
    assert classify_activity(ops_total=1, ops_window=1, days_since_last=10) == "activo"


# ── 2.3 TRIANGULATE — casos de borde ─────────────────────────────────────────


def test_no_purchases_never_inactivo_even_with_high_antiquity():
    """Cliente sin compras nunca es inactivo, sin importar la antigüedad del
    registro (client-activity §"Cliente sin compras nunca es inactivo")."""
    assert classify_activity(ops_total=0, ops_window=0, days_since_last=None) == "sin_compras"


def test_frequent_and_inactive_overlap_resolves_to_inactivo():
    """Precedencia: un cliente que cumple frecuente E inactivo (3+ compras en
    ventana, pero todas hace >=60 días) se resuelve a inactivo."""
    assert classify_activity(ops_total=3, ops_window=3, days_since_last=60) == "inactivo"


def test_exactly_three_ops_in_window_is_frecuente():
    """Exactamente 3 operaciones en la ventana (el mínimo) → frecuente."""
    assert classify_activity(ops_total=3, ops_window=FRECUENTE_MIN_OPS, days_since_last=5) == "frecuente"


def test_exactly_sixty_days_is_inactivo():
    """Exactamente 60 días desde la última compra → inactivo (umbral inclusive)."""
    assert classify_activity(ops_total=1, ops_window=0, days_since_last=INACTIVO_MIN_DAYS) == "inactivo"


def test_fifty_nine_days_is_activo():
    """59 días (uno menos que el umbral) → todavía activo."""
    assert classify_activity(ops_total=1, ops_window=0, days_since_last=59) == "activo"


def test_two_ops_in_window_is_not_frecuente():
    """2 operaciones en la ventana (uno menos que el mínimo) → activo, no frecuente."""
    assert classify_activity(ops_total=2, ops_window=2, days_since_last=5) == "activo"


def test_constants_have_expected_calibrated_values():
    """Guardarraíl: los valores calibrados en design.md §1 no cambian sin que
    este test se toque explícitamente."""
    assert FRECUENTE_MIN_OPS == 3
    assert FRECUENTE_WINDOW_DAYS == 90
    assert INACTIVO_MIN_DAYS == 60


@pytest.mark.parametrize(
    "ops_total,ops_window,days_since_last,expected",
    [
        (0, 0, None, "sin_compras"),
        (10, 3, 0, "frecuente"),
        (2, 0, 100, "inactivo"),
        (1, 0, 0, "activo"),
    ],
)
def test_classify_activity_matrix(ops_total, ops_window, days_since_last, expected):
    assert classify_activity(
        ops_total=ops_total, ops_window=ops_window, days_since_last=days_since_last
    ) == expected
