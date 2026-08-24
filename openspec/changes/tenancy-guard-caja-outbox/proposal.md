## Why

> **Governance: CRÍTICO.** Seguridad multi-tenant sobre dinero (arqueo de caja) y sobre la contabilidad (outbox → asientos). Por la regla de governance del proyecto, **este propose es análisis + artefactos; el apply requiere aprobación humana explícita del PO**. El PO autorizó *proponer*, no *aplicar*. Checkpoint 🛑 al inicio de `tasks.md`.

Dos huecos de tenencia **verificados hoy (2026-08-23) contra producción** (`gxdhpxvdjjkmxhdkkwyb`, sólo `SELECT`) y **reproducidos en local** con dos tenants sintéticos. Los dos son la misma clase de bug que cerró `cuenta-corriente-party-guard`: **un identificador ajeno pasado por parámetro que nadie valida**. De hecho salieron de la auditoría del vecindario de ese change, que los dejó anotados como hallazgos laterales h1 y h2 sin corregirlos.

**h1 — el POS escribe en la caja de otro tenant.** `_c29_confirm_order_core` (`SECURITY DEFINER`, `authenticated`, md5 `cecd8c5454611f267a5e131d73bf7928`, len 15110) valida `is_account_writer` sobre la orden, valida la forma de pago (`WHERE account_id = v_account_id`), la sucursal y la cuenta bancaria — pero del `p_cash_session_id` **sólo chequea `IS NULL`** (`cash_requires_session`, `P0400`) y lo pasa crudo a `c28_register_cash_movement`, que es `SECURITY INVOKER` y sólo exige `status = 'open'` y sucursal activa: **ni `account_id`, ni `current_account_ids()`, ni que la caja sea la de la sucursal efectiva**. Como todos sus llamadores son `SECURITY DEFINER` y corren como `postgres`, la RLS no lo frena. Reproducido en local (`BEGIN … ROLLBACK`, sesión del tenant A, sesión de caja abierta del tenant B): la venta tiene éxito y **`cash_movements` de la víctima suma una fila** — ingreso fantasma en su arqueo — mientras la caja de A no registra nada. El contraste que da el patrón del fix está en el mismo dominio: el **formulario** de venta sí lo cierra, con `cash_optin_requires_open_session` (`cs.status = 'open' AND cb.branch_id = v_gate_branch` → `P0422`). El guard existe y no se replicó en el POS. Wrappers públicos afectados: `rpc_quick_sale` (md5 `ccb8afa0730195cb3df65807eb0a05ed`) y `rpc_confirm_sales_order` (md5 `38f2902380018ef717ff5b04cc711d20`). **El 100 % de los 65 movimientos de caja vivos en prod pasó por este único camino sin guard** (los 65 tienen `reference_id` en `sales_orders`), y hay **3 sesiones abiertas de 3 tenants distintos** ahora mismo.

**h2 — lectura y escritura cross-tenant en el outbox.** `rpc_process_outbox_batch(integer)` (`SECURITY DEFINER`, `authenticated`, md5 `e56e9eddda40754a4fc31a234a8d3309`) hace `SELECT * FROM public.events WHERE processed_at IS NULL … FOR UPDATE SKIP LOCKED` **sin filtro de tenant**, y `rpc_mark_event_processed(uuid)` (ídem, md5 `b1396bac350179e570b091069738db41`) hace `UPDATE public.events SET processed_at = now() WHERE id = $1`, también sin filtro. Reproducido en local con `SET LOCAL ROLE authenticated` y los claims del usuario A: el batch **devuelve eventos del tenant B con el payload completo legible** (`account_id`, `amount`, `client_id`) y marcarlos procesados hace que **el dispatcher real nunca postee su asiento contable**. No requiere conocer ningún UUID: el batch los entrega. Agravado en la API: `POST /outbox/process-pending` (`backend/routers/outbox.py` L32-35) sólo exige `Depends(get_current_user)`, sin gating de admin, y el pool corre como owner. El contraste correcto está al lado: `rpc_process_outbox_dispatch(integer)` —el que sí postea asientos, invocado por el pg_cron job `relay-process-outbox` como `postgres`— ya tiene `authenticated = false`.

**h2 bis — el relay Python es un consumidor duplicado y lesivo (hallazgo nuevo de este propose, verificado).** No es sólo que el endpoint esté sin gate: es que **no debería existir como consumidor**. `rpc_process_outbox_dispatch` corre **cuatro** consumers (AuditLog, Email, JournalEntry, Notification) y recién después marca `processed_at`. `OutboxRelayService` corre **dos** (AuditLog y Email) y marca `processed_at` igual. Los dos leen `WHERE processed_at IS NULL`. Compiten por el mismo flag: **todo evento que gane el relay Python pierde para siempre su asiento contable y su notificación**. El spec vigente de `transactional-outbox` ya exige los cuatro consumers en orden, así que el relay Python **incumple el spec como está escrito hoy**; el propio comentario del pg_cron job lo llama "trigger manual/secundario para debugging", y el docstring del router está desactualizado (afirma que lo llama el cron, y el cron llama a la RPC). Daño histórico medido: **cero** — 626 eventos, 0 pendientes, 464 elegibles para asiento y 465 asientos, **0 procesados sin asiento** —, es decir que el endpoint nunca se usó en prod. Sigue siendo un botón que borra la contabilidad de todos los tenants.

## What Changes

### 1. h1 — Guard de tenencia de la sesión de caja, en dos capas

- **Capa 1 (invariante fuerte, de sucursal)**: `_c29_confirm_order_core` valida el `p_cash_session_id` con el **mismo predicado que el formulario ya usa** — `cs.id = p_cash_session_id AND cs.status = 'open' AND cb.branch_id = v_gate_branch` → `P0422 cash_optin_requires_open_session`. Reutilización, no invención: el predicado se copia de `rpc_create_sale_operation_v2`. Cierra el POS por sus dos wrappers públicos de una sola vez.
- **Capa 2 (backstop de tenant, cubre todo caller presente y futuro)**: `c28_register_cash_movement` resuelve el tenant de la sesión por la cadena `cash_sessions → cashboxes → branches.account_id` y exige que pertenezca a `current_account_ids()`. **La firma no cambia** (el tenant es derivable; `rpc_register_cash_movement` ya hace exactamente esa resolución): sin `DROP FUNCTION`, sin riesgo de overload 42725.
- **BREAKING (dominio)**: una confirmación de POS con una sesión de caja de otra sucursal —aunque sea del mismo tenant— pasa a fallar con `P0422`. Hoy tiene éxito. Ningún camino de UI puede producir ese input.

### 2. h2 — El outbox deja de ser alcanzable desde el rol de aplicación

- El endpoint `POST /outbox/process-pending` pasa a ser un **disparador fino sobre `rpc_process_outbox_dispatch`** (el dispatcher completo, los cuatro consumers), corriendo sobre `get_service_conn` y gateado con `require_platform_admin`. `get_service_conn` es el **camino de servicio** que `v31-tenancy-pool-rls` D5 declara explícitamente separado: no inyecta claims y **nunca adopta el rol `authenticated`, sin importar el estado de ninguna de las dos palancas**. Por eso el gating y el revoke **sobreviven al Paso 2**.
- Se retiran `OutboxRelayService` y los cinco métodos de relay de `OutboxRepository` (`fetch_pending_batch`, `mark_processed`, `insert_audit_log`, `insert_email_log`, `claim_idempotency`): son una segunda implementación —incompleta— de los consumers 1 y 2 que el dispatcher SQL ya hace, y son el mecanismo de la supresión de asientos. `emit_event` **se conserva**: lo usan `purchase_repository` y `stock_repository` como productores.
- **BREAKING (superficie pública de PostgREST)**: `REVOKE ALL … FROM PUBLIC, anon, authenticated` sobre `rpc_process_outbox_batch(integer)` y `rpc_mark_event_processed(uuid)`, que quedan sin ningún caller de aplicación. **No se les pone filtro por tenant**: leer cross-account es su razón de ser y el spec vigente lo exige; el filtro rompería el relay sin arreglar la supresión de asientos.

### 3. Gate permanente en CI

- `supabase/tests/test_function_acl_gate.sql` suma un **chequeo (5)**: lista curada `v_cross_tenant_event_fns` — toda función `SECURITY DEFINER` que **lea (`FROM public.events`) o actualice (`UPDATE public.events`)** el outbox debe estar enumerada, y las que no son API pública no pueden ser ejecutables por `anon` ni `authenticated`. El chequeo (4) vigente **no** las habría atrapado: su filtro de nombre excluye `rpc_*` a propósito, y h2 vive justamente en dos `rpc_*`. La lista es viable porque es chica y estable: hoy son exactamente **cuatro** funciones en prod.
- `supabase/tests/test_tenancy_guard_caja_outbox.sql`: gate propio del change, con dos tenants sintéticos y cleanup sin residuos.

### 4. Auditoría del daño histórico (read-only, sin reparación automática)

Conteos en prod, sólo `SELECT`: movimientos de caja cuya sesión pertenece a un tenant distinto del de la venta/orden que los originó, y eventos con `processed_at` seteado que nunca produjeron su asiento. Los tres conteos preliminares de este propose dieron **0**. Se re-miden en el apply; si alguno da > 0, es checkpoint 🛑 firmado por el PO, con script fuera de `supabase/migrations/`.

### Sin superficie frontend

Change **sin superficie frontend** (regla PO 2026-08-02, excepción declarada). Verificado por `grep` sobre `frontend/`: las únicas menciones al outbox son `frontend/lib/database.types.ts` (generado — su presencia es justamente la prueba de que PostgREST expone las dos RPCs) y un comentario en `frontend/lib/types.ts`. **Ninguna pantalla llama a `POST /outbox/process-pending`**, así que el gating de admin no rompe ninguna superficie. Del lado de h1, el único efecto observable por un usuario legítimo es un `P0422` en lugar de un éxito silencioso, y ese camino ya está construido: el selector de caja del POS lista sólo las cajas de la sucursal seleccionada, así que la UI no puede producir el input rechazado.

## Capabilities

### New Capabilities

Ninguna. El change endurece capabilities existentes; no introduce dominio nuevo.

### Modified Capabilities

- `sales-order`: la confirmación de una orden (y el `quickSale` del POS) exige que la sesión de caja informada esté abierta **y pertenezca a la sucursal efectiva de la venta**, con el mismo invariante que el formulario ya cumple.
- `cash-movement`: el helper intra-transacción del hot path deja de aceptar una sesión de caja de otro tenant, resolviendo la cuenta por la cadena de claves foráneas sin cambiar su firma.
- `transactional-outbox`: el modelo de autorización del relay pasa a nombrar también al rol `authenticated`; se establece que **hay un único dispatcher** y que el disparador manual es un camino de servicio con gating de administrador de plataforma, no un consumidor paralelo.
- `account-tenancy`: invariante nuevo de plataforma — las funciones con privilegio de definidor que **recorren el outbox completo** integran una lista curada y no son ejecutables por los roles de aplicación, con gate permanente en CI.

## Impact

**DB — una migración: `20261012000001_tenancy_guard_caja_outbox.sql`**

`MAX(version)` vivo en prod verificado hoy: **`20261011000001`** (260 migraciones). El número **se re-verifica en el apply**: en el change anterior se movió tres veces porque otras ramas tomaron los intermedios.

- `_c29_confirm_order_core(text,uuid,text,uuid,text,uuid,text,uuid,uuid)` — guard nuevo. Reescritura completa desde el `pg_get_functiondef` **vivo** (gate de integridad de función; checkpoint 🛑 en tasks 1.5). Firma sin cambios.
- `c28_register_cash_movement(uuid,numeric,text,uuid,text)` — guard nuevo. Sigue `SECURITY INVOKER`. Firma sin cambios.
- `rpc_process_outbox_batch(integer)`, `rpc_mark_event_processed(uuid)` — sólo ACL y `COMMENT`, sin tocar el cuerpo.
- `rpc_quick_sale`, `rpc_confirm_sales_order` — **no se tocan**: heredan el guard del core.

**CI**

- `.github/workflows/KPI_Validation.yml`: la migración nueva se suma como **último eslabón** de la cadena de reapply del step "Verify G1/G4 migrations are idempotent on reapply" (el reapply de migraciones viejas re-otorga GRANTs en silencio — hallazgo del change anterior), más un step propio para el gate SQL nuevo.
- `supabase/tests/test_function_acl_gate.sql`: chequeo (5).
- Gates que deben seguir verdes sin cambios: los 30 del workflow, en particular `test_function_acl_gate.sql`, `test_errcode_5char_gate.sql`, `test_idempotency.sql`, `test_cuenta_corriente_party_guard.sql`, `test_tenancy_rls_role.sql` y los gates de caja/POS.

**Backend Python**

- `backend/routers/outbox.py` — reescrito (service conn + `require_platform_admin` + dispatch RPC), docstring corregido.
- `backend/services/outbox_relay_service.py` — eliminado.
- `backend/repositories/outbox_repository.py` — se retiran los cinco métodos de relay, se agrega `run_dispatch`, se conserva `emit_event`.
- `backend/tests/outbox/` — los cinco archivos de tests del relay Python se reemplazan por tests del disparador nuevo. Baseline a medir en la task 1.2 (referencia post-#458: 1604 passed / 3 skipped).

**Frontend**

Sin cambios. `frontend/lib/database.types.ts` se regenera si el pipeline de tipos corre después del revoke — consecuencia, no objetivo.

**Relación con otros changes**

- `v31-tenancy-pool-rls` (in-progress, Paso 1 y 2 mergeados detrás de palancas apagadas): **no solapa, pero condiciona**. Su D5 declara `get_service_conn` como camino separado que nunca adopta `authenticated` — es la pieza que hace que este change sobreviva al Paso 2. Además su propio inventario ya lista `events` y `email_logs` como colisiones del Paso 2 (INSERT directo sin policy), o sea que el relay Python que este change retira **ya estaba roto de antemano** para ese escenario. Sin conflicto de archivos: aquel toca `backend/core/database.py`, éste no.
- `v31-authz-token-hook`, `v31-mp-upgrade-webhook-fix`, `mp-real-subscriptions`, `asiento-venta-formulario` (in-progress): ninguno toca `c28_register_cash_movement`, `_c29_confirm_order_core` ni las RPCs del outbox. Verificado contra el estado vivo de prod.
- Consume el mismo patrón de gate permanente que `test_function_acl_gate.sql` chequeos (3) y (4), y la misma disciplina de baseline vivo que `cuenta-corriente-party-guard`.
