"""fix ad-hoc `ventas-formulario-sucursal`: el alta de una venta desde el
formulario descartaba la sucursal elegida (la RPC `rpc_create_sale_operation`
ya aceptaba `p_branch_id`, pero ni el esquema, ni el servicio, ni el
repositorio la propagaban) y la venta quedaba con `sales.branch_id = NULL`
mientras stock/caja/banco se resolvían contra la sucursal por defecto.

Cubre la cadena completa del alta, eslabón por eslabón: repositorio -> esquema ->
servicio -> camino HTTP (POST /sales). Los asserts buscan el valor por el NOMBRE
del parámetro de la RPC (parseando el `$N` al que está ligado), nunca por índice
posicional: la RPC ya acumuló cinco parámetros opcionales y cada uno que se
agregó corrió los índices de los tests que miraban `args[-k]`.
"""
from __future__ import annotations

import uuid
from unittest.mock import AsyncMock, patch

import asyncpg
import pytest
from pydantic import ValidationError

from backend.repositories.sales_repository import SalesRepository
from backend.schemas.sales import SaleOperationIn
from backend.services import sales as sales_service
from backend.tests.conftest import make_token, named_rpc_arg

USER_ID = "11111111-1111-1111-1111-111111111111"
ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
BRANCH_ID = "77777777-7777-7777-7777-777777777777"
OTHER_BRANCH_ID = "55555555-5555-5555-5555-555555555555"
PM_ID = "44444444-4444-4444-4444-444444444444"
CASH_SESSION_ID = "88888888-8888-8888-8888-888888888888"
BANK_ACCOUNT_ID = "99999999-9999-9999-9999-999999999999"

OPERATION_ROW = {
    "operation_id": "66666666-6666-6666-6666-666666666666",
    "operation_kind": "sale",
}

ITEMS = [{"product_id": "prod-uuid-1", "quantity": "2.0000", "amount": "300.00"}]


def _capturing_conn() -> tuple[AsyncMock, dict]:
    """Conexión doble que devuelve 'sin replay' a la idempotencia y captura la
    llamada a la RPC (query + args) — el transporte real de asyncpg."""
    captured: dict = {}
    conn = AsyncMock()

    async def fetchrow(query, *args):
        if "operation_idempotency" in query:
            return None
        captured["query"] = query
        captured["args"] = args
        return OPERATION_ROW

    conn.fetchrow = AsyncMock(side_effect=fetchrow)
    return conn, captured


# ── Eslabón 1: repositorio ──────────────────────────────────────────────────


async def test_repository_create_operation_binds_branch_id_by_name():
    conn, captured = _capturing_conn()

    await SalesRepository(conn).create_operation(
        USER_ID, ACCOUNT_ID, ITEMS, "key-1", branch_id=BRANCH_ID
    )

    assert "rpc_create_sale_operation" in captured["query"]
    assert named_rpc_arg(captured, "p_branch_id") == BRANCH_ID


async def test_repository_create_operation_without_branch_binds_null():
    """Sin sucursal elegida la RPC recibe NULL (V6): la venta sigue quedando con
    branch_id NULL, que es lo que declara la spec `branches` — nunca se
    inventa una sucursal en el repositorio."""
    conn, captured = _capturing_conn()

    await SalesRepository(conn).create_operation(USER_ID, ACCOUNT_ID, ITEMS, "key-2")

    assert named_rpc_arg(captured, "p_branch_id") is None


async def test_repository_branch_id_does_not_shift_the_other_named_args():
    """Triangulación: sumar `p_branch_id` no puede desplazar a los demás
    parámetros — cada uno sigue ligado a SU valor (canal, forma de pago, sesión
    de caja, cuenta bancaria, vencimiento)."""
    conn, captured = _capturing_conn()

    await SalesRepository(conn).create_operation(
        USER_ID,
        ACCOUNT_ID,
        ITEMS,
        "key-3",
        canal="instagram",
        payment_method_id=PM_ID,
        cash_session_id=CASH_SESSION_ID,
        bank_account_id=BANK_ACCOUNT_ID,
        branch_id=OTHER_BRANCH_ID,
    )

    assert named_rpc_arg(captured, "p_branch_id") == OTHER_BRANCH_ID
    assert named_rpc_arg(captured, "p_canal") == "instagram"
    assert named_rpc_arg(captured, "p_payment_method_id") == PM_ID
    assert named_rpc_arg(captured, "p_cash_session_id") == CASH_SESSION_ID
    assert named_rpc_arg(captured, "p_bank_account_id") == BANK_ACCOUNT_ID


# ── Eslabón 2: esquema `SaleOperationIn` ────────────────────────────────────


def _payload_kwargs(**extra) -> dict:
    return {"org_id": "org-uuid-1", "items": ITEMS, **extra}


def test_schema_accepts_branch_id_as_uuid():
    payload = SaleOperationIn(**_payload_kwargs(branch_id=BRANCH_ID))

    assert payload.branch_id == uuid.UUID(BRANCH_ID)


def test_schema_branch_id_is_optional_and_defaults_to_none():
    """Un cliente que no manda sucursal (cuentas sin módulo, o "Sin sucursal
    (general)") sigue siendo válido: el campo es opcional con default None."""
    payload = SaleOperationIn(**_payload_kwargs())

    assert payload.branch_id is None


def test_schema_rejects_a_malformed_branch_id():
    with pytest.raises(ValidationError) as excinfo:
        SaleOperationIn(**_payload_kwargs(branch_id="no-es-un-uuid"))

    assert [err["loc"] for err in excinfo.value.errors()] == [("branch_id",)]


# ── Eslabón 3: servicio ─────────────────────────────────────────────────────


def _service_repo() -> AsyncMock:
    repo = AsyncMock()
    repo.create_operation = AsyncMock(return_value=OPERATION_ROW)
    return repo


async def test_service_forwards_branch_id_as_text():
    """Passthrough sin lógica de negocio: el uuid del esquema viaja como str al
    repositorio (el mismo criterio que payment_method_id / cash_session_id)."""
    repo = _service_repo()
    payload = SaleOperationIn(
        **_payload_kwargs(idempotency_key="key-svc-1", branch_id=BRANCH_ID)
    )

    await sales_service.create_sale_operation(repo, {"user_id": USER_ID, "role": "user"}, ACCOUNT_ID, payload)

    assert repo.create_operation.await_args.kwargs["branch_id"] == BRANCH_ID


async def test_service_without_branch_forwards_none():
    repo = _service_repo()
    payload = SaleOperationIn(**_payload_kwargs(idempotency_key="key-svc-2"))

    await sales_service.create_sale_operation(repo, {"user_id": USER_ID, "role": "user"}, ACCOUNT_ID, payload)

    assert repo.create_operation.await_args.kwargs["branch_id"] is None


# ── Camino HTTP completo: POST /sales ───────────────────────────────────────

SALE_PAYLOAD = {
    "idempotency_key": "key-http-1",
    "org_id": "org-uuid-1",
    "items": ITEMS,
}


def _post_capturing(conn: AsyncMock) -> dict:
    """Instala en `conn` un fetchrow que captura la llamada a la RPC."""
    captured: dict = {}

    async def fetchrow(query, *args):
        if "operation_idempotency" in query:
            return None
        captured["query"] = query
        captured["args"] = args
        return OPERATION_ROW

    conn.fetchrow = AsyncMock(side_effect=fetchrow)
    return captured


async def _post_sale(async_client, pool, body: dict):
    token = make_token({"role": "user"})
    with patch("backend.core.database.pool", pool):
        return await async_client.post(
            "/sales", json=body, headers={"Authorization": f"Bearer {token}"}
        )


async def test_post_sales_delivers_the_chosen_branch_to_the_rpc(async_client, mock_pool):
    pool, conn = mock_pool
    captured = _post_capturing(conn)

    resp = await _post_sale(async_client, pool, {**SALE_PAYLOAD, "branch_id": BRANCH_ID})

    assert resp.status_code == 201
    assert named_rpc_arg(captured, "p_branch_id") == BRANCH_ID


async def test_post_sales_without_branch_keeps_sending_null(async_client, mock_pool):
    """V6: sin sucursal elegida el alta sigue exactamente como antes."""
    pool, conn = mock_pool
    captured = _post_capturing(conn)

    resp = await _post_sale(async_client, pool, SALE_PAYLOAD)

    assert resp.status_code == 201
    assert named_rpc_arg(captured, "p_branch_id") is None


async def test_post_sales_rejects_a_malformed_branch_id_with_422(async_client, mock_pool):
    pool, conn = mock_pool
    captured = _post_capturing(conn)

    resp = await _post_sale(async_client, pool, {**SALE_PAYLOAD, "branch_id": "no-es-un-uuid"})

    assert resp.status_code == 422
    assert "query" not in captured  # ni siquiera llegó a la RPC


# ── Errores de la RPC que ahora SÍ puede disparar el alta ───────────────────
# Antes de este fix el alta nunca mandaba p_branch_id, así que `branch_not_found`
# (P0404), `branch_closed` (P0422) y `insufficient_branch_stock` (P0409) no se
# podían producir desde el formulario. El mapeo sqlstate -> status es el global
# de `asyncpg_error_handler` (backend/core/errors.py): estos tests lo FIJAN para
# el camino del alta (caracterización — el mapeo ya existía, no hubo que
# agregarlo).


def _rpc_raises(conn: AsyncMock, message: str, sqlstate: str) -> None:
    err = asyncpg.exceptions.RaiseError(message)
    err.sqlstate = sqlstate

    async def fetchrow(query, *args):
        if "operation_idempotency" in query:
            return None
        raise err

    conn.fetchrow = AsyncMock(side_effect=fetchrow)


async def test_post_sales_branch_of_another_account_is_404(async_client, mock_pool):
    """Sucursal ajena o inactiva: la RPC levanta P0404 (filtra por la cuenta de
    la sesión) -> 404 RFC 7807, no un 500."""
    pool, conn = mock_pool
    _rpc_raises(conn, "branch_not_found or not active for this account", "P0404")

    resp = await _post_sale(async_client, pool, {**SALE_PAYLOAD, "branch_id": BRANCH_ID})

    assert resp.status_code == 404
    assert resp.json()["code"] == "P0404"


async def test_post_sales_closed_branch_is_422(async_client, mock_pool):
    pool, conn = mock_pool
    _rpc_raises(conn, "branch_closed: la sucursal está cerrada", "P0422")

    resp = await _post_sale(async_client, pool, {**SALE_PAYLOAD, "branch_id": BRANCH_ID})

    assert resp.status_code == 422
    assert resp.json()["code"] == "P0422"


async def test_post_sales_insufficient_stock_in_chosen_branch_is_409(async_client, mock_pool):
    """El stock se descuenta de la sucursal ELEGIDA: si no alcanza, la RPC
    levanta `insufficient_branch_stock` (P0409) -> 409 con el token en el
    detail, que el cliente traduce con camino a transferir."""
    pool, conn = mock_pool
    _rpc_raises(conn, "insufficient_branch_stock for product prod-uuid-1", "P0409")

    resp = await _post_sale(async_client, pool, {**SALE_PAYLOAD, "branch_id": BRANCH_ID})

    assert resp.status_code == 409
    body = resp.json()
    assert body["code"] == "P0409"
    assert "insufficient_branch_stock" in body["detail"]
