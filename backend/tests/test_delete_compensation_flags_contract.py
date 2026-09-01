"""qa-integral-modulos (G10, task 10.2 / H12) — contrato de los derivados de
compensación de borrado en `GET /purchases` y `GET /sales`.

El re-QA del 2026-09-01 encontró que el diálogo de borrado de una compra
enumera la reposición de stock pero **nunca** la reversión del cargo en la
cuenta corriente del proveedor, ni siquiera con una compra a crédito que SÍ
tiene el cargo posteado en `supplier_account_movements`.

Causa: `list_paginated_by_operation` calcula `has_account_charge` /
`has_bank_movement` (y `has_cash_movement` en ventas) con los mismos `EXISTS`
de los guards — pero `PurchaseItemOut` / `SaleItemOut` solo declaraban
`is_payment_locked`, así que Pydantic los **descartaba** al serializar y
`use-purchases.ts` / `use-sales.ts` los recibían ausentes y los mapeaban
`?? false`. `lib/delete-compensation.ts` deriva la línea del cargo ÚNICAMENTE
de `hasAccountCharge` (no de `is_payment_locked`), así que la línea no
aparecía jamás. Los tests de 10.2 no lo atraparon porque pasan el flag como
fixture del componente, saltándose el transporte.

Estos tests usan el transporte REAL: la fila TAL CUAL la proyectan los
repositorios, validada por el mismo schema que usa `response_model`.
"""
from __future__ import annotations

import datetime
import uuid
from decimal import Decimal

from backend.schemas.purchases import PurchaseItemOut
from backend.schemas.sales import SaleItemOut

ACCOUNT_ID = uuid.UUID("11111111-1111-1111-1111-111111111111")
OPERATION_ID = uuid.UUID("22222222-2222-2222-2222-222222222222")


def _purchase_row(**overrides: object) -> dict:
    """Fila como la proyecta purchase_repository.list_paginated_by_operation."""
    row = {
        "id": uuid.uuid4(),
        "date": datetime.date(2026, 8, 30),
        "product_id": uuid.uuid4(),
        "product_name": "Harina 000",
        "operation_id": OPERATION_ID,
        "quantity": Decimal("3"),
        "amount": Decimal("1200.00"),
        "total": Decimal("3600.00"),
        "description": "Compra a cuenta corriente",
        "cost_center_id": None,
        "cost_center_name": None,
        "payment_method_id": uuid.uuid4(),
        "payment_method_name": "Cuenta corriente",
        "payment_method_kind": "credit",
        "branch_id": None,
        "unit_id": None,
        "supplier_id": uuid.uuid4(),
        "supplier_name": "Insumos Andinos",
        "has_account_charge": True,
        "has_bank_movement": False,
        "is_payment_locked": True,
    }
    row.update(overrides)
    return row


def _sale_row(**overrides: object) -> dict:
    """Fila como la proyecta sales_repository.list_paginated_by_operation."""
    row = {
        "id": uuid.uuid4(),
        "date": datetime.date(2026, 8, 30),
        "product_id": uuid.uuid4(),
        "product_name": "Vino Malbec",
        "operation_id": OPERATION_ID,
        "quantity": Decimal("2"),
        "amount": Decimal("5000.00"),
        "total": Decimal("10000.00"),
        "branch_id": None,
        "canal": None,
        "unit_id": None,
        "is_invoiced": False,
        "has_account_charge": True,
        "has_cash_movement": False,
        "has_bank_movement": True,
        "is_payment_locked": True,
    }
    row.update(overrides)
    return row


class TestPurchaseDeleteCompensationFlags:
    def test_has_account_charge_survives_serialization(self) -> None:
        """H12: sin esto la línea del cargo del diálogo no existe en la app."""
        payload = PurchaseItemOut.model_validate(_purchase_row()).model_dump()

        assert payload["has_account_charge"] is True
        assert payload["has_bank_movement"] is False

    def test_bank_movement_flag_travels_independently(self) -> None:
        """Triangulación: compra pagada por transferencia (banco, sin cargo)."""
        row = _purchase_row(
            has_account_charge=False,
            has_bank_movement=True,
            payment_method_kind="transfer",
            payment_method_name="Transferencia",
        )

        payload = PurchaseItemOut.model_validate(row).model_dump()

        assert payload["has_account_charge"] is False
        assert payload["has_bank_movement"] is True

    def test_row_without_the_flags_defaults_to_no_money_posted(self) -> None:
        """Una lectura vieja sin los derivados no debe romper ni mentir."""
        row = _purchase_row()
        del row["has_account_charge"]
        del row["has_bank_movement"]

        payload = PurchaseItemOut.model_validate(row).model_dump()

        assert payload["has_account_charge"] is False
        assert payload["has_bank_movement"] is False

    def test_is_payment_locked_is_not_a_substitute(self) -> None:
        """El diálogo NO puede derivar el cargo de is_payment_locked: el OR
        de los tres EXISTS no dice CUÁL libro se compensa."""
        row = _purchase_row(has_account_charge=False, has_bank_movement=True)

        payload = PurchaseItemOut.model_validate(row).model_dump()

        assert payload["is_payment_locked"] is True
        assert payload["has_account_charge"] is False


class TestSaleDeleteCompensationFlags:
    def test_the_three_flags_survive_serialization(self) -> None:
        payload = SaleItemOut.model_validate(_sale_row()).model_dump()

        assert payload["has_account_charge"] is True
        assert payload["has_cash_movement"] is False
        assert payload["has_bank_movement"] is True

    def test_cash_flag_travels_independently(self) -> None:
        row = _sale_row(
            has_account_charge=False,
            has_cash_movement=True,
            has_bank_movement=False,
        )

        payload = SaleItemOut.model_validate(row).model_dump()

        assert payload["has_cash_movement"] is True
        assert payload["has_account_charge"] is False
        assert payload["has_bank_movement"] is False

    def test_row_without_the_flags_defaults_to_no_money_posted(self) -> None:
        row = _sale_row()
        for key in ("has_account_charge", "has_cash_movement", "has_bank_movement"):
            del row[key]

        payload = SaleItemOut.model_validate(row).model_dump()

        assert payload["has_account_charge"] is False
        assert payload["has_cash_movement"] is False
        assert payload["has_bank_movement"] is False
