"""
v31-authz-token-hook — tasks 5.4-5.6: `require_account_role` (D6) nació con
un fallback singular a `account_members.role`.

v3-rbac-multirole Parte B — grupo 10 (D10, D15, R6): `require_account_role`
pasa a evaluar el CONJUNTO de roles activos del actor (`account_roles`),
conservando el claim singular `account_role` como conjunto-de-uno de
compatibilidad, y con el fallback a la base reescrito para leer las
asignaciones VIGENTES del pivot (nunca la columna singular legacy) vía
`rpc_my_active_account_roles()`. Orden de resolución (10.2): claim del
conjunto -> claim singular como conjunto de uno -> asignaciones vigentes en
la base -> sin ninguna de las tres, deniega.
"""
from __future__ import annotations

from unittest.mock import AsyncMock

import pytest
from fastapi import HTTPException


def _auth(account_role: str | None = None, account_roles: list[str] | None = None) -> dict:
    return {
        "user_id": "11111111-1111-1111-1111-111111111111",
        "role": "user",
        "account_role": account_role,
        "account_roles": account_roles,
        "plan": "gratis",
    }


# ── 10.1 RED — el conjunto autoriza si INTERSECA `allowed`; deniega si ninguno ──


@pytest.mark.asyncio
async def test_require_account_role_authorizes_when_any_role_in_set_is_allowed():
    """RED (10.1a): el actor tiene 2 roles activos, sólo uno está permitido
    -> autoriza (semántica "alguno", no "todos")."""
    from backend.core.guards import require_account_role

    conn = AsyncMock()
    auth = _auth(account_roles=["seller", "cashier"])

    await require_account_role(conn, auth, ["owner", "admin", "cashier"])

    conn.fetchval.assert_not_awaited()


@pytest.mark.asyncio
async def test_require_account_role_denies_when_no_role_in_set_is_allowed():
    """RED (10.1b): el conjunto de roles activos no interseca `allowed` ->
    403, sin caer a ningún fallback (el claim del conjunto está presente)."""
    from backend.core.guards import require_account_role

    conn = AsyncMock()
    auth = _auth(account_roles=["seller", "stock"])

    with pytest.raises(HTTPException) as exc_info:
        await require_account_role(conn, auth, ["owner", "admin"])

    assert exc_info.value.status_code == 403
    conn.fetchval.assert_not_awaited()


@pytest.mark.asyncio
async def test_require_account_role_claim_set_present_does_not_query_db():
    """El claim del conjunto presente decide SOLO — el mock de conexión no
    recibe ninguna query, aunque el resultado sea autorizar o denegar."""
    from backend.core.guards import require_account_role

    conn = AsyncMock()
    auth = _auth(account_roles=["owner"])

    await require_account_role(conn, auth, ["owner", "admin"])

    conn.fetchval.assert_not_awaited()
    conn.fetchrow.assert_not_awaited()
    conn.fetch.assert_not_awaited()


@pytest.mark.asyncio
async def test_require_account_role_empty_set_claim_denies_without_falling_back():
    """D9: un conjunto VACÍO ya resuelto por el hook (claim PRESENTE, sin
    roles activos) es la fuente de verdad — NO cae al claim singular ni a
    la DB, aunque ambos pudieran dar un rol permisivo distinto (staleness
    aceptada en la dirección correcta: el claim fresco gana)."""
    from backend.core.guards import require_account_role

    conn = AsyncMock()
    auth = _auth(account_role="owner", account_roles=[])

    with pytest.raises(HTTPException) as exc_info:
        await require_account_role(conn, auth, ["owner", "admin"])

    assert exc_info.value.status_code == 403
    conn.fetchval.assert_not_awaited()


# ── 10.2 RED — orden de resolución de las tres vías ─────────────────────────


@pytest.mark.asyncio
async def test_require_account_role_falls_back_to_singular_claim_as_set_of_one():
    """RED (10.2a): claim del conjunto AUSENTE (None, token viejo) -> usa el
    claim singular legacy `account_role` como conjunto de uno, SIN tocar la
    base."""
    from backend.core.guards import require_account_role

    conn = AsyncMock()
    auth = _auth(account_role="owner", account_roles=None)

    await require_account_role(conn, auth, ["owner", "admin"])

    conn.fetchval.assert_not_awaited()


@pytest.mark.asyncio
async def test_require_account_role_singular_claim_present_but_not_allowed_denies_without_db():
    """Ronda 1 adversarial (nit 9): el claim SINGULAR presente pero NO
    permitido deniega SIN caer al fallback de DB. Esta aserción se había
    perdido: el test original (`..._claim_present_but_not_allowed_denies_
    without_db`) se reemplazó por `test_require_account_role_db_fallback_
    no_membership_denies`, que ya no cubre este camino (claim singular
    PRESENTE, no ausente) -- los caminos hermanos con el conjunto sí la
    conservan (`test_require_account_role_denies_when_no_role_in_set_is_
    allowed`, `..._empty_set_claim_denies_without_falling_back`), pero el
    camino 2 del orden de resolución (10.2) había quedado sin este candado
    contra que una denegación degrade en una consulta permisiva a la base."""
    from backend.core.guards import require_account_role

    conn = AsyncMock()
    auth = _auth(account_role="member", account_roles=None)

    with pytest.raises(HTTPException) as exc_info:
        await require_account_role(conn, auth, ["owner", "admin"])

    assert exc_info.value.status_code == 403
    conn.fetchval.assert_not_awaited()


@pytest.mark.asyncio
async def test_require_account_role_falls_back_to_db_when_both_claims_absent():
    """RED (10.2b): ni el conjunto ni el singular viajan -> resuelve contra
    la base (rpc_my_active_account_roles) y autoriza si el resultado
    interseca `allowed`."""
    from backend.core.guards import require_account_role

    conn = AsyncMock()
    conn.fetchval = AsyncMock(return_value=["owner"])
    auth = _auth(account_role=None, account_roles=None)

    await require_account_role(conn, auth, ["owner", "admin"])

    conn.fetchval.assert_awaited_once()


@pytest.mark.asyncio
async def test_require_account_role_denies_without_any_of_the_three_sources():
    """RED (10.2c): ninguna de las tres vías produce un rol -> 403. La
    ausencia de información NUNCA autoriza."""
    from backend.core.guards import require_account_role

    conn = AsyncMock()
    conn.fetchval = AsyncMock(return_value=None)
    auth = _auth(account_role=None, account_roles=None)

    with pytest.raises(HTTPException) as exc_info:
        await require_account_role(conn, auth, ["owner", "admin"])

    assert exc_info.value.status_code == 403


# ── 10.3 RED — el fallback a DB lee asignaciones VIGENTES, no la columna singular (R6) ──


@pytest.mark.asyncio
async def test_require_account_role_db_fallback_queries_active_assignments_not_singular_column():
    """RED (10.3): el fallback debe invocar `rpc_my_active_account_roles`
    (lee el pivot vigente vía member_active_roles, D4) — NUNCA la sentencia
    legacy `SELECT role FROM account_members` (columna singular espejo,
    R6). Se verifica el texto de la query awaited."""
    from backend.core.guards import require_account_role

    conn = AsyncMock()
    conn.fetchval = AsyncMock(return_value=["owner"])
    auth = _auth(account_role=None, account_roles=None)

    await require_account_role(conn, auth, ["owner", "admin"])

    awaited_sql = conn.fetchval.await_args.args[0]
    assert "rpc_my_active_account_roles" in awaited_sql
    assert "account_members.role" not in awaited_sql
    assert "SELECT role FROM account_members" not in awaited_sql


@pytest.mark.asyncio
async def test_require_account_role_db_fallback_no_membership_denies():
    """TRIANGULATE: fallback a la base sin ninguna asignación vigente
    (NULL/lista vacía) -> 403, nunca un default permisivo."""
    from backend.core.guards import require_account_role

    conn = AsyncMock()
    conn.fetchval = AsyncMock(return_value=None)
    auth = _auth(account_role=None, account_roles=None)

    with pytest.raises(HTTPException) as exc_info:
        await require_account_role(conn, auth, ["owner", "admin"])

    assert exc_info.value.status_code == 403


@pytest.mark.asyncio
async def test_require_account_role_db_fallback_role_not_allowed_denies():
    """TRIANGULATE adicional: la base resuelve un conjunto de roles VIGENTE
    que no interseca `allowed` -> 403."""
    from backend.core.guards import require_account_role

    conn = AsyncMock()
    conn.fetchval = AsyncMock(return_value=["viewer"])
    auth = _auth(account_role=None, account_roles=None)

    with pytest.raises(HTTPException) as exc_info:
        await require_account_role(conn, auth, ["owner", "admin"])

    assert exc_info.value.status_code == 403


# ── Ronda 1 adversarial (nit 8) — el claim del conjunto debe ser una LISTA ──
# El hook SIEMPRE serializa `account_roles` como `to_jsonb(text[])` (un array
# JSON), así que un claim con otra forma no debería poder llegar por ese
# camino real -- pero `require_account_role` no lo comprobaba antes de
# iterarlo. Reproducido: un dict itera sus CLAVES (podía autorizar por
# coincidencia de texto), un str itera sus CARACTERES (idem), y un int no es
# iterable (TypeError -> 500 en vez de 403). Fail-closed: cualquier forma
# no-lista se trata como "claim ausente" y cae al resto del orden de
# resolución, nunca a una autorización ni a una excepción no controlada.


@pytest.mark.asyncio
async def test_require_account_role_dict_shaped_claim_does_not_authorize_via_its_keys():
    """RED (nit 8a): un claim `account_roles` con forma de OBJETO
    (`{"owner": 1}`) NO debe autorizar por iterar sus claves -- se trata
    como ausente y, sin singular ni DB con rol permitido, deniega."""
    from backend.core.guards import require_account_role

    conn = AsyncMock()
    conn.fetchval = AsyncMock(return_value=None)
    auth = _auth(account_role=None, account_roles=None)
    auth["account_roles"] = {"owner": 1}

    with pytest.raises(HTTPException) as exc_info:
        await require_account_role(conn, auth, ["owner", "admin"])

    assert exc_info.value.status_code == 403


@pytest.mark.asyncio
async def test_require_account_role_string_shaped_claim_does_not_authorize_via_its_characters():
    """TRIANGULATE (nit 8b): un claim `account_roles` como STRING plano
    (`"o"`) tampoco debe autorizar por coincidencia de caracteres contra
    `allowed` (`"o" in "owner"` sería True si se comparara mal)."""
    from backend.core.guards import require_account_role

    conn = AsyncMock()
    conn.fetchval = AsyncMock(return_value=None)
    auth = _auth(account_role=None, account_roles=None)
    auth["account_roles"] = "o"

    with pytest.raises(HTTPException) as exc_info:
        await require_account_role(conn, auth, ["owner", "admin"])

    assert exc_info.value.status_code == 403


@pytest.mark.asyncio
async def test_require_account_role_non_iterable_claim_denies_instead_of_500():
    """TRIANGULATE (nit 8c): un claim `account_roles` NO iterable (`5`) no
    debe reventar con `TypeError` (500) -- se trata como ausente y deniega,
    fail-closed, igual que las otras formas rotas."""
    from backend.core.guards import require_account_role

    conn = AsyncMock()
    conn.fetchval = AsyncMock(return_value=None)
    auth = _auth(account_role=None, account_roles=None)
    auth["account_roles"] = 5

    with pytest.raises(HTTPException) as exc_info:
        await require_account_role(conn, auth, ["owner", "admin"])

    assert exc_info.value.status_code == 403
