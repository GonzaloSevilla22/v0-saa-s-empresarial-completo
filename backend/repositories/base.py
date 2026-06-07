from __future__ import annotations

import asyncpg


class BaseRepository:
    """Base class for all data repositories.

    Invariant: the connection received here already has JWT-passthrough applied
    via `get_db_conn` — do NOT inject claims again in subclasses.

    Usage in a router endpoint:
        @router.get("/example")
        async def example(conn: asyncpg.Connection = Depends(get_db_conn)):
            repo = SalesRepository(conn)
            return await repo.fetch("SELECT * FROM sales")
    """

    def __init__(self, conn: asyncpg.Connection) -> None:
        self._conn = conn

    async def call_rpc(self, name: str, **params) -> asyncpg.Record:
        """Execute a stored procedure and return the first result row."""
        if params:
            param_placeholders = ", ".join(
                f"{k} => ${i + 1}" for i, k in enumerate(params)
            )
            query = f"SELECT * FROM {name}({param_placeholders})"
            return await self._conn.fetchrow(query, *params.values())
        return await self._conn.fetchrow(f"SELECT * FROM {name}()")

    async def fetch(self, query: str, *args) -> list[asyncpg.Record]:
        """Execute a query and return all matching rows."""
        return await self._conn.fetch(query, *args)

    async def fetchrow(self, query: str, *args) -> asyncpg.Record | None:
        """Execute a query and return a single row, or None if not found."""
        return await self._conn.fetchrow(query, *args)

    async def execute(self, query: str, *args) -> str:
        """Execute a statement and return the PostgreSQL status string."""
        return await self._conn.execute(query, *args)
