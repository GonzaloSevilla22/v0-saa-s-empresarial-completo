"""Tests vivos del CRUD de gastos.

gastos-forma-pago (grupo 7) — JUSTIFICACION ESCRITA de las aserciones que
cambiaron en este change (D15 exige que quede por escrito, no que quede en
verde):

  · `test_get_expenses_ok`, `test_get_expenses_serializes_timestamp_date_with_
    time_component` y `test_get_expenses_empty` leian una LISTA PLANA. Por D18,
    `GET /expenses` adopta el envelope estandar `{items,total,page,pages}` de
    v3-api-standards, igual que `GET /sales` — es un BREAKING de API interna
    declarado en el propose, con un unico consumidor (el frontend propio). La
    asercion de FONDO de cada test se conserva intacta: la categoria sigue
    serializandose, la fecha `timestamptz` con hora != 00:00 sigue
    coercionandose a `date`, y el listado vacio sigue devolviendo cero filas.
    Lo unico que se movio es donde vive la fila: `data[0]` -> `data["items"][0]`.
    El listado ahora resuelve el total con un COUNT, asi que el mock tambien
    define `conn.fetchval`.

  · `test_create_expense_ok` mockeaba el `INSERT ... RETURNING *`. Por D4 el
    alta pasa a UNA llamada a `rpc_create_expense` mas un re-SELECT de la fila
    (precedente: `BankAccountRepository.create`), asi que el mock replica ese
    transporte real: primero el jsonb de la RPC, despues la fila. La asercion
    de fondo (201 + la categoria en la respuesta) no cambia.

Los otros 3 tests (`member_forbidden` x2 y `cross_org_empty`) quedan sin tocar.
"""
from __future__ import annotations

import json
from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import make_token

EXPENSE_ROW = {
    "id": "55555555-5555-5555-5555-555555555555",
    "user_id": "11111111-1111-1111-1111-111111111111",
    "category": "supplies",
    "amount": "150.00",
    "description": "Paper",
    "date": "2024-01-15",
    "created_at": "2024-01-15T10:00:00",
}

# jsonb que devuelve rpc_create_expense (contrato del grupo 3).
CREATE_RPC_RESULT = {"result": json.dumps({"expense_id": EXPENSE_ROW["id"]})}


async def test_get_expenses_ok(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[EXPENSE_ROW])
    conn.fetchval = AsyncMock(return_value=1)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/expenses", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    data = resp.json()
    # D18: envelope estandar, ya no una lista plana (ver cabecera del archivo).
    assert isinstance(data["items"], list)
    assert data["items"][0]["category"] == "supplies"


async def test_get_expenses_serializes_timestamp_date_with_time_component(async_client, valid_token, mock_pool):
    """Regresión 2026-06-13: expenses.date es timestamptz; filas con hora ≠ 00:00
    deben coercionarse a date en vez de tirar 500 (mismo bug que ventas/compras)."""
    import datetime

    row = {
        **EXPENSE_ROW,
        "date": datetime.datetime(2026, 4, 6, 16, 33, 40, 270406, tzinfo=datetime.timezone.utc),
        "created_at": datetime.datetime(2026, 4, 6, 16, 33, 40, tzinfo=datetime.timezone.utc),
    }
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[row])
    conn.fetchval = AsyncMock(return_value=1)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/expenses", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    assert resp.json()["items"][0]["date"] == "2026-04-06"


async def test_get_expenses_empty(async_client, valid_token, mock_pool):
    pool, conn = mock_pool
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchval = AsyncMock(return_value=0)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/expenses", headers={"Authorization": f"Bearer {valid_token}"}
        )
    assert resp.status_code == 200
    assert resp.json() == {"items": [], "total": 0, "page": 0, "pages": 0}


async def test_create_expense_ok(async_client, mock_pool):
    pool, conn = mock_pool
    owner_token = make_token({"role": "user"})
    # D4: rpc_create_expense (jsonb) + re-SELECT de la fila — transporte real.
    conn.fetchrow = AsyncMock(side_effect=[CREATE_RPC_RESULT, EXPENSE_ROW])
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/expenses",
            json={"category": "supplies", "amount": "150.00", "date": "2024-01-15"},
            headers={"Authorization": f"Bearer {owner_token}"},
        )
    assert resp.status_code == 201
    assert resp.json()["category"] == "supplies"


async def test_create_expense_member_forbidden(async_client, mock_pool):
    pool, conn = mock_pool
    member_token = make_token({"role": "member"})
    conn.fetchrow = AsyncMock(return_value=EXPENSE_ROW)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/expenses",
            json={"category": "supplies", "amount": "50.00", "date": "2024-01-15"},
            headers={"Authorization": f"Bearer {member_token}"},
        )
    assert resp.status_code == 403


async def test_delete_expense_member_forbidden(async_client, mock_pool):
    pool, conn = mock_pool
    member_token = make_token({"role": "member"})
    conn.fetchrow = AsyncMock(return_value=EXPENSE_ROW)
    with patch("backend.core.database.pool", pool):
        resp = await async_client.delete(
            "/expenses/exp-uuid-1",
            headers={"Authorization": f"Bearer {member_token}"},
        )
    assert resp.status_code == 403


async def test_get_expense_cross_org_empty(async_client, mock_pool):
    """RLS via JWT-passthrough returns no row for a different org's expense."""
    pool, conn = mock_pool
    conn.fetchrow = AsyncMock(return_value=None)
    other_token = make_token({"sub": "other-user-id"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/expenses/exp-uuid-1",
            headers={"Authorization": f"Bearer {other_token}"},
        )
    assert resp.status_code == 404
