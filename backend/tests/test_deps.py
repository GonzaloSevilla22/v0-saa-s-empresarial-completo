"""
v31-authz-token-hook — task 4.1-4.4: resolución determinística de la cuenta
activa en `get_account_id` (D4).

`get_account_id` delega la selección en SQL crudo ejecutado sobre la conexión
asyncpg (no hay forma de simular "dos filas candidatas" con un mock sin
motor SQL real) — el contrato que se puede verificar a nivel unitario es que
la QUERY use un criterio de orden EXPLÍCITO y estable (ORDER BY created_at, id
LIMIT 1), el mismo que la migración 20260818000001 usa en el hook (D4). La
prueba de que ambos lados (hook SQL + este resolver) coinciden bajo
multi-membresía vive en el gate SQL de esa migración (gates j.1/j.2).
"""
from __future__ import annotations

import uuid
from unittest.mock import AsyncMock

import pytest
from fastapi import HTTPException

ACCOUNT_ID = uuid.UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")


def _mock_conn(return_value):
    conn = AsyncMock()
    conn.fetchval = AsyncMock(return_value=return_value)
    return conn


# ── 4.1 RED ──────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_get_account_id_query_uses_deterministic_order():
    """RED (4.1): la query SHALL ordenar explícitamente por (created_at, id)
    — sin esto, bajo multi-membresía el resultado es no determinístico
    (design.md D4). Debe fallar mientras la query sea un `LIMIT 1` desnudo."""
    from backend.core.deps import get_account_id

    conn = _mock_conn(ACCOUNT_ID)

    gen = get_account_id(conn=conn)
    result = await gen

    assert result == ACCOUNT_ID
    query = conn.fetchval.call_args.args[0]
    assert "ORDER BY created_at, id" in query, (
        f"get_account_id debe ordenar por (created_at, id) para ser "
        f"determinístico bajo multi-membresía (D4). Query real: {query!r}"
    )
    assert "LIMIT 1" in query


# ── 4.2 GREEN — ya cubierto arriba; se agrega un caso de contrato adicional ─


@pytest.mark.asyncio
async def test_get_account_id_still_raises_403_without_membership():
    """GREEN: el comportamiento existente (403 sin cuenta) no cambia al
    agregar el ORDER BY."""
    from backend.core.deps import get_account_id

    conn = _mock_conn(None)

    with pytest.raises(HTTPException) as exc_info:
        await get_account_id(conn=conn)

    assert exc_info.value.status_code == 403


# ── 4.4 TRIANGULATE ──────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_get_account_id_order_by_ties_break_on_id():
    """TRIANGULATE (4.4): el criterio de desempate declarado es `id` (la PK),
    no el orden físico de inserción de las filas — verificado a nivel de
    contrato de la query (la prueba de comportamiento real, con dos cuentas
    y ambos órdenes de creación invertidos, vive en el gate SQL j.1/j.2 de
    la migración 20260818000001 — un mock sin motor SQL no puede ejercitar
    dos filas candidatas de verdad)."""
    from backend.core.deps import get_account_id

    conn = _mock_conn(ACCOUNT_ID)
    await get_account_id(conn=conn)

    query = conn.fetchval.call_args.args[0]
    # El desempate declarado es la PK (`id`), no cualquier otra columna —
    # asegura que la cláusula ORDER BY completa sea "created_at, id" y no,
    # por ejemplo, solo "created_at" (empate no resuelto ante timestamps
    # iguales, que sí pueden colisionar con inserts en la misma transacción).
    assert "ORDER BY created_at, id" in query
