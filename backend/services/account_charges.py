"""
Service layer — cobranzas-vencimientos OQ-1: cambiar el vencimiento de un
cargo abierto (cliente o proveedor).

Guard: require_account_role(conn, auth, CAN_CONFIGURE) — mismo criterio de
rol de TENANT que cost_centers.py/payment_methods.py/product_categories.py
(D9 v31-authz-token-hook; CAN_CONFIGURE = {owner, admin} sin cambio de
comportamiento, v3-rbac-multirole Parte B D10/D15), en línea con el guard
is_account_writer (también owner/admin, ahora resuelto sobre el pivot) que
las RPCs re-verifican en la DB (defensa en profundidad).

Los ERRCODEs que lanzan rpc_update_customer_charge_due_date /
rpc_update_supplier_charge_due_date (P0400/P0401/P0403/P0404) ya están en el
mapeo GLOBAL (backend/core/errors.py, _BUSINESS_ERRCODE_STATUS) — no hace
falta ningún mapeo nuevo. El asyncpg.PostgresError se deja propagar sin
capturar, igual que en cost_centers.py/product_categories.py: el
asyncpg_error_handler de la app lo traduce a RFC 7807.
"""
from __future__ import annotations

import datetime

from backend.core.guards import require_account_role
from backend.core.rbac import CAN_CONFIGURE
from backend.repositories.account_charge_repository import AccountChargeRepository


async def update_customer_charge_due_date(
    repo: AccountChargeRepository,
    auth: dict,
    *,
    movement_id: str,
    due_date: datetime.date | None,
    reason: str | None,
    conn,
) -> dict:
    """Cambia el vencimiento de un cargo (sale/adjustment>0) abierto de la
    cuenta corriente de un cliente. Requiere rol de TENANT owner o admin."""
    await require_account_role(conn, auth, CAN_CONFIGURE)
    return await repo.update_customer_charge_due_date(movement_id, due_date, reason)


async def update_supplier_charge_due_date(
    repo: AccountChargeRepository,
    auth: dict,
    *,
    movement_id: str,
    due_date: datetime.date | None,
    reason: str | None,
    conn,
) -> dict:
    """Espejo exacto de update_customer_charge_due_date sobre la cuenta
    corriente de un proveedor (purchase/adjustment>0 es cargo)."""
    await require_account_role(conn, auth, CAN_CONFIGURE)
    return await repo.update_supplier_charge_due_date(movement_id, due_date, reason)
