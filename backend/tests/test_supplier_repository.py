"""v3-soft-delete-policy (5.3): SupplierRepository alineado al patrón de
maestros — lecturas con filtro RN-B1 y soft delete RN-B2 heredado.

`suppliers` no exponía borrado en el backend (no había repositorio); se crea
alineado al patrón único de maestros. Sin router/service: el módulo de compras
sigue hablando con Supabase directo — este repo es la superficie canónica para
cuando la API lo exponga.
"""
from __future__ import annotations

from unittest.mock import AsyncMock

import pytest

from backend.repositories.supplier_repository import SupplierRepository

SUPPLIER_ID = "44444444-4444-4444-4444-444444444444"
ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
USER_ID = "11111111-1111-1111-1111-111111111111"


@pytest.fixture
def mock_conn():
    conn = AsyncMock()
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchrow = AsyncMock(return_value=None)
    conn.execute = AsyncMock(return_value="UPDATE 1")
    return conn


@pytest.mark.asyncio
async def test_list_by_org_excludes_soft_deleted_by_default(mock_conn):
    repo = SupplierRepository(mock_conn)

    await repo.list_by_org(ACCOUNT_ID)

    sql = mock_conn.fetch.call_args.args[0]
    assert "FROM suppliers" in sql
    assert "deleted_at IS NULL" in sql
    assert mock_conn.fetch.call_args.args[1] == ACCOUNT_ID


@pytest.mark.asyncio
async def test_list_by_org_include_deleted_opt_in(mock_conn):
    """Spec RN-B1: un caso de uso (auditoría) puede pedir explícitamente las
    filas borradas — el filtro desaparece SOLO con el opt-in."""
    repo = SupplierRepository(mock_conn)

    await repo.list_by_org(ACCOUNT_ID, include_deleted=True)

    sql = mock_conn.fetch.call_args.args[0]
    assert "deleted_at IS NULL" not in sql


@pytest.mark.asyncio
async def test_get_by_id_excludes_soft_deleted(mock_conn):
    repo = SupplierRepository(mock_conn)

    await repo.get_by_id(SUPPLIER_ID, ACCOUNT_ID)

    sql = mock_conn.fetchrow.call_args.args[0]
    assert "FROM suppliers" in sql
    assert "deleted_at IS NULL" in sql
    assert mock_conn.fetchrow.call_args.args[1:] == (SUPPLIER_ID, ACCOUNT_ID)


@pytest.mark.asyncio
async def test_soft_delete_suppliers_allowed_and_marks_row(mock_conn):
    """"suppliers" está en la allowlist del BaseRepository — el soft delete
    centralizado emite el UPDATE con deleted_at/deleted_by."""
    repo = SupplierRepository(mock_conn)

    affected = await repo.soft_delete("suppliers", SUPPLIER_ID, ACCOUNT_ID, USER_ID)

    assert affected is True
    sql = mock_conn.execute.call_args.args[0]
    assert "UPDATE suppliers" in sql
    assert "deleted_at = now()" in sql
    assert "deleted_at IS NULL" in sql
