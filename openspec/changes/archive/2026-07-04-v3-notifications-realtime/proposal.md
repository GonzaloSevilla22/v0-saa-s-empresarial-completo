## Why

El sistema ya emite eventos de dominio al outbox transaccional (ventas, compras, pagos, ajustes de stock) y los procesa post-commit con tres consumers (AuditLog, Email, Journal). Falta el último eslabón del patrón "snapshot + historial + **aviso**" del Modelo V3 §3: **avisar al usuario correcto, en el momento correcto, dentro de la app** — que se cerró una caja con diferencia, que un producto quedó bajo mínimo, que ARCA rechazó un CAE. Hoy esa información solo existe en tablas que el usuario tiene que ir a mirar. El Modelo V3 exige que el aviso sea un efecto **post-commit** (nunca dentro de la transacción de negocio) y que la UI no haga polling. El outbox ya está maduro en producción: es el momento de agregarle el Consumer 4.

## What Changes

- **Nueva tabla `notifications`** (read model efímero para la campana): `id`, `account_id`, `branch_id`, `type`, `severity`, `payload jsonb`, `audience uuid[]`, `read`, más `created_at`/`read_at` para TTL y orden. RLS por pertenencia a la audiencia.
- **Consumer 4 del relay del outbox** (`rpc_process_outbox_dispatch`), mismo patrón SQL puro, idempotencia `(event_id, 'Notification')` y per-event isolation que los tres consumers existentes. Traduce eventos de dominio en-scope a filas de `notifications`, resolviendo `audience` por rol dentro del consumer (nunca en el cliente).
- **Casos iniciales** (todos derivados de eventos que el outbox ya emite o emitirá): `StockBelowMinimum` → rol con permiso de compras; `CashSessionClosed` con diferencia ≠ 0 → admin; CAE rechazado (`FiscalDocumentRejected`) → urgente; `QuoteAccepted` → vendedor; `TransferDispatched` → sucursal destino.
- **Campana de notificaciones en el header** (`BreadcrumbNav`): badge de no-leídas, dropdown con las últimas N, marcar-como-leída. Es la primera suscripción **Supabase Realtime** del frontend.
- **Suscripción Realtime por organización** vía `postgres_changes` sobre `notifications`, con RLS aplicando el filtro de audiencia en el servidor (el cliente nunca decide qué ve). Resincronización por query de React Query al reconectar (patrón de resiliencia FS §9.6).
- **Producers nuevos donde falten**: los eventos `CashSessionClosed`, `StockBelowMinimum`, `QuoteAccepted`, `TransferDispatched` y `FiscalDocumentRejected` que hoy no se emiten al outbox se agregan como productores dentro de la misma transacción de su mutación (DEC-20). Los que ya existen no se recrean.

Sin cambios de comportamiento en las transacciones de negocio: `notifications` es un read model que solo el relay escribe. No se toca `sale_notifications` (log de envíos WhatsApp/email al cliente final — otra cosa).

## Capabilities

### New Capabilities
- `in-app-notifications`: read model `notifications` (schema + RLS por audiencia + índices), su ciclo de vida (creación solo por el relay, marcar-como-leída, retención/TTL) y la entrega en tiempo real vía Supabase Realtime `postgres_changes` con la campana en el header. Incluye la resolución de `audience` por rol y la resincronización al reconectar.

### Modified Capabilities
- `transactional-outbox`: se agrega el **Consumer 4 (Notification)** a `rpc_process_outbox_dispatch` (mismo per-event isolation e idempotencia por `(event_id, consumer_type)` que los consumers 1-3) y los **producers** de los eventos de dominio en-scope que aún no se emiten (`CashSessionClosed`, `StockBelowMinimum`, `QuoteAccepted`, `TransferDispatched`, `FiscalDocumentRejected`), emitidos en la misma transacción de su mutación.

## Impact

- **DB (Supabase, PROD `gxdhpxvdjjkmxhdkkwyb`)**: nueva migración `supabase/migrations/20260808000001_v3_notifications_realtime.sql` — tabla `notifications` + RLS + índices; `CREATE OR REPLACE` de `rpc_process_outbox_dispatch` preservando consumers 1-3; helper `_notification_from_event`; productores nuevos en las RPCs/triggers de las mutaciones en-scope. Publicación Realtime de `notifications` (`ALTER PUBLICATION supabase_realtime ADD TABLE`).
- **Frontend (Next.js/`frontend/`)**: componente `NotificationBell` client en el header (`BreadcrumbNav`), hook `useNotifications` (React Query + suscripción Realtime vía `frontend/lib/supabase/client.ts`), tipos en `lib/types.ts`. Primera integración Realtime del proyecto.
- **Roles**: el catálogo `account_members.role` hoy es binario (`owner`/`member`) — la resolución de audiencia mapea los roles funcionales del V3 (compras/admin/vendedor) a `owner` (y a `member` según el caso) hasta que `v3-rbac-multirole` amplíe el catálogo; el diseño deja el mapeo aislado en un punto único para migrarlo sin tocar el resto.
- **Governance**: MEDIO — consumer nuevo + read model; no toca transacciones de negocio ni dinero. No requiere sign-off bloqueante del PO.
- **No afecta**: `sale_notifications`, la spec legacy `realtime-websocket` (patrón WSManager propio rechazado por el V3 §10 — no se implementa ni se toca), ni el backend Python (Realtime se queda en Supabase por DEC-16).
