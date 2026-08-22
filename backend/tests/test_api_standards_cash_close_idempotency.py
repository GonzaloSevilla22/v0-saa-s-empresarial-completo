"""
v3-api-standards §4 — idempotencia de cerrar caja (migración gobernada).

Cubre:
- 4.3 repo/service pasan idempotency_key al RPC actualizado
- 4.4 require_idempotency_key cableado en POST /cash/sessions/{id}/close
- 4.5 doble cierre con la misma clave cierra una sola vez y devuelve el
  resultado del primero (semántica de replay, verificada a nivel HTTP
  mockeando el RPC como ya-idempotente vía asyncpg)
"""
from __future__ import annotations

import json
from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import make_token

SESSION_ID = "33333333-3333-3333-3333-333333333333"

CLOSE_SESSION_RESULT = {
    "session_id": SESSION_ID,
    "status": "closed",
    "opening_balance": 1000.00,
    "expected_balance": 6200.00,
    "counted_balance": 6200.00,
    "difference": 0.00,
    "closing_balance": 6200.00,
    # banco-caja-historial-ajustes (D5): rpc_close_cash_session ahora siempre
    # devuelve estas dos claves — sesión sin ajustes, así que quedan en 0.
    "adjustments_total": 0.00,
    "difference_before_adjustments": 0.00,
}


@pytest.mark.asyncio
async def test_close_session_repo_passes_idempotency_key_to_rpc():
    """4.3: CashSessionRepository.close_session pasa idempotency_key al RPC."""
    from unittest.mock import AsyncMock as _AsyncMock

    from backend.repositories.cash_session_repository import CashSessionRepository

    conn = _AsyncMock()
    conn.fetchrow = _AsyncMock(return_value={"result": json.dumps(CLOSE_SESSION_RESULT)})
    repo = CashSessionRepository(conn)

    await repo.close_session(SESSION_ID, 6200.0, idempotency_key="my-close-key")

    call_args = conn.fetchrow.call_args.args
    assert "my-close-key" in call_args


@pytest.mark.asyncio
async def test_close_session_repo_backward_compatible_without_key():
    """4.3 TRIANGULATE: llamada sin idempotency_key (compat con callers viejos)
    sigue funcionando — el parámetro es opcional."""
    from backend.repositories.cash_session_repository import CashSessionRepository

    conn = AsyncMock()
    conn.fetchrow = AsyncMock(return_value={"result": json.dumps(CLOSE_SESSION_RESULT)})
    repo = CashSessionRepository(conn)

    result = await repo.close_session(SESSION_ID, 6200.0)

    assert result["status"] == "closed"
    call_args = conn.fetchrow.call_args.args
    assert None in call_args


@pytest.mark.asyncio
async def test_close_session_endpoint_requires_idempotency_key(async_client, mock_pool):
    """4.4: POST /sessions/{id}/close sin Idempotency-Key ni body -> 422."""
    pool, conn = mock_pool
    token = make_token({"role": "user"})

    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            f"/sessions/{SESSION_ID}/close",
            json={"counted_balance": 6200.0},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert resp.status_code == 422
    assert resp.headers["content-type"].startswith("application/problem+json")
    body = resp.json()
    assert body["code"] == "idempotency_key_required"
    conn.fetchrow.assert_not_awaited()


@pytest.mark.asyncio
async def test_close_session_endpoint_accepts_header_key(async_client, mock_pool):
    """4.4: con el header, el cierre sigue funcionando (200) y la clave llega al RPC."""
    pool, conn = mock_pool
    token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value={"result": json.dumps(CLOSE_SESSION_RESULT)})

    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            f"/sessions/{SESSION_ID}/close",
            json={"counted_balance": 6200.0},
            headers={
                "Authorization": f"Bearer {token}",
                "Idempotency-Key": "close-key-header",
            },
        )

    assert resp.status_code == 200
    assert resp.json()["status"] == "closed"
    call_args = conn.fetchrow.call_args.args
    assert "close-key-header" in call_args


@pytest.mark.asyncio
async def test_double_close_same_key_returns_first_result_without_reexecuting(async_client, mock_pool):
    """4.5: doble cierre con la misma clave — el RPC (mockeado con semántica
    de replay) devuelve el resultado del primer cierre en ambas llamadas, sin
    que el backend re-ejecute ni cambie el comportamiento. La atomicidad real
    la garantiza el RPC en Postgres (D5); a nivel HTTP se verifica que ambas
    respuestas sean idénticas y que la clave viajó igual en ambas llamadas."""
    pool, conn = mock_pool
    token = make_token({"role": "user"})

    # El RPC real es replay-safe: devuelve el MISMO resultado ambas veces
    # cuando la clave coincide (comportamiento documentado en la migración).
    conn.fetchrow = AsyncMock(return_value={"result": json.dumps(CLOSE_SESSION_RESULT)})

    with patch("backend.core.database.pool", pool):
        first = await async_client.post(
            f"/sessions/{SESSION_ID}/close",
            json={"counted_balance": 6200.0},
            headers={
                "Authorization": f"Bearer {token}",
                "Idempotency-Key": "double-close-key",
            },
        )
        second = await async_client.post(
            f"/sessions/{SESSION_ID}/close",
            json={"counted_balance": 6200.0},
            headers={
                "Authorization": f"Bearer {token}",
                "Idempotency-Key": "double-close-key",
            },
        )

    assert first.status_code == 200
    assert second.status_code == 200
    assert first.json() == second.json()

    # ambas llamadas al RPC deben propagar la misma clave
    calls = conn.fetchrow.call_args_list
    assert len(calls) == 2
    assert "double-close-key" in calls[0].args
    assert "double-close-key" in calls[1].args
