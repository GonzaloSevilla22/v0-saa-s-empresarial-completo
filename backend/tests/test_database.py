import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

TEST_USER = {
    "user_id": "test-user-id",
    "role": "user",
    "account_role": None,
    "plan": "pro",
}


def _expected_request_claims(user: dict) -> str:
    return json.dumps({"sub": user["user_id"], "role": "authenticated"})


# ── v31-tenancy-pool-rls Paso 1 — grupo 2 ───────────────────────────────
#
# `get_db_conn` queda detrás de la palanca `settings.tenancy_tx_scope_enabled`
# (D8, apagada por defecto). Este archivo reemplaza el test que afirmaba
# literalmente el comportamiento defectuoso (`query.count(", false)") == 2`
# y la presencia de `app.jwt_claims`, GUC que design.md D2 confirma que NO
# lee nadie en todo el repositorio (migraciones, backend, frontend, edge
# functions — barrido de tasks.md 1.4). El test viejo protegía el bug en
# vez de detectarlo: se reemplaza en vez de borrarse en silencio (tasks.md
# 2.1).


@pytest.mark.asyncio
async def test_get_db_conn_step1_on_uses_transactional_scope(mock_pool):
    """RED→GREEN (2.1/2.2): con la palanca encendida, get_db_conn SHALL abrir
    una transacción explícita y setear `request.jwt.claims` con alcance
    TRANSACCIONAL (`set_config(..., true)`, D1) — NUNCA `app.jwt_claims`
    (D2: cero lectores)."""
    pool_mock, conn_mock = mock_pool

    import backend.core.database as db_module

    db_module.pool = pool_mock

    try:
        with patch("backend.core.database.settings") as mock_settings:
            mock_settings.tenancy_tx_scope_enabled = True
            mock_settings.tenancy_tx_idle_timeout = "30s"
            # v31-tenancy-pool-rls Paso 2 (grupo 7): explícito en False acá
            # — sin esto, el MagicMock de settings devuelve un atributo
            # auto-generado (truthy) para `tenancy_rls_role_enabled`, que
            # dispararía el SET LOCAL ROLE del grupo 7 y rompería el
            # `assert_awaited_once()` de abajo por una razón ajena a este
            # test (grupo 2, Paso 1 solo).
            mock_settings.tenancy_rls_role_enabled = False

            from backend.core.database import get_db_conn

            gen = get_db_conn(TEST_USER)
            conn = await gen.__anext__()

            # La transacción se abrió (D1) antes de yieldar la conexión.
            conn_mock.transaction.assert_called_once()
            transaction_ctx = conn_mock.transaction.return_value
            transaction_ctx.__aenter__.assert_awaited_once()

            conn_mock.execute.assert_awaited_once()
            query, request_claims, idle_timeout = conn_mock.execute.call_args[0]

            assert "app.jwt_claims" not in query, (
                "app.jwt_claims no debe inyectarse con la palanca encendida "
                "(design.md D2: cero lectores en todo el repositorio)"
            )
            assert "set_config('request.jwt.claims'" in query
            assert "idle_in_transaction_session_timeout" in query
            # Alcance TRANSACCIONAL: is_local=true (equivalente a SET LOCAL),
            # no alcance de sesión (false) — D1.
            assert query.count(", true)") == 2
            assert query.count(", false)") == 0
            assert request_claims == _expected_request_claims(TEST_USER)
            assert idle_timeout == "30s"
            assert conn is conn_mock

            # Cerrar el generador limpiamente (commit simulado, sin excepción).
            with pytest.raises(StopAsyncIteration):
                await gen.__anext__()
            transaction_ctx.__aexit__.assert_awaited_once()
            # __aexit__ recibido sin excepción == commit.
            assert transaction_ctx.__aexit__.await_args.args == (None, None, None)
    finally:
        db_module.pool = None


@pytest.mark.asyncio
async def test_get_db_conn_step1_off_matches_legacy_behavior_byte_for_byte(mock_pool):
    """GREEN (tasks.md 4.1): con la palanca apagada (default), el
    comportamiento es idéntico byte a byte al de antes de este change —
    incluido el GUC `app.jwt_claims` que nadie lee. Es el camino de
    rollback inmediato (D8): se retira recién en el change de limpieza
    posterior (tasks.md 9.7), NO acá."""
    pool_mock, conn_mock = mock_pool

    import backend.core.database as db_module

    db_module.pool = pool_mock

    try:
        with patch("backend.core.database.settings") as mock_settings:
            mock_settings.tenancy_tx_scope_enabled = False

            from backend.core.database import get_db_conn

            gen = get_db_conn(TEST_USER)
            conn = await gen.__anext__()

            # Camino legacy: SIN transacción explícita de request.
            conn_mock.transaction.assert_not_called()

            conn_mock.execute.assert_awaited_once()
            query, app_claims, request_claims = conn_mock.execute.call_args[0]
            assert "set_config('app.jwt_claims'" in query
            assert "set_config('request.jwt.claims'" in query
            # Alcance de SESIÓN (is_local=false) — comportamiento previo,
            # defectuoso, conservado sólo como palanca de apagado.
            assert query.count(", false)") == 2
            assert app_claims == json.dumps(TEST_USER)
            assert request_claims == _expected_request_claims(TEST_USER)
            assert conn is conn_mock
    finally:
        db_module.pool = None


@pytest.mark.asyncio
async def test_get_db_conn_step1_on_rollback_on_exception_no_writes_leak(mock_pool):
    """TRIANGULATE 2.3(a): un request que lanza una excepción produce
    ROLLBACK (la transacción externa recibe la excepción en __aexit__, no
    un commit limpio) y la excepción se re-propaga — FastAPI usa
    exactamente este mecanismo (AsyncExitStack.athrow) para limpiar
    dependencias `yield` cuando el handler falla."""
    pool_mock, conn_mock = mock_pool

    import backend.core.database as db_module

    db_module.pool = pool_mock

    try:
        with patch("backend.core.database.settings") as mock_settings:
            mock_settings.tenancy_tx_scope_enabled = True
            mock_settings.tenancy_tx_idle_timeout = "30s"
            mock_settings.tenancy_rls_role_enabled = False

            from backend.core.database import get_db_conn

            gen = get_db_conn(TEST_USER)
            await gen.__anext__()

            transaction_ctx = conn_mock.transaction.return_value

            class _BoomError(Exception):
                pass

            with pytest.raises(_BoomError):
                await gen.athrow(_BoomError("downstream failure"))

            transaction_ctx.__aexit__.assert_awaited_once()
            exc_type, exc, _tb = transaction_ctx.__aexit__.await_args.args
            assert exc_type is _BoomError, (
                "la transacción externa SHALL recibir la excepción (rollback), "
                "no un cierre limpio (commit) — design.md D1/D3"
            )
    finally:
        db_module.pool = None


@pytest.mark.asyncio
async def test_get_db_conn_step1_on_two_requests_do_not_share_claims(mock_pool):
    """TRIANGULATE 2.3(b): dos requests consecutivos que reutilizan la misma
    conexión mockeada (simulando reciclado de conexión física del pool) NO
    comparten claims — cada invocación de get_db_conn pasa los suyos
    propios como parámetro de la query, nunca un residuo del anterior."""
    pool_mock, conn_mock = mock_pool

    import backend.core.database as db_module

    db_module.pool = pool_mock

    try:
        with patch("backend.core.database.settings") as mock_settings:
            mock_settings.tenancy_tx_scope_enabled = True
            mock_settings.tenancy_tx_idle_timeout = "30s"
            mock_settings.tenancy_rls_role_enabled = False

            from backend.core.database import get_db_conn

            user_a = {"user_id": "user-aaaa", "role": "user", "account_role": None, "plan": "pro"}
            user_b = {"user_id": "user-bbbb", "role": "user", "account_role": None, "plan": "pro"}

            gen_a = get_db_conn(user_a)
            await gen_a.__anext__()
            with pytest.raises(StopAsyncIteration):
                await gen_a.__anext__()

            gen_b = get_db_conn(user_b)
            await gen_b.__anext__()
            with pytest.raises(StopAsyncIteration):
                await gen_b.__anext__()

            assert conn_mock.execute.await_count == 2
            first_call_claims = conn_mock.execute.await_args_list[0].args[1]
            second_call_claims = conn_mock.execute.await_args_list[1].args[1]

            assert first_call_claims == _expected_request_claims(user_a)
            assert second_call_claims == _expected_request_claims(user_b)
            assert first_call_claims != second_call_claims
    finally:
        db_module.pool = None


@pytest.mark.asyncio
async def test_get_db_conn_step1_on_set_config_between_transaction_open_and_yield(mock_pool):
    """TRIANGULATE 2.3(c): el orden es normativo, no incidental — la
    transacción se abre PRIMERO, `set_config` corre DESPUÉS (todavía dentro
    de la transacción) y ANTES de yieldar la conexión al caller."""
    pool_mock, conn_mock = mock_pool

    import backend.core.database as db_module

    db_module.pool = pool_mock

    call_order: list[str] = []
    transaction_ctx = conn_mock.transaction.return_value

    async def _record_enter(*_args, **_kwargs):
        call_order.append("transaction_enter")
        return None

    async def _record_execute(*_args, **_kwargs):
        call_order.append("execute")
        return "SET"

    transaction_ctx.__aenter__ = AsyncMock(side_effect=_record_enter)
    conn_mock.execute = AsyncMock(side_effect=_record_execute)

    try:
        with patch("backend.core.database.settings") as mock_settings:
            mock_settings.tenancy_tx_scope_enabled = True
            mock_settings.tenancy_tx_idle_timeout = "30s"
            mock_settings.tenancy_rls_role_enabled = False

            from backend.core.database import get_db_conn

            gen = get_db_conn(TEST_USER)
            await gen.__anext__()
            call_order.append("yielded")

            assert call_order == ["transaction_enter", "execute", "yielded"], (
                "orden esperado: abrir transacción -> set_config -> yield "
                f"(orden real: {call_order!r})"
            )
    finally:
        db_module.pool = None


@pytest.mark.asyncio
async def test_get_service_conn_has_no_request_transaction_or_claims(mock_pool):
    """RED/GREEN 2.4 (D5): `get_service_conn` es un camino de servicio
    explícitamente separado del de request — nunca abre la transacción del
    Paso 1 ni inyecta claims, sin importar la palanca. Lo usan el webhook de
    pagos y el relay CAE del cron; ambos son cross-account por diseño."""
    pool_mock, conn_mock = mock_pool

    import backend.core.database as db_module

    db_module.pool = pool_mock

    try:
        with patch("backend.core.database.settings") as mock_settings:
            mock_settings.tenancy_tx_scope_enabled = True
            mock_settings.tenancy_tx_idle_timeout = "30s"

            from backend.core.database import get_service_conn

            gen = get_service_conn()
            conn = await gen.__anext__()

            conn_mock.transaction.assert_not_called()
            conn_mock.execute.assert_not_called()
            assert conn is conn_mock
    finally:
        db_module.pool = None


# ── v31-tenancy-pool-rls Paso 2 — grupo 7 (D6) ──────────────────────────
#
# Detrás de `settings.tenancy_rls_role_enabled` (apagada por defecto,
# requiere `tenancy_tx_scope_enabled=True` — ver backend/core/config.py),
# `get_db_conn` adopta el rol `authenticated` con alcance TRANSACCIONAL
# (`SET LOCAL ROLE`, NUNCA `SET ROLE` de sesión) dentro de la MISMA
# transacción del Paso 1, inmediatamente después de inyectar los claims —
# mismo punto, no pueden divergir (D6). Estos tests son mocks: afirman la
# forma exacta del SQL emitido y su orden, que es lo que efectivamente causa
# el cambio de rol contra Postgres real. La prueba de que el aislamiento
# ES efectivo bajo RLS real (7.3c/7.4) corre contra Postgres real vía el
# gate SQL `supabase/tests/test_tenancy_rls_role.sql` (no hay Postgres real
# en esta suite, ver test_tenancy_tx_atomicity.py).


@pytest.mark.asyncio
async def test_get_db_conn_step2_on_adopts_authenticated_role(mock_pool):
    """RED (7.1) → GREEN (7.2): con AMBAS palancas encendidas, get_db_conn
    SHALL emitir, dentro de la transacción del request y ANTES de yieldar
    la conexión, un segundo statement que cambia el rol efectivo a
    `authenticated` — el rol con `rolbypassrls=false` (verificado en prod).
    Contra código sin el grupo 7, este test falla porque sólo hay UNA
    llamada a `execute` (la de claims/timeout del grupo 2): no existe
    ningún cambio de rol."""
    pool_mock, conn_mock = mock_pool
    # D6 bis: Postgres "sano" — la verificacion post-SET responde bien.
    conn_mock.fetchval = AsyncMock(return_value="authenticated")

    import backend.core.database as db_module

    db_module.pool = pool_mock

    try:
        with patch("backend.core.database.settings") as mock_settings:
            mock_settings.tenancy_tx_scope_enabled = True
            mock_settings.tenancy_tx_idle_timeout = "30s"
            mock_settings.tenancy_rls_role_enabled = True

            from backend.core.database import get_db_conn

            gen = get_db_conn(TEST_USER)
            conn = await gen.__anext__()

            transaction_ctx = conn_mock.transaction.return_value
            transaction_ctx.__aenter__.assert_awaited_once()

            assert conn_mock.execute.await_count == 2, (
                "con el Paso 2 encendido, get_db_conn SHALL emitir un "
                "segundo statement (cambio de rol) además del de "
                "claims/timeout del Paso 1"
            )
            claims_query = conn_mock.execute.await_args_list[0].args[0]
            role_query = conn_mock.execute.await_args_list[1].args[0]

            assert "request.jwt.claims" in claims_query
            assert "authenticated" in role_query
            assert "ROLE" in role_query.upper()

            with pytest.raises(StopAsyncIteration):
                await gen.__anext__()
            transaction_ctx.__aexit__.assert_awaited_once()
            assert conn is conn_mock
    finally:
        db_module.pool = None


@pytest.mark.asyncio
async def test_get_db_conn_step2_off_does_not_adopt_role_even_with_step1_on(mock_pool):
    """7.5 (combinación on/off): con el Paso 1 encendido y el Paso 2
    APAGADO (default), get_db_conn NO emite ningún cambio de rol — sigue
    corriendo como `postgres` (comportamiento actual). Guard de regresión
    explícito: separa "el Paso 1 solo" de "el Paso 1 + Paso 2", que es
    justo la combinación que el PO firmó mantener activa durante la ventana
    de observación (design.md, "probado bajo carga")."""
    pool_mock, conn_mock = mock_pool

    import backend.core.database as db_module

    db_module.pool = pool_mock

    try:
        with patch("backend.core.database.settings") as mock_settings:
            mock_settings.tenancy_tx_scope_enabled = True
            mock_settings.tenancy_tx_idle_timeout = "30s"
            mock_settings.tenancy_rls_role_enabled = False

            from backend.core.database import get_db_conn

            gen = get_db_conn(TEST_USER)
            await gen.__anext__()

            assert conn_mock.execute.await_count == 1, (
                "con el Paso 2 apagado, get_db_conn NO debe emitir ningún "
                "cambio de rol — sólo el statement de claims/timeout"
            )
            query = conn_mock.execute.await_args_list[0].args[0]
            assert "ROLE" not in query.upper()
    finally:
        db_module.pool = None


@pytest.mark.asyncio
async def test_get_db_conn_step2_role_statement_uses_set_local_not_session_scope(mock_pool):
    """GREEN (7.2), literal de D6: el statement de cambio de rol SHALL ser
    `SET LOCAL ROLE authenticated` — NUNCA `SET ROLE authenticated` a
    secas (scope de SESIÓN, el defecto original de C-17 que design.md D1
    corrige: sobrevive al fin de la transacción y puede filtrarse al
    siguiente cliente que reutilice la conexión física bajo Supavisor en
    transaction mode). La distinción LOCAL/sesión es la base técnica de
    todo el change (design.md, "La nota de C-17, corregida") — se afirma
    como texto literal, no sólo como intención, para que una regresión
    futura (alguien "simplifica" a `SET ROLE`) la rompa en el test."""
    pool_mock, conn_mock = mock_pool
    # D6 bis: Postgres "sano" — la verificacion post-SET responde bien.
    conn_mock.fetchval = AsyncMock(return_value="authenticated")

    import backend.core.database as db_module

    db_module.pool = pool_mock

    try:
        with patch("backend.core.database.settings") as mock_settings:
            mock_settings.tenancy_tx_scope_enabled = True
            mock_settings.tenancy_tx_idle_timeout = "30s"
            mock_settings.tenancy_rls_role_enabled = True

            from backend.core.database import get_db_conn

            gen = get_db_conn(TEST_USER)
            await gen.__anext__()

            role_query = conn_mock.execute.await_args_list[1].args[0]
            assert role_query.strip() == "SET LOCAL ROLE authenticated", (
                f"esperaba exactamente 'SET LOCAL ROLE authenticated', dio {role_query!r}"
            )
    finally:
        db_module.pool = None


@pytest.mark.asyncio
async def test_get_db_conn_step2_role_switch_happens_after_claims_before_yield(mock_pool):
    """TRIANGULATE (7.3, orden): el orden es normativo — transacción
    abierta -> set_config de claims/timeout -> SET LOCAL ROLE -> yield.
    El cambio de rol ocurre DESPUÉS de setear los claims (D6: mismo lugar,
    misma transacción, pero los claims se inyectan mientras la sesión
    todavía es `postgres` — sin restricción alguna sobre qué GUC puede
    setear — y el rol cambia recién antes de exponer la conexión al
    código de negocio, que es lo que efectivamente queda sujeto a RLS)."""
    pool_mock, conn_mock = mock_pool
    # D6 bis: Postgres "sano" — la verificacion post-SET responde bien.
    conn_mock.fetchval = AsyncMock(return_value="authenticated")

    import backend.core.database as db_module

    db_module.pool = pool_mock

    call_order: list[str] = []
    transaction_ctx = conn_mock.transaction.return_value

    async def _record_enter(*_args, **_kwargs):
        call_order.append("transaction_enter")
        return None

    async def _record_execute(query: str, *_args, **_kwargs):
        if "request.jwt.claims" in query:
            call_order.append("claims")
        elif "ROLE" in query.upper():
            call_order.append("role_switch")
        return "SET"

    transaction_ctx.__aenter__ = AsyncMock(side_effect=_record_enter)
    conn_mock.execute = AsyncMock(side_effect=_record_execute)

    try:
        with patch("backend.core.database.settings") as mock_settings:
            mock_settings.tenancy_tx_scope_enabled = True
            mock_settings.tenancy_tx_idle_timeout = "30s"
            mock_settings.tenancy_rls_role_enabled = True

            from backend.core.database import get_db_conn

            gen = get_db_conn(TEST_USER)
            await gen.__anext__()
            call_order.append("yielded")

            assert call_order == ["transaction_enter", "claims", "role_switch", "yielded"], (
                "orden esperado: abrir transacción -> claims -> cambio de "
                f"rol -> yield (orden real: {call_order!r})"
            )
    finally:
        db_module.pool = None


@pytest.mark.asyncio
async def test_get_db_conn_step2_on_two_requests_do_not_carry_over_role_state(mock_pool):
    """TRIANGULATE 7.3(a): dos requests consecutivos que reutilizan la misma
    conexión mockeada (simulando reciclado de conexión física del pool bajo
    Supavisor en transaction mode) emiten CADA UNO su propio `SET LOCAL
    ROLE authenticated` — no hay ningún estado que uno herede del anterior.
    La garantía de que el rol efectivamente NO persiste más allá del
    COMMIT/ROLLBACK es semántica de Postgres para `SET LOCAL` (no algo que
    un mock pueda demostrar por sí solo — design.md, "La nota de C-17,
    corregida"); este test triangula el lado observable: get_db_conn no
    cachea ni condiciona el segundo request a lo que pasó en el primero."""
    pool_mock, conn_mock = mock_pool
    # D6 bis: Postgres "sano" — la verificacion post-SET responde bien.
    conn_mock.fetchval = AsyncMock(return_value="authenticated")

    import backend.core.database as db_module

    db_module.pool = pool_mock

    try:
        with patch("backend.core.database.settings") as mock_settings:
            mock_settings.tenancy_tx_scope_enabled = True
            mock_settings.tenancy_tx_idle_timeout = "30s"
            mock_settings.tenancy_rls_role_enabled = True

            from backend.core.database import get_db_conn

            user_a = {"user_id": "user-aaaa", "role": "user", "account_role": None, "plan": "pro"}
            user_b = {"user_id": "user-bbbb", "role": "user", "account_role": None, "plan": "pro"}

            gen_a = get_db_conn(user_a)
            await gen_a.__anext__()
            with pytest.raises(StopAsyncIteration):
                await gen_a.__anext__()

            gen_b = get_db_conn(user_b)
            await gen_b.__anext__()
            with pytest.raises(StopAsyncIteration):
                await gen_b.__anext__()

            # 2 requests × 2 statements (claims + SET LOCAL ROLE) = 4.
            assert conn_mock.execute.await_count == 4, (
                "cada request SHALL emitir su propio SET LOCAL ROLE — no "
                "hay un estado de rol que se reutilice entre requests"
            )
            role_query_a = conn_mock.execute.await_args_list[1].args[0]
            role_query_b = conn_mock.execute.await_args_list[3].args[0]
            assert role_query_a.strip() == "SET LOCAL ROLE authenticated"
            assert role_query_b.strip() == "SET LOCAL ROLE authenticated"
            # La transacción se abrió y cerró una vez por request (2 veces
            # en total) — nunca queda una transacción "colgada" del
            # request anterior reutilizando la conexión mockeada.
            assert conn_mock.transaction.call_count == 2
    finally:
        db_module.pool = None


@pytest.mark.asyncio
async def test_get_service_conn_step2_never_adopts_role_even_with_both_flags_on(mock_pool):
    """TRIANGULATE 7.3(b): `get_service_conn` sigue sin adoptar el rol
    (ni abrir transacción, ni inyectar nada) aunque AMBAS palancas del
    Paso 1 y Paso 2 estén encendidas — D5: el camino de servicio (webhook
    de pagos, relay CAE del cron) es explícitamente distinto del de
    request y depende de seguir corriendo como `postgres` (BYPASSRLS)."""
    pool_mock, conn_mock = mock_pool

    import backend.core.database as db_module

    db_module.pool = pool_mock

    try:
        with patch("backend.core.database.settings") as mock_settings:
            mock_settings.tenancy_tx_scope_enabled = True
            mock_settings.tenancy_tx_idle_timeout = "30s"
            mock_settings.tenancy_rls_role_enabled = True

            from backend.core.database import get_service_conn

            gen = get_service_conn()
            conn = await gen.__anext__()

            conn_mock.transaction.assert_not_called()
            conn_mock.execute.assert_not_called()
            assert conn is conn_mock
    finally:
        db_module.pool = None


@pytest.mark.asyncio
async def test_get_db_conn_raises_when_pool_not_initialized():
    import backend.core.database as db_module

    db_module.pool = None

    from fastapi import HTTPException

    from backend.core.database import get_db_conn

    with pytest.raises(HTTPException) as exc_info:
        async for _ in get_db_conn(TEST_USER):
            pass

    assert exc_info.value.status_code == 503


@pytest.mark.asyncio
async def test_init_pool_raises_when_database_url_empty():
    with patch("backend.core.database.settings") as mock_settings:
        mock_settings.database_url = ""

        from backend.core.database import init_pool

        with pytest.raises(ValueError, match="DATABASE_URL"):
            await init_pool()


@pytest.mark.asyncio
async def test_init_pool_creates_pool_with_correct_params():
    with (
        patch("backend.core.database.settings") as mock_settings,
        patch("backend.core.database.asyncpg") as mock_asyncpg,
    ):
        mock_settings.database_url = "postgresql://user:pass@host/db"
        mock_asyncpg.create_pool = AsyncMock(return_value=MagicMock())

        import backend.core.database as db_module

        db_module.pool = None

        from backend.core.database import init_pool

        await init_pool()

        mock_asyncpg.create_pool.assert_called_once_with(
            "postgresql://user:pass@host/db",
            min_size=2,
            max_size=10,
            statement_cache_size=0,
        )

        db_module.pool = None


# ── v31-tenancy-pool-rls Paso 2 — verificación del cambio de rol (D6 bis) ──
#
# El "falla abierto" que design.md D6 nombra como riesgo: get_db_conn emite
# `SET LOCAL ROLE authenticated` pero hasta acá NADA verificaba que el rol
# efectivamente tomara. Si por lo que fuera no aplica (un pooler que rutea el
# statement a otra conexión física, una revocación de la membresía de rol de
# `postgres`, un statement tragado), la conexión se yieldaba igual — y el
# request corría como `postgres` (BYPASSRLS) creyendo estar bajo RLS, sin
# ninguna señal. Estos tests fijan el contrato inverso: después del SET LOCAL
# ROLE, get_db_conn SHALL leer `current_user` y, si no es `authenticated`,
# SHALL fallar CERRADO (503, sin yieldar la conexión) y loguear CRITICAL.
# Sólo aplica con AMBAS palancas encendidas; los caminos legacy y Paso-1-solo
# no pagan el round-trip extra ni cambian de forma.


@pytest.mark.asyncio
async def test_get_db_conn_step2_verifies_role_took_effect_before_yield(mock_pool):
    """RED→GREEN: con ambas palancas encendidas y el rol tomando bien
    (current_user = 'authenticated'), get_db_conn SHALL emitir la
    verificación DESPUÉS del SET LOCAL ROLE y ANTES de yieldar, y yieldar
    normalmente. Contra código sin la verificación este test falla porque
    fetchval nunca se llama."""
    pool_mock, conn_mock = mock_pool
    conn_mock.fetchval = AsyncMock(return_value="authenticated")

    import backend.core.database as db_module

    db_module.pool = pool_mock

    try:
        with patch("backend.core.database.settings") as mock_settings:
            mock_settings.tenancy_tx_scope_enabled = True
            mock_settings.tenancy_tx_idle_timeout = "30s"
            mock_settings.tenancy_rls_role_enabled = True

            from backend.core.database import get_db_conn

            gen = get_db_conn(TEST_USER)
            conn = await gen.__anext__()

            conn_mock.fetchval.assert_awaited_once()
            verify_query = conn_mock.fetchval.await_args.args[0]
            assert "current_user" in verify_query.lower(), (
                "la verificación SHALL leer current_user (el rol efectivo "
                f"post-SET), dio {verify_query!r}"
            )
            assert conn is conn_mock
    finally:
        db_module.pool = None


@pytest.mark.asyncio
async def test_get_db_conn_step2_fails_closed_when_role_did_not_take(mock_pool):
    """RED→GREEN (el caso que motiva todo): el SET LOCAL ROLE no tomó —
    current_user sigue siendo `postgres` (BYPASSRLS). get_db_conn SHALL
    levantar HTTPException 503 SIN yieldar la conexión: ningún código de
    negocio corre jamás sobre una conexión que dice estar bajo RLS y no lo
    está. Contra código sin la verificación este test falla porque la
    conexión se yielda igual."""
    pool_mock, conn_mock = mock_pool
    conn_mock.fetchval = AsyncMock(return_value="postgres")

    import backend.core.database as db_module
    from fastapi import HTTPException

    db_module.pool = pool_mock

    try:
        with patch("backend.core.database.settings") as mock_settings:
            mock_settings.tenancy_tx_scope_enabled = True
            mock_settings.tenancy_tx_idle_timeout = "30s"
            mock_settings.tenancy_rls_role_enabled = True

            from backend.core.database import get_db_conn

            gen = get_db_conn(TEST_USER)
            with pytest.raises(HTTPException) as exc_info:
                await gen.__anext__()

            assert exc_info.value.status_code == 503
            # Falla cerrado de verdad: el detalle no filtra el rol efectivo
            # ni ningún interno de la sesión.
            assert "postgres" not in str(exc_info.value.detail).lower()
    finally:
        db_module.pool = None


@pytest.mark.asyncio
async def test_get_db_conn_step2_fails_closed_when_role_check_returns_none(mock_pool):
    """TRIANGULATE: una respuesta imposible (None) tampoco pasa — el
    contrato es igualdad estricta con 'authenticated', no 'distinto de
    postgres'. Cubre el caso de un pooler/proxy que devuelva vacío."""
    pool_mock, conn_mock = mock_pool
    conn_mock.fetchval = AsyncMock(return_value=None)

    import backend.core.database as db_module
    from fastapi import HTTPException

    db_module.pool = pool_mock

    try:
        with patch("backend.core.database.settings") as mock_settings:
            mock_settings.tenancy_tx_scope_enabled = True
            mock_settings.tenancy_tx_idle_timeout = "30s"
            mock_settings.tenancy_rls_role_enabled = True

            from backend.core.database import get_db_conn

            gen = get_db_conn(TEST_USER)
            with pytest.raises(HTTPException) as exc_info:
                await gen.__anext__()

            assert exc_info.value.status_code == 503
    finally:
        db_module.pool = None


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("tx_scope", "rls_role"),
    [
        (False, False),  # legacy
        (True, False),  # Paso 1 solo
    ],
)
async def test_get_db_conn_role_check_absent_when_step2_off(mock_pool, tx_scope, rls_role):
    """TRIANGULATE: con el Paso 2 apagado NO hay verificación — el
    round-trip extra sólo existe donde existe el SET LOCAL ROLE que
    verifica. Los caminos legacy y Paso-1-solo quedan byte a byte como
    estaban."""
    pool_mock, conn_mock = mock_pool

    import backend.core.database as db_module

    db_module.pool = pool_mock

    try:
        with patch("backend.core.database.settings") as mock_settings:
            mock_settings.tenancy_tx_scope_enabled = tx_scope
            mock_settings.tenancy_tx_idle_timeout = "30s"
            mock_settings.tenancy_rls_role_enabled = rls_role

            from backend.core.database import get_db_conn

            gen = get_db_conn(TEST_USER)
            await gen.__anext__()

            conn_mock.fetchval.assert_not_awaited()
    finally:
        db_module.pool = None
