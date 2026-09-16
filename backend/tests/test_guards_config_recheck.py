"""auth-hardening-jwt-cookies Parte A, grupo 6 (D12) — para las acciones de
configuración, la base es la autoridad y el claim es un caché.

**El hallazgo.** Hoy `require_account_role` corta en el claim: si
`account_roles` viaja en el token, decide con eso y no consulta nada
(`backend/core/guards.py`). Un rol **revocado o vencido** sigue autorizando
hasta la próxima emisión de token. Ese riesgo está aceptado con sign-off del
PO para el caso general (`archive/2026-09-12-v3-rbac-multirole`), y la
ventana está acotada a una vida de token — pero las acciones de configuración
son pocas, poco frecuentes y las de mayor daño. Pagar una query por request
ahí es barato; pagarla en cada lectura del POS no lo es (OQ-4).
"""
from __future__ import annotations

from unittest.mock import AsyncMock

import pytest
from fastapi import HTTPException

from backend.core.guards import require_account_role
from backend.core.rbac import CAN_CONFIGURE, CAN_SELL, is_sensitive_capability


def _conn(db_roles: list[str] | None) -> AsyncMock:
    conn = AsyncMock()
    conn.fetchval = AsyncMock(return_value=db_roles)
    return conn


def _auth(**overrides) -> dict:
    auth = {
        "user_id": "11111111-1111-1111-1111-111111111111",
        "role": "user",
        "account_role": None,
        "account_roles": None,
        "plan": "pro",
    }
    auth.update(overrides)
    return auth


# ── 6.1 — la acción de configuración consulta la base aunque el claim esté ──


@pytest.mark.asyncio
async def test_configuration_guard_queries_db_even_with_claim():
    """6.1 RED: hoy el claim presente hace short-circuit y `fetchval` nunca se
    llama."""
    conn = _conn(["owner"])

    await require_account_role(conn, _auth(account_roles=["owner"]), CAN_CONFIGURE)

    conn.fetchval.assert_awaited_once()
    assert "rpc_my_active_account_roles" in conn.fetchval.await_args.args[0]


@pytest.mark.asyncio
async def test_equal_but_distinct_list_does_not_trigger_the_recheck():
    """6.1b: candado contra las dos implementaciones ingenuas.

    `allowed is CAN_CONFIGURE` se rompe con cualquier copia; `allowed ==
    CAN_CONFIGURE` engancha **cualquier literal coincidente** — justo lo que
    el docstring de `rbac.py` prohíbe escribir pero nada impedía. La decisión
    se toma por **capacidad nombrada**, así que un caller que pasa la lista
    literal `["owner","admin"]` no activa nada: sigue el camino normal y
    resuelve por el claim.
    """
    conn = _conn(["owner"])

    await require_account_role(conn, _auth(account_roles=["owner"]), ["owner", "admin"])

    conn.fetchval.assert_not_awaited()


def test_the_capability_registry_decides_by_name_not_by_content():
    """6.1b (unidad): la propiedad, aislada del guard.

    Una lista con el mismo contenido NO es la capacidad nombrada. Un
    `frozenset` equivalente sí cuenta como la capacidad: es la dirección
    **fail-safe** del error (de más, no de menos: activa el re-chequeo en vez
    de saltearlo), y así el registro sigue funcionando si alguien reconstruye
    la constante en vez de importarla.
    """
    assert is_sensitive_capability(CAN_CONFIGURE) is True
    assert is_sensitive_capability(["owner", "admin"]) is False
    assert is_sensitive_capability({"owner", "admin"}) is False
    assert is_sensitive_capability(("owner", "admin")) is False
    assert is_sensitive_capability(CAN_SELL) is False
    # Reconstruida a mano, pero del tipo de la capacidad: cuenta.
    assert is_sensitive_capability(frozenset({"owner", "admin"})) is True


# ── 6.2 — un rol revocado deja de configurar antes de que venza el token ──


@pytest.mark.asyncio
async def test_revoked_role_denied_before_token_expiry():
    """6.2: el hallazgo de staleness de la fila 2 de §8 de la auditoría. El
    token todavía declara `owner`; la base ya no lo registra."""
    conn = _conn(["viewer"])

    with pytest.raises(HTTPException) as exc:
        await require_account_role(conn, _auth(account_roles=["owner"]), CAN_CONFIGURE)

    assert exc.value.status_code == 403
    conn.fetchval.assert_awaited_once()


@pytest.mark.asyncio
async def test_granted_role_missing_from_the_claim_is_honoured():
    """6.2 TRIANGULATE: la base manda en las DOS direcciones. Si sólo se
    aplicara para denegar, sería un filtro, no una fuente de verdad — y un
    rol recién concedido seguiría sin funcionar hasta el próximo login."""
    conn = _conn(["admin"])

    await require_account_role(conn, _auth(account_roles=["viewer"]), CAN_CONFIGURE)

    conn.fetchval.assert_awaited_once()


# ── 6.3 — el hot path NO paga la query ───────────────────────────────────


@pytest.mark.asyncio
async def test_non_configuration_guard_still_short_circuits_on_claim():
    """6.3: candado contra la alternativa rechazada de OQ-4 (consultar SIEMPRE
    la base). Una query por request en el hot path del POS para cerrar una
    ventana que el PO ya aceptó con sign-off no es un intercambio razonable."""
    conn = _conn(["seller"])

    await require_account_role(conn, _auth(account_roles=["seller"]), CAN_SELL)

    conn.fetchval.assert_not_awaited()


@pytest.mark.asyncio
async def test_non_configuration_guard_still_falls_back_to_db_without_claims():
    """6.3 TRIANGULATE: el orden de resolución de v3-rbac-multirole sigue
    intacto para las capacidades no sensibles — sin ningún claim, se resuelve
    contra la base como siempre."""
    conn = _conn(["cashier"])

    await require_account_role(conn, _auth(), CAN_SELL)

    conn.fetchval.assert_awaited_once()


@pytest.mark.asyncio
async def test_non_configuration_guard_still_accepts_the_legacy_single_claim():
    """6.3 TRIANGULATE: el claim SINGULAR legacy (`account_role`) sigue siendo
    el segundo escalón para las capacidades no sensibles."""
    conn = _conn(None)

    await require_account_role(conn, _auth(account_role="seller"), CAN_SELL)

    conn.fetchval.assert_not_awaited()


# ── 6.4 — nunca concede por ausencia de información ──────────────────────


@pytest.mark.asyncio
@pytest.mark.parametrize("db_roles", [None, []])
async def test_configuration_guard_denies_when_db_returns_empty(db_roles):
    """6.4: sin roles vigentes en la base, deniega — aunque el claim afirme lo
    contrario. La ausencia de información NUNCA se resuelve concediendo."""
    conn = _conn(db_roles)

    with pytest.raises(HTTPException) as exc:
        await require_account_role(conn, _auth(account_roles=["owner"]), CAN_CONFIGURE)

    assert exc.value.status_code == 403


@pytest.mark.asyncio
async def test_configuration_guard_error_message_is_deterministic():
    """Las capacidades pasan a ser conjuntos, y el orden de iteración de un
    conjunto no es estable entre procesos. El mensaje que ve el usuario no
    puede cambiar de una corrida a otra."""
    conn = _conn(["viewer"])

    with pytest.raises(HTTPException) as exc:
        await require_account_role(conn, _auth(), CAN_CONFIGURE)

    assert exc.value.detail == "Rol de cuenta insuficiente: se requiere admin o owner"
