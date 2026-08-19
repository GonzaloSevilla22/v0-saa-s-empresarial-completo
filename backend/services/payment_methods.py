from __future__ import annotations

import datetime

from fastapi import HTTPException

from backend.core.guards import require_account_role
from backend.repositories.payment_method_repository import PaymentMethodRepository
from backend.schemas.payment_methods import PAYMENT_METHOD_KINDS


async def list_payment_methods(
    repo: PaymentMethodRepository,
    auth: dict,
    account_id: str,
    *,
    active_only: bool = True,
) -> list:
    """List payment methods for the account. Available to all members (read-only)."""
    # No guard here — reads are permitted to all account members, igual que
    # cost_centers. El SELECT policy (RLS members_select) ya limita al scope
    # de la cuenta.
    return await repo.list_by_account(account_id, active_only=active_only)


async def create_payment_method(
    repo: PaymentMethodRepository,
    auth: dict,
    account_id: str,
    name: str,
    kind: str,
    sort_order: int,
    *,
    conn,
) -> dict:
    """Create a payment method. Requires TENANT role owner or admin.

    Espejo de create_cost_center (D9 de v31-authz-token-hook): gatea contra
    el rol de TENANT (account_members.role), con defence-in-depth vía RLS
    is_account_writer en la DB.
    """
    await require_account_role(conn, auth, ["owner", "admin"])
    if kind not in PAYMENT_METHOD_KINDS:
        raise HTTPException(
            status_code=422,
            detail=f"kind inválido: se requiere uno de {', '.join(PAYMENT_METHOD_KINDS)}",
        )
    normalised_name = name.strip()
    record = await repo.create(account_id, name=normalised_name, kind=kind, sort_order=sort_order)
    if record is None:
        raise HTTPException(status_code=500, detail="Error al crear la forma de pago")
    return dict(record)


async def update_payment_method(
    repo: PaymentMethodRepository,
    auth: dict,
    account_id: str,
    payment_method_id: str,
    name: str,
    sort_order: int | None,
    *,
    conn,
) -> dict:
    """Update name/sort_order of a payment method. Requires TENANT role owner or admin.

    `kind` es inmutable (D2: renombrar no cambia la semántica) — no se acepta
    en este payload.
    """
    await require_account_role(conn, auth, ["owner", "admin"])
    normalised_name = name.strip()
    record = await repo.update(payment_method_id, account_id, name=normalised_name, sort_order=sort_order)
    if record is None:
        raise HTTPException(status_code=404, detail="Forma de pago no encontrada")
    return dict(record)


async def deactivate_payment_method(
    repo: PaymentMethodRepository,
    auth: dict,
    account_id: str,
    payment_method_id: str,
    *,
    conn,
) -> dict:
    """Soft-delete a payment method (is_active=false). Requires TENANT role owner or admin.

    Preserva imputaciones históricas: ventas/compras existentes conservan su
    payment_method_id (el nombre sigue siendo legible vía JOIN).
    """
    await require_account_role(conn, auth, ["owner", "admin"])
    record = await repo.deactivate(payment_method_id, account_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Forma de pago no encontrada")
    return dict(record)


async def get_payment_method_report(
    repo: PaymentMethodRepository,
    auth: dict,
    account_id: str,
    start: datetime.date,
    end: datetime.date,
) -> list[dict]:
    """Read-model de distribución por forma de pago. Disponible a todo
    miembro de la cuenta (sin gate de plan, D10) — el propio RPC
    (SECURITY DEFINER) verifica membership contra account_id (P0401)."""
    if end < start:
        raise HTTPException(status_code=422, detail="El rango de fechas es inválido: end < start")
    rows = await repo.get_report(account_id, start, end)
    return [dict(r) for r in rows]
