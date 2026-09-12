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


@pytest.mark.asyncio
async def test_claims_status_endpoint_reports_account_roles_set(async_client, mock_pool):
    """Bug fix humo v3-rbac-multirole (2026-09-12): con `account_roles`
    presente en el JWT, la respuesta HTTP REAL (a través de Pydantic/
    ClaimsStatusOut, no la llamada directa a get_claims_status) debe
    reportar su presencia y su valor efectivo -- antes del fix,
    ClaimsStatusOut no declaraba estos 2 campos y FastAPI los descartaba
    en silencio al serializar, pese a que get_claims_status() sí los
    devolvía (ver test_claims_status_reports_account_roles_set_claim_
    presence_and_value en test_auth.py, que ejercita la dependency
    directamente y por eso nunca detectó el descarte)."""
    token = make_token({
        "app_metadata": {
            "role": "user",
            "account_role": "seller",
            "account_roles": ["seller", "stock"],
            "plan": "pro",
        }
    })

    resp = await async_client.get(
        "/auth/claims-status",
        headers={"Authorization": f"Bearer {token}"},
    )

    assert resp.status_code == 200
    data = resp.json()
    assert data["account_roles_claim_present"] is True
    assert data["effective_account_roles"] == ["seller", "stock"]


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
    assert data["account_roles_claim_present"] is False
    assert data["plan_claim_present"] is False
    assert data["effective_role"] == "user"
    assert data["effective_account_role"] is None
    assert data["effective_account_roles"] is None
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
    la sesión del propio llamante. Contrato exacto: 9 claves nada más (bug
    fix humo v3-rbac-multirole 2026-09-12: eran 7 antes de que
    ClaimsStatusOut declarara account_roles_claim_present/
    effective_account_roles — este mismo test, con el conjunto viejo de 7,
    era el que ocultaba el descarte silencioso de Pydantic)."""
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
        "account_roles_claim_present",
        "plan_claim_present",
        "effective_role",
        "effective_account_role",
        "effective_account_roles",
        "effective_plan",
        "source",
    }
    assert token not in str(data)
    # Ningún identificador de usuario en la respuesta (ni el propio ni ajeno) —
    # la respuesta describe roles/plan, no identidad.
    assert "user_id" not in data
    assert "sub" not in data
