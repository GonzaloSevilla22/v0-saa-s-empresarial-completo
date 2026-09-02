"""
caja-compras-cobranzas — Tests TDD (Strict TDD Mode) a nivel de esquema Python.

La cobertura de comportamiento de negocio (payload -> RPC, servicios, listado)
vive en test_purchases.py y test_c30_customer_supplier_accounts.py (specific
tests agregados por este change, ver git log). Este archivo cubre
específicamente el vocabulario de MovementType (grupo 2, task 2.4/2.5), que
no tenía un home dedicado.

Run: python -m pytest backend/tests/test_caja_compras_cobranzas.py
"""
from __future__ import annotations

import pytest
from pydantic import ValidationError


class TestMovementTypeVocabulary:
    """task 2.4: MovementType tiene los 11 valores, _INCOME_TYPES/_EXPENSE_TYPES
    son los conjuntos exactos que design.md D1 fija como normativos."""

    def test_movement_type_has_eleven_members(self):
        from backend.schemas.cash import MovementType

        assert len(MovementType) == 11
        assert {m.value for m in MovementType} == {
            "sale", "purchase_payment", "expense", "advance", "withdrawal",
            "sale_reversal", "expense_reversal",
            "purchase_payment_reversal", "payment_received", "payment_made",
            "adjustment",
        }

    def test_income_types_exact_set(self):
        from backend.schemas.cash import MovementType, _INCOME_TYPES

        assert _INCOME_TYPES == {
            MovementType.sale,
            MovementType.advance,
            MovementType.expense_reversal,
            MovementType.purchase_payment_reversal,
            MovementType.payment_received,
        }

    def test_expense_types_exact_set(self):
        from backend.schemas.cash import MovementType, _EXPENSE_TYPES

        assert _EXPENSE_TYPES == {
            MovementType.purchase_payment,
            MovementType.expense,
            MovementType.withdrawal,
            MovementType.sale_reversal,
            MovementType.payment_made,
        }

    def test_adjustment_is_in_neither_set(self):
        """adjustment sigue con signo libre — no entra a ninguno de los dos
        conjuntos (D4 de banco-caja-historial-ajustes, ya normativo)."""
        from backend.schemas.cash import MovementType, _EXPENSE_TYPES, _INCOME_TYPES

        assert MovementType.adjustment not in _INCOME_TYPES
        assert MovementType.adjustment not in _EXPENSE_TYPES

    def test_income_and_expense_sets_are_disjoint(self):
        """TRIANGULATE: ningún tipo puede ser ingreso y egreso a la vez — un
        error de copy-paste en D1 lo habría dejado en las dos taxonomías."""
        from backend.schemas.cash import _EXPENSE_TYPES, _INCOME_TYPES

        assert _INCOME_TYPES.isdisjoint(_EXPENSE_TYPES)

    @pytest.mark.parametrize("movement_type", [
        "purchase_payment_reversal", "payment_received", "payment_made",
    ])
    def test_new_types_are_valid_register_movement_in(self, movement_type):
        """Los tres tipos nuevos son valores válidos de RegisterMovementIn —
        no sólo del enum crudo (regresión del gate del historial manual de
        caja, que también acepta estos tipos)."""
        from decimal import Decimal

        from backend.schemas.cash import RegisterMovementIn

        sign = Decimal("100") if movement_type != "payment_made" else Decimal("-100")
        payload = RegisterMovementIn(amount=sign, movement_type=movement_type)
        assert payload.movement_type.value == movement_type

    def test_tip_is_not_a_valid_movement_type(self):
        from backend.schemas.cash import RegisterMovementIn
        from decimal import Decimal

        with pytest.raises(ValidationError):
            RegisterMovementIn(amount=Decimal("100"), movement_type="tip")
