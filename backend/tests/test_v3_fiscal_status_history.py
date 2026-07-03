"""
v3-document-status-history — retrofit del relay CAE (task 4.6).

El punto exacto donde el backend persiste pending_cae → authorized|rejected es
FiscalDocumentRepository.update_authorized / update_rejected. El retrofit exige
que, EN LA MISMA TRANSACCIÓN que el UPDATE de fiscal_documents.status, se invoque
public.rpc_record_fiscal_transition (SECURITY DEFINER, GRANT solo service_role)
para insertar la fila de document_status_history (RN-A1).

Reglas verificadas:
- update_authorized: UPDATE + rpc_record_fiscal_transition('authorized') en una
  transacción; si el UPDATE no matcheó (otro relay ya lo transicionó), NO se
  registra historial (idempotencia — el claim/lease ya garantiza un solo ganador).
- update_rejected: ídem con 'rejected' y reason = last_error.
"""
from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock

import pytest

from backend.repositories.fiscal_document_repository import FiscalDocumentRepository

DOC_ID = "11111111-2222-3333-4444-555555555555"


def _make_conn(update_status: str = "UPDATE 1") -> AsyncMock:
    """Conn asyncpg falsa: execute devuelve el status del UPDATE; transaction()
    es un método sync que devuelve un async context manager (como asyncpg)."""
    conn = AsyncMock()
    conn.execute = AsyncMock(return_value=update_status)
    tx = MagicMock()
    tx.__aenter__ = AsyncMock(return_value=None)
    tx.__aexit__ = AsyncMock(return_value=False)
    conn.transaction = MagicMock(return_value=tx)
    return conn


@pytest.mark.asyncio
async def test_update_authorized_records_history_in_same_transaction():
    """RN-A1: el UPDATE a authorized y el registro del historial comparten transacción."""
    conn = _make_conn("UPDATE 1")
    repo = FiscalDocumentRepository(conn)

    import datetime
    await repo.update_authorized(
        doc_id=DOC_ID, cae="75123456789012", cae_due_date=datetime.date(2026, 7, 20)
    )

    # Una transacción explícita envuelve ambos statements
    conn.transaction.assert_called_once()

    calls = conn.execute.call_args_list
    assert len(calls) == 2, "se esperaban 2 statements: UPDATE + rpc_record_fiscal_transition"

    update_query = calls[0][0][0]
    assert "UPDATE public.fiscal_documents" in update_query
    assert "status       = 'authorized'" in update_query

    rpc_query = calls[1][0][0]
    assert "rpc_record_fiscal_transition" in rpc_query
    assert calls[1][0][1] == DOC_ID
    assert calls[1][0][2] == "authorized"


@pytest.mark.asyncio
async def test_update_authorized_skips_history_when_no_row_transitioned():
    """Si el UPDATE no matcheó (doc ya terminal por otro relay), no hay historial."""
    conn = _make_conn("UPDATE 0")
    repo = FiscalDocumentRepository(conn)

    import datetime
    await repo.update_authorized(
        doc_id=DOC_ID, cae="75123456789012", cae_due_date=datetime.date(2026, 7, 20)
    )

    calls = conn.execute.call_args_list
    assert len(calls) == 1, "con UPDATE 0 no debe invocarse el RPC de historial"
    assert "rpc_record_fiscal_transition" not in calls[0][0][0]


@pytest.mark.asyncio
async def test_update_rejected_records_history_with_error_reason():
    """El rechazo registra 'rejected' con el detalle del error como reason."""
    conn = _make_conn("UPDATE 1")
    repo = FiscalDocumentRepository(conn)

    await repo.update_rejected(doc_id=DOC_ID, last_error="[10015] CUIT invalido")

    conn.transaction.assert_called_once()
    calls = conn.execute.call_args_list
    assert len(calls) == 2

    rpc_query = calls[1][0][0]
    assert "rpc_record_fiscal_transition" in rpc_query
    assert calls[1][0][1] == DOC_ID
    assert calls[1][0][2] == "rejected"
    assert calls[1][0][3] == "[10015] CUIT invalido"


@pytest.mark.asyncio
async def test_update_rejected_skips_history_when_no_row_transitioned():
    conn = _make_conn("UPDATE 0")
    repo = FiscalDocumentRepository(conn)

    await repo.update_rejected(doc_id=DOC_ID, last_error="[10015] CUIT invalido")

    calls = conn.execute.call_args_list
    assert len(calls) == 1
    assert "rpc_record_fiscal_transition" not in calls[0][0][0]
