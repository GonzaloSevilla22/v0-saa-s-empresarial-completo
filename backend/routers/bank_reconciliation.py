"""
Router para bank-reconciliation C3 — import de extracto, sesiones y matching.

Routes:
  POST /bank-accounts/{id}/statement-imports          → importar extracto (filas normalizadas)
  GET  /bank-accounts/{id}/statement-imports          → historial de imports
  GET  /statement-imports/{id}/lines                  → líneas del import (+ matched derivado)
  POST /bank-accounts/{id}/reconciliation-sessions    → abrir sesión
  GET  /bank-accounts/{id}/reconciliation-sessions    → historial de sesiones
  GET  /reconciliation-sessions/{id}                  → detalle de sesión
  GET  /reconciliation-sessions/{id}/pending          → líneas + movimientos sin conciliar
  GET  /reconciliation-sessions/{id}/suggestions      → sugerencias 1:1 (nunca auto-confirma)
  POST /reconciliation-sessions/{id}/matches          → crear grupo de match (1:1/1:N/N:1)
  POST /reconciliation-sessions/{id}/matches/{group}/undo → deshacer con motivo
  POST /reconciliation-sessions/{id}/close            → cerrar (motivo si diferencia ≠ 0)

Arquitectura dura: routers = validación + DI únicamente; la lógica vive en el
service y los invariantes en las RPCs.
"""
from __future__ import annotations

import json

import asyncpg
from fastapi import APIRouter, Depends

from backend.core.auth import get_current_user
from backend.core.database import get_db_conn
from backend.repositories.bank_reconciliation_repository import (
    BankReconciliationRepository,
)
from backend.schemas.bank_reconciliation import (
    ManualMovementIn,
    ManualMovementOut,
    MatchCreateIn,
    MatchGroupOut,
    MatchListItem,
    PendingMovementOut,
    SessionCloseIn,
    SessionCloseOut,
    SessionOpenIn,
    SessionOpenOut,
    SessionOut,
    StatementImportIn,
    StatementImportListItem,
    StatementImportOut,
    StatementLineOut,
    SuggestionOut,
    UndoMatchIn,
    UndoMatchOut,
)
from backend.services import bank_reconciliation as recon_service

router = APIRouter(tags=["bank-reconciliation"])


def get_repo(
    conn: asyncpg.Connection = Depends(get_db_conn),
) -> BankReconciliationRepository:
    return BankReconciliationRepository(conn)


# ── Import de extracto ─────────────────────────────────────────────────────────

@router.post("/bank-accounts/{bank_account_id}/statement-imports", response_model=StatementImportOut)
async def import_statement(
    bank_account_id: str,
    payload: StatementImportIn,
    auth: dict = Depends(get_current_user),
    repo: BankReconciliationRepository = Depends(get_repo),
):
    """Importa un extracto bancario como filas normalizadas (parseo en el cliente, D2)."""
    lines_json = json.dumps(
        [
            {
                "line_no": line.line_no,
                "value_date": line.value_date.isoformat(),
                "description": line.description,
                "amount": str(line.amount),
                "balance": str(line.balance) if line.balance is not None else None,
            }
            for line in payload.lines
        ]
    )
    return await recon_service.import_statement(
        repo,
        auth,
        bank_account_id=bank_account_id,
        idempotency_key=payload.idempotency_key,
        file_name=payload.file_name,
        file_hash=payload.file_hash,
        lines_json=lines_json,
    )


@router.get("/bank-accounts/{bank_account_id}/statement-imports", response_model=list[StatementImportListItem])
async def list_statement_imports(
    bank_account_id: str,
    auth: dict = Depends(get_current_user),
    repo: BankReconciliationRepository = Depends(get_repo),
):
    return await repo.list_imports(bank_account_id)


@router.get("/statement-imports/{import_id}/lines", response_model=list[StatementLineOut])
async def list_statement_lines(
    import_id: str,
    auth: dict = Depends(get_current_user),
    repo: BankReconciliationRepository = Depends(get_repo),
):
    return await repo.list_import_lines(import_id)


@router.post("/bank-accounts/{bank_account_id}/movements", response_model=ManualMovementOut)
async def register_manual_movement(
    bank_account_id: str,
    payload: ManualMovementIn,
    auth: dict = Depends(get_current_user),
    repo: BankReconciliationRepository = Depends(get_repo),
):
    """Carga manual de movimiento bancario ('solo anotar' V1: fee/tax_debit/interest + transferencias)."""
    return await recon_service.register_manual_movement(
        repo,
        auth,
        bank_account_id=bank_account_id,
        idempotency_key=payload.idempotency_key,
        amount=payload.amount,
        movement_type=payload.movement_type,
        value_date=payload.value_date,
        description=payload.description,
    )


# ── Sesiones ───────────────────────────────────────────────────────────────────

@router.post("/bank-accounts/{bank_account_id}/reconciliation-sessions", response_model=SessionOpenOut)
async def open_session(
    bank_account_id: str,
    payload: SessionOpenIn,
    auth: dict = Depends(get_current_user),
    repo: BankReconciliationRepository = Depends(get_repo),
):
    return await recon_service.open_session(
        repo,
        auth,
        bank_account_id=bank_account_id,
        period_from=payload.period_from,
        period_to=payload.period_to,
        statement_closing_balance=payload.statement_closing_balance,
    )


@router.get("/bank-accounts/{bank_account_id}/reconciliation-sessions", response_model=list[SessionOut])
async def list_sessions(
    bank_account_id: str,
    auth: dict = Depends(get_current_user),
    repo: BankReconciliationRepository = Depends(get_repo),
):
    return await repo.list_sessions(bank_account_id)


@router.get("/reconciliation-sessions/{session_id}", response_model=SessionOut)
async def get_session(
    session_id: str,
    auth: dict = Depends(get_current_user),
    repo: BankReconciliationRepository = Depends(get_repo),
):
    return await recon_service.get_session_or_404(repo, session_id)


@router.get("/reconciliation-sessions/{session_id}/pending")
async def session_pending(
    session_id: str,
    auth: dict = Depends(get_current_user),
    repo: BankReconciliationRepository = Depends(get_repo),
):
    """Líneas de extracto y movimientos del ledger aún sin conciliar (panel doble de la UI)."""
    return await recon_service.session_pending(repo, session_id)


@router.get("/reconciliation-sessions/{session_id}/suggestions", response_model=list[SuggestionOut])
async def session_suggestions(
    session_id: str,
    auth: dict = Depends(get_current_user),
    repo: BankReconciliationRepository = Depends(get_repo),
):
    """Sugerencias 1:1 (monto exacto + fecha ±3 días). Solo propone — confirmar pasa por /matches."""
    return await recon_service.session_suggestions(repo, session_id)


# ── Matching ───────────────────────────────────────────────────────────────────

@router.get("/reconciliation-sessions/{session_id}/matches", response_model=list[MatchListItem])
async def list_matches(
    session_id: str,
    auth: dict = Depends(get_current_user),
    repo: BankReconciliationRepository = Depends(get_repo),
):
    """Grupos de match activos de la sesión (lista de conciliados; base del undo)."""
    return await repo.list_matches(session_id)


@router.post("/reconciliation-sessions/{session_id}/matches", response_model=MatchGroupOut)
async def create_match(
    session_id: str,
    payload: MatchCreateIn,
    auth: dict = Depends(get_current_user),
    repo: BankReconciliationRepository = Depends(get_repo),
):
    return await recon_service.create_match(
        repo,
        auth,
        session_id=session_id,
        statement_line_ids=[str(x) for x in payload.statement_line_ids],
        bank_movement_ids=[str(x) for x in payload.bank_movement_ids],
    )


@router.post("/reconciliation-sessions/{session_id}/matches/{match_group}/undo", response_model=UndoMatchOut)
async def undo_match(
    session_id: str,
    match_group: str,
    payload: UndoMatchIn,
    auth: dict = Depends(get_current_user),
    repo: BankReconciliationRepository = Depends(get_repo),
):
    return await recon_service.undo_match(
        repo, auth, match_group=match_group, undo_reason=payload.undo_reason
    )


@router.post("/reconciliation-sessions/{session_id}/close", response_model=SessionCloseOut)
async def close_session(
    session_id: str,
    payload: SessionCloseIn,
    auth: dict = Depends(get_current_user),
    repo: BankReconciliationRepository = Depends(get_repo),
):
    return await recon_service.close_session(
        repo, auth, session_id=session_id, close_reason=payload.close_reason
    )
