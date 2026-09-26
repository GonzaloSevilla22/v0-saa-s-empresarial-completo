"""ventas-unidades-conversion — hallazgo BE-1 de la revisión del PR #584 (D-C).

`PUT /products/{id}` hace escribible `base_unit_id`. Sin guard, cambiar la
unidad de un producto que YA tiene stock o historial reinterpreta en silencio
todas sus cantidades: "12 u" pasa a leerse "12 kg". Decisión provisoria
(opción (a) de la decisión 6 del PO, pendiente de sign-off):

  (a) ASIGNAR una unidad a un producto que no tenía        → permitido, aunque tenga stock,
      SALVO que su stock/historia estén grabados con OTRA unidad explícita
      (cuarta revisión del PR #584: historia en kg + base 'g' dejaba el stock
      1000 veces menor; historia en 'u' + base 'kg' lo leía en kilos) → 409
  (b) CAMBIAR la unidad con stock ≠ 0 en alguna sucursal   → 409 `base_unit_locked`
  (c) CAMBIAR la unidad con stock 0 pero con movimientos   → 409 `base_unit_locked`
  (d) CAMBIAR la unidad sin stock ni movimientos           → permitido
  (e) mandar la MISMA unidad que ya tiene                  → permitido (no es un cambio)
  (f) DESASIGNAR (null) una unidad con stock               → 409 (también es un cambio)

Los tests mockean asyncpg como el resto de la suite: el repositorio consulta
stock y movimientos por separado, así que cada caso ejercita un camino
distinto del guard.
"""
from __future__ import annotations

from unittest.mock import AsyncMock, patch

from backend.repositories.product_repository import ProductRepository
from backend.tests.conftest import TEST_ACCOUNT_ID, make_token

UNIT_UN = "0b0b0b0b-0b0b-4b0b-8b0b-0b0b0b0b0b0b"
UNIT_KG = "0a0a0a0a-0a0a-4a0a-8a0a-0a0a0a0a0a0a"
PRODUCT_ID = "22222222-2222-2222-2222-222222222222"


def _product_row(base_unit_id: str | None) -> dict:
    return {
        "id": PRODUCT_ID,
        "user_id": "11111111-1111-1111-1111-111111111111",
        "account_id": str(TEST_ACCOUNT_ID),
        "name": "Tomate",
        "category": None,
        "category_id": None,
        "price": "1000.0000",
        "cost": "600.0000",
        "stock": "12.0000",
        "min_stock": "0.0000",
        "barcode": None,
        "sku": None,
        "parent_id": None,
        "is_variant": False,
        "stock_control_type": "tracked",
        "created_at": "2024-01-01T08:00:00",
        "base_unit_id": base_unit_id,
    }


def _wire(
    conn,
    *,
    current_base: str | None,
    has_stock: bool,
    has_movements: bool,
    has_other_unit_lines: bool = False,
):
    """Arma el conn falso: la fila actual del producto, el guard de tenencia de
    la unidad siempre OK, y las consultas del guard por separado (stock,
    movimientos y — cuarta revisión — líneas grabadas en otra unidad, que
    quedan en `conn.lines_checks`). Devuelve las listas donde quedan
    registradas las consultas y los UPDATE."""
    stock_checks: list[tuple] = []
    movement_checks: list[tuple] = []
    lines_checks: list[tuple] = []
    updates: list[tuple[str, tuple]] = []
    conn.lines_checks = lines_checks

    async def fetchrow_side_effect(query, *args):
        if "FROM units_of_measure" in query:
            return {"?column?": 1}
        return _product_row(current_base)

    async def fetchval_side_effect(query, *args):
        if "FROM quote_items" in query:
            lines_checks.append(args)
            return has_other_unit_lines
        if "FROM branch_stock" in query:
            stock_checks.append(args)
            return has_stock
        if "FROM stock_movements" in query:
            movement_checks.append(args)
            return has_movements
        return None

    async def execute_side_effect(query, *args):
        if query.lstrip().startswith("UPDATE products"):
            updates.append((query, args))
            return "UPDATE 1"
        return "SET"

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)
    conn.fetchval = AsyncMock(side_effect=fetchval_side_effect)
    conn.execute = AsyncMock(side_effect=execute_side_effect)
    return stock_checks, movement_checks, updates


async def _put(async_client, pool, body: dict):
    headers = {"Authorization": f"Bearer {make_token({'role': 'user'})}"}
    with patch("backend.core.database.pool", pool):
        return await async_client.put(f"/products/{PRODUCT_ID}", json=body, headers=headers)


def _assert_locked(resp) -> None:
    assert resp.status_code == 409, resp.text
    assert resp.headers["content-type"].startswith("application/problem+json")
    body = resp.json()
    assert body["code"] == "base_unit_locked"
    assert body["status"] == 409
    assert body["field"] == "base_unit_id"
    # Accionable: dice por qué y qué hacer, no sólo "conflicto".
    assert "unidad base" in body["detail"]
    assert "producto nuevo" in body["detail"]


# (a) ─────────────────────────────────────────────────────────────────────────
async def test_assign_base_unit_to_product_without_one_is_allowed_even_with_stock(async_client, mock_pool):
    pool, conn = mock_pool
    stock_checks, movement_checks, updates = _wire(conn, current_base=None, has_stock=True, has_movements=True)

    resp = await _put(async_client, pool, {"base_unit_id": UNIT_KG})

    assert resp.status_code == 200, resp.text
    assert len(updates) == 1
    assert "base_unit_id = $" in updates[0][0]
    assert UNIT_KG in updates[0][1]
    # Asignar no es cambiar: sin líneas grabadas en OTRA unidad el guard ni
    # siquiera consulta el stock (cuarta revisión: sí mira las líneas, con la
    # unidad que se asigna y scopeado a la cuenta).
    assert stock_checks == []
    assert movement_checks == []
    assert len(conn.lines_checks) == 1
    assert [str(a) for a in conn.lines_checks[0]] == [PRODUCT_ID, str(TEST_ACCOUNT_ID), UNIT_KG]


# (b) ─────────────────────────────────────────────────────────────────────────
async def test_change_base_unit_with_stock_is_rejected_409(async_client, mock_pool):
    pool, conn = mock_pool
    stock_checks, _, updates = _wire(conn, current_base=UNIT_UN, has_stock=True, has_movements=False)

    resp = await _put(async_client, pool, {"base_unit_id": UNIT_KG})

    _assert_locked(resp)
    assert updates == []  # nada se escribió
    # La consulta de stock va scopeada al producto Y a la cuenta del request.
    assert len(stock_checks) == 1
    assert str(stock_checks[0][0]) == PRODUCT_ID
    assert str(stock_checks[0][1]) == str(TEST_ACCOUNT_ID)


# (c) ─────────────────────────────────────────────────────────────────────────
async def test_change_base_unit_with_zero_stock_but_movements_is_rejected_409(async_client, mock_pool):
    pool, conn = mock_pool
    stock_checks, movement_checks, updates = _wire(conn, current_base=UNIT_UN, has_stock=False, has_movements=True)

    resp = await _put(async_client, pool, {"base_unit_id": UNIT_KG})

    _assert_locked(resp)
    assert updates == []
    assert len(stock_checks) == 1
    assert len(movement_checks) == 1
    assert str(movement_checks[0][0]) == PRODUCT_ID
    assert str(movement_checks[0][1]) == str(TEST_ACCOUNT_ID)


# (d) ─────────────────────────────────────────────────────────────────────────
async def test_change_base_unit_without_stock_nor_movements_is_allowed(async_client, mock_pool):
    pool, conn = mock_pool
    stock_checks, movement_checks, updates = _wire(conn, current_base=UNIT_UN, has_stock=False, has_movements=False)

    resp = await _put(async_client, pool, {"base_unit_id": UNIT_KG})

    assert resp.status_code == 200, resp.text
    assert len(stock_checks) == 1
    assert len(movement_checks) == 1
    assert len(updates) == 1
    assert UNIT_KG in updates[0][1]


# (e) ─────────────────────────────────────────────────────────────────────────
async def test_sending_the_same_base_unit_is_not_a_change(async_client, mock_pool):
    pool, conn = mock_pool
    stock_checks, movement_checks, updates = _wire(conn, current_base=UNIT_KG, has_stock=True, has_movements=True)

    # El formulario manda la unidad actual en cada guardado: no puede bloquearlo.
    resp = await _put(async_client, pool, {"name": "Tomate perita", "base_unit_id": UNIT_KG})

    assert resp.status_code == 200, resp.text
    assert stock_checks == []
    assert movement_checks == []
    assert len(updates) == 1


# (f) ─────────────────────────────────────────────────────────────────────────
async def test_unassigning_base_unit_with_stock_is_rejected_409(async_client, mock_pool):
    pool, conn = mock_pool
    _, _, updates = _wire(conn, current_base=UNIT_KG, has_stock=True, has_movements=True)

    resp = await _put(async_client, pool, {"base_unit_id": None})

    _assert_locked(resp)
    assert updates == []


async def test_omitting_base_unit_never_runs_the_guard(async_client, mock_pool):
    """Tri-estado por ausencia: un PUT que no toca la unidad no paga el guard."""
    pool, conn = mock_pool
    stock_checks, movement_checks, updates = _wire(conn, current_base=UNIT_UN, has_stock=True, has_movements=True)

    resp = await _put(async_client, pool, {"name": "Tomate perita"})

    assert resp.status_code == 200, resp.text
    assert stock_checks == []
    assert movement_checks == []
    assert "base_unit_id" not in updates[0][0]


async def test_change_base_unit_on_missing_product_is_404(async_client, mock_pool):
    pool, conn = mock_pool
    _, _, updates = _wire(conn, current_base=UNIT_UN, has_stock=False, has_movements=False)

    async def fetchrow_side_effect(query, *args):
        if "FROM units_of_measure" in query:
            return {"?column?": 1}
        return None  # producto inexistente o de otra cuenta

    conn.fetchrow = AsyncMock(side_effect=fetchrow_side_effect)

    resp = await _put(async_client, pool, {"base_unit_id": UNIT_KG})

    assert resp.status_code == 404, resp.text
    assert updates == []


# ── Repositorio: alcance de las dos consultas del guard ─────────────────────


def _repo_with(results: list[object]) -> tuple[ProductRepository, AsyncMock]:
    conn = AsyncMock()
    conn.fetchval = AsyncMock(side_effect=results)
    return ProductRepository(conn), conn


async def test_repo_stock_hit_short_circuits_the_movements_query():
    repo, conn = _repo_with([True])

    assert await repo.has_stock_or_movements(PRODUCT_ID, str(TEST_ACCOUNT_ID)) is True
    assert conn.fetchval.await_count == 1
    sql, *args = conn.fetchval.await_args_list[0].args
    assert "FROM branch_stock" in sql
    assert args == [PRODUCT_ID, str(TEST_ACCOUNT_ID)]


async def test_repo_returns_false_only_when_both_queries_are_empty():
    repo, conn = _repo_with([False, False])
    assert await repo.has_stock_or_movements(PRODUCT_ID, str(TEST_ACCOUNT_ID)) is False
    assert conn.fetchval.await_count == 2

    repo, conn = _repo_with([False, True])
    assert await repo.has_stock_or_movements(PRODUCT_ID, str(TEST_ACCOUNT_ID)) is True
    assert "FROM stock_movements" in conn.fetchval.await_args_list[1].args[0]


async def test_repo_queries_are_tenant_scoped_and_cover_the_variant_group():
    repo, conn = _repo_with([False, False])
    await repo.has_stock_or_movements(PRODUCT_ID, str(TEST_ACCOUNT_ID))

    stock_sql = conn.fetchval.await_args_list[0].args[0]
    movements_sql = conn.fetchval.await_args_list[1].args[0]
    # Guard de tenencia explícito en la tabla del ledger Y en products.
    assert "bs.account_id = $2" in stock_sql and "p.account_id = $2" in stock_sql
    assert "sm.account_id = $2" in movements_sql and "p.account_id = $2" in movements_sql
    # Las variantes heredan la unidad del padre: su stock también está en ella.
    for sql in (stock_sql, movements_sql):
        assert "p.parent_id = $1::uuid" in sql
    # "Stock ≠ 0 en ALGUNA sucursal", no la suma (+5 / −5 también cuenta).
    assert "bs.quantity <> 0" in stock_sql
    assert "SUM(" not in stock_sql.upper()


# ── Segunda revisión del PR #584 ────────────────────────────────────────────
# (g) VARIANTE: su unidad "actual" es la heredada del padre (v_products_with_stock
#     expone COALESCE(p.base_unit_id, pp.base_unit_id)). Cambiarla con stock en
#     el grupo también es un cambio → 409. Ninguna fixture tenía una variante.
async def test_variant_with_inherited_base_unit_and_stock_is_rejected_409(async_client, mock_pool):
    pool, conn = mock_pool
    stock_checks, movement_checks, updates = _wire(conn, current_base=UNIT_KG, has_stock=True, has_movements=False)
    variant_row = {**_product_row(UNIT_KG), "parent_id": "33333333-3333-3333-3333-333333333333", "is_variant": True}

    async def fetchrow_variant(query, *args):
        if "FROM units_of_measure" in query:
            return {"?column?": 1}
        return variant_row

    conn.fetchrow = AsyncMock(side_effect=fetchrow_variant)

    resp = await _put(async_client, pool, {"base_unit_id": UNIT_UN})

    _assert_locked(resp)
    assert updates == []
    assert len(stock_checks) == 1


# (h) El guard de la BASE (trg_product_base_unit_guard, P0409) es el que decide
#     cuando la carrera la gana otro escritor entre el chequeo y el UPDATE
#     (TOCTOU) o el cambio llega por otro camino: el backend lo traduce a 409
#     RFC 7807 con el mensaje del RAISE, nunca a un 500.
async def test_db_trigger_base_unit_locked_maps_to_409_problem(async_client, mock_pool):
    import asyncpg

    pool, conn = mock_pool
    _wire(conn, current_base=UNIT_KG, has_stock=False, has_movements=False)
    err = asyncpg.exceptions.RaiseError(
        "base_unit_locked: el producto ya tiene stock o movimientos en su unidad base actual"
    )
    err.sqlstate = "P0409"

    async def execute_raises(query, *args):
        if query.lstrip().startswith("UPDATE products"):
            raise err
        return "SET"

    conn.execute = AsyncMock(side_effect=execute_raises)

    resp = await _put(async_client, pool, {"base_unit_id": UNIT_UN})

    assert resp.status_code == 409, resp.text
    assert resp.headers["content-type"].startswith("application/problem+json")
    assert "base_unit_locked" in resp.json()["detail"]


# ── Cuarta revisión del PR #584 (fix-round 3) ───────────────────────────────
# (i) ASIGNAR sobre stock e historia grabados con OTRA unidad explícita: un
#     producto sin unidad base admite líneas en cualquier unidad base (kg, L,
#     u). Con historia en 'u', asignarle 'kg' hacía que "7 u" se leyeran "7 kg"
#     y que el POS vendiera kilos de algo contado en unidades
#     (redteam-3a/30-assign-probe). Mismo 409 que el cambio, con un detalle que
#     dice qué hacer.
async def test_assign_base_unit_over_history_in_another_unit_is_rejected_409(async_client, mock_pool):
    pool, conn = mock_pool
    stock_checks, _, updates = _wire(
        conn, current_base=None, has_stock=True, has_movements=True, has_other_unit_lines=True,
    )

    resp = await _put(async_client, pool, {"base_unit_id": UNIT_KG})

    _assert_locked(resp)
    assert "otra unidad" in resp.json()["detail"]
    assert "asign" in resp.json()["detail"].lower()
    assert updates == []
    assert len(conn.lines_checks) == 1
    assert len(stock_checks) == 1


# (j) ...pero sin stock ni movimientos no hay cantidades que reinterpretar:
#     asignar se permite (mismo criterio que el cambio, D-C).
async def test_assign_base_unit_with_other_unit_lines_but_no_stock_nor_movements_is_allowed(async_client, mock_pool):
    pool, conn = mock_pool
    stock_checks, movement_checks, updates = _wire(
        conn, current_base=None, has_stock=False, has_movements=False, has_other_unit_lines=True,
    )

    resp = await _put(async_client, pool, {"base_unit_id": UNIT_KG})

    assert resp.status_code == 200, resp.text
    assert len(stock_checks) == 1
    assert len(movement_checks) == 1
    assert len(updates) == 1


# (k) Repositorio: la consulta de líneas en otra unidad recorre las SEIS
#     tablas de líneas, sólo el producto y las variantes que HEREDAN (base
#     propia NULL — misma regla que trg_product_base_unit_guard), ignora las
#     líneas sin unidad, compara contra la unidad que se asigna y filtra la
#     cuenta en products y en cada tabla de líneas (regla dura de tenencia).
async def test_repo_other_unit_lines_query_scope():
    repo, conn = _repo_with([True])

    assert await repo.has_lines_in_other_unit(PRODUCT_ID, str(TEST_ACCOUNT_ID), UNIT_KG) is True
    sql, *args = conn.fetchval.await_args_list[0].args
    assert args == [PRODUCT_ID, str(TEST_ACCOUNT_ID), UNIT_KG]
    assert "p.account_id = $2" in sql
    assert "p.parent_id = $1::uuid AND p.base_unit_id IS NULL" in sql
    for table in ("sales", "purchases", "sale_items", "purchase_items", "sales_order_items", "quote_items"):
        assert f"FROM {table} l " in sql, table
    assert sql.count("l.account_id = $2") == 6
    assert sql.count("l.unit_id IS NOT NULL AND l.unit_id <> $3::uuid") == 6
