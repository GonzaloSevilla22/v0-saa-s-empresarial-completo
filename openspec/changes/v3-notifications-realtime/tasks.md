# Tasks — v3-notifications-realtime

> TDD estricto donde el runner aplica (gates SQL en DO-block para la migración, patrón C2/C3; Vitest/RTL para el frontend). Governance MEDIO: checkpoints, un producer por commit lógico. Migración base: `supabase/migrations/20260808000001_v3_notifications_realtime.sql`. Apply via CI (`npx supabase db push` en el pipeline), NUNCA MCP `apply_migration`.

## 1. Schema `notifications` + RLS + índices

- [x] 1.1 (RED gate) Escribir el DO-block que falla si `public.notifications` no existe / no tiene las columnas esperadas (`id, account_id, branch_id, type, severity, payload, audience, read, created_at, read_at`)
- [x] 1.2 `CREATE TABLE IF NOT EXISTS public.notifications` con FKs (`account_id`→accounts, `branch_id`→branches nullable), `severity CHECK (IN ('info','warning','urgent'))`, `audience uuid[] NOT NULL`, `read boolean NOT NULL DEFAULT false`, `read_at timestamptz NULL`, `created_at timestamptz NOT NULL DEFAULT now()`
- [x] 1.3 Índices: `(account_id, created_at DESC)` para el dropdown; parcial `(account_id) WHERE read = false` para el badge de no-leídas
- [x] 1.4 `ALTER TABLE ... ENABLE ROW LEVEL SECURITY`
- [x] 1.5 Política SELECT `TO authenticated USING (account_id IN (SELECT current_account_ids()) AND (select auth.uid()) = ANY(audience))`
- [x] 1.6 Política UPDATE `TO authenticated` con `USING` (audiencia/cuenta) + `WITH CHECK` que preserva `account_id/audience/type/severity/payload` (solo `read`/`read_at` mutan)
- [x] 1.7 Verificar que NO existe política INSERT para `authenticated` (gate)
- [x] 1.8 (GATE) DO-block de comportamiento: usuario en audiencia ve la fila; usuario fuera de audiencia (misma cuenta) NO la ve; INSERT directo por authenticated falla

## 2. Helpers de proyección (audiencia + posting)

- [x] 2.1 (RED) Gate que verifica que `_notification_audience` y `_notification_from_event` existen y están REVOCADAS de anon/authenticated/PUBLIC
- [x] 2.2 `_notification_audience(p_account_id uuid, p_target text, p_branch_id uuid) RETURNS uuid[]` — mapeo binario (D3): ADMIN/PURCHASES/URGENT_FISCAL→owners; SELLER→owners+members; BRANCH_DEST→members del branch con fallback owners. `SECURITY DEFINER`, `SET search_path=public`
- [x] 2.3 `_notification_from_event(p_event public.events) RETURNS void` (`SECURITY DEFINER`, `SET search_path=public`): filtro por los 5 event_types (no-op fuera de scope); reclamar idempotencia `(event_id,'Notification')` en `operation_idempotency` (`operation_kind='event_consumer'`, `ON CONFLICT ... DO NOTHING`); dispatch por tipo → target + severity; resolver audiencia; si vacía → no insertar; `INSERT INTO notifications`
- [x] 2.4 Mapeo por evento con severity (D3): CashSessionClosed(dif≠0)→ADMIN/warning; FiscalDocumentRejected→URGENT_FISCAL/urgent; StockBelowMinimum→PURCHASES/warning; QuoteAccepted→SELLER/info; TransferDispatched→BRANCH_DEST/info
- [x] 2.5 `REVOKE ALL/EXECUTE` de PUBLIC/anon/authenticated en ambos helpers + `COMMENT ON FUNCTION`
- [x] 2.6 (GATE) DO-block: CashSessionClosed con dif=0 NO crea fila; con dif≠0 crea fila con audiencia = owners y severity=warning; re-ejecución del helper NO duplica (idempotencia)

## 3. Consumer 4 en `rpc_process_outbox_dispatch`

- [x] 3.1 (Safety net) Baseline: dump del `rpc_process_outbox_dispatch` actual; confirmar que consumers 1-3 se preservan byte-a-byte
- [x] 3.2 `CREATE OR REPLACE FUNCTION rpc_process_outbox_dispatch` agregando el bloque Consumer 4 (`PERFORM _notification_from_event(v_event)` para los 5 tipos) DESPUÉS del Consumer 3, dentro del mismo `BEGIN/EXCEPTION/END` per-event
- [x] 3.3 Actualizar `COMMENT ON FUNCTION rpc_process_outbox_dispatch` para documentar Consumer 4
- [x] 3.4 (GATE) DO-block: un evento in-scope pasa por consumers 1-4 y queda processed; un fallo simulado del Consumer 4 deja el evento pending sin abortar el batch; evento fuera de scope solo corre consumers 1-3
- [x] 3.5 `ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications` (idempotente / guarded)

## 4. Retención (TTL cleanup)

- [x] 4.1 Función `_notifications_cleanup()` (o SQL inline) — `DELETE FROM notifications WHERE read = true AND read_at < now() - interval '30 days'`
- [x] 4.2 Schedule pg_cron del cleanup (patrón del relay C-27); gate que verifica que el job existe y que NO borra no-leídas ni leídas dentro del TTL

## 5. Producers de eventos (uno por commit lógico — checkpoints)

- [x] 5.1 `CashSessionClosed`: emitir `INSERT INTO events` en la RPC de cierre de caja (C-28), payload `{session_id, branch_id, difference, closed_by}`, en la misma tx; gate "evento emitido en la tx del cierre"
- [x] 5.2 `StockBelowMinimum`: emitir en el write-path de stock cuando el movimiento deja producto/branch ≤ mínimo, payload `{product_id, branch_id, current_qty, min_qty}`; resolver dónde vive el mínimo (Open Question) antes de implementar — **resuelto**: `branch_stock.min_stock` (per-branch), reutilizando el trigger existente `check_branch_low_stock`
- [x] 5.3 `QuoteAccepted`: emitir en la transición de estado a ACCEPTED (integra con `v3-document-status-history`), payload `{quote_id, seller_id, branch_id, total}`
- [x] 5.4 `TransferDispatched`: emitir en el dispatch de `stock_transfer`, payload `{transfer_id, source_branch_id, destination_branch_id}`
- [x] 5.5 `FiscalDocumentRejected`: emitir en el path de rechazo de CAE (resolver RPC vs trigger AFTER UPDATE — Open Question) — **resuelto**: el rechazo se persiste desde el backend Python (`fiscal_document_repository.py::update_rejected`, service_role), no hay RPC Postgres para este path; se implementó como **trigger AFTER UPDATE ON fiscal_documents** (mismo patrón que `trg_quote_record_creation`), payload `{fiscal_document_id, error, branch_id}`
- [x] 5.6 Verificar que ningún producer existente se recreó y que todos stampan `account_id/event_type/aggregate_type/aggregate_id/payload/occurred_at`

## 6. Frontend — campana + hook Realtime

- [x] 6.1 Tipos en `frontend/lib/types.ts`: `Notification`, `NotificationType`, `NotificationSeverity` (sin `any`)
- [x] 6.2 (RED) Test de `useNotifications`: fetch inicial devuelve lista + unread count; INSERT por Realtime agrega al cache y sube el badge; dedupe por `id`
- [x] 6.3 `frontend/hooks/data/use-notifications.ts`: React Query `useQuery` (fetch + count) + `supabase.channel(...).on('postgres_changes', {event:'INSERT', table:'notifications', filter:'account_id=eq...'})`; en subscribe/reconnect → invalidar la query (resync FS §9.6); cleanup con `removeChannel`
- [x] 6.4 `frontend/components/dashboard/NotificationBell.tsx` (client, PascalCase): ícono `Bell` + badge de no-leídas, `DropdownMenu` (shadcn) con la lista, acción marcar-leída (`.update({read:true, read_at})`)
- [x] 6.5 Montar `<NotificationBell />` en el header `breadcrumb-nav.tsx` (alineado a la derecha)
- [x] 6.6 (Test) marcar-leída baja el badge y es idempotente (re-marcar no rompe); sin `refetchInterval` (no polling)

## 7. Cierre

- [x] 7.1 `openspec validate --strict` verde
- [ ] 7.2 Verificación en prod post-merge (MCP read-only): tabla `notifications` presente en `supabase_realtime`, relay procesa un evento in-scope y crea la fila, RLS aísla por audiencia
- [ ] 7.3 Marcar `v3-notifications-realtime` en CHANGES.md §"Roadmap Modelo V3"
