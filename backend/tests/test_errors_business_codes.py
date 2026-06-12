"""
Fix ERRCODEs 5-char — el handler de asyncpg mapea los códigos de negocio
custom de los RPCs (P0400/P0401/P0403/P0404/P0409/P0422) al HTTP status
correspondiente CON el mensaje original del RAISE (es texto escrito por
nuestras propias funciones SQL, seguro para el usuario).

Antes: cualquier código no mapeado → 500 "Error interno de base de datos."
(y los RPCs ni siquiera llegaban con su código: los ERRCODE de 4 chars
degradaban a 42704 — corregido en la migración 20260624000001).
"""
from __future__ import annotations

import json

import asyncpg
import pytest

from backend.core.errors import asyncpg_error_handler


class _FakePgError(asyncpg.PostgresError):
    def __init__(self, message: str, sqlstate: str | None):
        super().__init__(message)
        self.sqlstate = sqlstate


class _FakeRequest:
    headers: dict = {}


def _body(resp) -> dict:
    return json.loads(resp.body)


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
async def test_business_codes_map_to_http_status_with_original_message(
    sqlstate, expected_status
):
    exc = _FakePgError("Insufficient stock for product abc", sqlstate)

    resp = await asyncpg_error_handler(_FakeRequest(), exc)

    assert resp.status_code == expected_status
    assert _body(resp)["detail"] == "Insufficient stock for product abc"


@pytest.mark.asyncio
async def test_unknown_code_still_returns_generic_500():
    exc = _FakePgError("internal details must not leak", "XX000")

    resp = await asyncpg_error_handler(_FakeRequest(), exc)

    assert resp.status_code == 500
    assert "internal details" not in _body(resp)["detail"]


@pytest.mark.asyncio
async def test_constraint_codes_keep_existing_mapping():
    exc = _FakePgError("duplicate key value violates unique constraint", "23505")

    resp = await asyncpg_error_handler(_FakeRequest(), exc)

    assert resp.status_code == 409
    assert _body(resp)["detail"] == "Ya existe un registro con esos datos."
