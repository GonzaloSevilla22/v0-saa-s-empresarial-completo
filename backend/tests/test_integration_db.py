"""v31-money-integration-tests (task 1.1) — el fixture canónico de integración.

Hermético: no abre ningún socket. Fija la guardia de host de
`backend/tests/integration_db.py`: los tests de integración borran filas de
`auth.users`, así que un `DATABASE_URL` exportado contra el pooler de producción
tendría que ser rechazado ANTES de abrir una conexión.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

from backend.tests import integration_db
from backend.tests.integration_db import NonLocalDatabaseError, assert_local_dsn


@pytest.mark.parametrize(
    "dsn",
    [
        "postgresql://postgres:postgres@127.0.0.1:54322/postgres",
        "postgresql://postgres:postgres@localhost:5432/postgres",
        "postgresql://postgres:postgres@[::1]:54322/postgres",
        "postgres://u@LOCALHOST/db",
        "host=127.0.0.1 port=54322 dbname=postgres user=postgres",
        "postgresql:///postgres?host=localhost",
    ],
)
def test_assert_local_dsn_accepts_loopback_hosts(dsn: str):
    assert assert_local_dsn(dsn) == dsn


@pytest.mark.parametrize(
    "dsn",
    [
        "postgresql://postgres:secret@db.gxdhpxvdjjkmxhdkkwyb.supabase.co:5432/postgres",
        "postgresql://postgres.abc:secret@aws-0-sa-east-1.pooler.supabase.com:6543/postgres",
        "postgresql://postgres:secret@10.0.0.5:5432/postgres",
        # El `host=` de una cadena clave/valor es el que manda, no el resto del texto.
        "host=db.example.com port=5432 dbname=postgres user=postgres",
        "dbname=postgres host=prod.example.com options='-c x=localhost'",
        # Un host remoto camuflado: loopback en el userinfo, remoto de verdad.
        "postgresql://127.0.0.1@evil.example.com:5432/postgres",
        # Ni siquiera nombra host: no es verificable, se rechaza.
        "postgresql:///postgres",
        "",
    ],
)
def test_assert_local_dsn_rejects_non_local_hosts(dsn: str):
    with pytest.raises(NonLocalDatabaseError):
        assert_local_dsn(dsn)


def test_rejection_message_does_not_leak_the_password():
    with pytest.raises(NonLocalDatabaseError) as info:
        assert_local_dsn("postgresql://postgres:s3cr3tpass@db.example.com:5432/postgres")
    assert "s3cr3tpass" not in str(info.value)
    assert "db.example.com" in str(info.value)


def _fresh_import():
    """Importa una copia nueva del módulo (sin tocar sys.modules ni el paquete)."""
    path = Path(integration_db.__file__)
    spec = importlib.util.spec_from_file_location("_integration_db_fresh", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_importing_with_a_remote_database_url_does_not_raise(monkeypatch: pytest.MonkeyPatch):
    # El job hermético importa estos módulos al recolectar (la deselección por
    # `-m` ocurre después): un raise a nivel de import lo rompería.
    monkeypatch.setenv("DATABASE_URL", "postgresql://postgres:x@db.example.com:5432/postgres")
    mod = _fresh_import()
    assert mod.DSN.endswith("db.example.com:5432/postgres")


def test_default_dsn_is_the_local_supabase_stack(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.delenv("DATABASE_URL", raising=False)
    mod = _fresh_import()
    assert mod.DSN == "postgresql://postgres:postgres@127.0.0.1:54322/postgres"


async def test_connect_refuses_a_remote_dsn_before_opening_a_socket(monkeypatch: pytest.MonkeyPatch):
    def _boom(*_a, **_k):  # pragma: no cover - sólo si la guardia falla
        raise AssertionError("asyncpg.connect no debe llamarse con un host remoto")

    monkeypatch.setattr(integration_db, "DSN", "postgresql://u:p@db.example.com:5432/postgres")
    monkeypatch.setattr(integration_db.asyncpg, "connect", _boom)
    with pytest.raises(NonLocalDatabaseError):
        await integration_db.connect()


async def test_connect_skips_when_postgres_is_not_reachable(monkeypatch: pytest.MonkeyPatch):
    async def _refused(*_a, **_k):
        raise ConnectionRefusedError()

    monkeypatch.setattr(integration_db, "DSN", "postgresql://u:p@127.0.0.1:1/postgres")
    monkeypatch.setattr(integration_db.asyncpg, "connect", _refused)
    with pytest.raises(pytest.skip.Exception) as info:
        await integration_db.connect()
    assert "Postgres local no disponible" in str(info.value)
    assert "supabase start" in str(info.value)


async def test_connect_skips_when_postgres_is_starting_up(monkeypatch: pytest.MonkeyPatch):
    async def _starting(*_a, **_k):
        raise integration_db.asyncpg.CannotConnectNowError("the database system is starting up")

    monkeypatch.setattr(integration_db, "DSN", "postgresql://u:p@127.0.0.1:54322/postgres")
    monkeypatch.setattr(integration_db.asyncpg, "connect", _starting)
    with pytest.raises(pytest.skip.Exception, match="Postgres local no disponible"):
        await integration_db.connect()


async def test_connect_returns_the_connection_when_reachable(monkeypatch: pytest.MonkeyPatch):
    sentinel = object()

    async def _ok(dsn, *_a, **_k):
        assert dsn == "postgresql://u:p@127.0.0.1:5432/postgres"
        return sentinel

    monkeypatch.setattr(integration_db, "DSN", "postgresql://u:p@127.0.0.1:5432/postgres")
    monkeypatch.setattr(integration_db.asyncpg, "connect", _ok)
    assert await integration_db.connect() is sentinel


class _FakeConn:
    def __init__(self) -> None:
        self.calls: list[tuple[str, tuple]] = []

    async def execute(self, sql: str, *args):
        self.calls.append((sql, args))


async def test_set_claims_sets_both_transaction_local_settings():
    import json

    conn = _FakeConn()
    await integration_db.set_claims(conn, "user-1")  # type: ignore[arg-type]
    sqls = [c[0] for c in conn.calls]
    assert any("request.jwt.claims" in s and ", true)" in s for s in sqls)
    assert any("request.jwt.claim.sub" in s and ", true)" in s for s in sqls)
    claims = json.loads(conn.calls[0][1][0])
    assert claims == {"sub": "user-1", "role": "authenticated"}
    assert conn.calls[1][1] == ("user-1",)


async def test_set_claims_merges_extra_claims():
    import json

    conn = _FakeConn()
    await integration_db.set_claims(conn, "u2", {"account_id": "acc-1", "role": "service"})  # type: ignore[arg-type]
    claims = json.loads(conn.calls[0][1][0])
    assert claims == {"sub": "u2", "role": "service", "account_id": "acc-1"}
