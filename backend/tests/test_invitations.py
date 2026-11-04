"""
multiusuario-operativo TANDA C (grupo 15) — la invitación de punta a punta por FastAPI.

3 capas: router (validación + DI) -> service (CAN_CONFIGURE, nombre del negocio) -> repository
(RPCs). Sólo la conexión de asyncpg se mockea; router + service + repository corren de verdad.

  POST   /members/invitations                 crea la invitación y encola el email (misma transacción)
  GET    /members/invitations                 pendientes y vencidas/revocadas recientes (sin token)
  POST   /members/invitations/{id}/resend     reenvía: ROTA el token
  DELETE /members/invitations/{id}            revoca
  GET    /invitations/{token}                 vista previa (ligada a la identidad, en la base)
  POST   /invitations/{token}/accept          acepta y deja el negocio como cuenta activa

Los P04xx de las RPCs se traducen a RFC 7807 por el handler global: P0404 -> 404, P0409 -> 409,
P0402/P0403/P0401 -> 403 y P0439 (topes de envío) -> 429.
"""
from __future__ import annotations

import json
from unittest.mock import AsyncMock, patch

import asyncpg
import pytest

from backend.tests.conftest import effective_routes, make_token, tenant_token

ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
OTHER_ACCOUNT_ID = "dddddddd-dddd-dddd-dddd-dddddddddddd"
INVITATION_ID = "11111111-1111-1111-1111-111111111111"
TOKEN = "a" * 64
NEW_TOKEN = "b" * 64

ISSUER = {"brand_display_name": "Panadería Sol", "business_name": "Dueño S.A."}

INVITE_RESULT = {
    "id": INVITATION_ID,
    "token": TOKEN,
    "email": "invitado@test.local",
    "roles": ["seller"],
    "expires_at": "2026-10-24T12:00:00+00:00",
}
SEND_RESULT = {
    "id": INVITATION_ID,
    "email": "invitado@test.local",
    "roles": ["seller"],
    "expires_at": "2026-10-24T12:00:00+00:00",
    "token": TOKEN,
    "queued": True,
}
LIST_ROW = {
    "id": INVITATION_ID,
    "email": "invitado@test.local",
    "roles": ["seller"],
    "role_labels": ["Vendedor"],
    "state": "pending",
    "created_at": "2026-10-17T12:00:00+00:00",
    "expires_at": "2026-10-24T12:00:00+00:00",
    "invited_by": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
    "invited_by_name": "Dueño",
    "last_sent_at": "2026-10-17T12:00:05+00:00",
    "send_count": 1,
}
PREVIEW = {
    "account_id": ACCOUNT_ID,
    "account_display_name": "Panadería Sol",
    "inviter_name": "Dueño",
    "roles": ["seller"],
    "role_labels": ["Vendedor"],
    "expires_at": "2026-10-24T12:00:00+00:00",
    "already_member": False,
}
ACCEPTED = {
    "account_member_id": "22222222-2222-2222-2222-222222222222",
    "account_id": ACCOUNT_ID,
    "active_account_id": ACCOUNT_ID,
    "role": "member",
    "roles": ["seller"],
}


def pg_error(sqlstate: str, message: str) -> asyncpg.PostgresError:
    class _Err(asyncpg.PostgresError):
        def __init__(self):
            super().__init__(message)
            self.sqlstate = sqlstate

    return _Err()


def wire(conn, *, roles, results=None, fail_on=None, issuer=ISSUER, account_id=ACCOUNT_ID):
    """Arma la conexión simulada: un `fetchval` que distingue las consultas que comparten
    el método (cuenta activa, guard de rol, emisor) y un `fetchrow` que responde por RPC.
    Devuelve la lista de llamadas `(consulta, argumentos)` a las RPCs de invitación."""
    results = {
        "rpc_invite_member": INVITE_RESULT,
        "rpc_send_invitation_email": SEND_RESULT,
        "rpc_revoke_invitation": {"id": INVITATION_ID, "status": "revoked"},
        "rpc_invitation_preview": PREVIEW,
        "rpc_accept_invitation": ACCEPTED,
        **(results or {}),
    }
    calls: list[tuple[str, tuple]] = []

    async def _fetchval(query, *args, **kwargs):
        if "rpc_my_active_account_roles" in query:
            return roles
        if "current_account_ids" in query:
            return account_id
        if "rpc_commercial_issuer" in query:
            return json.dumps(issuer)
        return None

    async def _fetchrow(query, *args, **kwargs):
        for name, payload in results.items():
            if name in query:
                calls.append((query, args))
                if fail_on and fail_on[0] == name:
                    raise fail_on[1]
                return {"result": json.dumps(payload)}
        raise AssertionError(f"consulta inesperada: {query}")

    async def _fetch(query, *args, **kwargs):
        if "rpc_list_account_invitations" in query:
            calls.append((query, args))
            if fail_on and fail_on[0] == "rpc_list_account_invitations":
                raise fail_on[1]
            return [{**LIST_ROW, "token": "no-debe-salir"}]
        raise AssertionError(f"consulta inesperada: {query}")

    conn.fetchval = AsyncMock(side_effect=_fetchval)
    conn.fetchrow = AsyncMock(side_effect=_fetchrow)
    conn.fetch = AsyncMock(side_effect=_fetch)
    return calls


def _headers(token: str, **extra) -> dict:
    return {"Authorization": f"Bearer {token}", **extra}


def _rpc_names(calls) -> list[str]:
    names = []
    for query, _args in calls:
        for name in ("rpc_invite_member", "rpc_send_invitation_email", "rpc_list_account_invitations",
                     "rpc_revoke_invitation", "rpc_invitation_preview", "rpc_accept_invitation"):
            if name in query:
                names.append(name)
    return names


# ── Registro de rutas ─────────────────────────────────────────────────────────


def test_las_seis_rutas_estan_registradas():
    from backend.main import app

    routes = {(method, route.path) for route in effective_routes(app) for method in route.methods}
    for expected in (
        ("POST", "/members/invitations"),
        ("GET", "/members/invitations"),
        ("POST", "/members/invitations/{invitation_id}/resend"),
        ("DELETE", "/members/invitations/{invitation_id}"),
        ("GET", "/invitations/{token}"),
        ("POST", "/invitations/{token}/accept"),
    ):
        assert expected in routes, expected


# ── POST /members/invitations ────────────────────────────────────────────────


class TestCrearInvitacion:
    @pytest.mark.asyncio
    async def test_el_dueno_invita_y_se_encola_el_email_en_la_misma_conexion(self, async_client, mock_pool):
        pool, conn = mock_pool
        calls = wire(conn, roles=["owner"])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/members/invitations",
                json={"email": "  Invitado@Test.Local ", "roles": ["seller"]},
                headers=_headers(tenant_token(["owner"])),
            )

        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert body["id"] == INVITATION_ID
        assert body["email"] == "invitado@test.local"
        assert body["roles"] == ["seller"]
        assert body["token"] == TOKEN          # el invitador lo necesita para «Copiar link» (OQ-6)
        assert body["email_queued"] is True
        # Primero crea, después envía: las dos RPCs, en ese orden, sobre la MISMA conexión del request.
        assert _rpc_names(calls) == ["rpc_invite_member", "rpc_send_invitation_email"]
        (invite_q, invite_args), (send_q, send_args) = calls
        assert invite_args == ("invitado@test.local", ACCOUNT_ID, ["seller"])
        # Al envío: el id de la invitación creada, el nombre del negocio por la cascada canónica del emisor y renew=False.
        assert send_args == (INVITATION_ID, "Panadería Sol", False)

    @pytest.mark.asyncio
    async def test_el_administrador_tambien_invita(self, async_client, mock_pool):
        pool, conn = mock_pool
        calls = wire(conn, roles=["admin"])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/members/invitations", json={"email": "a@b.co", "roles": ["viewer"]},
                headers=_headers(tenant_token(["admin"])),
            )

        assert resp.status_code == 201, resp.text
        assert _rpc_names(calls) == ["rpc_invite_member", "rpc_send_invitation_email"]

    @pytest.mark.asyncio
    async def test_sin_roles_el_conjunto_viaja_vacio_y_la_base_resuelve_a_observador(self, async_client, mock_pool):
        pool, conn = mock_pool
        calls = wire(conn, roles=["owner"])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/members/invitations", json={"email": "a@b.co"}, headers=_headers(tenant_token(["owner"])),
            )

        assert resp.status_code == 201, resp.text
        assert calls[0][1][2] == []

    @pytest.mark.asyncio
    @pytest.mark.parametrize("roles", [["seller"], ["viewer"], ["cashier", "purchases"], []])
    async def test_quien_no_es_dueno_ni_administrador_no_invita_y_no_toca_la_base(self, async_client, mock_pool, roles):
        pool, conn = mock_pool
        calls = wire(conn, roles=roles)
        token = tenant_token(roles) if roles else make_token({"app_metadata": {"account_roles": []}})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/members/invitations", json={"email": "a@b.co", "roles": ["viewer"]}, headers=_headers(token),
            )

        assert resp.status_code == 403
        assert calls == []                       # ni invitó ni envió: el guard va ANTES

    @pytest.mark.asyncio
    async def test_sin_sesion_es_401(self, async_client, mock_pool):
        pool, conn = mock_pool
        calls = wire(conn, roles=["owner"])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post("/members/invitations", json={"email": "a@b.co"})

        assert resp.status_code == 401
        assert calls == []

    @pytest.mark.asyncio
    @pytest.mark.parametrize("payload", [
        {"email": "esto-no-es-un-email"},
        {"email": "a@b"},
        {"email": "a b@c.co"},
        {"email": "all_users"},
        {"email": "a@b.co\nBcc: x@y.z"},
        {"email": ""},
        {},
        {"email": "a@b.co", "roles": ["Seller; DROP TABLE"]},
        {"email": "a@b.co", "roles": ["x"] * 9},
    ])
    async def test_un_payload_invalido_es_422_antes_de_tocar_la_base(self, async_client, mock_pool, payload):
        pool, conn = mock_pool
        calls = wire(conn, roles=["owner"])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post("/members/invitations", json=payload, headers=_headers(tenant_token(["owner"])))

        assert resp.status_code == 422
        assert calls == []

    @pytest.mark.asyncio
    async def test_una_pestana_desfasada_recibe_409_account_switched_sin_invitar(self, async_client, mock_pool):
        from backend.core.deps import get_account_id
        from backend.main import app

        pool, conn = mock_pool
        calls = wire(conn, roles=["owner"])

        # El fixture `async_client` reemplaza `get_account_id` por un doble fijo: acá corre el REAL
        # (con la conexión simulada), que es el que compara `X-Account-Id` con la cuenta activa.
        override = app.dependency_overrides.pop(get_account_id, None)
        try:
            with patch("backend.core.database.pool", pool):
                resp = await async_client.post(
                    "/members/invitations", json={"email": "a@b.co"},
                    headers=_headers(tenant_token(["owner"]), **{"X-Account-Id": OTHER_ACCOUNT_ID}),
                )
        finally:
            if override is not None:
                app.dependency_overrides[get_account_id] = override

        assert resp.status_code == 409
        assert resp.json()["code"] == "account_switched"
        assert calls == []

    @pytest.mark.asyncio
    @pytest.mark.parametrize("sqlstate,status", [
        ("P0402", 403),   # cupo del plan
        ("P0403", 403),   # autoridad fina (un administrador no invita administradores)
        ("P0407", 409),   # ya hay una invitación pendiente para ese email
        ("P0400", 400),   # email inválido / rol fuera del catálogo
        ("P0401", 403),
    ])
    async def test_los_errores_de_la_invitacion_se_traducen_a_rfc_7807(self, async_client, mock_pool, sqlstate, status):
        pool, conn = mock_pool
        wire(conn, roles=["owner"], fail_on=("rpc_invite_member", pg_error(sqlstate, "mensaje de la base")))

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/members/invitations", json={"email": "a@b.co", "roles": ["seller"]},
                headers=_headers(tenant_token(["owner"])),
            )

        assert resp.status_code == status
        assert resp.json()["code"] == sqlstate

    @pytest.mark.asyncio
    async def test_el_tope_diario_en_el_envio_es_429_y_la_invitacion_no_queda(self, async_client, mock_pool):
        """P0439 sale del ENVÍO (después de crear): el request falla -> el handler global lo traduce a 429
        y la transacción del request se revierte, así la invitación tampoco queda."""
        pool, conn = mock_pool
        calls = wire(conn, roles=["owner"],
                     fail_on=("rpc_send_invitation_email", pg_error("P0439", "invitation_daily_cap: tope")))

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/members/invitations", json={"email": "a@b.co", "roles": ["seller"]},
                headers=_headers(tenant_token(["owner"])),
            )

        assert resp.status_code == 429
        body = resp.json()
        assert body["code"] == "P0439"
        assert "invitation_daily_cap" in body["detail"]
        assert _rpc_names(calls) == ["rpc_invite_member", "rpc_send_invitation_email"]


# ── GET /members/invitations ─────────────────────────────────────────────────


class TestListarInvitaciones:
    @pytest.mark.asyncio
    async def test_lista_las_pendientes_y_nunca_expone_el_token(self, async_client, mock_pool):
        pool, conn = mock_pool
        calls = wire(conn, roles=["owner"])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/members/invitations", headers=_headers(tenant_token(["owner"])))

        assert resp.status_code == 200, resp.text
        items = resp.json()
        assert len(items) == 1
        assert items[0]["email"] == "invitado@test.local"
        assert items[0]["state"] == "pending"
        assert items[0]["role_labels"] == ["Vendedor"]
        assert items[0]["send_count"] == 1
        assert "token" not in items[0]
        assert "no-debe-salir" not in resp.text
        assert calls[0][1] == (ACCOUNT_ID,)

    @pytest.mark.asyncio
    async def test_el_vendedor_no_las_ve(self, async_client, mock_pool):
        pool, conn = mock_pool
        calls = wire(conn, roles=["seller"])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/members/invitations", headers=_headers(tenant_token(["seller"])))

        assert resp.status_code == 403
        assert calls == []

    @pytest.mark.asyncio
    async def test_sin_sesion_es_401(self, async_client, mock_pool):
        pool, conn = mock_pool
        wire(conn, roles=["owner"])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get("/members/invitations")
        assert resp.status_code == 401


# ── POST /members/invitations/{id}/resend ────────────────────────────────────


class TestReenviarInvitacion:
    @pytest.mark.asyncio
    async def test_reenviar_renueva_y_devuelve_el_token_nuevo(self, async_client, mock_pool):
        pool, conn = mock_pool
        calls = wire(conn, roles=["owner"], results={"rpc_send_invitation_email": {**SEND_RESULT, "token": NEW_TOKEN}})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/members/invitations/{INVITATION_ID}/resend", headers=_headers(tenant_token(["owner"])),
            )

        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["token"] == NEW_TOKEN
        assert body["email_queued"] is True
        assert _rpc_names(calls) == ["rpc_send_invitation_email"]
        # id, nombre del negocio (misma cascada) y renew=True: la RPC rota el token.
        assert calls[0][1] == (INVITATION_ID, "Panadería Sol", True)

    @pytest.mark.asyncio
    async def test_el_vendedor_no_reenvia(self, async_client, mock_pool):
        pool, conn = mock_pool
        calls = wire(conn, roles=["seller"])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/members/invitations/{INVITATION_ID}/resend", headers=_headers(tenant_token(["seller"])),
            )

        assert resp.status_code == 403
        assert calls == []

    @pytest.mark.asyncio
    @pytest.mark.parametrize("sqlstate,message,status", [
        ("P0439", "invitation_cooldown: esperá unos minutos", 429),
        ("P0439", "invitation_daily_cap: tope diario", 429),
        ("P0409", "invitation_not_pending: ya fue revocada", 409),
        ("P0404", "P404: invitation not found", 404),
        ("P0403", "insufficient_role: solo el dueño", 403),
    ])
    async def test_los_errores_del_reenvio_se_traducen(self, async_client, mock_pool, sqlstate, message, status):
        pool, conn = mock_pool
        wire(conn, roles=["owner"], fail_on=("rpc_send_invitation_email", pg_error(sqlstate, message)))

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/members/invitations/{INVITATION_ID}/resend", headers=_headers(tenant_token(["owner"])),
            )

        assert resp.status_code == status
        assert resp.json()["code"] == sqlstate

    @pytest.mark.asyncio
    async def test_un_id_que_no_es_uuid_es_422(self, async_client, mock_pool):
        pool, conn = mock_pool
        calls = wire(conn, roles=["owner"])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post("/members/invitations/no-es-un-uuid/resend", headers=_headers(tenant_token(["owner"])))
        assert resp.status_code == 422
        assert calls == []


# ── DELETE /members/invitations/{id} ─────────────────────────────────────────


class TestRevocarInvitacion:
    @pytest.mark.asyncio
    async def test_el_dueno_revoca(self, async_client, mock_pool):
        pool, conn = mock_pool
        calls = wire(conn, roles=["owner"])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.delete(f"/members/invitations/{INVITATION_ID}", headers=_headers(tenant_token(["owner"])))

        assert resp.status_code == 200, resp.text
        assert resp.json() == {"id": INVITATION_ID, "status": "revoked"}
        assert _rpc_names(calls) == ["rpc_revoke_invitation"]
        assert calls[0][1] == (INVITATION_ID,)

    @pytest.mark.asyncio
    async def test_el_vendedor_no_revoca(self, async_client, mock_pool):
        pool, conn = mock_pool
        calls = wire(conn, roles=["seller"])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.delete(f"/members/invitations/{INVITATION_ID}", headers=_headers(tenant_token(["seller"])))

        assert resp.status_code == 403
        assert calls == []

    @pytest.mark.asyncio
    async def test_una_invitacion_de_otra_cuenta_es_404(self, async_client, mock_pool):
        pool, conn = mock_pool
        wire(conn, roles=["owner"], fail_on=("rpc_revoke_invitation", pg_error("P0404", "P404: invitation not found")))

        with patch("backend.core.database.pool", pool):
            resp = await async_client.delete(f"/members/invitations/{INVITATION_ID}", headers=_headers(tenant_token(["owner"])))

        assert resp.status_code == 404
        assert resp.json()["code"] == "P0404"


# ── GET /invitations/{token} ─────────────────────────────────────────────────


class TestVistaPrevia:
    @pytest.mark.asyncio
    async def test_cualquier_usuario_autenticado_previsualiza_con_su_identidad(self, async_client, mock_pool):
        """No exige rol de la cuenta (el invitado todavía no es miembro) ni la cuenta activa: la
        identidad la liga la RPC contra el email de la invitación."""
        pool, conn = mock_pool
        calls = wire(conn, roles=[])
        # Un token SIN claims de rol de tenant: el usuario sólo tiene su cuenta personal.
        token = make_token({})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(f"/invitations/{TOKEN}", headers=_headers(token))

        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["account_display_name"] == "Panadería Sol"
        assert body["inviter_name"] == "Dueño"
        assert body["role_labels"] == ["Vendedor"]
        assert body["already_member"] is False
        assert body["account_id"] == ACCOUNT_ID
        assert "token" not in body
        assert calls[0][1] == (TOKEN,)
        # No resolvió la cuenta activa ni consultó el guard de rol.
        conn.fetchval.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_la_pestana_desfasada_no_bloquea_la_vista_previa(self, async_client, mock_pool):
        """El guard de pestaña desfasada (X-Account-Id) es de las operaciones de la cuenta; la
        vista previa del invitado no depende de cuál muestre la pantalla."""
        pool, conn = mock_pool
        wire(conn, roles=[])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(
                f"/invitations/{TOKEN}", headers=_headers(make_token({}), **{"X-Account-Id": OTHER_ACCOUNT_ID}),
            )

        assert resp.status_code == 200, resp.text

    @pytest.mark.asyncio
    async def test_otra_identidad_o_token_invalido_es_404_con_el_mensaje_generico(self, async_client, mock_pool):
        pool, conn = mock_pool
        wire(conn, roles=[], fail_on=("rpc_invitation_preview", pg_error("P0404", "P404: invalid or expired invitation token")))

        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(f"/invitations/{TOKEN}", headers=_headers(make_token({})))

        assert resp.status_code == 404
        assert resp.json()["code"] == "P0404"
        assert "invalid or expired invitation token" in resp.json()["detail"]

    @pytest.mark.asyncio
    async def test_sin_sesion_es_401(self, async_client, mock_pool):
        pool, conn = mock_pool
        calls = wire(conn, roles=[])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(f"/invitations/{TOKEN}")
        assert resp.status_code == 401
        assert calls == []

    @pytest.mark.asyncio
    @pytest.mark.parametrize("token", ["corto", "z" * 200, "tok en con espacios"])
    async def test_un_token_con_forma_invalida_es_404_sin_tocar_la_base(self, async_client, mock_pool, token):
        pool, conn = mock_pool
        calls = wire(conn, roles=[])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.get(f"/invitations/{token}", headers=_headers(make_token({})))
        assert resp.status_code == 404
        assert calls == []


# ── POST /invitations/{token}/accept ─────────────────────────────────────────


class TestAceptarInvitacion:
    @pytest.mark.asyncio
    async def test_acepta_y_devuelve_la_cuenta_activa(self, async_client, mock_pool):
        pool, conn = mock_pool
        calls = wire(conn, roles=[])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(f"/invitations/{TOKEN}/accept", headers=_headers(make_token({})))

        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["account_id"] == ACCOUNT_ID
        assert body["active_account_id"] == ACCOUNT_ID
        assert body["roles"] == ["seller"]
        assert _rpc_names(calls) == ["rpc_accept_invitation"]
        assert calls[0][1] == (TOKEN,)

    @pytest.mark.asyncio
    async def test_la_pestana_desfasada_no_bloquea_la_aceptacion(self, async_client, mock_pool):
        pool, conn = mock_pool
        wire(conn, roles=[])

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                f"/invitations/{TOKEN}/accept",
                headers=_headers(make_token({}), **{"X-Account-Id": OTHER_ACCOUNT_ID}),
            )

        assert resp.status_code == 200, resp.text

    @pytest.mark.asyncio
    @pytest.mark.parametrize("sqlstate,message,status", [
        ("P0404", "P404: invalid or expired invitation token", 404),
        ("P0409", "P409: caller is already a member of account x", 409),
        ("P0402", "P403: member quota reached (2 / 2)", 403),
        ("P0401", "Not authenticated", 403),
    ])
    async def test_los_errores_de_la_aceptacion_se_traducen(self, async_client, mock_pool, sqlstate, message, status):
        pool, conn = mock_pool
        wire(conn, roles=[], fail_on=("rpc_accept_invitation", pg_error(sqlstate, message)))

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(f"/invitations/{TOKEN}/accept", headers=_headers(make_token({})))

        assert resp.status_code == status
        assert resp.json()["code"] == sqlstate

    @pytest.mark.asyncio
    async def test_sin_sesion_es_401(self, async_client, mock_pool):
        pool, conn = mock_pool
        calls = wire(conn, roles=[])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(f"/invitations/{TOKEN}/accept")
        assert resp.status_code == 401
        assert calls == []

    @pytest.mark.asyncio
    async def test_un_token_con_forma_invalida_es_404_sin_tocar_la_base(self, async_client, mock_pool):
        pool, conn = mock_pool
        calls = wire(conn, roles=[])
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post("/invitations/corto/accept", headers=_headers(make_token({})))
        assert resp.status_code == 404
        assert calls == []


# ── P0439 en el mapa de errores ──────────────────────────────────────────────


def test_p0439_se_traduce_a_429_en_el_mapa_global():
    from backend.core.errors import _BUSINESS_ERRCODE_STATUS

    assert _BUSINESS_ERRCODE_STATUS["P0439"] == 429
