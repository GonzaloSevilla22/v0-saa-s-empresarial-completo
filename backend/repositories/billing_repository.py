from __future__ import annotations

import asyncpg

from backend.repositories.base import BaseRepository

# Recibos = pagos que el cliente puede ver/descargar: alta única legacy
# ('plan_upgraded', C-17) + cobro recurrente de suscripción
# ('subscription_payment_approved', mp-real-subscriptions). bugfix
# 2026-09-04 (bugfix/receipts-subscription-charges): antes de esta
# constante, el SELECT paginado y el count(*) filtraban 'plan_upgraded' por
# separado y la primera suscripción real quedó invisible en "Recibos de
# Pago" (0 receipt_number, 0 aparición en la lista) — regla del proyecto
# "reutilización antes que repetición": UNA sola tupla, nunca dos listas de
# literales que puedan divergir.
RECEIPT_EVENT_TYPES: tuple[str, ...] = ("plan_upgraded", "subscription_payment_approved")
_RECEIPT_EVENT_TYPES_SQL = ", ".join(f"'{t}'" for t in RECEIPT_EVENT_TYPES)

# Se accede con una conexión service (BYPASSRLS) porque el admin lee pagos de
# TODAS las cuentas; el gating de admin lo hace `require_admin` en el router.
_RECEIPT_SELECT = f"""
    SELECT be.id,
           be.receipt_number,
           be.mercadopago_payment_id AS payment_id,
           be.to_plan                AS plan,
           be.amount,
           be.created_at,
           u.email                   AS customer_email,
           p.name                    AS customer_name
    FROM billing_events be
    JOIN auth.users u ON u.id = be.user_id
    LEFT JOIN profiles p ON p.id = be.user_id
    WHERE be.event_type IN ({_RECEIPT_EVENT_TYPES_SQL})
"""


# mp-real-subscriptions follow-up (task 8.8): selector de cuenta destino de
# la cola de conciliación manual de suscripciones ambiguas. `accounts` no
# tiene nombre de negocio propio — se busca por el email/nombre del owner
# (mismo join que _RECEIPT_SELECT). Conexión service (BYPASSRLS): el admin
# busca entre TODAS las cuentas, no solo la propia.
_ACCOUNT_SEARCH_SELECT = """
    SELECT a.id           AS account_id,
           u.email        AS owner_email,
           p.name         AS owner_name,
           a.billing_plan AS billing_plan
    FROM public.accounts a
    JOIN auth.users u ON u.id = a.owner_user_id
    LEFT JOIN profiles p ON p.id = a.owner_user_id
    WHERE u.email ILIKE $1 OR p.name ILIKE $1 OR p.business_name ILIKE $1
    ORDER BY u.email
    LIMIT $2
"""


class BillingRepository(BaseRepository):
    async def list_receipts(
        self, limit: int, offset: int
    ) -> tuple[list[asyncpg.Record], int]:
        total: int = await self._conn.fetchval(
            f"SELECT count(*) FROM billing_events WHERE event_type IN ({_RECEIPT_EVENT_TYPES_SQL})"
        ) or 0
        rows: list[asyncpg.Record] = await self._conn.fetch(
            _RECEIPT_SELECT + " ORDER BY be.created_at DESC LIMIT $1 OFFSET $2",
            limit,
            offset,
        )
        return rows, total

    async def get_receipt(self, billing_event_id: str) -> asyncpg.Record | None:
        return await self._conn.fetchrow(
            _RECEIPT_SELECT + " AND be.id = $1::uuid",
            billing_event_id,
        )

    async def search_accounts(self, query: str, limit: int = 20) -> list[asyncpg.Record]:
        """Busca cuentas por email o nombre del owner (task 8.8). `query`
        se envuelve en `%...%` para ILIKE — el caller ya valida un largo
        mínimo (evita escanear con un patrón `%%` demasiado amplio)."""
        pattern = f"%{query.strip()}%"
        return await self._conn.fetch(_ACCOUNT_SEARCH_SELECT, pattern, limit)
