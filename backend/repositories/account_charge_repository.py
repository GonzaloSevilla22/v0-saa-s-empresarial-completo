"""
Repository — cobranzas-vencimientos OQ-1: cambiar el vencimiento de un cargo
abierto en la cuenta corriente de un cliente o un proveedor.

Archivo NUEVO (no toca customer_account_repository.py / supplier_account_
repository.py, que otro agente está editando en paralelo). JWT-passthrough
via base.py. Mutación vía SELECT rpc_...(args) → SECURITY DEFINER RPCs
(rpc_update_customer_charge_due_date / rpc_update_supplier_charge_due_date,
migración 20261033000001_charge_due_date_update.sql).
"""
from __future__ import annotations

import datetime
import json

from backend.repositories.base import BaseRepository


def _jsonb(value) -> dict:
    """asyncpg devuelve jsonb como str cuando no hay codec registrado."""
    return json.loads(value) if isinstance(value, str) else value


class AccountChargeRepository(BaseRepository):
    """Repository para el cambio de vencimiento de un cargo (cliente/proveedor)."""

    async def update_customer_charge_due_date(
        self,
        movement_id: str,
        due_date: datetime.date | None,
        reason: str | None,
    ) -> dict:
        """Invoca rpc_update_customer_charge_due_date.

        p_due_date NULL limpia el vencimiento (nunca un error). Errores de
        tenencia/estado (P0400/P0401/P0403/P0404) propagan como
        asyncpg.PostgresError — el service NO los captura, quedan mapeados
        por el handler global (backend/core/errors.py, _BUSINESS_ERRCODE_STATUS).
        """
        row = await self.fetchrow(
            "SELECT public.rpc_update_customer_charge_due_date($1::uuid, $2::date, $3::text) AS result",
            movement_id,
            due_date,
            reason,
        )
        return _jsonb(row["result"])

    async def update_supplier_charge_due_date(
        self,
        movement_id: str,
        due_date: datetime.date | None,
        reason: str | None,
    ) -> dict:
        """Invoca rpc_update_supplier_charge_due_date — espejo exacto de
        update_customer_charge_due_date sobre supplier_account_movements."""
        row = await self.fetchrow(
            "SELECT public.rpc_update_supplier_charge_due_date($1::uuid, $2::date, $3::text) AS result",
            movement_id,
            due_date,
            reason,
        )
        return _jsonb(row["result"])
