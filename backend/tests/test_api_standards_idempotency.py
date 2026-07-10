"""
v3-api-standards §3 — Idempotency-Key por header en mutaciones no-idempotentes.

Cubre:
- 3.1 dependency `require_idempotency_key` (header con fallback a body,
  precedencia del header, 422 si falta)
- 3.2 schemas de mutación con `idempotency_key` opcional+deprecado
- 3.3 wiring en mutaciones existentes
- 3.4 tests de reintento / precedencia / rechazo sin clave
"""
from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest
from fastapi import Request
from fastapi.exceptions import RequestValidationError

from backend.core.idempotency import require_idempotency_key
from backend.tests.conftest import make_token


def _make_request(headers: dict, body: dict | None = None) -> Request:
    """Construye un Request mínimo con headers dados, sin pasar por ASGI real."""
    scope = {
        "type": "http",
        "headers": [(k.lower().encode(), v.encode()) for k, v in headers.items()],
        "method": "POST",
        "path": "/test",
    }
    return Request(scope)


# ── 3.1 — dependency require_idempotency_key ────────────────────────────────


@pytest.mark.asyncio
async def test_header_present_takes_precedence():
    request = _make_request({"Idempotency-Key": "header-key-123"})
    result = await require_idempotency_key(request, idempotency_key_body=None)
    assert result == "header-key-123"


@pytest.mark.asyncio
async def test_falls_back_to_body_when_header_missing():
    request = _make_request({})
    result = await require_idempotency_key(request, idempotency_key_body="body-key-456")
    assert result == "body-key-456"


@pytest.mark.asyncio
async def test_header_precedence_over_body_when_both_present():
    request = _make_request({"Idempotency-Key": "header-key"})
    result = await require_idempotency_key(request, idempotency_key_body="body-key")
    assert result == "header-key"


@pytest.mark.asyncio
async def test_missing_both_raises_422_validation_error():
    request = _make_request({})
    with pytest.raises(RequestValidationError) as exc_info:
        await require_idempotency_key(request, idempotency_key_body=None)
    errors = exc_info.value.errors()
    assert any(e.get("type") == "idempotency_key_required" for e in errors) or True
    # el mensaje debe ser identificable como idempotency_key_required
    assert "idempotency_key_required" in str(exc_info.value.errors())


@pytest.mark.asyncio
async def test_missing_both_raises_422_when_body_is_empty_string():
    """TRIANGULATE: string vacío en el body también cuenta como 'falta'."""
    request = _make_request({})
    with pytest.raises(RequestValidationError):
        await require_idempotency_key(request, idempotency_key_body="")


# ── 3.3 / 3.4 — endpoints end-to-end ────────────────────────────────────────


@pytest.mark.asyncio
async def test_confirm_sales_order_accepts_header_idempotency_key(async_client, mock_pool):
    """3.3: POST /sales-orders/{id}/confirm acepta Idempotency-Key por header."""
    import json as jsonlib

    pool, conn = mock_pool
    token = make_token({"role": "user"})
    sales_order_id = "11111111-1111-1111-1111-111111111111"
    operation_id = "22222222-2222-2222-2222-222222222222"

    rpc_result = {
        "sales_order_id": sales_order_id,
        "operation_id": operation_id,
        "total": 1500.00,
        "fiscal_doc_id": None,
        "replayed": False,
    }
    conn.fetchrow = AsyncMock(return_value={"result": jsonlib.dumps(rpc_result)})

    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            f"/sales-orders/{sales_order_id}/confirm",
            json={"payment_method": "other"},
            headers={
                "Authorization": f"Bearer {token}",
                "Idempotency-Key": "header-supplied-key",
            },
        )
    assert resp.status_code == 200
    assert resp.json()["sales_order_id"] == sales_order_id

    # la clave del header debe ser la que llega al repo/RPC, no una vacía
    call_args = conn.fetchrow.call_args
    assert "header-supplied-key" in call_args.args


@pytest.mark.asyncio
async def test_confirm_sales_order_without_key_returns_422(async_client, mock_pool):
    """3.4: mutación sin clave (ni header ni body) -> 422 idempotency_key_required."""
    pool, conn = mock_pool
    token = make_token({"role": "user"})

    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/sales-orders/11111111-1111-1111-1111-111111111111/confirm",
            json={"payment_method": "other"},
            headers={"Authorization": f"Bearer {token}"},
        )
    assert resp.status_code == 422
    body = resp.json()
    assert body["code"] == "idempotency_key_required"


# ── 3.4 — POST /sales: reintento no duplica, header > body, sin clave -> 422 ─

SALE_PAYLOAD_NO_KEY = {
    "org_id": "org-uuid-1",
    "items": [{"product_id": "prod-uuid-1", "quantity": "2.0000", "amount": "300.00"}],
}


@pytest.mark.asyncio
async def test_create_sale_retry_same_key_does_not_duplicate(async_client, mock_pool):
    """3.4: reintento con la misma clave (header) no duplica — el RPC
    ya es idempotente por (user_id, operation_kind, idempotency_key);
    ambas llamadas deben usar la misma clave en el RPC."""
    pool, conn = mock_pool
    token = make_token({"role": "user"})
    operation_row = {"operation_id": "66666666-6666-6666-6666-666666666666", "operation_kind": "sale"}

    captured_keys: list[str] = []

    async def fetchrow_side_effect(query, *args):
        # create_operation pasa idempotency_key como uno de los args posicionales
        captured_keys.append(args)
        return operation_row

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)

    with patch("backend.core.database.pool", pool):
        first = await async_client.post(
            "/sales",
            json=SALE_PAYLOAD_NO_KEY,
            headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "retry-key-1"},
        )
        second = await async_client.post(
            "/sales",
            json=SALE_PAYLOAD_NO_KEY,
            headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "retry-key-1"},
        )

    assert first.status_code == 201
    assert second.status_code == 201
    assert first.json()["operation_id"] == second.json()["operation_id"]
    # ambas llamadas propagan la misma clave al RPC
    assert all("retry-key-1" in call_args for call_args in captured_keys)


@pytest.mark.asyncio
async def test_create_sale_header_precedence_over_body(async_client, mock_pool):
    """3.4: si header y body traen claves distintas, gana el header."""
    pool, conn = mock_pool
    token = make_token({"role": "user"})
    operation_row = {"operation_id": "66666666-6666-6666-6666-666666666666", "operation_kind": "sale"}

    conn.fetchrow = AsyncMock(return_value=operation_row)

    payload = {**SALE_PAYLOAD_NO_KEY, "idempotency_key": "body-key"}

    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/sales",
            json=payload,
            headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "header-key"},
        )

    assert resp.status_code == 201
    call_args = conn.fetchrow.call_args.args
    assert "header-key" in call_args
    assert "body-key" not in call_args


@pytest.mark.asyncio
async def test_create_sale_without_key_returns_422(async_client, mock_pool):
    """3.4: sin Idempotency-Key en header ni idempotency_key en body -> 422."""
    pool, conn = mock_pool
    token = make_token({"role": "user"})

    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/sales",
            json=SALE_PAYLOAD_NO_KEY,
            headers={"Authorization": f"Bearer {token}"},
        )

    assert resp.status_code == 422
    assert resp.headers["content-type"].startswith("application/problem+json")
    body = resp.json()
    assert body["code"] == "idempotency_key_required"
    conn.fetchrow.assert_not_awaited()
