"""Servicio compartido de la edición con dinero (edicion-operaciones-con-dinero, tanda B, grupo 10).

Tres piezas que las tres operaciones (venta, compra y gasto) comparten y que NO son lógica de negocio de dinero —esa vive
en la RPC (`_op_edit_plan`)—:

  · `money_intent_kwargs`: traduce el tri-estado por AUSENCIA (`model_fields_set`) de caja, banco y vencimiento al par
    (valor, `*_provided`) que la RPC espera. NUNCA `is None`: un `null` explícito y una clave ausente tienen el mismo
    valor y distinto significado.
  · `edit_errors_as_problems`: los rechazos de la RPC (P0422 cash_intent_required, P0424, P0425, P0426, P0403
    money_edit_requires_admin, P0423 fiscal…) viajan como RFC 7807 con el `code` ESTABLE de su token.
  · `guard_money_correction`: el guard del servicio de OQ-4, ESPEJO de la RPC. Corregir dinero ya registrado es del dueño o un
    administrador (`CAN_CORRECT_MONEY`); una edición que no escribe en ningún libro sigue con la autorización de siempre. Al
    servicio no le toca decidir si una edición escribe dinero (lo decide el plan), así que un actor sin la capacidad pide la
    vista previa —la misma RPC en seco, sin efectos— y corta con 403 antes de la edición real si el plan escribe. La RPC
    sigue siendo la autoridad: este corte evita el viaje y nombra el motivo.
"""
from __future__ import annotations

import contextlib
import datetime
import uuid
from typing import Awaitable, Callable

import asyncpg

from backend.core.errors import ProblemHTTPException, pg_stable_code, problem_from_pg_error
from backend.core.guards import has_account_role
from backend.core.rbac import CAN_CORRECT_MONEY
from backend.repositories.operation_edit_repository import OperationEditRepository

MONEY_EDIT_REQUIRES_ADMIN = "money_edit_requires_admin"

# Tokens de rechazo de la edición con dinero (los escribe la base al principio del mensaje: «token: texto»).
EDIT_TOKENS: frozenset[str] = frozenset(
    {
        MONEY_EDIT_REQUIRES_ADMIN,
        "cash_intent_required",
        "reversal_would_go_negative",
        "no_open_session_for_reversal",
        "bank_period_reconciled",
        "bank_account_required_for_expense",
        "bank_account_requires_bank_kind",
        "credit_requires_client",
        "credit_requires_supplier",
        "due_date_before_charge",
        "cash_optin_requires_cash_kind",
        "cash_optin_requires_open_session",
        "cash_optin_requires_today",
    }
)

# action de audit_logs por tipo de operación (D14).
EDIT_ACTIONS: dict[str, str] = {
    "sale": "sale_operation.edited",
    "purchase": "purchase_operation.edited",
    "expense": "expense.edited",
}


def _uid(value: uuid.UUID | None) -> str | None:
    return str(value) if value is not None else None


def money_intent_kwargs(payload, *, with_due_date: bool = True) -> dict[str, object]:
    """Intenciones de caja, banco y vencimiento, en el contrato (valor, `*_provided`) de la RPC."""
    sent = payload.model_fields_set
    kwargs: dict[str, object] = {
        "cash_session_id": _uid(payload.cash_session_id),
        "cash_provided": "cash_session_id" in sent,
        "bank_account_id": _uid(payload.bank_account_id),
        "bank_account_provided": "bank_account_id" in sent,
        "reason": payload.reason,
    }
    if with_due_date:
        due: datetime.date | None = payload.due_date
        kwargs["due_date"] = due
        kwargs["due_date_provided"] = "due_date" in sent
    return kwargs


def stable_edit_code(exc: asyncpg.PostgresError) -> str | None:
    """El `code` estable del token de un rechazo de EDICIÓN, o `None` si no es uno de los tokens de la edición con dinero (el
    llamador conserva el sqlstate). Una lista cerrada: no pretende ser un traductor general."""
    code = pg_stable_code(exc)
    return code if code in EDIT_TOKENS else None


@contextlib.contextmanager
def edit_errors_as_problems():
    """Traduce los errores de negocio de las RPCs de edición a RFC 7807 con el `code` estable de su token. Un sqlstate
    fuera del mapa se re-lanza tal cual: el handler global lo resuelve como 500 genérico, sin filtrar internals."""
    try:
        yield
    except asyncpg.PostgresError as exc:
        # Sólo los tokens de la edición con dinero cambian de `code`; el resto (P0423 fiscal, P0409 stock, P0404…) conserva
        # el camino de siempre —el handler global, con el sqlstate—, que el frontend ya traduce.
        if stable_edit_code(exc) is None:
            raise
        problem = problem_from_pg_error(exc)
        if problem is None:
            raise
        raise problem from exc


async def guard_money_correction(conn, auth: dict, preview: Callable[[], Awaitable[dict]]) -> None:
    """Corta con 403 `money_edit_requires_admin` si el actor no tiene CAN_CORRECT_MONEY y el plan escribe dinero."""
    if await has_account_role(conn, auth, CAN_CORRECT_MONEY):
        return
    with edit_errors_as_problems():
        result = await preview()
    plan = result.get("plan") or {}
    if plan.get("writes_money"):
        raise ProblemHTTPException(
            status_code=403,
            detail=(
                f"{MONEY_EDIT_REQUIRES_ADMIN}: solo el dueño o un administrador corrigen dinero ya registrado — "
                "esta edición modifica la caja, el banco o la cuenta corriente"
            ),
            code=MONEY_EDIT_REQUIRES_ADMIN,
        )


async def list_edits(repo: OperationEditRepository, kind: str, entity_id: str) -> list[dict]:
    """Historial de ediciones de una venta, una compra o un gasto (más reciente primero)."""
    return await repo.list_edits(EDIT_ACTIONS[kind], entity_id)
