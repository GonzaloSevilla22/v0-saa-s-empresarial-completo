"""C-25 v20-outbox-activation — disparador manual del outbox.

Endpoint: POST /outbox/process-pending
  Disparador MANUAL e idempotente del relay, para debugging y operaciones
  puntuales. **No lo llama nadie automáticamente**: el despacho real lo hace
  el pg_cron job `relay-process-outbox`, que cada minuto ejecuta
  `SELECT public.rpc_process_outbox_dispatch(100)` directamente contra la DB
  (pivot de C-25 — el docstring previo afirmaba que el cron llamaba a este
  endpoint, y no era cierto desde entonces).

Un solo despachador (tenancy-guard-caja-outbox D4): este endpoint delega en
`rpc_process_outbox_dispatch`, la MISMA función que corre el cron, que
ejecuta los cuatro consumers (AuditLog, EmailNotification, JournalEntry,
Notification) y recién después marca `processed_at`. Hasta este hotfix había
un segundo relay en Python (`OutboxRelayService`) que corría sólo dos de los
cuatro y marcaba `processed_at` igual: todo evento que le ganaba al cron
perdía para siempre su asiento contable y su notificación. Ese servicio se
retiró; NO reintroducir un consumidor paralelo acá.

Autorización (tenancy-guard-caja-outbox D3):
  - `require_platform_admin` — el disparador recorre el outbox de TODOS los
    tenants por diseño, así que no es una operación de tenant. Antes sólo
    exigía `get_current_user`.
  - `get_service_conn` — camino de servicio (v31-tenancy-pool-rls D5): no
    recibe claims, no queda dentro de la transacción del request y nunca
    adopta el rol `authenticated`, sin importar el estado de las dos
    palancas del pool. Ésa es la razón por la que este endpoint sobrevive al
    `REVOKE` de `rpc_process_outbox_batch` / `rpc_mark_event_processed`
    (20261012000001) y al Paso 2 del pool.

3 capas: router → OutboxRepository → RPC. Sin service_role.
"""
from __future__ import annotations

import asyncpg
from fastapi import APIRouter, Depends

from backend.core.auth import get_current_user
from backend.core.database import get_service_conn
from backend.core.guards import require_platform_admin
from backend.repositories.outbox_repository import OutboxRepository

router = APIRouter(prefix="/outbox", tags=["outbox"])


@router.post("/process-pending")
async def process_pending_outbox(
    conn: asyncpg.Connection = Depends(get_service_conn),
    auth: dict = Depends(get_current_user),
) -> dict:
    """Dispara una corrida del relay del outbox. Solo admin de plataforma.

    Delega en `rpc_process_outbox_dispatch(100)` — el único despachador, el
    mismo que ejecuta el pg_cron job `relay-process-outbox` cada minuto.
    Devuelve cuántos eventos quedaron marcados como procesados en esta
    corrida. Un evento cuyo consumer falla queda `processed_at IS NULL` para
    reintentarse en el próximo tick (aislamiento por evento dentro de la RPC).
    """
    await require_platform_admin(conn, auth)
    procesados = await OutboxRepository(conn).run_dispatch()
    return {"processed": procesados}
