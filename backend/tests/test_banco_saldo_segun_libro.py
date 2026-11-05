"""
banco-saldo-segun-libro — saldo "según libro" de una cuenta bancaria (TDD estricto).

Pedido del PO: al elegir una cuenta en /banco, mostrar el saldo que debería
tener el banco, como en caja. Definición canónica (decisión del orquestador):
    saldo según libro = opening_balance + COALESCE(SUM(bank_movements.amount), 0)
recalculado SIEMPRE sobre los movimientos, NUNCA leyendo el último
`balance_after` (que en 1 de 8 cuentas de prod deriva — candidato aparte).

Lectura pura: cero escritura de dinero.
"""
from __future__ import annotations

import uuid
from decimal import Decimal
from unittest.mock import AsyncMock

import pytest

from backend.repositories.bank_account_repository import BankAccountRepository
from backend.schemas.bank_accounts import BankAccountOut

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
BANK_ACCOUNT_ID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

ROW = {
    "id": BANK_ACCOUNT_ID,
    "account_id": ACCOUNT_ID,
    "name": "Cuenta Galicia",
    "bank_name": "Galicia",
    "cbu": None,
    "alias": None,
    "currency": "ARS",
    "account_kind": "bank",
    "is_active": True,
    "opening_balance": Decimal("1000.00"),
    "current_balance": Decimal("1300.00"),
    "last_movement_date": None,
    "pending_reconciliation_count": 2,
}


class TestSchema:
    def test_out_exposes_opening_and_current_balance(self):
        out = BankAccountOut.model_validate(ROW)
        assert out.opening_balance == Decimal("1000.00")
        assert out.current_balance == Decimal("1300.00")
        assert out.pending_reconciliation_count == 2
        assert out.last_movement_date is None

    def test_zero_opening_and_no_movements_is_zero(self):
        out = BankAccountOut.model_validate(
            {**ROW, "opening_balance": Decimal("0"), "current_balance": Decimal("0"),
             "pending_reconciliation_count": 0}
        )
        assert out.current_balance == Decimal("0")

    def test_negative_current_balance_is_allowed(self):
        out = BankAccountOut.model_validate({**ROW, "current_balance": Decimal("-250.50")})
        assert out.current_balance == Decimal("-250.50")


def _repo(row=None, rows=None):
    conn = AsyncMock()
    conn.fetch = AsyncMock(return_value=rows or [])
    conn.fetchrow = AsyncMock(return_value=row)
    return BankAccountRepository(conn), conn


def _assert_libro_sql(sql: str):
    # Recalculado sobre los movimientos, scoped por el tenant, sin balance_after.
    assert "opening_balance" in sql
    assert "SUM(bm.amount)" in sql
    assert "COALESCE" in sql
    assert "public.bank_movements" in sql
    assert "bm.bank_account_id = ba.id" in sql
    assert "bm.account_id = ba.account_id" in sql
    assert "unreconciled" in sql
    assert "balance_after" not in sql


class TestRepositoryLibroSql:
    @pytest.mark.asyncio
    async def test_list_active_computes_current_balance(self):
        repo, conn = _repo(rows=[ROW])
        await repo.list_active(ACCOUNT_ID)
        sql = conn.fetch.call_args[0][0]
        _assert_libro_sql(sql)
        assert "current_balance" in sql
        assert "ba.account_id = $1" in sql  # filtro explícito por tenant

    @pytest.mark.asyncio
    async def test_get_by_id_for_account_computes_current_balance(self):
        repo, conn = _repo(row=ROW)
        result = await repo.get_by_id_for_account(BANK_ACCOUNT_ID, ACCOUNT_ID)
        _assert_libro_sql(conn.fetchrow.call_args[0][0])
        assert result["current_balance"] == Decimal("1300.00")

    @pytest.mark.asyncio
    async def test_get_by_id_after_create_returns_balance_shape(self):
        repo, conn = _repo(row=ROW)
        result = await repo._get_by_id(uuid.UUID(BANK_ACCOUNT_ID))
        _assert_libro_sql(conn.fetchrow.call_args[0][0])
        BankAccountOut.model_validate(result)  # el POST arma BankAccountOut con este shape
