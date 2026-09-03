from __future__ import annotations

import asyncpg

# v3-soft-delete-policy (RN-B2, D4): allowlist de maestros soft-deleteables
# con scope DIRECTO por account_id — anti-inyección de identificador: el nombre
# de tabla jamás viene del usuario, pero la interpolación en el SQL exige un
# set cerrado. `cashboxes` queda FUERA: su scope de cuenta es indirecto
# (branch_id → branches.account_id) y su soft delete vive en
# CashboxRepository.soft_delete_cashbox() (OQ2 del design).
# v3-catalog-masters: client_addresses tiene account_id DIRECTO (D2 del
# design) — igual familia que clients/products, se agrega a la allowlist.
# productos-categorias-sku (D3): product_categories entra a la enumeración de
# maestros de soft-delete-policy — account_id directo, misma política que
# cost_centers (la baja es desactivación o soft delete, nunca borrado físico
# de una fila referenciada: la FK de products.category_id es RESTRICT).
SOFT_DELETE_TABLES: frozenset[str] = frozenset(
    {
        "clients",
        "products",
        "suppliers",
        "cost_centers",
        "bank_accounts",
        "client_addresses",
        "product_categories",
    }
)


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

    async def fetch(self, query: str, *args) -> list[dict]:
        """Execute a query and return all matching rows as plain dicts.

        Pydantic v2 with from_attributes=True does not reliably access
        asyncpg.Record fields. Converting to dict guarantees correct
        response model serialization across all list endpoints.
        """
        records = await self._conn.fetch(query, *args)
        return [dict(r) for r in records]

    async def fetchrow(self, query: str, *args) -> asyncpg.Record | None:
        """Execute a query and return a single row, or None if not found."""
        return await self._conn.fetchrow(query, *args)

    async def execute(self, query: str, *args) -> str:
        """Execute a statement and return the PostgreSQL status string."""
        return await self._conn.execute(query, *args)

    # ── v3-api-standards §2 — paginación estándar centralizada ──────────────

    async def paginate(
        self,
        select_sql: str,
        count_sql: str,
        *args,
        page: int,
        size: int,
    ) -> dict:
        """Ejecuta un SELECT paginado + su COUNT y arma el envelope estándar.

        `select_sql`/`count_sql` deben aceptar los mismos `*args` posicionales
        de filtro (p. ej. `$1::uuid` para account_id); `select_sql` NO debe
        incluir su propio LIMIT/OFFSET — este helper les agrega
        `LIMIT $N OFFSET $N+1` con los siguientes placeholders posicionales
        después de `*args`.

        `page` es 0-based. Ambas queries corren sobre la misma conexión ya
        inyectada (JWT-passthrough) — no se abren conexiones nuevas ni se
        re-inyectan claims. Compatible con `not_deleted_clause()` (se
        concatena al WHERE de `select_sql`/`count_sql` antes de llamar acá).
        """
        offset = page * size
        limit_placeholder = len(args) + 1
        offset_placeholder = len(args) + 2
        paginated_sql = f"{select_sql} LIMIT ${limit_placeholder} OFFSET ${offset_placeholder}"

        total = await self._conn.fetchval(count_sql, *args) or 0
        rows = await self._conn.fetch(paginated_sql, *args, size, offset)
        items = [dict(r) for r in rows]
        pages = -(-total // size) if total > 0 else 0  # ceil division sin math.ceil

        return {"items": items, "total": total, "page": page, "pages": pages}

    # ── v3-soft-delete-policy (RN-B1 / RN-B2) ────────────────────────────────

    @staticmethod
    def not_deleted_clause(alias: str = "", *, include_deleted: bool = False) -> str:
        """RN-B1: fragmento de predicado que excluye filas soft-deleteadas.

        Se concatena a un WHERE existente (empieza con " AND "). Los repos de
        maestros lo usan en sus SELECT para no repetir el filtro a mano.
        `include_deleted=True` es el opt-in explícito (p. ej. auditoría) y
        devuelve cadena vacía — el default SIEMPRE excluye borrados.
        """
        if include_deleted:
            return ""
        prefix = f"{alias}." if alias else ""
        return f" AND {prefix}deleted_at IS NULL"

    async def soft_delete(
        self, table: str, row_id: str, account_id: str, deleted_by: str
    ) -> bool:
        """RN-B2: soft delete centralizado de un maestro.

        Setea deleted_at=now() + deleted_by, solo sobre filas vivas de la
        cuenta (el predicado `deleted_at IS NULL` hace el doble borrado un
        no-op). Retorna True si afectó una fila. Usa la conexión ya
        configurada (JWT-passthrough) — la RLS org-based sigue activa.

        `table` se valida contra SOFT_DELETE_TABLES (set cerrado de maestros
        con account_id directo) antes de interpolarse en el SQL.
        """
        if table not in SOFT_DELETE_TABLES:
            raise ValueError(
                f"Tabla no permitida para soft delete: {table!r} "
                f"(permitidas: {sorted(SOFT_DELETE_TABLES)})"
            )
        status = await self._conn.execute(
            f"UPDATE {table} SET deleted_at = now(), deleted_by = $3 "
            "WHERE id = $1 AND account_id = $2 AND deleted_at IS NULL",
            row_id,
            account_id,
            deleted_by,
        )
        # asyncpg devuelve "UPDATE <n>" para UPDATE.
        return int(status.rsplit(" ", 1)[-1]) > 0
