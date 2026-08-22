"""
RegisterMovementIn.validate_sign_coherence — coherencia signo↔movement_type
(OQ-2 de C-28: ingresos +, egresos −). Strict TDD Mode.

Bug preexistente (hallazgo de banco-caja-historial-ajustes, PR #440): el
validador estaba declarado sobre `amount`, que iba ANTES que `movement_type`
en la clase. En Pydantic v2 los campos se validan en orden de declaración y
`info.data` solo trae los ya validados, así que `movement_type` nunca estaba
disponible y la validación era un no-op silencioso — un `sale` con amount
negativo llegaba a la RPC sin que el backend lo rechazara.

Comportamientos cubiertos:
  - Schema: ingresos (sale/advance) con amount<0 → ValidationError en
    loc=('amount',); egresos (purchase_payment/expense/withdrawal) con
    amount>0 → ValidationError en loc=('amount',).
  - Schema: signo correcto en ambos conjuntos → aceptado; movement_type
    inválido → un solo error (el del enum), sin explotar el validador de
    signo.
  - Endpoint: POST /sessions/{id}/movements con signo incoherente → 422 con
    field=amount (api-standards: `field` apunta al campo ofensor) y sin
    tocar la DB.
"""
from __future__ import annotations

import json
from decimal import Decimal
from unittest.mock import AsyncMock, patch

import pytest
from pydantic import ValidationError

from backend.schemas.cash import RegisterMovementIn
from backend.tests.conftest import make_token

SESSION_ID  = "dddddddd-dddd-dddd-dddd-dddddddddddd"
MOVEMENT_ID = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"


class TestRegisterMovementInSignCoherence:
    @pytest.mark.parametrize("movement_type", ["sale", "advance"])
    def test_income_with_negative_amount_rejected(self, movement_type):
        with pytest.raises(ValidationError, match="ingreso") as exc_info:
            RegisterMovementIn(amount=Decimal("-100"), movement_type=movement_type)
        errors = exc_info.value.errors()
        assert len(errors) == 1
        # El error debe colgar de `amount` — es lo que el handler RFC 7807
        # traduce a `field` (api-standards), y lo que prueba que el validador
        # corre con movement_type ya disponible.
        assert errors[0]["loc"] == ("amount",)

    @pytest.mark.parametrize("movement_type", ["purchase_payment", "expense", "withdrawal"])
    def test_expense_with_positive_amount_rejected(self, movement_type):
        with pytest.raises(ValidationError, match="egreso") as exc_info:
            RegisterMovementIn(amount=Decimal("100"), movement_type=movement_type)
        errors = exc_info.value.errors()
        assert len(errors) == 1
        assert errors[0]["loc"] == ("amount",)

    @pytest.mark.parametrize("movement_type", ["sale", "advance"])
    def test_income_with_positive_amount_accepted(self, movement_type):
        payload = RegisterMovementIn(amount=Decimal("100"), movement_type=movement_type)
        assert payload.amount == Decimal("100")

    @pytest.mark.parametrize("movement_type", ["purchase_payment", "expense", "withdrawal"])
    def test_expense_with_negative_amount_accepted(self, movement_type):
        payload = RegisterMovementIn(amount=Decimal("-100"), movement_type=movement_type)
        assert payload.amount == Decimal("-100")

    def test_invalid_movement_type_reports_only_enum_error(self):
        """Triangulación del guard `movement_type is None`: si el enum falla,
        `info.data` no trae movement_type y el validador de signo debe
        devolver el valor sin agregar un segundo error ni explotar."""
        with pytest.raises(ValidationError) as exc_info:
            RegisterMovementIn(amount=Decimal("-100"), movement_type="no_existe")
        errors = exc_info.value.errors()
        assert len(errors) == 1
        assert errors[0]["loc"] == ("movement_type",)


class TestRegisterMovementSignEndpoint:
    """Integración HTTP — DB mockeada; verifica el 422 RFC 7807 con field=amount."""

    async def test_sale_with_negative_amount_returns_422_field_amount(self, async_client, mock_pool):
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(return_value={"result": json.dumps({"movement_id": MOVEMENT_ID})})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/sessions/{SESSION_ID}/movements",
                json={"amount": -100.0, "movement_type": "sale"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 422
        body = resp.json()
        assert body["field"] == "amount"
        assert "ingreso" in body["detail"]
        # el rechazo es de Pydantic, antes de tocar la RPC
        conn.fetchrow.assert_not_called()

    async def test_sale_with_positive_amount_still_returns_200(self, async_client, mock_pool):
        """Triangulación: el signo correcto sigue pasando al RPC como antes."""
        pool, conn = mock_pool
        owner_token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(return_value={"result": json.dumps({"movement_id": MOVEMENT_ID})})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/sessions/{SESSION_ID}/movements",
                json={"amount": 100.0, "movement_type": "sale"},
                headers={"Authorization": f"Bearer {owner_token}"},
            )
        assert resp.status_code == 200
        assert resp.json()["movement_id"] == MOVEMENT_ID
