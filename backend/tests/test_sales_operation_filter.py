"""fix clientes-historial-fecha-enlace — `GET /sales?operation_id=` (deep link
desde el historial de compras del cliente): filtro OPCIONAL por operación en
las tres capas. La operación se identifica igual que el historial del cliente
(`COALESCE(operation_id::text, id::text)`)."""
from __future__ import annotations

import uuid
from unittest.mock import AsyncMock

import pytest

from backend.repositories.sales_repository import SalesRepository
from backend.services import sales as sales_service

ACCOUNT = str(uuid.uuid4())
OP = str(uuid.uuid4())


@pytest.fixture
def repo_conn():
    conn = AsyncMock()
    conn.fetchval = AsyncMock(return_value=0)
    conn.fetch = AsyncMock(return_value=[])
    return SalesRepository(conn), conn


class TestRepositoryOperationFilter:
    @pytest.mark.asyncio
    async def test_filters_count_and_page_by_operation_key(self, repo_conn):
        repo, conn = repo_conn
        await repo.list_paginated_by_operation(ACCOUNT, 0, 25, operation_id=OP)

        count_sql, *count_args = conn.fetchval.call_args.args
        page_sql, *page_args = conn.fetch.call_args.args
        assert "COALESCE(operation_id::text, id::text) = $5::text" in count_sql
        assert OP in count_args
        assert "COALESCE(operation_id::text, id::text) = $7::text" in page_sql
        assert page_args[-1] == OP

    @pytest.mark.asyncio
    async def test_without_operation_id_binds_null(self, repo_conn):
        repo, conn = repo_conn
        await repo.list_paginated_by_operation(ACCOUNT, 0, 25)

        assert conn.fetchval.call_args.args[-1] is None
        assert conn.fetch.call_args.args[-1] is None


class TestServiceOperationFilter:
    @pytest.mark.asyncio
    async def test_forwards_operation_id_to_repository(self):
        repo = AsyncMock()
        repo.list_paginated_by_operation = AsyncMock(return_value=([], 0))

        await sales_service.list_sales_paginated(
            repo, ACCOUNT, 0, 25, None, None, None, OP,
        )

        assert repo.list_paginated_by_operation.call_args.kwargs["operation_id"] == OP
