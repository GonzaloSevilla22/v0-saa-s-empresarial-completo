# Hotfix `email-logs-cierre-insert` — inventario de escritores de `public.email_logs`

Fecha de la medición: **2026-10-17**. Prod: `gxdhpxvdjjkmxhdkkwyb`, sólo `SELECT` (`mcp__supabase__execute_sql`, de sólo lectura). `MAX(version) = 20261083000001`, 330 migraciones.

Origen: OQ-7 de `multiusuario-operativo` (opción **(a)**, firmada por el PO), grupo 12 de `tasks.md`.

## 1. Estado vivo de la tabla (antes del hotfix)

| Dato | Valor medido |
|---|---|
| RLS | `relrowsecurity = true`, `relforcerowsecurity = false`; propietaria `postgres` |
| `relacl` | `postgres=arwdDxtm`, `anon=rxtm`, **`authenticated=arwdDxtm`**, `service_role=arwdDxtm` |
| Policies | `Admins can view email logs` (SELECT, `authenticated`, `profiles.role='admin'`) y **`email_logs_backend_insert` (INSERT, `authenticated`, `WITH CHECK (true)`)** |
| Columnas | `id uuid default gen_random_uuid()`, `user_id uuid null` (FK `auth.users` ON DELETE SET NULL), `event_type text not null`, `recipient text not null`, `subject text not null`, **`status text not null default 'pending'` (sin CHECK)**, `provider_id`, `error_details`, `metadata jsonb default '{}'`, `created_at`, `sent_at` |
| Constraints | PK `id`; `UNIQUE (user_id, event_type, metadata)`; FK `user_id` |
| Trigger | `on_email_log_insert AFTER INSERT ... FOR EACH ROW EXECUTE FUNCTION send_email_log_webhook()` (`SECURITY DEFINER`, `search_path = public, vault`): sólo actúa si `NEW.status = 'pending'`, lee `send_email_webhook_secret` / `edge_functions_base_url` de Vault y hace `net.http_post` a `/functions/v1/send-email` con `x-webhook-secret` |

Consecuencia (verificada por construcción, **no ejecutada**): cualquier usuario autenticado podía `INSERT INTO email_logs (event_type, recipient, subject, metadata)` con un destinatario y un asunto arbitrarios; la fila nacía `pending`, el trigger invocaba a `send-email` y ALIADATA mandaba el correo desde `no-reply@aliadata.com.ar`. `authenticated` además conservaba `UPDATE`, `DELETE` y `TRUNCATE` a nivel tabla (sólo la RLS, sin policy, los frenaba), y `anon` conservaba `SELECT`.

La policy `email_logs_backend_insert` se agregó en `20260828000001_v31_rls_collision_rpcs.sql` (sección 4.2) como «excepción justificada» para cuando el backend pasara a correr como `authenticated`. **El inventario de abajo prueba que ningún escritor legítimo corre como `authenticated`**, así que la excepción nunca hizo falta.

## 2. Escritores legítimos (los que no se pueden romper)

### 2.1 Funciones SQL (todas `SECURITY DEFINER`, propietaria `postgres`, `EXECUTE` sólo para `postgres` y `service_role`)

Medido con `pg_proc.prosrc ILIKE '%email_logs%'` sobre todos los esquemas de usuario (11 funciones, 0 en `SECURITY INVOKER`).

| Función | Cómo se dispara | `event_type` | Rol efectivo del `INSERT` |
|---|---|---|---|
| `handle_new_user()` | trigger `on_auth_user_created` (AFTER INSERT `auth.users`) | `welcome`, `new_user_admin_notice` | propietario (`postgres`) |
| `check_low_margin()` | trigger `on_sale_insert_margin_check` (AFTER INSERT `sales`) | `low_margin_alert` | propietario |
| `check_branch_low_stock()` | trigger `on_branch_stock_update` (AFTER UPDATE `branch_stock`) | `low_branch_stock_alert` | propietario |
| `notify_meeting_created()` | trigger `on_meeting_created` (AFTER INSERT `community.meetings`) | `meeting_notice` | propietario |
| `notify_pool_created()` | trigger `on_pool_created` (AFTER INSERT `community.purchase_pools`) | `pool_notice` | propietario |
| `queue_trial_notifications()` | pg_cron `trial-notifications` (`0 9 * * *`) | `trial_expiring_soon` | propietario |
| `_produce_plan_expiring_soon()` | pg_cron `mp-subscriptions-plan-expiring-soon-sweep` (`0 12 * * *`) | `subscription_expiring_soon` | propietario |
| `_produce_receivables_overdue_digest()` | pg_cron `cobranzas-overdue-digest-sweep` (`0 12 * * *`) | `receivables_overdue_digest`, `payables_overdue_digest` | propietario |
| `rpc_process_outbox_dispatch(integer)` | pg_cron `relay-process-outbox` (`* * * * *`) | Consumer 4 de notificaciones (inserta correos del outbox) | propietario |
| `purge_internal_logs()` | retención | (`DELETE` de filas viejas) | propietario |
| `send_email_log_webhook()` | trigger `on_email_log_insert` | (no escribe: sólo lee `NEW`) | propietario |

Un trigger `SECURITY DEFINER` corre con el privilegio de su propietario aunque lo dispare un usuario `authenticated`: revocar `INSERT` a `authenticated` **no** los alcanza. El gate lo prueba ejecutando tres de ellos bajo `SET LOCAL ROLE authenticated` (alta de usuario, alta de reunión comunitaria, cancelación de plan) y recorriendo el catálogo para exigir que cualquier función futura que escriba en `email_logs` sea `SECURITY DEFINER`.

### 2.2 Backend Python (FastAPI)

Todos los `INSERT INTO email_logs` del backend corren sobre **`get_service_conn`** (pool sin adopción de rol: usuario `postgres`, propietario de la tabla y con `BYPASSRLS`), nunca sobre `get_db_conn` (la conexión del request, que hace `SET LOCAL ROLE authenticated`):

| Archivo | Línea | `event_type` | Conexión |
|---|---|---|---|
| `backend/routers/payments.py` | 412 (`resend_payment_receipt`) | `payment_receipt` | `Depends(get_service_conn)` |
| `backend/services/payments.py` | 365 (`process_payment`) | `plan_upgraded` | `conn` del webhook = `get_service_conn` |
| `backend/services/subscriptions.py` | 301 (`cancel_subscription`) | `subscription_cancelled` | `get_service_conn` |
| `backend/services/subscriptions.py` | 419 (`_apply_approved_charge`) | `subscription_payment_approved` | `get_service_conn` |
| `backend/services/subscriptions.py` | 770 (`_apply_preapproval_notification`, baja reportada por MercadoPago) | `subscription_cancelled` (`reason='mercadopago'`) | `get_service_conn` |
| `backend/services/subscriptions.py` | 959 (`_apply_authorized_payment_notification`, cobro rechazado) | `subscription_payment_failed` | `get_service_conn` |

Ninguno depende de la policy abierta: no se toca backend.

### 2.3 Edge Functions

- `send-email` hace `UPDATE email_logs SET status/provider_id/sent_at/error_details` con la **service role key** (`service_role` conserva `arwdDxtm`). Ninguna otra función lee ni escribe `email_logs`.

### 2.4 Frontend / PostgREST con sesión de usuario

- **Un solo caller**: `frontend/app/api/billing/cancel/route.ts` (L119), `supabase.from('email_logs').insert({... event_type: 'plan_downgraded' ...})` con el JWT del usuario. **Es el único que dependía de la policy abierta.** La misma ruta ya llamaba a `rpc_request_subscription_cancellation()` (RPC `SECURITY DEFINER` sin parámetros, sólo para el titular de la cuenta), que es el lugar natural para encolar el correo en la misma transacción.
- Ningún otro código del frontend lee ni escribe `email_logs` (sólo `lib/database.types.ts`, tipos generados).

### 2.5 Jobs y CI

- Los jobs de `pg_cron` de arriba corren como `postgres`. `KPI_Validation.yml` sólo hace `DELETE FROM public.email_logs` como `postgres` en un cleanup. `supabase/tests/test_internal_logs_retention.sql` inserta filas como `postgres`.

## 3. Evidencia de que no hay abuso previo (prod, 2026-10-17)

- 576 filas (550 `sent`, 26 `failed`), del 2026-07-20 al 2026-10-16. Ningún `plan_downgraded` en toda la historia (la ruta de cancelación heredada casi no se usó).
- Todas las filas con `user_id` tienen `recipient` = email del usuario, salvo las 8 `new_user_admin_notice` (que van al administrador, por diseño). Las 2 filas sin `user_id` son los humos de `send-email-webhook-hardening` (`webhook_hardening_smoke`, `webhook_hardening_smoke2`).
- Ningún `meeting_notice` / `pool_notice` (los tipos de fan-out `all_users`). Los `event_type` coinciden con los productores de §2.1.
- **Conclusión**: sin indicio de explotación; el hotfix cierra un vector latente.

## 4. Diseño del cierre

1. `DROP POLICY email_logs_backend_insert`.
2. `REVOKE ALL ON email_logs FROM anon, authenticated` y `GRANT SELECT ... TO authenticated` (la policy de lectura de administradores lo necesita). `service_role` y `postgres` conservan todo.
3. `rpc_request_subscription_cancellation()` encola el correo `plan_downgraded` **en la misma transacción**: destinatario y `user_id` salen de `auth.uid()` y `auth.users`, nunca de un parámetro; sólo la alcanza el titular (P0403 para cualquier otro); un segundo intento da P0409 y no encola nada. El `INSERT` va en un subbloque que traga el error: el correo nunca puede romper una cancelación.
4. `frontend/app/api/billing/cancel/route.ts` deja de insertar en `email_logs`.
5. `send-email`: plantillas extraídas a un módulo puro con escape de todo dato proveniente de un usuario; `meeting_notice` deja de tomar el enlace de la metadata.
