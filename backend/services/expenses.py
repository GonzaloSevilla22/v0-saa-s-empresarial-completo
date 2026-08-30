"""
Service de gastos — sólo validación y delegación (DEC-24).

gastos-forma-pago (D4): la unidad de trabajo es la RPC `SECURITY DEFINER`. Este
módulo NO evalúa guards de dominio (ni sesión de caja, ni período conciliado,
ni inmutabilidad): traduce el payload al contrato de la RPC, resuelve el
tri-estado con `model_fields_set` y mapea los ERRCODEs a HTTP.

Guard de rol: `require_role(["user","admin"])` como el hot path de ventas y
compras. El guard autoritativo por rol de cuenta es `is_account_writer` DENTRO
de cada RPC (P0401) — defensa en profundidad, no duplicación de lógica.
"""
from __future__ import annotations

import contextlib
import datetime
import uuid

import asyncpg
from fastapi import HTTPException

from backend.core.errors import (
    EXPENSE_ERRCODE_STATUS,
    EXPENSE_FIELD_BY_ERRCODE,
    ProblemHTTPException,
)
from backend.core.guards import require_role
from backend.repositories.expense_repository import ExpenseRepository
from backend.schemas.expenses import ExpenseCreate, ExpenseUpdate


def _pg_to_http(exc: asyncpg.PostgresError) -> HTTPException | None:
    """D19 — mapeo local de ERRCODEs del camino de gasto.

    `P0412` sube a 422 con `field = "bank_account_id"` SÓLO acá (en el resto de
    los callers conserva su 404 global: "cuenta bancaria no encontrada"). Un
    código fuera del mapa devuelve `None` para que la excepción original siga
    subiendo al handler global, que la resuelve como 500 genérico sin filtrar
    internals — este override no es un catch-all.
    """
    code = exc.sqlstate if hasattr(exc, "sqlstate") else None
    status = EXPENSE_ERRCODE_STATUS.get(code)
    if status is None:
        return None
    return ProblemHTTPException(
        status_code=status,
        detail=str(exc),
        code=code,
        field=EXPENSE_FIELD_BY_ERRCODE.get(code),
    )


@contextlib.contextmanager
def _pg_errors_as_problems():
    """Traduce los ERRCODEs de las tres RPCs de gasto a 7807, en un solo lugar.

    Se extrae porque el bloque aparecía idéntico en alta, edición y borrado
    (Regla de Tres). Un código fuera del mapa se re-lanza tal cual: el handler
    global lo resuelve como 500 genérico, sin filtrar internals.
    """
    try:
        yield
    except asyncpg.PostgresError as exc:
        mapped = _pg_to_http(exc)
        if mapped is None:
            raise
        raise mapped from exc


def _uid(value: uuid.UUID | None) -> str | None:
    return str(value) if value is not None else None


async def list_expenses(
    repo: ExpenseRepository,
    account_id: str,
    *,
    page: int,
    page_size: int,
    date_from: str | None = None,
    date_to: str | None = None,
    search: str | None = None,
    cost_center_id: str | None = None,
    payment_method_id: str | None = None,
) -> dict:
    """D18 — envelope estándar `{items,total,page,pages}` (v3-api-standards §2),
    misma plomería que `list_sales_paginated`."""
    df = datetime.date.fromisoformat(date_from) if date_from else None
    dt = datetime.date.fromisoformat(date_to) if date_to else None
    rows, total = await repo.list_paginated(
        account_id,
        page=page,
        page_size=page_size,
        date_from=df,
        date_to=dt,
        search=search,
        cost_center_id=cost_center_id,
        payment_method_id=payment_method_id,
    )
    pages = -(-total // page_size) if total > 0 else 0
    return {"items": rows, "total": total, "page": page, "pages": pages}


async def get_expense(repo: ExpenseRepository, account_id: str, expense_id: str) -> dict:
    record = await repo.get_by_id(expense_id, account_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Gasto no encontrado")
    return record


async def create_expense(
    repo: ExpenseRepository, auth: dict, account_id: str, payload: ExpenseCreate
) -> dict:
    require_role(auth, ["user", "admin"])
    with _pg_errors_as_problems():
        record = await repo.create(
            account_id,
            category=payload.category,
            amount=payload.amount,
            date=payload.date,
            description=payload.description,
            branch_id=_uid(payload.branch_id),
            cost_center_id=_uid(payload.cost_center_id),
            payment_method_id=_uid(payload.payment_method_id),
            cash_session_id=_uid(payload.cash_session_id),
            bank_account_id=_uid(payload.bank_account_id),
        )
    if record is None:
        raise HTTPException(status_code=500, detail="Error al crear el gasto")
    return record


async def update_expense(
    repo: ExpenseRepository, auth: dict, account_id: str, expense_id: str, payload: ExpenseUpdate
) -> dict:
    require_role(auth, ["user", "admin"])
    # D12 — tri-estado POR AUSENCIA: `model_fields_set` trae las claves que
    # vinieron en el JSON. NUNCA `is None`: un `null` explícito (desimputar) y
    # una clave ausente (preservar) tienen el mismo valor y distinto significado.
    sent = payload.model_fields_set
    with _pg_errors_as_problems():
        record = await repo.update(
            expense_id,
            account_id,
            category=payload.category,
            amount=payload.amount,
            date=payload.date,
            description=payload.description,
            payment_method_id=_uid(payload.payment_method_id),
            payment_method_provided="payment_method_id" in sent,
            branch_id=_uid(payload.branch_id),
            branch_provided="branch_id" in sent,
            cost_center_id=_uid(payload.cost_center_id),
            cost_center_provided="cost_center_id" in sent,
        )
    if record is None:
        raise HTTPException(status_code=404, detail="Gasto no encontrado")
    return record


async def delete_expense(
    repo: ExpenseRepository, auth: dict, account_id: str, expense_id: str
) -> dict:
    """Una sola llamada (D4): la RPC compensa los dos libros y borra, o falla
    entera. El P0404 lo levanta ella misma restringiendo por la cuenta de la
    sesión — no hay pre-chequeo acá, que sería una segunda consulta y una
    segunda definición de "existe para mí"."""
    require_role(auth, ["user", "admin"])
    with _pg_errors_as_problems():
        return await repo.delete(expense_id, account_id)
