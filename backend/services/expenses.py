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
from backend.repositories.operation_edit_repository import OperationEditRepository
from backend.services import operation_edit
from backend.schemas.expenses import ExpenseCreate, ExpenseUpdate


def _pg_to_http(exc: asyncpg.PostgresError, *, stable_edit_codes: bool = False) -> HTTPException | None:
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
    # edicion-operaciones-con-dinero (tanda B): los rechazos de la EDICIÓN (P0422 cash_intent_required, P0424, P0425, P0426,
    # P0403 money_edit_requires_admin…) viajan con el `code` ESTABLE de su token, no con el sqlstate. Los del alta y el
    # borrado conservan el suyo (el frontend ya los traduce por sqlstate).
    stable = operation_edit.stable_edit_code(exc) if stable_edit_codes else None
    return ProblemHTTPException(
        status_code=status,
        detail=str(exc),
        code=stable or code,
        field=EXPENSE_FIELD_BY_ERRCODE.get(code),
    )


@contextlib.contextmanager
def _pg_errors_as_problems(*, stable_edit_codes: bool = False):
    """Traduce los ERRCODEs de las tres RPCs de gasto a 7807, en un solo lugar.

    Se extrae porque el bloque aparecía idéntico en alta, edición y borrado
    (Regla de Tres). Un código fuera del mapa se re-lanza tal cual: el handler
    global lo resuelve como 500 genérico, sin filtrar internals.
    """
    try:
        yield
    except asyncpg.PostgresError as exc:
        mapped = _pg_to_http(exc, stable_edit_codes=stable_edit_codes)
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


def _expense_update_kwargs(payload: ExpenseUpdate) -> dict[str, object]:
    # D12 — tri-estado POR AUSENCIA: `model_fields_set` trae las claves que vinieron en el JSON. NUNCA `is None`: un `null`
    # explícito (desimputar) y una clave ausente (preservar) tienen el mismo valor y distinto significado.
    sent = payload.model_fields_set
    return {
        "category": payload.category,
        "amount": payload.amount,
        "date": payload.date,
        "description": payload.description,
        "payment_method_id": _uid(payload.payment_method_id),
        "payment_method_provided": "payment_method_id" in sent,
        "branch_id": _uid(payload.branch_id),
        "branch_provided": "branch_id" in sent,
        "cost_center_id": _uid(payload.cost_center_id),
        "cost_center_provided": "cost_center_id" in sent,
        # edicion-operaciones-con-dinero (tanda B): intenciones de caja y banco (tri-estado por ausencia). El gasto no tiene
        # vencimiento: sin cuenta corriente de la parte.
        **operation_edit.money_intent_kwargs(payload, with_due_date=False),
    }


async def update_expense(
    repo: ExpenseRepository, auth: dict, account_id: str, expense_id: str, payload: ExpenseUpdate, *, conn
) -> dict:
    require_role(auth, ["user", "admin"])
    kwargs = _expense_update_kwargs(payload)

    async def _preview() -> dict:
        return await repo.update(expense_id, account_id, **kwargs, dry_run=True) or {}

    # edicion-operaciones-con-dinero (tanda B, OQ-4): corregir DINERO ya registrado exige CAN_CORRECT_MONEY (espejo de la RPC).
    await operation_edit.guard_money_correction(conn, auth, _preview)
    with _pg_errors_as_problems(stable_edit_codes=True):
        record = await repo.update(expense_id, account_id, **kwargs)
    if record is None:
        raise HTTPException(status_code=404, detail="Gasto no encontrado")
    return record


async def preview_expense_edit(
    repo: ExpenseRepository, auth: dict, account_id: str, expense_id: str, payload: ExpenseUpdate
) -> dict:
    """edicion-operaciones-con-dinero (D13): el PLAN de la edición, calculado por la MISMA RPC en seco (sin escribir)."""
    require_role(auth, ["user", "admin"])
    with _pg_errors_as_problems(stable_edit_codes=True):
        result = await repo.update(expense_id, account_id, **_expense_update_kwargs(payload), dry_run=True)
    if result is None:
        raise HTTPException(status_code=404, detail="Gasto no encontrado")
    return result


async def list_expense_edits(repo: OperationEditRepository, expense_id: str) -> list[dict]:
    """Historial de ediciones del gasto (más reciente primero), filtrado por la cuenta del usuario."""
    return await operation_edit.list_edits(repo, "expense", expense_id)


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


# ── importador-gastos-transaccional ─────────────────────────────────────────


async def import_expenses(
    repo: ExpenseRepository,
    auth: dict,
    *,
    idempotency_key: str,
    rows_json: str,
    file_name: str,
    file_hash: str,
    default_payment_method_id: str | None,
    default_branch_id: str | None,
    default_cost_center_id: str | None,
    fallback_bank_account_id: str | None,
    dry_run: bool,
) -> dict:
    """Traduce el payload y delega en `rpc_import_expenses`. CERO reglas de
    dominio nuevas acá (D1 del design) — si aparece un `if` de negocio, está
    en la capa equivocada.

    `_pg_errors_as_problems()` sólo traduce los ERRCODEs que SÍ escapan de la
    RPC: forma del payload (P0427). Los errores de FILA nunca escapan como
    excepción (D2 del design) — viajan en el `errors[]` del retorno normal,
    así que esta RPC responde siempre `200` salvo por un problema real de
    protocolo (payload malformado, tope excedido, sin rol, sin clave).
    """
    require_role(auth, ["user", "admin"])
    with _pg_errors_as_problems():
        return await repo.import_batch(
            idempotency_key=idempotency_key,
            rows_json=rows_json,
            file_name=file_name,
            file_hash=file_hash,
            default_payment_method_id=_uid(default_payment_method_id),
            default_branch_id=_uid(default_branch_id),
            default_cost_center_id=_uid(default_cost_center_id),
            fallback_bank_account_id=_uid(fallback_bank_account_id),
            dry_run=dry_run,
        )
