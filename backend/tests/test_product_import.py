"""
importador-productos-fastapi — Grupo 7: backend Python (schemas, repository,
service, router).

Strict TDD: este archivo se escribió ANTES de tocar `backend/schemas/
products.py` (schemas del lote), `backend/repositories/product_repository.py`
(`import_batch`), `backend/services/products.py` (`import_products`) y
`backend/routers/products.py` (`POST /products/import`). Molde calcado de
`backend/tests/test_expense_import.py` (importador-gastos-transaccional).

Qué cubre, por task:

  7.1  — `ProductRepository.import_batch`: UNA sola llamada (`fetchrow`),
         orden POSICIONAL exacto de los 5 parámetros de la RPC, `rows`
         serializado a JSON string (no un dict crudo).
  7.2  — Schemas: `rows` acotado a 2500 (D6/OQ-2, sin trocear — bajado de
         5000 post-review por medición de degradación superlineal); ningún
         campo opcional con default numérico (D12).
  7.3  — Contrato NULL-PRESERVING (D12): una fila con `cost` ausente llega
         al repository como `null`, nunca como `0`.
  7.5  — Service: CERO reglas de dominio nuevas — sólo `require_role`.
         El `user_id` NO se lee del payload.
  7.6  — Router: `require_idempotency_key`, `"import"` declarado antes de
         `/{product_id}`.
  7.7  — `P0427`/`P0430` registrados en `backend/core/errors.py`.
  7.8  — Triangulación: lote aplicado, lote RECHAZADO (200 con errors[], NO
         4xx), simulación, replay por clave, replay por hash, sin rol de
         escritura (403), sin clave de idempotencia (422).
  7.9  — Un lote rechazado NO deja la conexión en estado inutilizable.
  7.10 — El lote en el tope (2500 filas, D6/OQ-2) completa el ciclo request/response.

Run: python -m pytest backend/tests/test_product_import.py -q -p no:cacheprovider
"""
from __future__ import annotations

import json
from decimal import Decimal
from unittest.mock import AsyncMock, patch

import pytest

from backend.tests.conftest import make_token

ROW_1 = {"row_no": 1, "name": "Remera básica", "price": "1000"}
ROW_2 = {
    "row_no": 2,
    "name": "Pantalón",
    "price": "2000",
    "cost": "800",
    "category": "Ropa",
    "sku": "PANT-001",
}

VALID_PAYLOAD = {
    "file_name": "productos-mayo.csv",
    "file_hash": "abc123",
    "rows": [ROW_1, ROW_2],
}

APPLIED_RESULT = {
    "committed": True,
    "import_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    "inserted": 2,
    "updated": 0,
    "errors": [],
    "new_categories": [{"name": "Ropa", "rows": 1}],
    "replayed": False,
    "dry_run": False,
}

REJECTED_RESULT = {
    "committed": False,
    "import_id": None,
    "inserted": 0,
    "updated": 0,
    "errors": [{"row": 2, "sku": None, "name": "Variante huérfana", "message": 'SKU Padre "X" no encontrado'}],
    "new_categories": [],
    "replayed": False,
    "dry_run": False,
}


def _rpc_row(result: dict) -> dict:
    return {"result": json.dumps(result)}


# ══════════════════════════════════════════════════════════════════════════
# 7.1 — Repository: una sola llamada, orden posicional, rows como JSON
# ══════════════════════════════════════════════════════════════════════════


class TestProductRepositoryImportBatch:
    async def test_single_fetchrow_call_with_positional_order(self):
        from backend.repositories.product_repository import ProductRepository

        conn = AsyncMock()
        conn.fetchrow = AsyncMock(return_value=_rpc_row(APPLIED_RESULT))
        repo = ProductRepository(conn)

        rows_json = json.dumps([ROW_1, ROW_2])
        result = await repo.import_batch(
            idempotency_key="key-1",
            rows_json=rows_json,
            file_name="productos-mayo.csv",
            file_hash="abc123",
            dry_run=False,
        )

        conn.fetchrow.assert_awaited_once()
        args = conn.fetchrow.call_args.args
        # args[0] es la query SQL; el resto son los 5 parámetros posicionales
        # de rpc_import_products, en el MISMO orden que la firma SQL.
        assert args[1] == "key-1"
        assert args[2] == rows_json
        assert isinstance(args[2], str), "rows debe viajar como STRING json, no un dict/list crudo"
        assert args[3] == "productos-mayo.csv"
        assert args[4] == "abc123"
        assert args[5] is False
        assert result["committed"] is True

    async def test_rows_json_is_a_real_json_string_not_a_python_list(self):
        """Control negativo: pasar un `list[dict]` crudo (sin json.dumps) es
        el bug que asyncpg NO castea automáticamente a jsonb — el contrato
        del repository exige que el CALLER (router) ya lo serializó."""
        from backend.repositories.product_repository import ProductRepository

        conn = AsyncMock()
        conn.fetchrow = AsyncMock(return_value=_rpc_row(APPLIED_RESULT))
        repo = ProductRepository(conn)

        rows_json = json.dumps([ROW_1])
        await repo.import_batch(
            idempotency_key="key-1", rows_json=rows_json,
            file_name="f.csv", file_hash="h1", dry_run=False,
        )
        passed_rows_arg = conn.fetchrow.call_args.args[2]
        assert isinstance(passed_rows_arg, str)
        json.loads(passed_rows_arg)  # no debe tirar — es JSON válido


# ══════════════════════════════════════════════════════════════════════════
# 7.2 — Schemas
# ══════════════════════════════════════════════════════════════════════════


class TestProductImportSchemas:
    def test_row_only_name_is_required(self):
        from backend.schemas.products import ProductImportRowIn

        row = ProductImportRowIn(row_no=1, name="Producto simple")
        assert row.price is None
        assert row.cost is None
        assert row.stock is None
        assert row.sku is None
        assert row.attributes == []

    def test_import_in_accepts_exactly_the_cap(self):
        from backend.schemas.products import PRODUCT_IMPORT_MAX_ROWS, ProductImportIn

        rows = [{"row_no": i, "name": f"producto {i}"} for i in range(1, PRODUCT_IMPORT_MAX_ROWS + 1)]
        payload = ProductImportIn(file_name="f.csv", file_hash="h", rows=rows)
        assert len(payload.rows) == PRODUCT_IMPORT_MAX_ROWS

    def test_import_in_rejects_one_row_over_the_cap(self):
        """D6: el tope se verifica en el SERVIDOR aunque la superficie
        también lo aplique — acá, en Pydantic, ANTES de llegar a la RPC."""
        from pydantic import ValidationError

        from backend.schemas.products import PRODUCT_IMPORT_MAX_ROWS, ProductImportIn

        rows = [{"row_no": i, "name": f"producto {i}"} for i in range(1, PRODUCT_IMPORT_MAX_ROWS + 2)]
        with pytest.raises(ValidationError):
            ProductImportIn(file_name="f.csv", file_hash="h", rows=rows)

    def test_import_in_rejects_empty_rows(self):
        from pydantic import ValidationError

        from backend.schemas.products import ProductImportIn

        with pytest.raises(ValidationError):
            ProductImportIn(file_name="f.csv", file_hash="h", rows=[])


# ══════════════════════════════════════════════════════════════════════════
# 7.3 — Contrato NULL-PRESERVING (D12): cost ausente -> null, nunca 0
# ══════════════════════════════════════════════════════════════════════════


class TestNullPreservingTransport:
    """Este test es el que impide que el TRANSPORTE destruya en silencio la
    distinción "celda vacía" vs. "cero" que `productos-costo-nullable` fijó
    en la semántica del costo — ninguna prueba de costo lo cubriría, porque
    el defecto estaría en el tubo, no en el dominio."""

    async def test_missing_cost_travels_as_null_not_zero(self, async_client, mock_pool):
        pool, conn = mock_pool
        token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(return_value=_rpc_row(APPLIED_RESULT))

        payload = {
            "file_name": "f.csv",
            "file_hash": "h",
            "rows": [{"row_no": 1, "name": "Sin costo"}],  # cost/price/stock ausentes
        }
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products/import", json=payload,
                headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "k-null"},
            )
        assert resp.status_code == 200

        rows_json_sent = conn.fetchrow.call_args.args[2]
        rows_sent = json.loads(rows_json_sent)
        assert rows_sent[0]["cost"] is None
        assert rows_sent[0]["price"] is None
        assert rows_sent[0]["stock"] is None
        assert "0" not in (rows_sent[0]["cost"] or ""), "un costo ausente NUNCA debe serializarse como '0'"

    async def test_explicit_zero_cost_travels_as_zero_not_null(self, async_client, mock_pool):
        """El otro lado de la distinción: un costo DECLARADO en 0 tiene que
        preservarse como "0", no colapsar a null."""
        pool, conn = mock_pool
        token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(return_value=_rpc_row(APPLIED_RESULT))

        payload = {
            "file_name": "f.csv",
            "file_hash": "h",
            "rows": [{"row_no": 1, "name": "Costo cero declarado", "cost": "0"}],
        }
        with patch("backend.core.database.pool", pool):
            await async_client.post(
                "/products/import", json=payload,
                headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "k-zero"},
            )
        rows_sent = json.loads(conn.fetchrow.call_args.args[2])
        assert rows_sent[0]["cost"] == "0"


# ══════════════════════════════════════════════════════════════════════════
# 7.7 — P0427/P0430 registrados
# ══════════════════════════════════════════════════════════════════════════


def test_p0427_registered_as_422():
    from backend.core.errors import _BUSINESS_ERRCODE_STATUS

    assert _BUSINESS_ERRCODE_STATUS["P0427"] == 422


def test_p0430_registered_reserved_for_plan_gate():
    """OQ-1 NO tiene sign-off del PO — rpc_import_products no emite P0430
    hoy, pero el mapeo queda listo para cuando el gate de plan se escriba."""
    from backend.core.errors import _BUSINESS_ERRCODE_STATUS

    assert _BUSINESS_ERRCODE_STATUS["P0430"] == 403


def test_p0429_never_needs_mapping_it_never_escapes_the_rpc():
    from backend.core.errors import _BUSINESS_ERRCODE_STATUS

    assert "P0429" not in _BUSINESS_ERRCODE_STATUS


# ══════════════════════════════════════════════════════════════════════════
# 7.5/7.6/7.8 — Service + router, end-to-end con mock_pool
# ══════════════════════════════════════════════════════════════════════════


class TestImportProductsEndpoint:
    async def test_applied_batch_returns_200_with_report(self, async_client, mock_pool):
        pool, conn = mock_pool
        token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(return_value=_rpc_row(APPLIED_RESULT))

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products/import",
                json=VALID_PAYLOAD,
                headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "batch-key-1"},
            )
        assert resp.status_code == 200
        body = resp.json()
        assert body["committed"] is True
        assert body["inserted"] == 2
        assert body["errors"] == []
        assert body["new_categories"] == [{"name": "Ropa", "rows": 1}]

    async def test_rejected_batch_returns_200_not_4xx(self, async_client, mock_pool):
        """D3 del design: un lote rechazado por errores de fila NO es un
        error de protocolo — sigue respondiendo 200 con el reporte."""
        pool, conn = mock_pool
        token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(return_value=_rpc_row(REJECTED_RESULT))

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products/import",
                json=VALID_PAYLOAD,
                headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "batch-key-2"},
            )
        assert resp.status_code == 200
        body = resp.json()
        assert body["committed"] is False
        assert body["errors"][0]["row"] == 2

    async def test_dry_run_forwarded_to_repository(self, async_client, mock_pool):
        pool, conn = mock_pool
        token = make_token({"role": "user"})
        dry_result = {**APPLIED_RESULT, "committed": False, "dry_run": True, "import_id": None}
        conn.fetchrow = AsyncMock(return_value=_rpc_row(dry_result))

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products/import",
                json={**VALID_PAYLOAD, "dry_run": True},
                headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "batch-key-3"},
            )
        assert resp.status_code == 200
        assert resp.json()["dry_run"] is True
        # p_dry_run (5º parámetro posicional) debe haber viajado en True
        assert conn.fetchrow.call_args.args[5] is True

    async def test_replay_by_same_key_returns_replayed_true(self, async_client, mock_pool):
        pool, conn = mock_pool
        token = make_token({"role": "user"})
        replayed_result = {**APPLIED_RESULT, "replayed": True}
        conn.fetchrow = AsyncMock(return_value=_rpc_row(replayed_result))

        with patch("backend.core.database.pool", pool):
            first = await async_client.post(
                "/products/import", json=VALID_PAYLOAD,
                headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "replay-key"},
            )
            second = await async_client.post(
                "/products/import", json=VALID_PAYLOAD,
                headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "replay-key"},
            )
        assert first.status_code == 200
        assert second.status_code == 200
        assert second.json()["replayed"] is True
        assert conn.fetchrow.call_args_list[0].args[1] == "replay-key"
        assert conn.fetchrow.call_args_list[1].args[1] == "replay-key"

    async def test_replay_by_same_file_hash_different_key(self, async_client, mock_pool):
        """Dedupe de dominio (D8): mismo file_hash, otra clave -> replayed."""
        pool, conn = mock_pool
        token = make_token({"role": "user"})
        replayed_result = {**APPLIED_RESULT, "replayed": True}
        conn.fetchrow = AsyncMock(return_value=_rpc_row(replayed_result))

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products/import", json=VALID_PAYLOAD,
                headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "otra-clave-distinta"},
            )
        assert resp.status_code == 200
        assert resp.json()["replayed"] is True

    async def test_member_without_write_role_forbidden(self, async_client, mock_pool):
        pool, conn = mock_pool
        member_token = make_token({"role": "member"})
        conn.fetchrow = AsyncMock(return_value=_rpc_row(APPLIED_RESULT))

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products/import", json=VALID_PAYLOAD,
                headers={"Authorization": f"Bearer {member_token}", "Idempotency-Key": "k"},
            )
        assert resp.status_code == 403
        conn.fetchrow.assert_not_awaited()

    async def test_missing_idempotency_key_returns_422(self, async_client, mock_pool):
        pool, conn = mock_pool
        token = make_token({"role": "user"})

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products/import", json=VALID_PAYLOAD,
                headers={"Authorization": f"Bearer {token}"},
            )
        assert resp.status_code == 422
        assert resp.json()["code"] == "idempotency_key_required"
        conn.fetchrow.assert_not_awaited()

    async def test_malformed_payload_p0427_maps_to_422(self, async_client, mock_pool):
        import asyncpg

        pool, conn = mock_pool
        token = make_token({"role": "user"})

        err = asyncpg.exceptions.RaiseError("import_payload_invalido: el archivo no tiene filas de datos")
        err.sqlstate = "P0427"
        conn.fetchrow = AsyncMock(side_effect=err)

        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products/import", json=VALID_PAYLOAD,
                headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "k"},
            )
        assert resp.status_code == 422
        assert resp.json()["code"] == "P0427"

    async def test_connection_stays_usable_after_a_rejected_batch(self, async_client, mock_pool):
        """7.9 — D3: el reporte de un lote rechazado viaja por el RETURN
        normal de la RPC, NUNCA por una excepción — la conexión sigue sana
        para cualquier llamada posterior."""
        pool, conn = mock_pool
        token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(side_effect=[_rpc_row(REJECTED_RESULT), _rpc_row(APPLIED_RESULT)])

        with patch("backend.core.database.pool", pool):
            rejected = await async_client.post(
                "/products/import", json=VALID_PAYLOAD,
                headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "k-rej"},
            )
            ok = await async_client.post(
                "/products/import", json=VALID_PAYLOAD,
                headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "k-ok"},
            )
        assert rejected.status_code == 200
        assert rejected.json()["committed"] is False
        assert ok.status_code == 200
        assert ok.json()["committed"] is True
        assert conn.fetchrow.await_count == 2

    async def test_user_id_never_read_from_payload(self, async_client, mock_pool):
        """El punto entero del change: el body NO lleva user_id/account_id,
        y aunque un caller viejo lo mandara, el schema lo ignora (Pydantic
        descarta claves extra en silencio, D6 del design análogo)."""
        pool, conn = mock_pool
        token = make_token({"role": "user"})
        conn.fetchrow = AsyncMock(return_value=_rpc_row(APPLIED_RESULT))

        payload_with_stray_user_id = {**VALID_PAYLOAD, "user_id": "attacker-controlled-uuid"}
        with patch("backend.core.database.pool", pool):
            resp = await async_client.post(
                "/products/import", json=payload_with_stray_user_id,
                headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "k-uid"},
            )
        assert resp.status_code == 200
        # Los 6 args posicionales de la query (SQL + 5 parámetros) no incluyen
        # nada derivado de "attacker-controlled-uuid".
        args = conn.fetchrow.call_args.args
        assert "attacker-controlled-uuid" not in args


# ══════════════════════════════════════════════════════════════════════════
# 7.10 — tope grande: la solicitud completa el ciclo request/response sin
# ninguna regla de negocio en Python.
# ══════════════════════════════════════════════════════════════════════════


async def test_import_batch_at_the_row_cap_reaches_the_repository(async_client, mock_pool):
    from backend.schemas.products import PRODUCT_IMPORT_MAX_ROWS

    pool, conn = mock_pool
    token = make_token({"role": "user"})
    conn.fetchrow = AsyncMock(return_value=_rpc_row({**APPLIED_RESULT, "inserted": PRODUCT_IMPORT_MAX_ROWS}))

    rows = [{"row_no": i, "name": f"producto {i}"} for i in range(1, PRODUCT_IMPORT_MAX_ROWS + 1)]
    with patch("backend.core.database.pool", pool):
        resp = await async_client.post(
            "/products/import",
            json={"file_name": "grande.csv", "file_hash": "h-grande", "rows": rows},
            headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "k-tope"},
        )
    assert resp.status_code == 200
    assert resp.json()["inserted"] == PRODUCT_IMPORT_MAX_ROWS
    conn.fetchrow.assert_awaited_once()
