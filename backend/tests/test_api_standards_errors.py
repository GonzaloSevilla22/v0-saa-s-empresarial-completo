"""
v3-api-standards §1 — Errores RFC 7807 (problem+json).

Cubre:
- 1.1 shape 7807 (helper/constructor) con media type application/problem+json
- 1.2 asyncpg_error_handler emite 7807 sobre el mapeo _BUSINESS_ERRCODE_STATUS
- 1.3 RequestValidationError -> 422 problem+json con `field`
- 1.4 HTTPException -> problem+json
- 1.5 catch-all Exception -> 500 problem+json genérico (`code=internal_error`)
- 1.6 CORS y `detail`-string preservados

No cambia comportamiento de negocio: solo el envelope de error.
"""
from __future__ import annotations

import json
from unittest.mock import AsyncMock, patch

import asyncpg
import pytest

from backend.core.errors import asyncpg_error_handler, problem_detail
from backend.tests.conftest import make_token


class _FakePgError(asyncpg.PostgresError):
    def __init__(self, message: str, sqlstate: str | None):
        super().__init__(message)
        self.sqlstate = sqlstate


class _FakeRequest:
    headers: dict = {}


def _body(resp) -> dict:
    return json.loads(resp.body)


# ── 1.1 — helper/constructor problem_detail ─────────────────────────────────


def test_problem_detail_shape_has_rfc7807_fields():
    body = problem_detail(status=409, title="Conflicto", detail="mensaje del RPC", code="P0409")
    assert body["status"] == 409
    assert body["title"] == "Conflicto"
    assert body["detail"] == "mensaje del RPC"
    assert body["code"] == "P0409"
    assert body["type"]  # presente, aunque sea un slug genérico


def test_problem_detail_field_extension_only_when_provided():
    without_field = problem_detail(status=500, title="x", detail="y", code="internal_error")
    assert "field" not in without_field

    with_field = problem_detail(status=422, title="x", detail="y", code="validation_error", field="name")
    assert with_field["field"] == "name"


# ── 1.2 — asyncpg_error_handler emite 7807 ───────────────────────────────────


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "sqlstate,expected_status",
    [
        ("P0400", 400),
        ("P0401", 403),
        ("P0403", 403),
        ("P0404", 404),
        ("P0409", 409),
        ("P0422", 422),
    ],
)
async def test_business_codes_map_to_problem_json_with_code_and_detail(sqlstate, expected_status):
    exc = _FakePgError("Insufficient stock for product abc", sqlstate)

    resp = await asyncpg_error_handler(_FakeRequest(), exc)

    assert resp.status_code == expected_status
    assert resp.media_type == "application/problem+json"
    body = _body(resp)
    assert body["status"] == expected_status
    assert body["code"] == sqlstate
    # RN: el detail del RPC se preserva tal cual lo escribió la función SQL
    assert body["detail"] == "Insufficient stock for product abc"


@pytest.mark.asyncio
async def test_unknown_code_still_returns_generic_500_problem_json():
    exc = _FakePgError("internal details must not leak", "XX000")

    resp = await asyncpg_error_handler(_FakeRequest(), exc)

    assert resp.status_code == 500
    assert resp.media_type == "application/problem+json"
    body = _body(resp)
    assert "internal details" not in body["detail"]
    assert body["code"] == "internal_error"


@pytest.mark.asyncio
async def test_constraint_codes_keep_existing_mapping_as_problem_json():
    exc = _FakePgError("duplicate key value violates unique constraint", "23505")

    resp = await asyncpg_error_handler(_FakeRequest(), exc)

    assert resp.status_code == 409
    assert resp.media_type == "application/problem+json"
    assert _body(resp)["detail"] == "Ya existe un registro con esos datos."


# ── 1.6 (parcial) — CORS headers preservados en el handler de asyncpg ───────


@pytest.mark.asyncio
async def test_asyncpg_handler_preserves_cors_headers(monkeypatch):
    from backend.core import errors as errors_module

    class _RequestWithOrigin:
        headers = {"origin": "https://allowed.example"}

    monkeypatch.setattr(errors_module.settings, "backend_allowed_origin", "https://allowed.example")

    exc = _FakePgError("conflict", "P0409")
    resp = await asyncpg_error_handler(_RequestWithOrigin(), exc)

    assert resp.headers.get("access-control-allow-origin") == "https://allowed.example"
    assert resp.headers.get("access-control-allow-credentials") == "true"


# ── 1.3 / 1.4 / 1.5 — handlers registrados en main.py, end-to-end ──────────


@pytest.mark.asyncio
async def test_validation_error_returns_422_problem_json_with_field(async_client, mock_pool):
    pool, conn = mock_pool
    token = make_token({"role": "user"})
    # POST /clients sin `name` (requerido) -> RequestValidationError de Pydantic
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/clients",
            json={"email": "a@b.com"},
            headers={"Authorization": f"Bearer {token}"},
        )

    assert resp.status_code == 422
    assert resp.headers["content-type"].startswith("application/problem+json")
    body = resp.json()
    assert body["status"] == 422
    assert body["code"] == "validation_error"
    assert body["field"] == "name"


@pytest.mark.asyncio
async def test_validation_error_body_is_not_default_fastapi_shape(async_client, mock_pool):
    pool, conn = mock_pool
    token = make_token({"role": "user"})
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/clients",
            json={"email": "a@b.com"},
            headers={"Authorization": f"Bearer {token}"},
        )
    body = resp.json()
    # el shape default de FastAPI es {"detail":[{loc,msg,type}]} — detail debe
    # dejar de ser una lista cruda
    assert not isinstance(body.get("detail"), list)


@pytest.mark.asyncio
async def test_http_exception_returns_problem_json(async_client, mock_pool):
    pool, conn = mock_pool
    token = make_token()
    conn.fetchrow = AsyncMock(return_value=None)  # cliente no encontrado -> 404

    with patch("backend.core.database.pool", pool):
        resp = await async_client.get(
            "/clients/00000000-0000-0000-0000-000000000000",
            headers={"Authorization": f"Bearer {token}"},
        )

    assert resp.status_code == 404
    assert resp.headers["content-type"].startswith("application/problem+json")
    body = resp.json()
    assert body["status"] == 404
    assert body["detail"] == "Cliente no encontrado"


@pytest.mark.asyncio
async def test_unhandled_exception_returns_generic_500_problem_json(mock_pool):
    # ASGITransport con raise_app_exceptions=True (default, usado por el
    # fixture async_client) re-lanza excepciones de servidor en vez de dejar
    # que el exception_handler(Exception) de FastAPI las capture — es un
    # comportamiento del harness de test, no de producción (uvicorn sí pasa
    # por ServerErrorMiddleware). Se usa un client propio con
    # raise_app_exceptions=False para ejercer el handler real.
    from unittest.mock import AsyncMock
    from httpx import ASGITransport, AsyncClient

    from backend.core.deps import get_account_id
    from backend.main import app

    pool, conn = mock_pool
    conn.fetch = AsyncMock(side_effect=RuntimeError("boom: internal secret stack detail"))
    token = make_token()

    async def _mock_account_id():
        from backend.tests.conftest import TEST_ACCOUNT_ID

        return TEST_ACCOUNT_ID

    with (
        patch("backend.core.auth.settings") as mock_settings,
        patch("backend.core.database.pool", pool),
    ):
        mock_settings.supabase_url = ""
        mock_settings.supabase_jwt_secret = "test-secret-key-de-32-bytes-o-mas!!"
        app.dependency_overrides[get_account_id] = _mock_account_id
        try:
            async with AsyncClient(
                transport=ASGITransport(app=app, raise_app_exceptions=False),
                base_url="http://test",
            ) as client:
                resp = await client.get(
                    "/clients",
                    headers={"Authorization": f"Bearer {token}"},
                )
        finally:
            app.dependency_overrides.pop(get_account_id, None)

    assert resp.status_code == 500
    assert resp.headers["content-type"].startswith("application/problem+json")
    body = resp.json()
    assert body["code"] == "internal_error"
    assert "boom" not in body["detail"]
    assert "secret" not in body["detail"]
