## Context

El Modelo V3 §3 cierra la tríada "snapshot + historial + **aviso**". Los dos primeros ya están en producción (`v3-snapshot-pattern`, `v3-document-status-history`). Falta el aviso in-app.

Estado actual verificado en el código:

- **Outbox maduro**: `public.events` (schema V2 canónico) + relay `rpc_process_outbox_dispatch` (pg_cron, `SECURITY DEFINER`, `FOR UPDATE SKIP LOCKED`, per-event `BEGIN/EXCEPTION/END`) con **3 consumers**: AuditLog (1), EmailNotification (2), JournalEntry (3). Idempotencia por `(event_id, consumer_type)` sobre `operation_idempotency` con `operation_kind = 'event_consumer'` (marcador sentinel `00000000-…`; el FK a `auth.users` fue dropeado en `20260804000005`). Última migración: `20260807000001`.
- **Roles**: `account_members.role` es binario hoy — `CHECK (role IN ('owner', 'member'))` (`20260606000001`). No existe el catálogo funcional del V3 (seller/cashier/stock/purchases/admin) — eso llega con `v3-rbac-multirole` (CRÍTICO, solo-análisis). Helper `current_account_ids()` = `SETOF uuid` de las cuentas del usuario (STABLE SECURITY DEFINER).
- **Frontend**: header = `frontend/components/dashboard/breadcrumb-nav.tsx` (client, dentro de `(dashboard)/layout.tsx`). **No hay ninguna suscripción Supabase Realtime en el frontend hoy** — esta sería la primera. Cliente browser en `frontend/lib/supabase/client.ts`. Data fetching = React Query.
- **No confundir**: `sale_notifications` (`20260510232324`) es el log de envíos WhatsApp/email al cliente final. Fuera de alcance. No existe tabla `notifications`.
- **Legacy**: la spec `realtime-websocket` describe un WSManager propio con JWT por query param — exactamente lo que el V3 §10 **rechaza**. No se implementa ni se toca.

Restricciones: DEC-16 (Realtime se queda en Supabase, no migra a Python). Governance MEDIO. Migraciones a `supabase/migrations/`, CI las aplica al mergear (nunca a mano). Prod = `gxdhpxvdjjkmxhdkkwyb`.

## Goals / Non-Goals

**Goals:**
- Tabla `notifications` como read model efímero, escrita solo por el relay, con RLS por audiencia.
- Consumer 4 (Notification) en `rpc_process_outbox_dispatch`, mismo patrón exacto que el Consumer 3 (helper `SECURITY DEFINER`, idempotencia `(event_id, 'Notification')`, per-event isolation, no-op fuera de scope).
- Producers de los 5 eventos en-scope emitidos en la misma transacción de su mutación.
- Campana en el header con badge de no-leídas + dropdown + marcar-como-leída, alimentada por Supabase Realtime `postgres_changes` (sin polling) + resync al reconectar.
- Mapeo de audiencia por rol aislado en un único punto, migrable a `v3-rbac-multirole` sin reescribir el consumer.

**Non-Goals:**
- Ampliar el catálogo de roles (eso es `v3-rbac-multirole`). Aquí solo se mapea al binario `owner`/`member` vigente.
- Notificaciones por email/push/WhatsApp — el Email consumer (2) ya cubre email; esto es in-app.
- Preferencias por usuario (silenciar tipos), agrupación/digest, historial paginado infinito. Read model acotado con TTL.
- Tocar `sale_notifications`, `realtime-websocket`, o el backend Python.

## Decisions

### D1 — Realtime: `postgres_changes` sobre `notifications`, no `broadcast`

Se usa **`postgres_changes`** (INSERT) sobre `public.notifications`, no un canal `broadcast`. Razón central: **seguridad de audiencia sin filtrar en el cliente**. Con `postgres_changes`, Supabase Realtime aplica la **RLS de la tabla** al stream — un usuario solo recibe los INSERTs de las filas que su política `SELECT` le permitiría leer. La política ya filtra por `account_id IN current_account_ids()` **y** `auth.uid() = ANY(audience)`, así que el filtrado de audiencia vive en el servidor y es imposible de burlar desde el cliente. Con `broadcast` tendríamos que decidir el destinatario en el emisor y confiar en un `topic` por usuario/rol — más frágil y sin RLS de respaldo.

Requisito operativo: `ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;` y RLS habilitada (Realtime respeta RLS solo con RLS activa). El cliente se suscribe con `filter: account_id=in.(...)` como optimización de red, pero **la garantía es la RLS**, no el filter.

Alternativa descartada: `broadcast` desde un trigger con `realtime.broadcast_changes` — más código, decide audiencia en el server-side del emisor pero sin la red de RLS por fila, y agrega un canal por usuario que hay que autorizar aparte.

### D2 — Consumer 4 clonando el patrón del Consumer 3

Se agrega el Consumer 4 con `CREATE OR REPLACE FUNCTION rpc_process_outbox_dispatch` preservando byte-a-byte los consumers 1-3 (igual que hizo `journal_entry_schema` al agregar el 3). El bloque del Consumer 4 dentro del `LOOP`, después del 3:

```sql
IF v_event.event_type IN (
    'StockBelowMinimum','CashSessionClosed','FiscalDocumentRejected',
    'QuoteAccepted','TransferDispatched'
) THEN
  PERFORM public._notification_from_event(v_event);
END IF;
```

Toda la lógica (idempotencia, resolución de audiencia, severity, INSERT) vive en `_notification_from_event(public.events)` — `SECURITY DEFINER`, `SET search_path = public`, `REVOKE` de anon/authenticated/PUBLIC. La idempotencia usa el mismo INSERT-marcador que el Consumer 3: `(event_id, 'Notification')`, `operation_kind = 'event_consumer'` (ya aceptado por el CHECK desde `20260804000005`). Un fallo del helper → `RAISE` → lo captura el `EXCEPTION WHEN OTHERS` del sub-bloque per-event → el evento queda pending, el batch sigue.

Alternativa descartada: consumer inline en el dispatch (como el Email consumer 2). El helper aislado es preferible porque la resolución de audiencia es la parte volátil (cambia con RBAC) y conviene tenerla en una función sola.

### D3 — Resolución de `audience` por rol, aislada en un helper mapeable

`_notification_from_event` calcula `audience uuid[]` con una función interna `_notification_audience(account_id, target, branch_id)` donde `target` es un enum semántico del V3 (`ADMIN`, `PURCHASES`, `SELLER`, `BRANCH_DEST`, `URGENT_FISCAL`). Mapeo al catálogo binario actual:

| Evento | Target V3 | Mapeo hoy (owner/member) | Severity |
|---|---|---|---|
| `CashSessionClosed` (dif ≠ 0) | ADMIN | owner(s) de la cuenta | warning |
| `FiscalDocumentRejected` | URGENT_FISCAL | owner(s) de la cuenta | urgent |
| `StockBelowMinimum` | PURCHASES | owner(s) de la cuenta | warning |
| `QuoteAccepted` | SELLER | owner(s) + members de la cuenta | info |
| `TransferDispatched` | BRANCH_DEST | members ligados al branch destino; fallback owner(s) | info |

Como el catálogo es binario, casi todos los targets colapsan a "owners" salvo `SELLER` (owner+member) y `BRANCH_DEST` (por branch, con fallback). **Todo el mapeo está en `_notification_audience`**: cuando `v3-rbac-multirole` amplíe `account_members.role`, se reescribe solo esa función — el dispatch, los producers, la tabla y el frontend no cambian. `branch_id` de la notificación se toma del payload del evento (o del branch de la sesión/transfer).

Si el `audience` resuelto es vacío → no se inserta fila (nada dirigido a nadie), y el relay igual marca el evento processed (el marcador de idempotencia ya se reclamó).

### D4 — Enriquecimiento de payloads y producers nuevos

Auditoría de qué eventos ya se emiten:

| Evento | ¿Producer existe? | Acción |
|---|---|---|
| `CashSessionClosed` | No (C-28 cierra caja pero no emite) | **Agregar** producer en la RPC de cierre; payload: `session_id`, `branch_id`, `difference`, `closed_by` |
| `StockBelowMinimum` | No como evento outbox (existe lógica `check_low_stock` para AI alerts, no outbox) | **Agregar** producer donde el movimiento de stock deja producto/branch ≤ mínimo; payload: `product_id`, `branch_id`, `current_qty`, `min_qty` |
| `QuoteAccepted` | No (transición de estado existe en `v3-document-status-history`, sin evento) | **Agregar** producer en la transición a ACCEPTED; payload: `quote_id`, `seller_id`, `branch_id`, `total` |
| `TransferDispatched` | No | **Agregar** producer en el dispatch de `stock_transfer`; payload: `transfer_id`, `source_branch_id`, `destination_branch_id` |
| `FiscalDocumentRejected` | No como evento outbox (el rechazo CAE se registra en el doc fiscal) | **Agregar** producer en el path de rechazo de CAE; payload: `fiscal_document_id`, `error`, `branch_id` |

Todos los producers hacen `INSERT INTO public.events (...)` en la **misma transacción** de su mutación (DEC-20), stampando `account_id/event_type/aggregate_type/aggregate_id/payload/occurred_at`. Ningún producer existente se recrea. **Nota de scope**: cada producer toca la RPC/trigger de su dominio — es la parte más invasiva del change; se implementa con checkpoints (governance MEDIO), un producer por commit lógico.

### D5 — Marcar-como-leída: UPDATE con RLS (USING + WITH CHECK), no RPC

El marcar-leída es un UPDATE directo con política RLS, no una RPC. Regla dura Supabase: la política UPDATE necesita **`USING`** (qué filas puede tocar: las de su audiencia/cuenta) **y `WITH CHECK`** (qué puede quedar tras el update). El `WITH CHECK` impide reasignar la fila o mutar campos que no sean `read`/`read_at`. Como el único mutation-path del usuario es "poner read=true", un UPDATE guardado es más simple que una RPC `SECURITY DEFINER` y no expone superficie extra. La app llama `.update({ read: true, read_at: now }).eq('id', id)`; RLS hace el resto. Idempotente: re-marcar no cambia `read_at` (el UPDATE puede condicionarse a `read = false`, o dejar `read_at` con `COALESCE`).

Alternativa descartada: RPC `rpc_mark_notification_read`. Innecesaria — no hay lógica cross-row ni privilegio elevado; sería boilerplate.

### D6 — Retención: TTL 30 días vía pg_cron, solo leídas

Read model efímero, no archivo. Cleanup pg_cron: `DELETE FROM notifications WHERE read = true AND read_at < now() - interval '30 days'`. Las no-leídas nunca se auto-borran (podrían ser importantes y sin ver). El dropdown del bell consulta `ORDER BY created_at DESC LIMIT N` (ej. 20) + un count de no-leídas — nunca carga la tabla entera. Índices: `(account_id, created_at DESC)` para el dropdown y **parcial** `(account_id) WHERE read = false` para el badge de no-leídas (WHERE frecuente = índice parcial, best-practice Supabase). Índice GIN sobre `audience` si el filtro por `= ANY(audience)` en RLS lo pide bajo carga (se evalúa; con pocas filas por cuenta puede no hacer falta).

### D7 — Frontend: hook `useNotifications` (React Query + Realtime), campana en `BreadcrumbNav`

- `NotificationBell.tsx` (client) en el header `BreadcrumbNav`: ícono `Bell` (lucide) + badge count, `DropdownMenu` (shadcn) con la lista y acción marcar-leída.
- `useNotifications` (hook en `frontend/hooks/data/`): React Query `useQuery` para el fetch inicial + unread count; monta un `supabase.channel('notifications:'+accountId).on('postgres_changes', {event:'INSERT', schema:'public', table:'notifications', filter:'account_id=eq...'}, cb)` que hace `queryClient.setQueryData` (dedupe por `id`) e incrementa el badge. En `subscribe`/reconnect → invalida la query (resync FS §9.6). Cleanup en `useEffect` return (`supabase.removeChannel`).
- Tipos en `lib/types.ts` (`Notification`, `NotificationType`, `NotificationSeverity`) — **sin `any`**. Componente en PascalCase.
- El badge se deriva del stream + query, **sin polling** (nada de `refetchInterval`).

## Risks / Trade-offs

- **[Realtime respeta RLS solo con RLS activa y tabla en la publicación]** → La migración habilita RLS **antes** de agregar la tabla a `supabase_realtime`; test/gate que verifica ambas cosas. Si faltara, un usuario podría recibir INSERTs de otras filas.
- **[El `filter` del cliente no es la garantía de seguridad]** → Se documenta que el filtro de red es optimización; la seguridad es la RLS por audiencia. Test: un usuario fuera del `audience` no recibe la fila aunque comparta `account_id`.
- **[Producers nuevos = superficie invasiva]** → Es lo más riesgoso (tocar RPCs de cierre de caja, stock, quotes, transfers, CAE). Mitigación: un producer por commit, cada uno solo agrega un `INSERT INTO events` sin cambiar la lógica existente; TDD con gate de "evento emitido en la tx". Governance MEDIO permite checkpoints.
- **[Catálogo binario sub-óptimo hoy]** → casi todo va a "owners", el vendedor/branch no se distingue finamente. Aceptable: el aislamiento en `_notification_audience` (D3) lo hace un cambio de una función cuando llegue RBAC. Se documenta como deuda conocida, no como bug.
- **[CAE rechazado corre en el backend Python/Render, no en la RPC de venta]** → hay que ubicar el path exacto donde se marca el rechazo (¿RPC? ¿update desde el backend?) para emitir `FiscalDocumentRejected` en la tx correcta. Si el rechazo se persiste vía backend, el producer puede ser un trigger AFTER UPDATE sobre el doc fiscal en vez de un INSERT en una RPC. Se resuelve en apply al leer el path real (queda como decisión de implementación acotada, no bloqueante del propose).
- **[Duplicados en la UI si Realtime + resync compiten]** → dedupe por `id` en `setQueryData` (D1/D7). Test de resync que no duplica.
- **[TTL borra historial que el usuario podría querer]** → solo borra **leídas** > 30d; las no-leídas persisten. Si el negocio pide historial, es otra capability (fuera de scope).

## Migration Plan

1. **Migración** `supabase/migrations/20260808000001_v3_notifications_realtime.sql` (idempotente, `IF NOT EXISTS`/`CREATE OR REPLACE`/`DROP POLICY IF EXISTS`, patrón de gates DO-block como C2/C3):
   - `notifications` table + índices + RLS (SELECT por audiencia, UPDATE con USING+WITH CHECK, sin INSERT policy).
   - `_notification_audience(...)` + `_notification_from_event(events)` (`SECURITY DEFINER`, REVOKE anon/authenticated/PUBLIC).
   - `CREATE OR REPLACE rpc_process_outbox_dispatch` agregando Consumer 4 (consumers 1-3 preservados byte-a-byte).
   - `ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications`.
   - pg_cron job de cleanup TTL.
   - Producers nuevos (pueden ir en la misma migración o en migraciones hermanas `20260808000002+`, una por dominio, para revisar aislado).
2. **Frontend**: `NotificationBell` + `useNotifications` + tipos; montar la campana en `BreadcrumbNav`.
3. **Deploy**: merge a main → CI aplica la migración a prod y deploya Vercel (pipeline automático). No requiere paso manual del PO.
4. **Rollback**: `DROP TABLE notifications CASCADE`, `CREATE OR REPLACE` del dispatch a la versión de 3 consumers, `ALTER PUBLICATION ... DROP TABLE`, unschedule del cron. Los producers nuevos son `INSERT INTO events` adicionales — inertes si no hay consumer (el dispatch los ignora como no-scope). Revert de las RPCs a su versión previa si se quiere limpieza total.

## Open Questions

- **CAE rechazado**: ¿el rechazo se persiste desde una RPC de Postgres o desde el backend Render? Determina si `FiscalDocumentRejected` se emite en una RPC o vía trigger AFTER UPDATE del doc fiscal. Resolver en apply leyendo el path real.
- **`StockBelowMinimum`**: ¿reutilizamos la lógica de `check_low_stock` (AI alerts) para no duplicar la detección del umbral, o emitimos el evento directamente donde el movimiento de stock actualiza `branch_stock`? Preferencia: en el write-path de stock, comparando contra el mínimo, para que sea transaccional. Confirmar dónde vive el mínimo (por producto vs por branch).
- **Índice GIN sobre `audience`**: ¿necesario? Depende del volumen por cuenta. Se mide en apply; por defecto no se crea (pocas filas).
