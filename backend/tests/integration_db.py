"""Fixture canónico de los tests de integración contra Postgres (v31-money-integration-tests, D4).

Un solo lugar para lo que los tests `@pytest.mark.integration` repetían:

* `DSN` — `DATABASE_URL` o el stack local de `supabase start`.
* `assert_local_dsn` — guardia de host. Los tests borran filas de `auth.users`;
  un `DATABASE_URL` exportado contra el pooler de producción sería un incidente.
* `connect()` — guardia + `asyncpg.connect` + skip legible si la base no está.
  Con `CI_REQUIRE_INTEGRATION=1` ese skip lo convierte en falla
  `backend/tests/integration_guard.py`.
* `set_claims()` — los dos `set_config(..., true)` que inyectan al usuario
  (`auth.uid()` en las RPCs `SECURITY DEFINER`). Hay que llamarlo dentro de
  `conn.transaction()`: el `true` los acota a la transacción.

Importar este módulo NO valida ni conecta: el job hermético (`-m "not
integration"`) lo importa al recolectar, y un raise a nivel de import rompería
la recolección entera.
"""
from __future__ import annotations

import json
import os
import re
from urllib.parse import parse_qs, urlsplit

import asyncpg
import pytest

DEFAULT_DSN = "postgresql://postgres:postgres@127.0.0.1:54322/postgres"
DSN = os.environ.get("DATABASE_URL", DEFAULT_DSN)

LOCAL_HOSTS = frozenset({"localhost", "127.0.0.1", "::1"})

_KV_PAIR = re.compile(r"(\w+)\s*=\s*('(?:[^'\\]|\\.)*'|\S+)")


class NonLocalDatabaseError(RuntimeError):
    """El DSN apunta a un host que no es el Postgres local."""


def _dsn_host(dsn: str) -> str | None:
    """Host efectivo de un DSN en forma URL o clave/valor (None si no lo nombra)."""
    text = dsn.strip()
    if "://" in text:
        parts = urlsplit(text)
        override = parse_qs(parts.query).get("host")
        host = override[0] if override else parts.hostname
        return host.lower() if host else None
    for key, value in _KV_PAIR.findall(text):
        if key == "host":
            return value.strip("'").lower()
    return None


def _redacted(dsn: str) -> str:
    return re.sub(r"(://[^:/@\s]*):[^@\s]*@", r"\1:***@", dsn.strip()) if "://" in dsn else re.sub(
        r"(password\s*=\s*)\S+", r"\1***", dsn.strip()
    )


def assert_local_dsn(dsn: str | None = None) -> str:
    """Devuelve el DSN si su host es `localhost`, `127.0.0.1` o `::1`; si no, lanza."""
    candidate = DSN if dsn is None else dsn
    host = _dsn_host(candidate)
    if host not in LOCAL_HOSTS:
        raise NonLocalDatabaseError(
            f"El DSN de integración apunta a {host or 'un host no declarado'!r}, que no es local "
            f"({', '.join(sorted(LOCAL_HOSTS))}): {_redacted(candidate)}. Estos tests borran filas "
            "de auth.users; levantá `supabase start` y usá el DATABASE_URL local."
        )
    return candidate


async def connect() -> asyncpg.Connection:
    """Conexión al Postgres local; se saltea (no da error) si no hay base."""
    dsn = assert_local_dsn()
    try:
        return await asyncpg.connect(dsn)
    except (OSError, asyncpg.PostgresError) as exc:
        pytest.skip(f"Postgres local no disponible ({type(exc).__name__}); levantá `supabase start`.")


async def set_claims(conn: asyncpg.Connection, user_id: object, extra: dict | None = None) -> None:
    """Inyecta al usuario como `auth.uid()` hasta el fin de la transacción en curso."""
    claims = {"sub": str(user_id), "role": "authenticated", **(extra or {})}
    await conn.execute("SELECT set_config('request.jwt.claims', $1, true)", json.dumps(claims))
    await conn.execute("SELECT set_config('request.jwt.claim.sub', $1, true)", str(user_id))


async def seed_account(conn: asyncpg.Connection, tag: str = "integ") -> tuple[object, object]:
    """Usuario sintético + su cuenta (la aprovisiona `handle_new_user`). Devuelve `(user_id, account_id)`."""
    import uuid

    user_id = uuid.uuid4()
    await conn.execute(
        """
        INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
        VALUES ($1, 'authenticated', 'authenticated', $2, now(), now(),
                jsonb_build_object('name', $3::text, 'phone', '', 'locality', '', 'province', ''))
        """,
        user_id,
        f"{tag}-{user_id}@test.local",
        f"Integración {tag}",
    )
    account_id = await conn.fetchval(
        "SELECT account_id FROM public.account_members WHERE user_id = $1 ORDER BY created_at LIMIT 1", user_id
    )
    assert account_id is not None, "SETUP: handle_new_user no creó la cuenta"
    return user_id, account_id


async def cleanup_account(
    conn: asyncpg.Connection,
    user_id: object,
    account_id: object,
    before: tuple[tuple[str, tuple], ...] = (),
) -> None:
    """Borra todo lo que cuelga de la cuenta sintética (residuo cero).

    `before`: sentencias `(sql, args)` que se ejecutan primero, con los triggers apagados, para las
    tablas que no llevan `account_id` propio (p. ej. `cash_sessions`, que cuelga de `cashboxes`).
    """
    await conn.execute("SET session_replication_role = replica")
    try:
        for sql, args in before:
            await conn.execute(sql, *args)
        tables = await conn.fetch(
            """
            SELECT c.table_name FROM information_schema.columns c
            JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
            WHERE c.table_schema = 'public' AND c.column_name = 'account_id'
              AND t.table_type = 'BASE TABLE' AND c.table_name <> 'accounts'
            """
        )
        for row in tables:
            await conn.execute(f'DELETE FROM public."{row["table_name"]}" WHERE account_id = $1', account_id)
        await conn.execute("DELETE FROM public.accounts WHERE id = $1", account_id)
    finally:
        await conn.execute("SET session_replication_role = DEFAULT")
    await conn.execute("DELETE FROM public.account_members WHERE user_id = $1", user_id)
    await conn.execute("DELETE FROM public.billing_events WHERE user_id = $1", user_id)
    await conn.execute("DELETE FROM public.email_logs WHERE user_id = $1", user_id)
    await conn.execute("DELETE FROM public.profiles WHERE id = $1", user_id)
    await conn.execute("DELETE FROM auth.users WHERE id = $1", user_id)
