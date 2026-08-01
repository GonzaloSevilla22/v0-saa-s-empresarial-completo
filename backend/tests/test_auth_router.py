"""
v31-authz-token-hook — tasks 7.1-7.3 (D8): GET /auth/claims-status.

Endpoint de diagnóstico PERMANENTE — verifica que los claims llegan al JWT
sin fabricar credenciales, sin iniciar sesión en nombre de nadie, y sin
exponer el token ni su contenido crudo. Es el ÚNICO camino de verificación
válido tras activar el hook: `auth.users.raw_app_metadata` NUNCA lo escribe
el hook (D8) — inspeccionar esa columna da `false` con o sin el hook activo.
"""
from __future__ import annotations

import pytest

from backend.tests.conftest import make_token


# ── 7.1 RED ──────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_claims_status_endpoint_reports_all_present(async_client, mock_pool):
    """RED (7.1): con un JWT que trae los tres claims, la respuesta reporta
    las tres presencias en true y los valores efectivos. Debe fallar (404)
    mientras el endpoint no exista."""
    pool, conn = mock_pool
    token = make_token({"app_metadata": {"role": "admin", "account_role": "owner", "plan": "avanzado"}})

    resp = await async_client.get(
        "/auth/claims-status",
        headers={"Authorization": f"Bearer {token}"},
    )

    assert resp.status_code == 200
    data = resp.json()
    assert data["role_claim_present"] is True
    assert data["account_role_claim_present"] is True
    assert data["plan_claim_present"] is True
    assert data["effective_role"] == "admin"
    assert data["effective_account_role"] == "owner"
    assert data["effective_plan"] == "avanzado"
    assert data["source"] == "token"


# ── 7.3 TRIANGULATE ──────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_claims_status_endpoint_without_app_metadata_reports_false(async_client, mock_pool):
    """TRIANGULATE (7.3a): JWT sin app_metadata → las tres presencias en
    false y los valores efectivos de fallback."""
    token = make_token({})

    resp = await async_client.get(
        "/auth/claims-status",
        headers={"Authorization": f"Bearer {token}"},
    )

    assert resp.status_code == 200
    data = resp.json()
    assert data["role_claim_present"] is False
    assert data["account_role_claim_present"] is False
    assert data["plan_claim_present"] is False
    assert data["effective_role"] == "user"
    assert data["effective_account_role"] is None
    assert data["effective_plan"] == "pro"
    assert data["source"] == "fallback"


@pytest.mark.asyncio
async def test_claims_status_endpoint_without_token_returns_401(async_client, mock_pool):
    """TRIANGULATE (7.3b): sin token → 401."""
    resp = await async_client.get("/auth/claims-status")
    assert resp.status_code == 401


@pytest.mark.asyncio
async def test_claims_status_endpoint_response_never_contains_token_or_other_users(async_client, mock_pool):
    """TRIANGULATE (7.3c): la respuesta NO contiene el token, ni el payload
    crudo, ni el identificador de ningún otro usuario — describe únicamente
    la sesión del propio llamante. Contrato exacto: 7 claves nada más."""
    token = make_token({"app_metadata": {"role": "user", "account_role": "member", "plan": "gratis"}})

    resp = await async_client.get(
        "/auth/claims-status",
        headers={"Authorization": f"Bearer {token}"},
    )

    assert resp.status_code == 200
    data = resp.json()
    assert set(data.keys()) == {
        "role_claim_present",
        "account_role_claim_present",
        "plan_claim_present",
        "effective_role",
        "effective_account_role",
        "effective_plan",
        "source",
    }
    assert token not in str(data)
    # Ningún identificador de usuario en la respuesta (ni el propio ni ajeno) —
    # la respuesta describe roles/plan, no identidad.
    assert "user_id" not in data
    assert "sub" not in data
