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


# ── compras-proveedor-cuenta-corriente (task 7.3): create/update/count_by_org ─


@pytest.mark.asyncio
async def test_count_by_org_excludes_soft_deleted(mock_conn):
    """D3: count_by_org existe como lectura útil, pero el service NUNCA la usa
    para pre-chequear el límite de plan (eso es exclusivo del trigger)."""
    mock_conn.fetchrow = AsyncMock(return_value={"total": 3})
    repo = SupplierRepository(mock_conn)

    total = await repo.count_by_org(ACCOUNT_ID)

    assert total == 3
    sql = mock_conn.fetchrow.call_args.args[0]
    assert "FROM suppliers" in sql
    assert "deleted_at IS NULL" in sql


@pytest.mark.asyncio
async def test_create_does_not_touch_legacy_company_id(mock_conn):
    """Fix post-apply (fase B, follow-up del orchestrator): suppliers.company_id
    dejó de ser NOT NULL en la migración (20261009000001, STEP 1) — el INSERT
    ya NO necesita resolverlo vía company_users/account_members. create() es
    ahora un mirror exacto de ClientRepository.create() (mismas 7 columnas,
    sin company_id ni subquery)."""
    repo = SupplierRepository(mock_conn)

    await repo.create(
        ACCOUNT_ID,
        {"name": "Distribuidora Sur", "tax_id": None, "iva_condition": None,
         "legal_name": None, "email": None, "phone": None},
    )

    sql = mock_conn.fetchrow.call_args.args[0]
    assert "INSERT INTO suppliers" in sql
    assert "company_users" not in sql
    assert "account_members" not in sql
    assert "company_id" not in sql
    args = mock_conn.fetchrow.call_args.args
    assert ACCOUNT_ID in args
    assert "Distribuidora Sur" in args


@pytest.mark.asyncio
async def test_create_persists_full_fiscal_identity(mock_conn):
    repo = SupplierRepository(mock_conn)

    await repo.create(
        ACCOUNT_ID,
        {
            "name": "Insumos del Este S.A.",
            "tax_id": "30-71234567-1",
            "iva_condition": "responsable_inscripto",
            "legal_name": "Insumos del Este Sociedad Anónima",
            "email": "compras@insumosdeleste.com",
            "phone": "+54 261 555-1111",
        },
    )

    args = mock_conn.fetchrow.call_args.args
    assert "30-71234567-1" in args
    assert "responsable_inscripto" in args
    assert "Insumos del Este Sociedad Anónima" in args


@pytest.mark.asyncio
async def test_update_only_sets_provided_fields(mock_conn):
    mock_conn.fetchrow = AsyncMock(return_value={"id": SUPPLIER_ID, "name": "Distribuidora Sur"})
    repo = SupplierRepository(mock_conn)

    await repo.update(SUPPLIER_ID, ACCOUNT_ID, {"phone": "+54 261 555-0000"})

    sql = mock_conn.fetchrow.call_args.args[0]
    assert "UPDATE suppliers" in sql
    assert "phone" in sql
    assert "name" not in sql.split("SET", 1)[1].split("WHERE", 1)[0]
    assert "deleted_at IS NULL" in sql


@pytest.mark.asyncio
async def test_update_with_no_fields_falls_back_to_get_by_id(mock_conn):
    """Espejo de ClientRepository.update: un payload vacío no emite ningún
    UPDATE, solo relee la fila vigente."""
    mock_conn.fetchrow = AsyncMock(return_value={"id": SUPPLIER_ID})
    repo = SupplierRepository(mock_conn)

    await repo.update(SUPPLIER_ID, ACCOUNT_ID, {})

    sql = mock_conn.fetchrow.call_args.args[0]
    assert "SELECT * FROM suppliers" in sql
    assert "UPDATE" not in sql
