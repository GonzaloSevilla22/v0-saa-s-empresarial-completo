"""
factura-fiscal-imprimible — tenencia de `FiscalDocumentRepository.get_by_id`
contra el Postgres LOCAL real (stack de `supabase start`).

Marcado `@pytest.mark.integration`: excluido del gate de CI (`pytest
backend/tests -m "not integration"`); correr a mano con `-m integration` y el
stack local levantado. En CI la evidencia es el test de repositorio de
test_factura_fiscal_endpoint.py (asserta el SQL y los parámetros).

Corre como `postgres` A PROPÓSITO: con BYPASSRLS la RLS es inerte, así que lo
único que puede impedir que la cuenta B lea el comprobante de A es el filtro
explícito por `account_id` del SQL — exactamente lo que se quiere fijar (la
RLS es red, no guard único).
"""
from __future__ import annotations

import os
import uuid

import asyncpg
import pytest

from backend.repositories.fiscal_document_repository import FiscalDocumentRepository

DSN = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@127.0.0.1:54322/postgres")

pytestmark = pytest.mark.integration


async def _anchor(conn: asyncpg.Connection, label: str) -> tuple[uuid.UUID, uuid.UUID]:
    """Usuario sintético; handle_new_user le crea cuenta y sucursal."""
    user_id = uuid.uuid4()
    await conn.execute(
        """
        INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
        VALUES ($1, 'authenticated', 'authenticated', $2, now(), now(),
                jsonb_build_object('name', $3::text, 'phone', '', 'locality', '', 'province', ''))
        """,
        user_id, f"ffi-tenencia-{label}-{user_id}@test.local", f"Tenencia factura {label}",
    )
    account_id = await conn.fetchval(
        "SELECT account_id FROM public.account_members WHERE user_id = $1 ORDER BY created_at LIMIT 1", user_id,
    )
    assert account_id is not None, "SETUP: handle_new_user no creó la cuenta"
    return user_id, account_id


async def _authorized_doc(conn: asyncpg.Connection, account_id: uuid.UUID) -> uuid.UUID:
    fiscal_profile_id = await conn.fetchval(
        """
        INSERT INTO public.fiscal_profiles (account_id, cuit, iva_condition, ambiente, delegacion_autorizada)
        VALUES ($1, '20-12345678-6', 'monotributista', 'homologacion', true) RETURNING id
        """,
        account_id,
    )
    point_of_sale_id = await conn.fetchval(
        "INSERT INTO public.points_of_sale (fiscal_profile_id, account_id, numero, is_active) "
        "VALUES ($1, $2, 8065, true) RETURNING id",
        fiscal_profile_id, account_id,
    )
    await conn.execute(
        "INSERT INTO public.document_sequences (point_of_sale_id, comprobante_type, last_number) "
        "VALUES ($1, 'factura_c', 0)",
        point_of_sale_id,
    )
    # Un comprobante sólo NACE pending_cae y sin CAE (trigger
    # FISCAL_DOCUMENT_INSERT_SOLO_PENDING); lo autoriza la misma RPC del relay.
    doc_id = await conn.fetchval(
        """
        INSERT INTO public.fiscal_documents
          (account_id, fiscal_profile_id, point_of_sale_id, comprobante_type, punto_de_venta, number,
           total, status, attempts)
        VALUES ($1, $2, $3, 'factura_c', 8065, 1, 1000, 'pending_cae', 0)
        RETURNING id
        """,
        account_id, fiscal_profile_id, point_of_sale_id,
    )
    authorized = await conn.fetchval(
        "SELECT public.rpc_fiscal_document_authorize($1::uuid, $2, CURRENT_DATE + 10, 1::bigint, CURRENT_DATE)",
        doc_id, "71234567890123",
    )
    assert authorized is True, "SETUP: la RPC del relay no autorizó el comprobante"
    return doc_id


async def _cleanup(conn: asyncpg.Connection, anchors: list[tuple[uuid.UUID, uuid.UUID]]) -> None:
    """Bajo replica nada cascadea: se borra en toda tabla de public con
    account_id/user_id del fixture (y las cajas por sucursal)."""
    cols = await conn.fetch(
        """
        SELECT c.table_name, c.column_name
        FROM information_schema.columns c
        JOIN information_schema.tables t
          ON t.table_schema = c.table_schema AND t.table_name = c.table_name
        WHERE c.table_schema = 'public' AND t.table_type = 'BASE TABLE'
          AND c.column_name IN ('account_id', 'user_id')
        """
    )
    async with conn.transaction():
        await conn.execute("SET LOCAL session_replication_role = replica")
        for user_id, account_id in anchors:
            await conn.execute(
                "DELETE FROM public.cashboxes WHERE branch_id IN "
                "(SELECT id FROM public.branches WHERE account_id = $1)",
                account_id,
            )
            for row in cols:
                value = account_id if row["column_name"] == "account_id" else user_id
                table = row["table_name"]
                column = row["column_name"]
                await conn.execute(f'DELETE FROM public."{table}" WHERE "{column}" = $1', value)
            await conn.execute("DELETE FROM public.accounts WHERE id = $1", account_id)
            await conn.execute("DELETE FROM public.profiles WHERE id = $1", user_id)
            await conn.execute("DELETE FROM auth.users WHERE id = $1", user_id)


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


async def test_get_by_id_no_devuelve_el_comprobante_de_otra_cuenta(conn: asyncpg.Connection):
    anchor_a = await _anchor(conn, "a")
    anchor_b = await _anchor(conn, "b")
    try:
        doc_a = await _authorized_doc(conn, anchor_a[1])
        repo = FiscalDocumentRepository(conn)

        propio = await repo.get_by_id(str(doc_a), str(anchor_a[1]))
        ajeno = await repo.get_by_id(str(doc_a), str(anchor_b[1]))
        inexistente = await repo.get_by_id(str(uuid.uuid4()), str(anchor_a[1]))

        assert propio is not None
        assert propio["id"] == doc_a and propio["account_id"] == anchor_a[1]
        assert ajeno is None
        assert inexistente is None
    finally:
        await _cleanup(conn, [anchor_a, anchor_b])
    for user_id, account_id in (anchor_a, anchor_b):
        assert await conn.fetchval("SELECT count(*) FROM public.accounts WHERE id = $1", account_id) == 0
        assert await conn.fetchval("SELECT count(*) FROM auth.users WHERE id = $1", user_id) == 0
