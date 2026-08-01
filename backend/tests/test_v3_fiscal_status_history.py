"""v3-document-status-history — retrofit del relay CAE (task 4.6).

v31-tenancy-pool-rls (colisión #1, sign-off PO 2026-08-01): fiscal_documents
no tiene policy de UPDATE (append-only vía RPC, no vía cliente) — el UPDATE
directo + la llamada condicional a rpc_record_fiscal_transition que este
repository hacía antes quedaron ENCAMINADOS por rpc_fiscal_document_authorize
/ rpc_fiscal_document_reject (SECURITY DEFINER), que hacen ambos pasos en un
solo statement SQL. Este test ya NO puede verificar la arquitectura interna
(UPDATE + PERFORM rpc_record_fiscal_transition) desde el mock de Python —
esa aritmética ahora vive dentro de la RPC y se prueba con gates SQL contra
Postgres real (supabase/migrations/20260828000001_v31_rls_collision_rpcs.sql,
gates fiscal-a/fiscal-b). Lo que SÍ puede y debe verificar un test a nivel de
repository es el CONTRATO: qué RPC se llama y con qué parámetros — igual que
el resto del proyecto prueba las llamadas a rpc_* (ver test_purchases.py,
test_sales.py, etc.).
"""
from __future__ import annotations

import datetime
from unittest.mock import AsyncMock

import pytest

from backend.repositories.fiscal_document_repository import FiscalDocumentRepository

DOC_ID = "11111111-2222-3333-4444-555555555555"


def _make_conn() -> AsyncMock:
    conn = AsyncMock()
    conn.execute = AsyncMock(return_value="SELECT 1")
    return conn


@pytest.mark.asyncio
async def test_update_authorized_calls_authorize_rpc_with_cae_and_due_date():
    """update_authorized encamina por rpc_fiscal_document_authorize (colisión
    #1) — la RPC hace el UPDATE + el registro de historial internamente."""
    conn = _make_conn()
    repo = FiscalDocumentRepository(conn)

    await repo.update_authorized(
        doc_id=DOC_ID, cae="75123456789012", cae_due_date=datetime.date(2026, 7, 20)
    )

    conn.execute.assert_awaited_once()
    query, doc_id, cae, cae_due_date = conn.execute.call_args.args
    assert "rpc_fiscal_document_authorize" in query
    assert doc_id == DOC_ID
    assert cae == "75123456789012"
    assert cae_due_date == datetime.date(2026, 7, 20)


@pytest.mark.asyncio
async def test_update_rejected_calls_reject_rpc_with_last_error():
    """update_rejected encamina por rpc_fiscal_document_reject (colisión #1)."""
    conn = _make_conn()
    repo = FiscalDocumentRepository(conn)

    await repo.update_rejected(doc_id=DOC_ID, last_error="[10015] CUIT invalido")

    conn.execute.assert_awaited_once()
    query, doc_id, last_error = conn.execute.call_args.args
    assert "rpc_fiscal_document_reject" in query
    assert doc_id == DOC_ID
    assert last_error == "[10015] CUIT invalido"


@pytest.mark.asyncio
async def test_update_retry_calls_retry_rpc_with_backoff_fields():
    """update_retry encamina por rpc_fiscal_document_retry (colisión #1) —
    sin historial, mismo contrato que el UPDATE directo que reemplaza."""
    conn = _make_conn()
    repo = FiscalDocumentRepository(conn)

    next_at = datetime.datetime(2026, 7, 20, 12, 0, tzinfo=datetime.timezone.utc)
    await repo.update_retry(
        doc_id=DOC_ID, attempts=3, next_attempt_at=next_at, last_error="[500] timeout"
    )

    conn.execute.assert_awaited_once()
    query, doc_id, attempts, out_next_at, last_error = conn.execute.call_args.args
    assert "rpc_fiscal_document_retry" in query
    assert doc_id == DOC_ID
    assert attempts == 3
    assert out_next_at == next_at
    assert last_error == "[500] timeout"


@pytest.mark.asyncio
async def test_claim_pending_calls_claim_rpc_and_returns_none_on_empty():
    """claim_pending encamina por rpc_fiscal_document_claim_pending — SETOF
    vacío (fetchrow -> None) se interpreta como "ya reclamado", igual que
    antes con el UPDATE...RETURNING de 0 filas."""
    conn = AsyncMock()
    conn.fetchrow = AsyncMock(return_value=None)
    repo = FiscalDocumentRepository(conn)

    result = await repo.claim_pending(DOC_ID, max_attempts=10)

    assert result is None
    conn.fetchrow.assert_awaited_once()
    query, doc_id, max_attempts = conn.fetchrow.call_args.args
    assert "rpc_fiscal_document_claim_pending" in query
    assert doc_id == DOC_ID
    assert max_attempts == 10


@pytest.mark.asyncio
async def test_claim_pending_returns_dict_when_rpc_returns_a_row():
    """TRIANGULATE: cuando la RPC sí devuelve una fila (claim exitoso),
    claim_pending la convierte a dict — mismo contrato que antes."""
    conn = AsyncMock()
    fake_row = {"id": DOC_ID, "cuit": "20111111112", "ambiente": "homologacion"}
    conn.fetchrow = AsyncMock(return_value=fake_row)
    repo = FiscalDocumentRepository(conn)

    result = await repo.claim_pending(DOC_ID)

    assert result == fake_row
