"""
v31-authz-token-hook — tasks 5.4-5.6: `require_account_role` (D6).

Gating de rol de TENANT (account_members.role), con fallback a la DB durante
la ventana de transición: prefiere el claim `account_role` del JWT; si está
ausente, resuelve contra la base con el MISMO criterio determinístico que
`get_account_id` (ORDER BY created_at, id). Sin membresía por ninguna vía →
403, nunca un default permisivo. Patrón asíncrono idéntico a
`require_platform_admin` (que ya resuelve el rol de plataforma contra la DB
cuando el claim no viaja en el token).
"""
from __future__ import annotations

from unittest.mock import AsyncMock

import pytest
from fastapi import HTTPException


def _auth(account_role: str | None) -> dict:
    return {
        "user_id": "11111111-1111-1111-1111-111111111111",
        "role": "user",
        "account_role": account_role,
        "plan": "gratis",
    }


# ── 5.4 RED — claim presente: autoriza sin tocar la base ────────────────────


@pytest.mark.asyncio
async def test_require_account_role_claim_present_does_not_query_db():
    """RED (5.4): con el claim presente, el mock de conexión NO debe recibir
    ninguna query — la decisión se toma enteramente con el valor del JWT."""
    from backend.core.guards import require_account_role

    conn = AsyncMock()
    auth = _auth("owner")

    await require_account_role(conn, auth, ["owner", "admin"])

    conn.fetchval.assert_not_awaited()
    conn.fetchrow.assert_not_awaited()
    conn.fetch.assert_not_awaited()


# ── 5.6 TRIANGULATE ──────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_require_account_role_claim_absent_falls_back_to_db_and_authorizes():
    """TRIANGULATE (5.6a): claim ausente (token viejo, D6) → resuelve contra
    la base y autoriza igual que si el claim hubiera estado presente."""
    from backend.core.guards import require_account_role

    conn = AsyncMock()
    conn.fetchval = AsyncMock(return_value="owner")
    auth = _auth(None)

    await require_account_role(conn, auth, ["owner", "admin"])

    conn.fetchval.assert_awaited_once()


@pytest.mark.asyncio
async def test_require_account_role_claim_absent_and_no_membership_denies():
    """TRIANGULATE (5.6b): claim ausente Y sin membresía en la base → 403.
    Nunca un default permisivo — la ausencia de información NUNCA autoriza."""
    from backend.core.guards import require_account_role

    conn = AsyncMock()
    conn.fetchval = AsyncMock(return_value=None)
    auth = _auth(None)

    with pytest.raises(HTTPException) as exc_info:
        await require_account_role(conn, auth, ["owner", "admin"])

    assert exc_info.value.status_code == 403


@pytest.mark.asyncio
async def test_require_account_role_claim_present_but_not_allowed_denies_without_db():
    """TRIANGULATE (5.6c): claim presente con rol NO permitido → 403 SIN
    consultar la base (el camino corto no debe degradar a un fallback)."""
    from backend.core.guards import require_account_role

    conn = AsyncMock()
    auth = _auth("member")

    with pytest.raises(HTTPException) as exc_info:
        await require_account_role(conn, auth, ["owner", "admin"])

    assert exc_info.value.status_code == 403
    conn.fetchval.assert_not_awaited()


@pytest.mark.asyncio
async def test_require_account_role_db_fallback_role_not_allowed_denies():
    """TRIANGULATE adicional: claim ausente, DB resuelve un rol que NO está
    permitido (member intenta un endpoint owner/admin) → 403."""
    from backend.core.guards import require_account_role

    conn = AsyncMock()
    conn.fetchval = AsyncMock(return_value="member")
    auth = _auth(None)

    with pytest.raises(HTTPException) as exc_info:
        await require_account_role(conn, auth, ["owner", "admin"])

    assert exc_info.value.status_code == 403
