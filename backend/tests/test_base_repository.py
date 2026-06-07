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
    row1 = MagicMock()
    row2 = MagicMock()
    mock_conn.fetch = AsyncMock(return_value=[row1, row2])

    repo = BaseRepository(mock_conn)
    result = await repo.fetch("SELECT * FROM sales")
    assert len(result) == 2
    assert result[0] is row1
    assert result[1] is row2


@pytest.mark.asyncio
async def test_fetchrow_returns_record_when_found(mock_conn):
    row = MagicMock()
    mock_conn.fetchrow = AsyncMock(return_value=row)

    repo = BaseRepository(mock_conn)
    result = await repo.fetchrow("SELECT * FROM products WHERE id = $1", "prod-1")
    assert result is row
