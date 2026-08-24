"""C-25 v20-outbox-activation — OutboxRepository

Acceso a datos del outbox transaccional. Dos responsabilidades, y sólo dos:

  - `emit_event`  — PRODUCTOR. Inserta un evento de dominio en la misma
    transacción que la mutación (DEC-20). Lo usan `purchase_repository` y
    `stock_repository`.
  - `run_dispatch` — DISPARADOR. Invoca `rpc_process_outbox_dispatch`, el
    único despachador del outbox.

Qué se retiró y por qué (tenancy-guard-caja-outbox D4, hotfix 2026-08-24):
`fetch_pending_batch`, `mark_processed`, `insert_audit_log`,
`insert_email_log` y `claim_idempotency` implementaban en Python una segunda
versión —incompleta— de los consumers del relay. Corrían 2 de los 4
consumers (AuditLog y EmailNotification) y marcaban `processed_at` igual,
compitiendo con `rpc_process_outbox_dispatch` por el mismo flag: todo evento
que ganaba el relay Python perdía para siempre su asiento contable
(JournalEntry) y su notificación. Además insertaban directo en `audit_logs`,
`email_logs` y `operation_idempotency`, tablas sin policy de INSERT para
`authenticated` — ese camino se rompe entero el día que se encienda el Paso 2
de `v31-tenancy-pool-rls`. **No reintroducir consumers acá**: los cuatro
viven en la RPC, en un solo lugar y en un solo orden.
"""
from __future__ import annotations

from backend.repositories.base import BaseRepository


class OutboxRepository(BaseRepository):
    """Productor de eventos + disparador del despachador SQL."""

    async def run_dispatch(self, batch_limit: int = 100) -> int:
        """Corre una tanda del despachador y devuelve cuántos eventos cerró.

        `rpc_process_outbox_dispatch` (SECURITY DEFINER) selecciona hasta
        `batch_limit` eventos pendientes con `FOR UPDATE SKIP LOCKED`,
        ejecuta los cuatro consumers por evento con aislamiento propio
        (`BEGIN/EXCEPTION/END`) y marca `processed_at` sólo si todos los
        consumers activos de ese evento tuvieron éxito.

        El default 100 es el mismo tamaño de lote que usa el pg_cron job
        `relay-process-outbox`.
        """
        procesados = await self._conn.fetchval(
            "SELECT public.rpc_process_outbox_dispatch($1::int)",
            batch_limit,
        )
        return procesados or 0

    async def emit_event(
        self,
        account_id: str,
        event_type: str,
        aggregate_type: str,
        aggregate_id: str,
        payload: dict,
    ) -> str:
        """INSERT a domain event into public.events within the current transaction.

        Must be called within the same transaction as the mutation (DEC-20).
        Returns the new event id.
        """
        import json
        row = await self._conn.fetchrow(
            """
            INSERT INTO public.events
              (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
            VALUES ($1::uuid, $2::text, $3::text, $4::uuid, $5::jsonb, now())
            RETURNING id
            """,
            account_id,
            event_type,
            aggregate_type,
            aggregate_id,
            json.dumps(payload),
        )
        return str(row["id"])
