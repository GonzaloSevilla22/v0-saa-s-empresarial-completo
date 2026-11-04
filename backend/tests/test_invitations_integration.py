"""
multiusuario-operativo TANDA C (grupo 15, "integración contra Postgres local") — la invitación de
punta a punta contra la base REAL.

Marcado `@pytest.mark.integration`: excluido del gate de CI (`-m "not integration"`); correr a mano con
`-m integration` contra el stack local con 20261085000001 aplicada. La evidencia de CI del esquema es el
gate SQL supabase/tests/test_multiusuario_invitaciones.sql.

Por qué además de test_invitations.py: aquel mockea la conexión y sólo asserta que el SQL NOMBRA las RPCs
y que los errores se traducen. Éste corre el MISMO `InvitationRepository` + `services.invitations` que usa
el endpoint contra la base, con los claims del JWT puestos en la transacción como hace
`backend/core/database.py` (sub, role y `app_metadata.account_id`; NUNCA el email) y bajo
`SET LOCAL ROLE authenticated`, y verifica lo que el mock no puede:

  * crear + enviar son ATÓMICOS: un tope P0439 en el envío revierte la invitación (en la misma conexión);
  * el email queda encolado con el destinatario y el token de la FILA;
  * la vista previa y la aceptación van ligadas a la identidad, resuelta contra `auth.users`;
  * aceptar deja el negocio como cuenta activa y conserva la personal.
"""
from __future__ import annotations

import contextlib
import json
import os
import uuid

import asyncpg
import pytest
from fastapi import HTTPException

from backend.repositories.invitation_repository import InvitationRepository
from backend.services import invitations as svc

DSN = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@127.0.0.1:54322/postgres")

pytestmark = pytest.mark.integration


class World:
    def __init__(self) -> None:
        self.owner = uuid.uuid4()
        self.seller = uuid.uuid4()
        self.invitee = uuid.uuid4()
        self.wrong = uuid.uuid4()
        self.account: uuid.UUID
        self.invitee_personal: uuid.UUID

    @property
    def users(self) -> list[uuid.UUID]:
        return [self.owner, self.seller, self.invitee, self.wrong]


def _email(tag: str, uid: uuid.UUID) -> str:
    return f"mu-c-integ-{tag}-{uid}@test.local"


async def _claims(conn: asyncpg.Connection, user_id: uuid.UUID, account_id: uuid.UUID | None) -> None:
    claims: dict = {"sub": str(user_id), "role": "authenticated"}
    if account_id is not None:
        claims["app_metadata"] = {"account_id": str(account_id)}
    await conn.execute("SELECT set_config('request.jwt.claims', $1, true)", json.dumps(claims))
    await conn.execute("SELECT set_config('request.jwt.claim.sub', $1, true)", str(user_id))


@contextlib.asynccontextmanager
async def _as(conn: asyncpg.Connection, user_id: uuid.UUID, account_id: uuid.UUID | None):
    """Una 'request': transacción + claims + SET LOCAL ROLE authenticated (Paso 2 de v31-tenancy-pool-rls)."""
    async with conn.transaction():
        await _claims(conn, user_id, account_id)
        await conn.execute("SET LOCAL ROLE authenticated")
        yield


def _auth(user_id: uuid.UUID) -> dict:
    # Sin claim `account_roles`: el guard (capacidad sensible) resuelve el pivot en la base.
    return {"user_id": str(user_id), "sub": str(user_id), "role": "user"}


async def _seed(conn: asyncpg.Connection) -> World:
    w = World()
    for tag, uid in (("owner", w.owner), ("seller", w.seller), ("invitee", w.invitee), ("wrong", w.wrong)):
        await conn.execute(
            """
            INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
            VALUES ($1, 'authenticated', 'authenticated', $2, now(), now(),
                    jsonb_build_object('name', $3::text, 'phone', '', 'locality', '', 'province', ''))
            """,
            uid, _email(tag, uid), f"Integración Invitaciones {tag}",
        )
    w.account = await conn.fetchval("SELECT account_id FROM public.account_members WHERE user_id = $1", w.owner)
    w.invitee_personal = await conn.fetchval("SELECT account_id FROM public.account_members WHERE user_id = $1", w.invitee)
    assert w.account and w.invitee_personal, "SETUP: handle_new_user no creó las cuentas"
    await conn.execute(
        "UPDATE public.accounts SET billing_plan = 'pro', trial_plan = NULL, trial_expires_at = NULL WHERE id = $1", w.account)
    # El vendedor es miembro de A (con SU cuenta personal además; la activa se declara por claim).
    member_id = await conn.fetchval(
        "INSERT INTO public.account_members (account_id, user_id, role) VALUES ($1, $2, 'member') RETURNING id",
        w.account, w.seller)
    await conn.execute(
        "INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES ($1, $2, 'seller')", w.account, member_id)
    return w


async def _cleanup(conn: asyncpg.Connection, w: World) -> None:
    accounts = [r["account_id"] for r in await conn.fetch(
        "SELECT DISTINCT account_id FROM public.account_members WHERE user_id = ANY($1::uuid[])", w.users)]
    await conn.execute("SET session_replication_role = replica")
    try:
        await conn.execute("DELETE FROM public.email_logs WHERE user_id = ANY($1::uuid[])", w.users)
        await conn.execute("DELETE FROM public.account_invitations WHERE account_id = ANY($1::uuid[])", accounts)
        tables = await conn.fetch(
            """
            SELECT c.table_name FROM information_schema.columns c
            JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
            WHERE c.table_schema = 'public' AND c.column_name = 'account_id'
              AND t.table_type = 'BASE TABLE' AND c.table_name NOT IN ('accounts', 'account_invitations')
            """
        )
        for row in tables:
            await conn.execute(f'DELETE FROM public."{row["table_name"]}" WHERE account_id = ANY($1::uuid[])', accounts)
        await conn.execute("DELETE FROM public.accounts WHERE id = ANY($1::uuid[])", accounts)
    finally:
        await conn.execute("SET session_replication_role = DEFAULT")
    await conn.execute("DELETE FROM public.account_members WHERE user_id = ANY($1::uuid[])", w.users)
    await conn.execute("DELETE FROM public.billing_events WHERE user_id = ANY($1::uuid[])", w.users)
    await conn.execute("DELETE FROM public.profiles WHERE id = ANY($1::uuid[])", w.users)
    await conn.execute("DELETE FROM auth.users WHERE id = ANY($1::uuid[])", w.users)


@pytest.fixture
async def conn():
    try:
        c = await asyncpg.connect(DSN)
    except (OSError, asyncpg.PostgresError) as exc:  # pragma: no cover - depende del entorno
        pytest.skip(f"Postgres local no disponible ({exc}); levantá `supabase start`")
    try:
        yield c
    finally:
        await c.close()


@pytest.fixture
async def world(conn: asyncpg.Connection):
    w = await _seed(conn)
    try:
        yield w
    finally:
        await _cleanup(conn, w)


async def _create(conn, w: World, email: str, roles: list[str]) -> dict:
    async with _as(conn, w.owner, w.account):
        return await svc.create_invitation(
            InvitationRepository(conn), _auth(w.owner), str(w.account), email, roles, conn=conn)


# ── crear + enviar ───────────────────────────────────────────────────────────


async def test_crear_encola_el_email_con_el_destinatario_y_el_token_de_la_fila(conn, world: World):
    w = world
    email = _email("invitee", w.invitee)

    sent = await _create(conn, w, email, ["seller"])

    row = await conn.fetchrow("SELECT * FROM public.account_invitations WHERE id = $1", uuid.UUID(str(sent["id"])))
    assert row["email"] == email and row["status"] == "pending" and row["roles"] == ["seller"]
    assert row["token"] == sent["token"] and row["account_id"] == w.account
    mail = await conn.fetchrow(
        "SELECT * FROM public.email_logs WHERE event_type = 'org_invite' AND recipient = $1", email)
    assert mail is not None and mail["status"] == "pending" and mail["user_id"] == w.owner
    meta = json.loads(mail["metadata"]) if isinstance(mail["metadata"], str) else mail["metadata"]
    assert meta["token"] == row["token"] and meta["invitation_id"] == str(row["id"])
    assert meta["role_labels"] == ["Vendedor"]
    # El nombre sale de la cascada canónica del emisor (sin marca ni perfil fiscal: el nombre del dueño).
    assert meta["account_name"] and row["account_display_name"] == meta["account_name"]


async def test_un_tope_de_envio_revierte_la_invitacion_en_la_misma_transaccion(conn, world: World):
    """El requirement: «una sola RPC encola el email DENTRO de la misma transacción». Con 20 envíos en
    el día, `rpc_send_invitation_email` levanta P0439 DESPUÉS de que `rpc_invite_member` insertó la fila:
    la excepción sale de la transacción del request y la invitación NO queda."""
    w = world
    for i in range(20):
        await conn.execute(
            "INSERT INTO public.email_logs (user_id, event_type, recipient, subject, status, metadata, created_at) "
            "VALUES ($1, 'org_invite', $2, 'cap', 'sent', $3::jsonb, now() - interval '2 hours')",
            w.owner, f"cap-{i}@test.local",
            json.dumps({"account_id": str(w.account), "invitation_id": str(uuid.uuid4()), "k": i}),
        )
    email = _email("invitee", w.invitee)

    with pytest.raises(asyncpg.PostgresError) as info:
        await _create(conn, w, email, ["seller"])

    assert info.value.sqlstate == "P0439" and "invitation_daily_cap" in str(info.value)
    assert await conn.fetchval("SELECT count(*) FROM public.account_invitations WHERE email = $1", email) == 0
    assert await conn.fetchval(
        "SELECT count(*) FROM public.email_logs WHERE event_type = 'org_invite' AND recipient = $1", email) == 0


async def test_el_vendedor_no_puede_invitar_ni_dejar_nada(conn, world: World):
    w = world
    email = _email("invitee", w.invitee)
    with pytest.raises(HTTPException) as info:
        async with _as(conn, w.seller, w.account):
            await svc.create_invitation(
                InvitationRepository(conn), _auth(w.seller), str(w.account), email, ["viewer"], conn=conn)
    assert info.value.status_code == 403
    assert await conn.fetchval("SELECT count(*) FROM public.account_invitations WHERE email = $1", email) == 0


# ── reenviar, listar, revocar ────────────────────────────────────────────────


async def test_reenviar_rota_el_token_y_el_viejo_deja_de_servir(conn, world: World):
    w = world
    sent = await _create(conn, w, _email("invitee", w.invitee), ["seller"])
    await conn.execute(  # pasó la ventana de enfriamiento
        "UPDATE public.email_logs SET created_at = created_at - interval '11 minutes' WHERE event_type = 'org_invite'")

    async with _as(conn, w.owner, w.account):
        again = await svc.resend_invitation(
            InvitationRepository(conn), _auth(w.owner), str(w.account), str(sent["id"]), conn=conn)

    assert again["token"] != sent["token"]
    with pytest.raises(asyncpg.PostgresError) as info:
        async with _as(conn, w.invitee, w.invitee_personal):
            await svc.accept_invitation(InvitationRepository(conn), sent["token"])
    assert info.value.sqlstate == "P0404"


async def test_listar_no_expone_el_token_y_revocar_impide_aceptar(conn, world: World):
    w = world
    sent = await _create(conn, w, _email("invitee", w.invitee), ["seller"])

    async with _as(conn, w.owner, w.account):
        rows = await svc.list_invitations(InvitationRepository(conn), _auth(w.owner), str(w.account), conn=conn)
    assert len(rows) == 1 and rows[0]["state"] == "pending" and "token" not in rows[0]

    async with _as(conn, w.owner, w.account):
        revoked = await svc.revoke_invitation(
            InvitationRepository(conn), _auth(w.owner), str(w.account), str(sent["id"]), conn=conn)
    assert revoked["status"] == "revoked"
    with pytest.raises(asyncpg.PostgresError) as info:
        async with _as(conn, w.invitee, w.invitee_personal):
            await svc.accept_invitation(InvitationRepository(conn), sent["token"])
    assert info.value.sqlstate == "P0404"


# ── vista previa y aceptación ────────────────────────────────────────────────


async def test_la_vista_previa_y_la_aceptacion_estan_ligadas_a_la_identidad(conn, world: World):
    w = world
    sent = await _create(conn, w, _email("invitee", w.invitee), ["seller"])

    # OTRA identidad: el mismo error que un token inexistente, en la vista previa y al aceptar.
    for fn in (svc.preview_invitation, svc.accept_invitation):
        with pytest.raises(asyncpg.PostgresError) as info:
            async with _as(conn, w.wrong, None):
                await fn(InvitationRepository(conn), sent["token"])
        assert info.value.sqlstate == "P0404" and "invalid or expired invitation token" in str(info.value)
    assert await conn.fetchval("SELECT count(*) FROM public.account_members WHERE user_id = $1", w.wrong) == 1

    # La identidad invitada (claims sin email): ve el negocio, acepta, y el negocio queda activo.
    async with _as(conn, w.invitee, w.invitee_personal):
        preview = await svc.preview_invitation(InvitationRepository(conn), sent["token"])
    assert preview["account_id"] == str(w.account) and preview["already_member"] is False
    assert preview["role_labels"] == ["Vendedor"] and "token" not in preview

    async with _as(conn, w.invitee, w.invitee_personal):
        accepted = await svc.accept_invitation(InvitationRepository(conn), sent["token"])
    assert accepted["account_id"] == str(w.account) and accepted["active_account_id"] == str(w.account)
    assert accepted["roles"] == ["seller"]

    assert await conn.fetchval("SELECT active_account_id FROM public.profiles WHERE id = $1", w.invitee) == w.account
    # La personal se conserva: el invitado tiene DOS cuentas y la activa es el negocio.
    async with _as(conn, w.invitee, None):
        accounts = await conn.fetch("SELECT account_id, is_active FROM public.rpc_my_accounts()")
    assert {r["account_id"] for r in accounts} == {w.account, w.invitee_personal}
    assert [r["account_id"] for r in accounts if r["is_active"]] == [w.account]
