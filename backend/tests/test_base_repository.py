from unittest.mock import AsyncMock, MagicMock

import pytest

from backend.repositories.base import BaseRepository


@pytest.fixture
def mock_conn():
    conn = AsyncMock()
    conn.fetch = AsyncMock(return_value=[])
    conn.fetchrow = AsyncMock(return_value=None)
    conn.execute = AsyncMock(return_value="UPDATE 1")
    return conn


@pytest.mark.asyncio
async def test_fetch_returns_empty_list_when_no_results(mock_conn):
    repo = BaseRepository(mock_conn)
    result = await repo.fetch("SELECT * FROM products WHERE org_id = $1", "org-123")
    assert result == []
    mock_conn.fetch.assert_called_once_with(
        "SELECT * FROM products WHERE org_id = $1", "org-123"
    )


@pytest.mark.asyncio
async def test_fetchrow_returns_none_when_not_found(mock_conn):
    repo = BaseRepository(mock_conn)
    result = await repo.fetchrow("SELECT * FROM products WHERE id = $1", "nonexistent")
    assert result is None
    mock_conn.fetchrow.assert_called_once_with(
        "SELECT * FROM products WHERE id = $1", "nonexistent"
    )


@pytest.mark.asyncio
async def test_execute_returns_status_string(mock_conn):
    repo = BaseRepository(mock_conn)
    result = await repo.execute("UPDATE products SET stock = $1 WHERE id = $2", 0, "prod-1")
    assert result == "UPDATE 1"
    mock_conn.execute.assert_called_once_with(
        "UPDATE products SET stock = $1 WHERE id = $2", 0, "prod-1"
    )


@pytest.mark.asyncio
async def test_call_rpc_executes_correct_query(mock_conn):
    row = MagicMock()
    mock_conn.fetchrow = AsyncMock(return_value=row)
    repo = BaseRepository(mock_conn)

    result = await repo.call_rpc("rpc_get_sales_summary", p_user_id="uid-1", p_period="month")

    assert result is row
    call_args = mock_conn.fetchrow.call_args
    query = call_args[0][0]
    assert "rpc_get_sales_summary" in query
    assert "p_user_id => $1" in query
    assert "p_period => $2" in query


@pytest.mark.asyncio
async def test_fetch_returns_rows_when_results_exist(mock_conn):
    row1 = {"id": "sale-1", "total": 100}
    row2 = {"id": "sale-2", "total": 250}
    mock_conn.fetch = AsyncMock(return_value=[row1, row2])

    repo = BaseRepository(mock_conn)
    result = await repo.fetch("SELECT * FROM sales")
    assert len(result) == 2
    # fetch convierte cada Record a dict plano (serialización Pydantic v2)
    assert all(type(r) is dict for r in result)
    assert result[0] == row1
    assert result[1] == row2


@pytest.mark.asyncio
async def test_fetchrow_returns_record_when_found(mock_conn):
    row = MagicMock()
    mock_conn.fetchrow = AsyncMock(return_value=row)

    repo = BaseRepository(mock_conn)
    result = await repo.fetchrow("SELECT * FROM products WHERE id = $1", "prod-1")
    assert result is row


# ── v3-soft-delete-policy: soft_delete() centralizado (RN-B2, D4) ────────────

CLIENT_ID = "33333333-3333-3333-3333-333333333333"
ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
USER_ID = "11111111-1111-1111-1111-111111111111"


@pytest.mark.asyncio
async def test_soft_delete_marks_row(mock_conn):
    """4.1 RED: soft_delete emite UPDATE con deleted_at=now(), deleted_by y
    el predicado anti-doble-borrado, y reporta la fila afectada."""
    mock_conn.execute = AsyncMock(return_value="UPDATE 1")
    repo = BaseRepository(mock_conn)

    affected = await repo.soft_delete("clients", CLIENT_ID, ACCOUNT_ID, USER_ID)

    assert affected is True
    sql = mock_conn.execute.call_args.args[0]
    assert "UPDATE clients" in sql
    assert "deleted_at = now()" in sql
    assert "deleted_by = $3" in sql
    assert "WHERE id = $1 AND account_id = $2 AND deleted_at IS NULL" in sql
    assert mock_conn.execute.call_args.args[1:] == (CLIENT_ID, ACCOUNT_ID, USER_ID)


@pytest.mark.asyncio
async def test_soft_delete_already_deleted_is_noop(mock_conn):
    """4.3 TRIANGULATE: fila ya borrada → el predicado deleted_at IS NULL la
    excluye → 0 filas afectadas → False."""
    mock_conn.execute = AsyncMock(return_value="UPDATE 0")
    repo = BaseRepository(mock_conn)

    affected = await repo.soft_delete("clients", CLIENT_ID, ACCOUNT_ID, USER_ID)

    assert affected is False


@pytest.mark.asyncio
async def test_soft_delete_wrong_account_noop(mock_conn):
    """4.3 TRIANGULATE: aislamiento por cuenta — el account_id ajeno viaja en
    el WHERE y la DB no afecta filas → False."""
    mock_conn.execute = AsyncMock(return_value="UPDATE 0")
    repo = BaseRepository(mock_conn)
    other_account = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    affected = await repo.soft_delete("clients", CLIENT_ID, other_account, USER_ID)

    assert affected is False
    assert mock_conn.execute.call_args.args[2] == other_account


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "bad_table",
    [
        "sales",  # documento, no maestro
        "cashboxes",  # scope indirecto por branch_id — usa CashboxRepository (OQ2)
        "clients; DROP TABLE clients--",  # inyección de identificador
        "",
    ],
)
async def test_soft_delete_rejects_table_outside_allowlist(mock_conn, bad_table):
    """4.2: allowlist anti-inyección — tablas fuera del set de maestros
    con account_id directo levantan ValueError sin tocar la conexión."""
    repo = BaseRepository(mock_conn)

    with pytest.raises(ValueError):
        await repo.soft_delete(bad_table, CLIENT_ID, ACCOUNT_ID, USER_ID)

    mock_conn.execute.assert_not_awaited()


# ── v3-soft-delete-policy: filtro de lectura RN-B1 (4.4) ─────────────────────


def test_not_deleted_clause_default_excludes_deleted():
    """4.4: por defecto el helper produce el predicado que excluye borrados."""
    assert BaseRepository.not_deleted_clause() == " AND deleted_at IS NULL"


def test_not_deleted_clause_include_deleted_returns_empty():
    """4.4: opt-in explícito para auditoría — incluye borrados (sin filtro)."""
    assert BaseRepository.not_deleted_clause(include_deleted=True) == ""


def test_not_deleted_clause_with_alias_prefixes_column():
    """4.4 TRIANGULATE: con alias de tabla el predicado se califica."""
    assert BaseRepository.not_deleted_clause("p") == " AND p.deleted_at IS NULL"
