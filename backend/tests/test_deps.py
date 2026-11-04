"""
multiusuario-operativo tanda A (D4, D6) — `get_account_id` resuelve la cuenta
activa con la MISMA función de base que usan las RPCs y la RLS
(`current_account_ids()`), nunca con un criterio propio, y compara la cuenta que
muestra la pantalla (`X-Account-Id`) contra la resuelta.

Historia: nació en v31-authz-token-hook (D4) como `ORDER BY created_at, id
LIMIT 1` sobre `account_members`, para que el hook y este resolver eligieran la
misma cuenta bajo multi-membresía. Con la cuenta activa elegible
(`profiles.active_account_id`) ese segundo criterio dejaba de poder coincidir con
el del token: ahora hay UNO solo, en la base. La prueba de que el hook y este
resolver coinciden bajo multi-membresía vive en el gate SQL
`supabase/tests/test_multiusuario_cuenta_activa.sql`.

`get_account_id` ejecuta SQL crudo sobre la conexión asyncpg, así que a nivel
unitario el contrato verificable es CUÁL es la consulta y qué hace con el header.
"""
from __future__ import annotations

import uuid
from unittest.mock import AsyncMock

import pytest
from fastapi import HTTPException

ACCOUNT_ID = uuid.UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
OTHER_ACCOUNT_ID = uuid.UUID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")


def _mock_conn(return_value):
    conn = AsyncMock()
    conn.fetchval = AsyncMock(return_value=return_value)
    return conn


# ── La consulta: el resolver canónico, sin criterio paralelo ────────────────


@pytest.mark.asyncio
async def test_get_account_id_reads_the_canonical_resolver_of_the_database():
    """RED (3.2): la consulta SHALL ser `current_account_ids()` — la misma
    función que ven las 45 RPCs y las policies —, no un `account_members ...
    ORDER BY ... LIMIT 1` propio (que bajo multi-membresía elige otra cuenta que
    el token)."""
    from backend.core.deps import get_account_id

    conn = _mock_conn(ACCOUNT_ID)

    result = await get_account_id(conn=conn)

    assert result == ACCOUNT_ID
    query = conn.fetchval.call_args.args[0]
    assert "current_account_ids()" in query
    assert "account_members" not in query, (
        "get_account_id NO debe implementar un criterio de cuenta activa propio: "
        f"la resolución vive en la base. Query real: {query!r}"
    )
    assert "ORDER BY" not in query.upper()


@pytest.mark.asyncio
async def test_get_account_id_still_raises_403_without_active_account():
    """El 403 'No active account found' se conserva: usuario sin membresía, o
    cuyo token declara una cuenta de la que ya no es miembro (0 filas)."""
    from backend.core.deps import get_account_id

    conn = _mock_conn(None)

    with pytest.raises(HTTPException) as exc_info:
        await get_account_id(conn=conn)

    assert exc_info.value.status_code == 403
    assert exc_info.value.detail == "No active account found"


# ── D6: guard de pestaña desfasada (X-Account-Id) ───────────────────────────


@pytest.mark.asyncio
async def test_get_account_id_without_header_does_not_compare():
    """Sin `X-Account-Id` NO se compara (compatibilidad con scripts y clientes
    viejos): devuelve la cuenta resuelta."""
    from backend.core.deps import get_account_id

    conn = _mock_conn(ACCOUNT_ID)

    assert await get_account_id(conn=conn, x_account_id=None) == ACCOUNT_ID


@pytest.mark.asyncio
async def test_get_account_id_matching_header_returns_the_account():
    """El header que coincide con la cuenta resuelta no cambia nada. La
    comparación es por UUID, no por texto: mayúsculas y llaves no importan."""
    from backend.core.deps import get_account_id

    conn = _mock_conn(ACCOUNT_ID)

    assert await get_account_id(conn=conn, x_account_id=str(ACCOUNT_ID)) == ACCOUNT_ID
    assert await get_account_id(conn=conn, x_account_id=str(ACCOUNT_ID).upper()) == ACCOUNT_ID


@pytest.mark.asyncio
async def test_get_account_id_mismatched_header_is_409_account_switched():
    """RED (3.2): una pestaña que muestra la cuenta A mientras el token ya
    describe la B recibe 409 RFC 7807 `account_switched` ANTES de que el endpoint
    ejecute nada. Sin esto, un alta sin entidad (gasto, venta de servicio)
    escrita desde la pestaña vieja caería en la cuenta nueva en silencio."""
    from backend.core.deps import get_account_id

    conn = _mock_conn(ACCOUNT_ID)

    with pytest.raises(HTTPException) as exc_info:
        await get_account_id(conn=conn, x_account_id=str(OTHER_ACCOUNT_ID))

    exc = exc_info.value
    assert exc.status_code == 409
    assert exc.code == "account_switched"
    assert exc.type_ == "account_switched"


@pytest.mark.asyncio
async def test_get_account_id_malformed_header_is_also_a_conflict():
    """Un header que no es un UUID declara una cuenta distinta de la activa:
    se rechaza como conflicto, nunca se ignora (fail-closed) ni se convierte en
    500 por un `ValueError`."""
    from backend.core.deps import get_account_id

    conn = _mock_conn(ACCOUNT_ID)

    with pytest.raises(HTTPException) as exc_info:
        await get_account_id(conn=conn, x_account_id="no-es-un-uuid")

    assert exc_info.value.status_code == 409
    assert exc_info.value.code == "account_switched"


@pytest.mark.asyncio
async def test_get_account_id_without_active_account_is_403_even_with_a_header():
    """Sin cuenta activa el rechazo es el 403 de siempre — el conflicto sólo
    existe cuando hay una cuenta resuelta contra la cual comparar."""
    from backend.core.deps import get_account_id

    conn = _mock_conn(None)

    with pytest.raises(HTTPException) as exc_info:
        await get_account_id(conn=conn, x_account_id=str(ACCOUNT_ID))

    assert exc_info.value.status_code == 403
