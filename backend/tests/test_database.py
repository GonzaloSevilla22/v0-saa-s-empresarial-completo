import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

TEST_USER = {"user_id": "test-user-id", "role": "authenticated"}


@pytest.mark.asyncio
async def test_get_db_conn_injects_jwt_claims(mock_pool):
    pool_mock, conn_mock = mock_pool

    import backend.core.database as db_module

    db_module.pool = pool_mock

    try:
        from backend.core.database import get_db_conn

        gen = get_db_conn(TEST_USER)
        conn = await gen.__anext__()

        conn_mock.execute.assert_called_once()
        query, app_claims, request_claims = conn_mock.execute.call_args[0]
        # Ambos configs en un solo round-trip, session-scoped (is_local=false)
        assert "set_config('app.jwt_claims'" in query
        assert "set_config('request.jwt.claims'" in query
        assert query.count(", false)") == 2
        assert app_claims == json.dumps(TEST_USER)
        assert request_claims == json.dumps(
            {"sub": TEST_USER["user_id"], "role": "authenticated"}
        )
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
