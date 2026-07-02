"""
Service para bank-reconciliation C3.

Orquestación + guards de rol; SIN lógica de dominio duplicada — la
transaccionalidad, la FSM y los invariantes (P0431/P0432/P0433/P0434)
viven en las RPCs SECURITY DEFINER (design D6: el equivalente del UoW son
los RPCs, la transacción vive en Postgres).

Guard: require_role(["user","admin"]) como el hot path (sales/purchases) —
el guard autoritativo por rol de cuenta es is_account_writer en la DB.
"""
from __future__ import annotations

from datetime import date
from decimal import Decimal

from fastapi import HTTPException

from backend.core.guards import require_role
from backend.repositories.bank_reconciliation_repository import (
    BankReconciliationRepository,
)


async def import_statement(
    repo: BankReconciliationRepository,
    auth: dict,
    *,
    bank_account_id: str,
    idempotency_key: str,
    file_name: str,
    file_hash: str,
    lines_json: str,
) -> dict:
    require_role(auth, ["user", "admin"])
    return await repo.import_statement(
        idempotency_key=idempotency_key,
        bank_account_id=bank_account_id,
        file_name=file_name,
        file_hash=file_hash,
        lines_json=lines_json,
    )


async def open_session(
    repo: BankReconciliationRepository,
    auth: dict,
    *,
    bank_account_id: str,
    period_from: date,
    period_to: date,
    statement_closing_balance: Decimal,
) -> dict:
    require_role(auth, ["user", "admin"])
    return await repo.open_session(
        bank_account_id=bank_account_id,
        period_from=period_from,
        period_to=period_to,
        statement_closing_balance=statement_closing_balance,
    )


async def close_session(
    repo: BankReconciliationRepository,
    auth: dict,
    *,
    session_id: str,
    close_reason: str | None,
) -> dict:
    require_role(auth, ["user", "admin"])
    return await repo.close_session(session_id=session_id, close_reason=close_reason)


async def create_match(
    repo: BankReconciliationRepository,
    auth: dict,
    *,
    session_id: str,
    statement_line_ids: list[str],
    bank_movement_ids: list[str],
) -> dict:
    require_role(auth, ["user", "admin"])
    return await repo.create_match(
        session_id=session_id,
        statement_line_ids=statement_line_ids,
        bank_movement_ids=bank_movement_ids,
    )


async def undo_match(
    repo: BankReconciliationRepository,
    auth: dict,
    *,
    match_group: str,
    undo_reason: str,
) -> dict:
    require_role(auth, ["user", "admin"])
    return await repo.undo_match(match_group=match_group, undo_reason=undo_reason)


async def register_manual_movement(
    repo: BankReconciliationRepository,
    auth: dict,
    *,
    bank_account_id: str,
    idempotency_key: str,
    amount: Decimal,
    movement_type: str,
    value_date: date | None,
    description: str | None,
) -> dict:
    """'Solo anotar' (V1): cargo del extracto sin contraparte → bank_movement manual."""
    require_role(auth, ["user", "admin"])
    return await repo.register_manual_movement(
        idempotency_key=idempotency_key,
        bank_account_id=bank_account_id,
        amount=amount,
        movement_type=movement_type,
        value_date=value_date,
        description=description,
    )


# ── Lecturas (sin guard de rol: RLS SELECT ya limita al tenant) ────────────────

async def get_session_or_404(
    repo: BankReconciliationRepository, session_id: str
) -> dict:
    record = await repo.get_session(session_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Sesión de conciliación no encontrada")
    return dict(record)


async def session_suggestions(
    repo: BankReconciliationRepository, session_id: str
) -> list[dict]:
    session = await get_session_or_404(repo, session_id)
    return await repo.suggestions(
        bank_account_id=str(session["bank_account_id"]),
        period_from=session["period_from"],
        period_to=session["period_to"],
    )


async def session_pending(
    repo: BankReconciliationRepository, session_id: str
) -> dict:
    session = await get_session_or_404(repo, session_id)
    lines = await repo.pending_lines(
        bank_account_id=str(session["bank_account_id"]),
        period_from=session["period_from"],
        period_to=session["period_to"],
    )
    movements = await repo.pending_movements(
        bank_account_id=str(session["bank_account_id"]),
        period_to=session["period_to"],
    )
    return {"session": session, "pending_lines": lines, "pending_movements": movements}
