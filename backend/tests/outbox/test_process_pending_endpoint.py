"""tenancy-guard-caja-outbox h2 / h2 bis — disparador manual del outbox.

Cubre el grupo 5 de `openspec/changes/tenancy-guard-caja-outbox/tasks.md`
(5.1 RED, 5.5 / 5.6 TRIANGULATE), que salió como HOTFIX por decisión del PO
sobre la OQ-1 ("h2 sale como hotfix ahora, h1 después").

Qué se afirma acá:

  1. `POST /outbox/process-pending` exige **admin de plataforma**. Antes de
     este hotfix sólo exigía `get_current_user`: cualquier usuario logueado
     disparaba el relay. Combinado con el `GRANT` a `authenticated` de
     `rpc_process_outbox_batch` / `rpc_mark_event_processed`, era el botón
     que cerraba eventos de TODOS los tenants sin postear su asiento.
  2. El endpoint corre sobre `get_service_conn` (camino de servicio) y
     delega en `rpc_process_outbox_dispatch` — **el único despachador**, el
     que corre los 4 consumers antes de marcar `processed_at`. El relay
     Python (`OutboxRelayService`) corría 2 de 4 y marcaba igual: todo
     evento que le ganaba al pg_cron perdía su asiento contable y su
     notificación para siempre (D4).
  3. Candado del contrato del que depende D3 (OQ-6): `get_service_conn`
     **no adopta el rol de aplicación** ni siquiera con las DOS palancas de
     `v31-tenancy-pool-rls` encendidas. Sin este test, todo D3 —y con él la
     supervivencia del `REVOKE` al Paso 2 del pool— se apoyaba en un
     docstring.
"""
from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn, get_service_conn
from backend.repositories.outbox_repository import OutboxRepository


def _override_conns(app, conn) -> None:
    """Sirve el mismo mock por los dos caminos de conexión.

    Se overridean los DOS a propósito: antes del hotfix el router colgaba de
    `get_db_conn` y después cuelga de `get_service_conn`. Con los dos
    overrideados, el test RED falla por el motivo correcto (200 en vez de
    403), no por un 503 de "pool not initialized".
    """
    async def _yield_conn():
        yield conn

    app.dependency_overrides[get_db_conn] = _yield_conn
    app.dependency_overrides[get_service_conn] = _yield_conn


def _clear_conns(app) -> None:
    app.dependency_overrides.pop(get_db_conn, None)
    app.dependency_overrides.pop(get_service_conn, None)


# ── 5.1 RED: gating de admin de plataforma ───────────────────────────────────

class TestProcessPendingRequiresPlatformAdmin:
    """El disparador manual del outbox es de administración de plataforma."""

    @pytest.mark.asyncio
    async def test_non_admin_gets_403(self, async_client, valid_token):
        """5.1 RED: usuario logueado que NO es admin de plataforma → 403.

        Antes del hotfix este endpoint devolvía 200 para cualquier JWT
        válido. `profiles.role` es la fuente de verdad del rol de plataforma
        (el rol app-level no viaja en el JWT), igual que en
        `backend/routers/fiscal.py`.
        """
        from backend.main import app

        conn = AsyncMock()
        conn.fetchval = AsyncMock(return_value="user")  # profiles.role
        conn.fetch = AsyncMock(return_value=[])
        conn.execute = AsyncMock(return_value="UPDATE 0")
        _override_conns(app, conn)
        try:
            resp = await async_client.post(
                "/outbox/process-pending",
                headers={"Authorization": f"Bearer {valid_token}"},
            )
        finally:
            _clear_conns(app)

        assert resp.status_code == 403, (
            "el disparador manual del outbox recorre y cierra eventos de "
            f"TODOS los tenants: sin gating de admin es una fuga. Recibido: "
            f"{resp.status_code} {resp.text}"
        )

    @pytest.mark.asyncio
    async def test_non_admin_never_reaches_the_dispatcher(self, async_client, valid_token):
        """5.1 RED (efecto, no sólo status): con 403 el dispatcher NO corre.

        El status code solo no alcanza — lo que importa es que ningún evento
        se haya tocado. Se afirma que la única query emitida fue la de
        `require_platform_admin` (la lectura de `profiles.role`).
        """
        from backend.main import app

        conn = AsyncMock()
        conn.fetchval = AsyncMock(return_value="user")
        conn.fetch = AsyncMock(return_value=[])
        conn.execute = AsyncMock(return_value="UPDATE 0")
        _override_conns(app, conn)
        try:
            await async_client.post(
                "/outbox/process-pending",
                headers={"Authorization": f"Bearer {valid_token}"},
            )
        finally:
            _clear_conns(app)

        emitidas = (
            [c.args[0] for c in conn.fetchval.await_args_list]
            + [c.args[0] for c in conn.fetch.await_args_list]
            + [c.args[0] for c in conn.execute.await_args_list]
        )
        assert all("outbox" not in q.lower() for q in emitidas), (
            f"un no-admin no debe alcanzar ninguna RPC del outbox: {emitidas!r}"
        )
        assert all("events" not in q.lower() for q in emitidas), (
            f"un no-admin no debe tocar public.events: {emitidas!r}"
        )

    @pytest.mark.asyncio
    async def test_sin_token_401(self, async_client):
        """Sin JWT no hay endpoint: el gating de admin va DESPUÉS del de auth."""
        from backend.main import app

        conn = AsyncMock()
        conn.fetchval = AsyncMock(return_value="admin")
        _override_conns(app, conn)
        try:
            resp = await async_client.post("/outbox/process-pending")
        finally:
            _clear_conns(app)

        assert resp.status_code in (401, 403)
        conn.fetchval.assert_not_awaited()


# ── 5.5 TRIANGULATE: el admin dispara el ÚNICO despachador ───────────────────

class TestProcessPendingDispatchesViaSingleDispatcher:
    """El camino feliz corre `rpc_process_outbox_dispatch`, no el relay viejo."""

    @pytest.mark.asyncio
    async def test_admin_gets_200_con_processed(self, async_client, valid_token):
        """5.5: admin de plataforma → 200 y el cuerpo informa `processed`."""
        from backend.main import app

        conn = AsyncMock()
        # 1ª fetchval: profiles.role (require_platform_admin)
        # 2ª fetchval: rpc_process_outbox_dispatch → cantidad procesada
        conn.fetchval = AsyncMock(side_effect=["admin", 7])
        _override_conns(app, conn)
        try:
            resp = await async_client.post(
                "/outbox/process-pending",
                headers={"Authorization": f"Bearer {valid_token}"},
            )
        finally:
            _clear_conns(app)

        assert resp.status_code == 200, resp.text
        assert resp.json() == {"processed": 7}

    @pytest.mark.asyncio
    async def test_admin_llama_al_dispatcher_completo(self, async_client, valid_token):
        """5.5 / D4: la RPC invocada es `rpc_process_outbox_dispatch`.

        NO `rpc_process_outbox_batch` (2 de 4 consumers + marca igual) ni
        `rpc_mark_event_processed`: ésas quedan revocadas de `authenticated`
        por 20261012000001 y sin ningún caller de aplicación.
        """
        from backend.main import app

        conn = AsyncMock()
        conn.fetchval = AsyncMock(side_effect=["admin", 0])
        _override_conns(app, conn)
        try:
            await async_client.post(
                "/outbox/process-pending",
                headers={"Authorization": f"Bearer {valid_token}"},
            )
        finally:
            _clear_conns(app)

        sql = conn.fetchval.await_args_list[1].args[0]
        assert "rpc_process_outbox_dispatch" in sql, sql
        assert "rpc_process_outbox_batch" not in sql, sql
        assert "rpc_mark_event_processed" not in sql, sql

    @pytest.mark.asyncio
    async def test_el_relay_python_ya_no_existe(self):
        """D4: `OutboxRelayService` se retira, no se parchea.

        Admin-gatear un consumidor que suprime asientos deja el arma cargada
        del lado de adentro. Este assert impide que vuelva por un revert
        parcial o un merge descuidado.
        """
        with pytest.raises(ModuleNotFoundError):
            __import__("backend.services.outbox_relay_service")

    def test_el_router_no_importa_el_relay_retirado(self):
        """Espejo estático del anterior, legible en el diff del router.

        El docstring SÍ nombra al servicio retirado —a propósito, para
        explicar por qué no debe volver—, así que lo que se afirma es que no
        quedó ningún **import** ni referencia ejecutable: ni símbolo en el
        módulo, ni la cadena de 3 capas vieja en el código.
        """
        import inspect

        import backend.routers.outbox as router_mod

        assert not hasattr(router_mod, "OutboxRelayService")

        cuerpo = inspect.getsource(router_mod).replace(router_mod.__doc__ or "", "")
        assert "OutboxRelayService" not in cuerpo, (
            "el router todavía importa o instancia el relay retirado"
        )
        assert "outbox_relay_service" not in cuerpo


# ── 5.3 GREEN: OutboxRepository.run_dispatch ─────────────────────────────────

class TestRunDispatch:
    """La única puerta del repository al despachador."""

    @pytest.mark.asyncio
    async def test_run_dispatch_llama_a_la_rpc_del_dispatcher(self):
        conn = AsyncMock()
        conn.fetchval = AsyncMock(return_value=3)
        repo = OutboxRepository(conn)

        procesados = await repo.run_dispatch(50)

        conn.fetchval.assert_awaited_once()
        sql, arg = conn.fetchval.await_args.args[0], conn.fetchval.await_args.args[1]
        assert "rpc_process_outbox_dispatch" in sql
        assert arg == 50
        assert procesados == 3

    @pytest.mark.asyncio
    async def test_run_dispatch_batch_limit_por_defecto_100(self):
        """Mismo tamaño de lote que el pg_cron job (`SELECT ... dispatch(100)`)."""
        conn = AsyncMock()
        conn.fetchval = AsyncMock(return_value=0)
        repo = OutboxRepository(conn)

        await repo.run_dispatch()

        assert conn.fetchval.await_args.args[1] == 100

    @pytest.mark.asyncio
    async def test_run_dispatch_normaliza_none_a_cero(self):
        """`fetchval` puede devolver None si la RPC no retorna fila.

        El contrato del endpoint es un entero: nunca `{"processed": null}`.
        """
        conn = AsyncMock()
        conn.fetchval = AsyncMock(return_value=None)
        repo = OutboxRepository(conn)

        assert await repo.run_dispatch() == 0

    @pytest.mark.parametrize(
        "metodo",
        [
            "fetch_pending_batch",
            "mark_processed",
            "insert_audit_log",
            "insert_email_log",
            "claim_idempotency",
        ],
    )
    def test_metodos_del_relay_retirado_no_existen(self, metodo):
        """D4: los 5 métodos del relay Python se retiran con el servicio.

        Eran la segunda implementación —incompleta— de los consumers 1 y 2 y
        el mecanismo concreto de la supresión de asientos.
        """
        assert not hasattr(OutboxRepository, metodo)

    def test_emit_event_se_conserva(self):
        """`emit_event` NO se retira: es un productor (DEC-20).

        Lo usan `purchase_repository.py` y `stock_repository.py` dentro de la
        misma transacción que la mutación.
        """
        assert hasattr(OutboxRepository, "emit_event")


# ── 5.6 TRIANGULATE: candado del contrato de `get_service_conn` (D3 / OQ-6) ──

class TestServiceConnNoAdoptaRolDeAplicacion:
    """Todo D3 se apoya en este contrato; acá deja de ser un docstring."""

    @pytest.mark.asyncio
    async def test_no_adopta_authenticated_con_las_dos_palancas_encendidas(
        self, mock_pool
    ):
        """OQ-6: con `TENANCY_TX_SCOPE_ENABLED` **y**
        `TENANCY_RLS_ROLE_ENABLED` encendidas, `get_service_conn` no emite
        `SET ROLE`, no abre transacción de request y no inyecta claims.

        Es la pieza que hace que el `REVOKE` de las dos RPCs del outbox
        sobreviva al Paso 2 del pool: si el camino de servicio adoptara
        `authenticated`, el disparador manual se rompería el día que se
        encienda la palanca.
        """
        pool_mock, conn_mock = mock_pool

        import backend.core.database as db_module

        db_module.pool = pool_mock
        try:
            with patch("backend.core.database.settings") as mock_settings:
                mock_settings.tenancy_tx_scope_enabled = True
                mock_settings.tenancy_rls_role_enabled = True
                mock_settings.tenancy_tx_idle_timeout = "30s"

                from backend.core.database import get_service_conn

                gen = get_service_conn()
                conn = await gen.__anext__()

                conn_mock.transaction.assert_not_called()
                sentencias = [c.args[0] for c in conn_mock.execute.await_args_list]
                assert sentencias == [], (
                    "el camino de servicio no debe emitir NINGUNA sentencia de "
                    f"sesión (ni SET ROLE ni claims). Emitidas: {sentencias!r}"
                )
                assert conn is conn_mock
        finally:
            db_module.pool = None

    @pytest.mark.asyncio
    async def test_el_endpoint_cuelga_del_camino_de_servicio(self):
        """El router declara `get_service_conn`, no `get_db_conn`.

        Con `get_db_conn` el endpoint quedaría sujeto al rol `authenticated`
        bajo el Paso 2 y volvería a depender del ACL que este hotfix revoca.
        """
        import inspect

        from backend.routers import outbox as outbox_router

        fuente = inspect.getsource(outbox_router)
        assert "get_service_conn" in fuente
        assert "get_db_conn" not in fuente


# ── Documentación viva: el docstring del router dejó de mentir ───────────────

def test_docstring_del_router_corregido():
    """El docstring afirmaba "Called by the pg_cron job relay-process-outbox".

    El pg_cron llama a `SELECT public.rpc_process_outbox_dispatch(100)` desde
    el pivot de C-25 — nunca a este endpoint. Un docstring desactualizado en
    un camino de seguridad es cómo se justifica no gatearlo.
    """
    import backend.routers.outbox as router_mod

    doc = (router_mod.__doc__ or "") + (
        router_mod.process_pending_outbox.__doc__ or ""
    )
    assert "pg_cron" in doc, "el docstring debe explicar la relación real con el cron"
    assert "Called by the pg_cron job relay-process-outbox" not in doc
    assert "rpc_process_outbox_dispatch" in doc
