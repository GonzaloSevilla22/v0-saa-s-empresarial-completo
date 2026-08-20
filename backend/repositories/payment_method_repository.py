from __future__ import annotations

import datetime

import asyncpg

from backend.repositories.base import BaseRepository


class PaymentMethodRepository(BaseRepository):
    """Repository for payment_methods catalog (metodos-pago-operaciones).

    Espejo de CostCenterRepository: escribe directo a la tabla (sin RPC
    SECURITY DEFINER — este catálogo no maneja dinero). RLS (is_account_writer)
    actúa como gate a nivel DB; la capa de servicio agrega require_account_role
    como defensa en profundidad. JWT-passthrough (invariante de BaseRepository)
    mantiene la RLS activa.
    """

    _COLUMNS = "id, account_id, name, kind, is_active, sort_order, created_at, bank_account_id"

    async def list_by_account(
        self,
        account_id: str,
        *,
        active_only: bool = True,
    ) -> list[dict]:
        """Return payment methods for the account.

        Args:
            account_id: The tenant account UUID (scoped by RLS too).
            active_only: If True (default), only return is_active=true rows.
                         If False, return all rows (for admin management screen).
        """
        # RN-B1 (v3-soft-delete-policy): ambas ramas excluyen filas BORRADAS
        # (deleted_at IS NULL). active_only=False sigue mostrando las
        # DESACTIVADAS (is_active=false) — baja lógica reversible, no borrado.
        if active_only:
            return await self.fetch(
                f"""
                SELECT {self._COLUMNS}
                FROM   payment_methods
                WHERE  account_id = $1
                  AND  is_active = TRUE
                  AND  deleted_at IS NULL
                ORDER BY sort_order, name
                """,
                account_id,
            )
        return await self.fetch(
            f"""
            SELECT {self._COLUMNS}
            FROM   payment_methods
            WHERE  account_id = $1
              AND  deleted_at IS NULL
            ORDER BY sort_order, name
            """,
            account_id,
        )

    async def get_by_id(
        self,
        payment_method_id: str,
        account_id: str,
    ) -> asyncpg.Record | None:
        """Fetch a single payment method by id scoped to the account."""
        return await self.fetchrow(
            f"""
            SELECT {self._COLUMNS}
            FROM   payment_methods
            WHERE  id = $1 AND account_id = $2
              AND  deleted_at IS NULL
            """,
            payment_method_id,
            account_id,
        )

    async def create(
        self,
        account_id: str,
        name: str,
        kind: str,
        sort_order: int = 0,
    ) -> asyncpg.Record | None:
        """Insert a new payment method and return the created row.

        The UNIQUE(account_id, lower(name)) partial index enforces
        case-insensitive uniqueness among LIVE rows at the DB level. Callers
        should normalize name (strip) before calling this; the service layer
        is responsible for trimming.

        `bank_account_id` no se acepta en el alta (D7 — pos-banco-
        movimientos): nace siempre NULL, igual que las 210 filas sembradas
        por provisioning; se asigna después vía `update`.
        """
        return await self.fetchrow(
            f"""
            INSERT INTO payment_methods (account_id, name, kind, sort_order)
            VALUES ($1, $2, $3, $4)
            RETURNING {self._COLUMNS}
            """,
            account_id,
            name,
            kind,
            sort_order,
        )

    async def update(
        self,
        payment_method_id: str,
        account_id: str,
        name: str,
        sort_order: int | None,
        *,
        bank_account_id: str | None = None,
        bank_account_provided: bool = False,
    ) -> asyncpg.Record | None:
        """Update name/sort_order/bank_account_id of a payment method. `kind`
        is immutable by design (D2: renombrar no cambia la semántica) — no
        hay columna kind en este UPDATE a propósito.

        pos-banco-movimientos (D7): `bank_account_id` es tri-estado por
        AUSENCIA — `bank_account_provided=False` preserva el valor vigente
        (COALESCE), `True` lo asigna o desasigna (incluido a NULL, explícito).
        Devuelve None si la fila no existe/no pertenece a la cuenta; la
        validación de la cuenta bancaria (pertenencia/activa/no-borrada,
        kind bancario del método) corre en el SERVICE antes de llamar acá
        (P0412/422 — mismo criterio que costo/branch en las RPCs SQL).
        """
        if bank_account_provided:
            return await self.fetchrow(
                f"""
                UPDATE payment_methods
                SET    name             = $3,
                       sort_order       = COALESCE($4, sort_order),
                       bank_account_id  = $5
                WHERE  id = $1 AND account_id = $2
                  AND  deleted_at IS NULL
                RETURNING {self._COLUMNS}
                """,
                payment_method_id,
                account_id,
                name,
                sort_order,
                bank_account_id,
            )
        return await self.fetchrow(
            f"""
            UPDATE payment_methods
            SET    name       = $3,
                   sort_order = COALESCE($4, sort_order)
            WHERE  id = $1 AND account_id = $2
              AND  deleted_at IS NULL
            RETURNING {self._COLUMNS}
            """,
            payment_method_id,
            account_id,
            name,
            sort_order,
        )

    async def get_bank_account_for_validation(
        self,
        bank_account_id: str,
        account_id: str,
    ) -> asyncpg.Record | None:
        """pos-banco-movimientos (D7): valida la cuenta bancaria destino
        ANTES del UPDATE — pertenece a la cuenta, activa, no borrada. Espejo
        Python de la validación que `_pay_resolve_bank_account` hace en SQL
        para el camino operativo (D2); acá corre del lado del catálogo,
        donde la escritura es directa (sin RPC SECURITY DEFINER)."""
        return await self.fetchrow(
            """
            SELECT id FROM bank_accounts
            WHERE id = $1 AND account_id = $2
              AND is_active = TRUE AND deleted_at IS NULL
            """,
            bank_account_id,
            account_id,
        )

    async def deactivate(
        self,
        payment_method_id: str,
        account_id: str,
    ) -> asyncpg.Record | None:
        """Soft-delete: set is_active=false. Preserves historical references.

        Physical DELETE is intentionally avoided so that existing sales/
        purchases that reference this payment method keep their
        payment_method_id intact (the ON DELETE SET NULL FK is a
        last-resort safety net only) — mismo criterio que CostCenterRepository.
        """
        return await self.fetchrow(
            f"""
            UPDATE payment_methods
            SET    is_active = FALSE
            WHERE  id = $1 AND account_id = $2
              AND  deleted_at IS NULL
            RETURNING {self._COLUMNS}
            """,
            payment_method_id,
            account_id,
        )

    async def get_report(
        self,
        account_id: str,
        start: datetime.date,
        end: datetime.date,
    ) -> list[asyncpg.Record]:
        """Read-model: ventas y compras agregadas por forma de pago en un
        rango (rpc_payment_method_report, SECURITY DEFINER — espejo de
        rpc_cost_center_report). auth.uid() viaja vía JWT-passthrough de la
        conexión; el RPC verifica membership contra p_account_id (P0401)."""
        return await self.fetch(
            "SELECT * FROM public.rpc_payment_method_report($1::uuid, $2::date, $3::date)",
            account_id,
            start,
            end,
        )
