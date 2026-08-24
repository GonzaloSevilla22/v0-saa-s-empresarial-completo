# Tasks — `tenancy-guard-caja-outbox`

> ## 🛑 GATE DE GOVERNANCE — LEER ANTES DE TOCAR NADA
>
> **Governance: CRÍTICO** (seguridad multi-tenant + dinero + contabilidad). El PO
> autorizó **proponer**, no **aplicar**. Ninguna task de este archivo se ejecuta
> sin sign-off explícito del PO en la task **0.1**. No hay excepción "empiezo por
> lo inofensivo": el grupo 1 ya toca prod (aunque sea de lectura) y consume
> tiempo de decisión.
>
> **Strict TDD activo.** Cada task de código sigue RED → GREEN → TRIANGULATE →
> REFACTOR, con safety net previo sobre lo que se toca. Los tests van **antes**
> de la implementación, nunca después.
>
> Las tasks marcadas **[OQ-n]** dependen de la respuesta del PO a la Open
> Question correspondiente de `design.md`. Sin respuesta, se implementa la
> **recomendación**. Las marcadas 🛑 exigen mostrar el resultado al PO antes de
> seguir.
>
> **Los grupos 3 (h1) y 4-5 (h2) no comparten ningún objeto de base de datos**
> (D5): se pueden aplicar, revisar y revertir por separado. La migración los
> separa en dos secciones con encabezado propio.

## 0. Sign-off (bloqueante)

- [ ] 0.1 🛑 **[OQ-0]** Obtener aprobación explícita del PO para ejecutar el apply. Presentarle: los dos hallazgos con su reproducción, los conteos de daño histórico preliminares (**0 en los tres**), y el hecho de que hay **3 sesiones de caja abiertas de 3 tenants distintos** y **10 tenants con eventos** en el outbox. Sin respuesta afirmativa registrada, **el apply no arranca**.
- [ ] 0.2 🛑 **[OQ-1]** Preguntar si el tramo **h2** sale como hotfix inmediato (patrón #446/#454) en vez de esperar el apply completo. *Recomendación: sí para h2 (revoke + `require_platform_admin`, PR chico con rollback de dos líneas), no para h1 (reescribir una RPC de 15 110 caracteres no se hace con urgencia de hotfix).* Si el PO elige el hotfix, los grupos **4 y 5.1-5.4** salen a un PR propio y este change conserva h1, el retiro del relay y los gates — anotarlo acá y ajustar los grupos 6 y 9.
- [ ] 0.3 Registrar la decisión de 0.1 y 0.2 en `CHANGES.md` y en engram (`topic_key: opsx/tenancy-guard-caja-outbox/apply`) **antes** de escribir una línea de código.

## 1. Reconocimiento y safety net

- [ ] 1.1 Verificar el **MAX de `supabase_migrations.schema_migrations` vivo en prod** (`npx supabase migration list`, o `SELECT max(version) …`). Al escribirse este propose era `20261011000001` (260 migraciones) → el archivo nace como `20261012000001_tenancy_guard_caja_outbox.sql`. ⚠️ **El número se re-verifica acá, siempre**: en `cuenta-corriente-party-guard` se movió **tres veces** porque otras ramas tomaron los intermedios (#452 tomó `20261009000001`, el hotfix #454 tomó `20261010000001`). Un archivo con número **menor o igual** al MAX remoto no lo aplica nunca el push automático de Supabase. Si prod está adelante, renumerar y anotarlo en el PR.
- [ ] 1.2 Correr la suite backend completa (`python -m pytest backend/tests -q -p no:cacheprovider`) y registrar el baseline `N/N`. Referencia post-#458: **1604 passed / 3 skipped**. Cualquier fallo preexistente se **reporta**, no se arregla en este change.
- [ ] 1.3 Levantar el stack local (`npx supabase db reset`) y correr los **30 gates del workflow en el orden exacto de CI**, registrando el baseline. Prestar atención a `test_function_acl_gate.sql`, `test_errcode_5char_gate.sql`, `test_idempotency.sql`, `test_cuenta_corriente_party_guard.sql` y `test_tenancy_rls_role.sql`.
- [ ] 1.4 Reproducir la **cadena de reapply** del step "Verify G1/G4 migrations are idempotent on reapply" en local, en el orden exacto del YAML, y confirmar que fallan **sólo** los dos eslabones tolerados que el workflow documenta (`20260928000001` y `20261002000001`, cada uno por su marcador literal de gate ANTI-OVERLOAD).
- [ ] 1.5 🛑 **Gate de integridad de función.** Capturar el `pg_get_functiondef` **vivo en prod** de las funciones a reescribir y de las de referencia, en `openspec/changes/tenancy-guard-caja-outbox/baseline/<nombre>.sql`, con cabecera de procedencia, **`md5` y `length` verificados** (molde: `openspec/changes/archive/2026-08-23-cuenta-corriente-party-guard/baseline/`). Los valores medidos el 2026-08-23, para contrastar:
  - `_c29_confirm_order_core(text,uuid,text,uuid,text,uuid,text,uuid,uuid)` — md5 `cecd8c5454611f267a5e131d73bf7928`, len 15110
  - `c28_register_cash_movement(uuid,numeric,text,uuid,text)` — md5 `510adc8e150fb5c315e6e9a2635eaff8`, len 2288
  - `rpc_process_outbox_batch(integer)` — md5 `e56e9eddda40754a4fc31a234a8d3309`, len 963
  - `rpc_mark_event_processed(uuid)` — md5 `b1396bac350179e570b091069738db41`, len 266
  - referencia (no se tocan): `rpc_process_outbox_dispatch(integer)` `28ef69cefc0fd0a5d112b656e7795ac6`/5933, `rpc_quick_sale` `ccb8afa0730195cb3df65807eb0a05ed`/4046, `rpc_confirm_sales_order` `38f2902380018ef717ff5b04cc711d20`/777, `rpc_create_sale_operation_v2` `0b6bcc5b6caa1a3c01e0da16518c7d35`/13914
  > Si algún md5 difiere del de arriba, **algo cambió en prod desde el propose**: parar y reportar.
- [ ] 1.6 🛑 Diffear cada baseline contra su archivo de migración de referencia: `20261003000001_limpiezas_pagos_admin.sql` ~L760 (`_c29_confirm_order_core`), `20261006000001_banco_caja_historial_ajustes.sql` §5 (`c28_register_cash_movement`), `20260718000001_c25_events_outbox_reconcile.sql` L172/L203 (las dos del outbox). **Si difieren en una sola línea, reportar antes de escribir SQL.** `_c29_confirm_order_core` tiene antecedente concreto de divergencia: `compras-proveedor-cuenta-corriente` la encontró desalineada por una reescritura in-place del G3 de `20261003000001`.
- [ ] 1.7 Auditar en **prod** el estado real de permisos (`has_function_privilege` para `anon`/`authenticated`/`service_role`) de las 4 funciones a tocar más `rpc_process_outbox_dispatch` y `rpc_register_cash_movement`. Guardar la salida en `baseline/prod_acl_audit_<fecha>.md`. Recordar el gotcha #432 (prod concede EXECUTE **directo**, no vía `PUBLIC`).
- [ ] 1.8 Confirmar por `grep` sobre `frontend/`, `backend/` y `supabase/functions/` que **ningún consumidor de aplicación** invoca `rpc_process_outbox_batch` ni `rpc_mark_event_processed` fuera de `OutboxRepository`, y que ninguna pantalla llama a `POST /outbox/process-pending`. Anotar el resultado en el PR.
- [ ] 1.9 Enumerar contra **prod** los callers vivos de `c28_register_cash_movement` por `pg_get_functiondef` (**no** por `grep` sobre archivos: hay migraciones superseded que la mencionan y no la llaman). Contrastar contra la tabla de `design.md` D1 — al escribirse el propose eran 5 funciones más el gate embebido de `20260804000003`.

## 2. Test SQL — RED

- [ ] 2.1 **RED**: crear `supabase/tests/test_tenancy_guard_caja_outbox.sql` con el molde de `test_cuenta_corriente_party_guard.sql`: un solo `DO $$ … $$`, **dos tenants sintéticos** A y B provisionados por el trigger de `auth.users` → `account_members`, sesión sintética vía `set_config('request.jwt.claims', …, true)`, guard degrade-don't-fail con `auth.uid()`, ERRCODEs de 5 chars, **sin BOM** (`head -c 3 | od -c`) y **cleanup completo al final** (verificar dos corridas seguidas sin residuos, incluidas las filas de `operation_idempotency` con `operation_kind = 'event_consumer'` y las de `email_logs`, que no cuelgan del anchor).
- [ ] 2.2 **RED [h1]**: `rpc_quick_sale` del tenant A en efectivo con `p_cash_session_id` = sesión abierta del tenant **B** → esperado `P0422`. Debe **fallar hoy**: hoy la venta se confirma y deja **1 fila nueva en `cash_movements` de la sesión de B**. Medir los movimientos de la sesión de B **antes y después** y exigir que queden idénticos — el SQLSTATE solo no alcanza, el spec pide "sin efectos parciales".
- [ ] 2.3 **RED [h1]**: espejo por `rpc_confirm_sales_order` (orden creada y confirmada por separado) con la sesión ajena → `P0422`, y la orden **no** queda confirmada.
- [ ] 2.4 **RED [h1]**: sesión de **otra sucursal del mismo tenant** → `P0422`. Es el caso que sólo la capa 1 puede cubrir (la capa 2 lo dejaría pasar): sin este assert, D1 no está probado.
- [ ] 2.5 **RED [h1, capa 2]**: invocar `c28_register_cash_movement` directo (como `postgres`, con los claims de A) contra la sesión de B → esperado `P0401`, y 0 filas nuevas. Hoy inserta.
- [ ] 2.6 **RED [h2]**: con `SET LOCAL ROLE authenticated` y los claims del usuario A, `rpc_process_outbox_batch(1000)` → esperado `42501`. Hoy **devuelve eventos del tenant B**; medir cuántos devuelve del `account_id` de B y exigir 0 tras el fix.
- [ ] 2.7 **RED [h2]**: ídem con `rpc_mark_event_processed(<evento pendiente de B>)` → esperado `42501`, y el `processed_at` de ese evento **sin cambios**. Hoy lo setea.
- [ ] 2.8 **RED [h2 bis]**: candado del invariante "un solo despachador" — insertar un evento de tipo con asiento (`SaleConfirmed`), correr `rpc_process_outbox_dispatch(10)`, y exigir que el evento quede `processed_at IS NOT NULL` **y** con su `journal_entries.source_event_id`. Después, control negativo: verificar que **no existe** ningún camino vivo capaz de marcar `processed_at` sin postear el asiento (assert de que `rpc_process_outbox_batch` / `rpc_mark_event_processed` ya no son alcanzables por `authenticated`).
- [ ] 2.9 **Barrido global**: assert sobre **toda** la tabla `cash_movements` (no sólo los tenants sintéticos) exigiendo 0 filas cuya sesión pertenezca a un tenant distinto del de la orden/venta que las originó. Mismo patrón que el assert (9) del gate del change anterior: convierte la auditoría del grupo 8 en candado permanente y cubre residuos de otros gates de la misma corrida de CI.
- [ ] 2.10 Verificar que el archivo corre y **falla** contra el schema actual, y anotar cuáles asserts fallan. Si el gate es fail-fast, escribir un **diagnóstico independiente** read-only (`BEGIN … ROLLBACK`) versionado en `baseline/red_probe_<fecha>.sql` que pruebe cada comportamiento por separado, y volcar la tabla de resultados acá. Eso es el RED del change entero.

## 3. Migración — h1: guard de la sesión de caja

- [ ] 3.1 Crear `supabase/migrations/20261012000001_tenancy_guard_caja_outbox.sql` (número re-verificado en 1.1) con la cabecera del proyecto: las dos familias del hallazgo, D1/D2/D7/D8, MAX de prod, procedencia del baseline, gotcha #432, nota de que `service_role` conserva su EXECUTE, "ninguna firma cambia" y la declaración **BREAKING** de dominio. **Sin BOM UTF-8.** Separar h1 y h2 en dos secciones con encabezado propio (D5).
- [ ] 3.2 **GREEN [capa 1]**: `_c29_confirm_order_core(...)` partiendo del cuerpo capturado en 1.5, con el guard **inmediatamente después de `cash_requires_session`** y **antes de la primera escritura** (D2). El predicado se **copia** de `rpc_create_sale_operation_v2`: `cs.status = 'open' AND cb.branch_id = v_gate_branch` → `P0422 cash_optin_requires_open_session`, con el mismo mensaje literal. Enumerar en la evidencia cada bloque preservado byte a byte (formas de pago, `credit_requires_client`, banco, `sales`, caja, cuenta corriente, evento).
- [ ] 3.3 **GREEN [capa 2] [OQ-2]**: `c28_register_cash_movement(uuid,numeric,text,uuid,text)` desde el baseline, resolviendo la cuenta por `cash_sessions → cashboxes → branches.account_id` —**copiando el `SELECT` de `rpc_register_cash_movement`** (`20261006000001` §4, L160-166), no escribiéndolo de nuevo— y exigiendo `= ANY(current_account_ids())` → `P0401 unauthorized`. **Membresía, no `is_account_writer`** (D1 (iii)). Sigue `SECURITY INVOKER`, firma intacta.
- [ ] 3.4 ACLs de las dos funciones: reafirmar tras el `CREATE OR REPLACE`. `_c29_confirm_order_core` conserva su `GRANT` a `authenticated` (está en la allowlist del chequeo (4) por decisión de OQ-3 del change anterior — el hueco era alcanzable por sus wrappers, y ahora que se cierra el hueco **revisar si la justificación de la allowlist cambia** y actualizar su comentario en `test_function_acl_gate.sql`). `c28_register_cash_movement` conserva el suyo (OQ-4: no se revoca en este change). `COMMENT ON FUNCTION` de ambas citando el guard nuevo y su ERRCODE.
- [ ] 3.5 **TRIANGULATE**: control positivo — venta POS en efectivo con la sesión **correcta** de la propia sucursal sigue funcionando y escribe exactamente 1 `cash_movements` de tipo `sale` con `reference_id = sales_order_id` y el importe total. Es el assert que impide que el guard rompa el POS.
- [ ] 3.6 🛑 **TRIANGULATE — verificación del ERRCODE contra el gate embebido.** Confirmar empíricamente que con `P0401` la reconstrucción del esquema (`npx supabase db reset`) **no aborta**: el gate (b) de `20260804000003_fix_c28_cash_movement_balance.sql` invoca el helper sobre un anchor cuyo usuario no está en `account_members` de la cuenta del anchor, y su `EXCEPTION WHEN raise_exception` matchea **sólo `P0001`**. Verificar que el `NOTICE` de degradación aparece y que la migración sigue. **Si se eligiera `P0001`, `db reset` abortaría** — dejarlo escrito en la evidencia.
- [ ] 3.7 **TRIANGULATE — recuperar la cobertura que 3.6 degrada.** Replicar dentro del gate nuevo, con un tenant **bien provisionado**, la aserción de saldo firmado que el gate (b) de `20260804000003` deja de ejercitar: `opening = 1000`, luego `+500 / −200 / +300` → `balance_after` = `1500 / 1300 / 1600` (con el bug viejo de `MAX(balance_after)` el tercero daría 1800). **No se edita `20260804000003`**: es una migración ya aplicada en prod y editarla es el anti-patrón que produjo la regresión de julio.
- [ ] 3.8 **TRIANGULATE**: verificar que 2.2 y 2.3 pasan **sin haber tocado** `rpc_quick_sale` ni `rpc_confirm_sales_order` (`grep` sobre el archivo de migración → 0 ocurrencias). Es la prueba de que los wrappers heredan el guard del core.
- [ ] 3.9 **TRIANGULATE**: `rpc_delete_sale_operation` sigue compensando caja normalmente sobre una venta propia (control de regresión de la capa 2 sobre el camino de borrado), y `rpc_register_cash_movement` sigue exigiendo `is_account_writer` (el guard duplicado no relaja nada).

## 4. Migración — h2: cierre del outbox [OQ-1]

> Si OQ-1 sale como hotfix, este grupo entero se muda al PR del hotfix y acá queda la **verificación** de que el estado sigue cerrado (mismo patrón que la reconciliación con #454 del change anterior).

- [ ] 4.1 **GREEN**: `REVOKE ALL ON FUNCTION public.rpc_process_outbox_batch(integer) FROM PUBLIC, anon, authenticated;` — sin tocar el cuerpo. Enumerar los tres roles explícitamente (gotcha #432). `service_role` **no** se nombra: conserva su EXECUTE.
- [ ] 4.2 **GREEN**: ídem para `public.rpc_mark_event_processed(uuid)`.
- [ ] 4.3 `COMMENT ON FUNCTION` de ambas: abrir con **"SIN GRANT — NO AGREGAR UNO"**, explicar el vector concreto (recorren el outbox de todos los tenants sin filtro, por diseño), nombrar al único caller legítimo (el camino de servicio del disparador manual) y remitir al chequeo (5) del gate.
- [ ] 4.4 Gate anti-overload + verificación de ACLs dentro de la migración: `count(*) = 1` por nombre para las 4 funciones tocadas, y assert de que las dos del outbox quedan `anon = false` y `authenticated = false` mientras `rpc_process_outbox_dispatch` sigue igual. Añadir la verificación —heredada del change anterior— de que `_pay_register_party_charge` y `_journal_post_from_event` **siguen** cerrados, con `RAISE EXCEPTION` apuntando a #454 si alguien los reabrió.
- [ ] 4.5 Reaplicar el archivo **dos veces seguidas** en local y verificar que el segundo apply es no-op: fingerprint `md5` de cuerpos + ACLs (`anon`/`authenticated`/`service_role`) + `COMMENT` de las 4 funciones tocadas, antes y después.

## 5. Backend — h2 bis: un solo despachador [OQ-3]

- [ ] 5.1 **RED**: `backend/tests/outbox/test_process_pending_endpoint.py` — `POST /outbox/process-pending` con un usuario **no** admin de plataforma → 403. Debe fallar hoy (hoy devuelve 200).
- [ ] 5.2 **GREEN**: reescribir `backend/routers/outbox.py` — `get_service_conn` en lugar de `get_db_conn`, `await require_platform_admin(conn, auth)` importado de `backend.core.guards` (**reutilizar**, no escribir un `require_admin` nuevo; molde exacto en `backend/routers/fiscal.py` L225-226), y delegar en `OutboxRepository.run_dispatch`. **Corregir el docstring**: hoy afirma "Called by the pg_cron job relay-process-outbox" y el cron llama a `rpc_process_outbox_dispatch(100)` desde el pivot de C-25.
- [ ] 5.3 **GREEN**: agregar `OutboxRepository.run_dispatch(batch_limit)` → `SELECT public.rpc_process_outbox_dispatch($1::int)`. Retirar `fetch_pending_batch`, `mark_processed`, `insert_audit_log`, `insert_email_log` y `claim_idempotency`. **Conservar `emit_event`**: lo usan `purchase_repository.py` L349 y `stock_repository.py` L86.
- [ ] 5.4 **GREEN**: eliminar `backend/services/outbox_relay_service.py`. Verificar por `grep` que no queda ninguna referencia fuera de tests.
- [ ] 5.5 **TRIANGULATE**: admin de plataforma → 200 y el cuerpo informa `processed`. Mock de `asyncpg` con el molde de los tests existentes.
- [ ] 5.6 **TRIANGULATE — candado del contrato del que depende D3 (OQ-6).** Test que afirme que `get_service_conn` **no adopta el rol de aplicación** con las dos palancas (`TENANCY_TX_SCOPE_ENABLED`, `TENANCY_RLS_ROLE_ENABLED`) **encendidas**. Hoy ese contrato vive sólo en un docstring de `backend/core/database.py` y en el design de `v31-tenancy-pool-rls`; sin este test, todo D3 se apoya en una suposición. Le sirve también a aquel change.
- [ ] 5.7 Reemplazar los cinco archivos de `backend/tests/outbox/` que testean el relay retirado (`test_audit_consumer.py`, `test_email_consumer.py`, `test_idempotency.py`, `test_relay_select.py`, `test_e2e_outbox.py`) por tests del disparador nuevo. **No borrar cobertura sin reemplazarla**: los invariantes de los consumers 1-4 los cubre el dispatcher SQL y sus gates — anotar explícitamente dónde vive ahora cada invariante que se retira.
- [ ] 5.8 Correr la suite backend completa y comparar contra el baseline de 1.2. Explicar el delta (los tests retirados y los agregados), no sólo reportar el número.

## 6. CI — gates y cadena de reapply

- [ ] 6.1 Agregar `20261012000001_tenancy_guard_caja_outbox.sql` como **último eslabón** de la cadena del step "Verify G1/G4 migrations are idempotent on reapply", con comentario propio. Va último por el mismo motivo que el eslabón anterior: el reapply de migraciones viejas re-otorga GRANTs en silencio (`20261001000001` L137, `20261004000001` L1778), y el gate final de esta migración **audita** el estado que dejan los eslabones previos, incluido el de #454.
- [ ] 6.2 Descubrir la lista **real** de funciones que leen (`FROM public.events`) o actualizan (`UPDATE public.events`) el outbox, contra la DB de CI post-migraciones **y** contra prod. Comparar y anotar diferencias. Al escribirse el propose eran **exactamente 4** en prod: `rpc_process_outbox_dispatch` (no expuesta, correcta), `rpc_process_outbox_batch` y `rpc_mark_event_processed` (expuestas — se revocan), y `rpc_atomic_update_sale_operation` (expuesta y **legítima**: hace el reemplazo in-place del evento pendiente que introdujo `asiento-venta-formulario`, sobre una operación ya verificada por cuenta).
- [ ] 6.3 **RED**: agregar el **chequeo (5)** a `supabase/tests/test_function_acl_gate.sql` con la lista `v_cross_tenant_event_fns` **vacía**. Verificar que falla y lista exactamente los offenders de 6.2.
- [ ] 6.4 **GREEN [OQ-7]**: poblar la lista con las 4 entradas y su **veredicto** (`expuesta: no` / `expuesta: sí + justificación`). Criterio: leer o actualizar, **no** insertar — los productores que sólo hacen `INSERT INTO public.events` quedan fuera a propósito (D6, OQ-7), porque incluirlos convertiría una lista de 4 en una de decenas y apagaría el gate.
- [ ] 6.5 Documentar en el encabezado del gate: por qué existe el chequeo (5) y qué punto ciego cubre (el (4) excluye `rpc_*` a propósito, y h2 vivía en dos `rpc_*` — **el gate vigente no lo habría atrapado**); por qué el criterio es leer/actualizar y no insertar; por qué **no** se intentó un chequeo del tipo "lee una tabla con `account_id` sin filtrar por tenant" (no es implementable con honestidad por análisis de texto: no distingue "menciona `account_id`" de "filtra por `account_id`"); y la regla de mantenimiento (la lista sólo crece; agregar exige justificación en el PR).
- [ ] 6.6 **TRIANGULATE**: control negativo — verificar que el chequeo (5) **no** reporta a los productores de eventos (los `rpc_*` que sólo insertan), y que los chequeos (1)(2)(3)(4) siguen dando exactamente lo mismo que en el baseline de 1.3.
- [ ] 6.7 **Control positivo de cada chequeo nuevo**, en `BEGIN … ROLLBACK` por separado: (a) `GRANT EXECUTE … TO authenticated` sobre `rpc_process_outbox_batch` → el (5) falla listando exactamente esa firma; (b) verificar que tras el `ROLLBACK` `has_function_privilege` vuelve a `false`. Un gate sin control positivo puede estar pasando en falso.
- [ ] 6.8 Agregar el step `Run tenancy-guard-caja-outbox gates` con `-v ON_ERROR_STOP=1` (sin la flag, `psql` imprime los `RAISE EXCEPTION` y sale 0 — los asserts fallidos se verían verdes), con comentario de qué cubre. Validar el YAML con `yaml.safe_load`.
- [ ] 6.9 Con un `npx supabase db reset` limpio, correr la cadena de reapply completa en el orden exacto de CI y después **los 31 gates**, y verificar que están todos verdes. El gate nuevo debe correr **dos veces seguidas en verde** sin residuos (candado del cleanup de 2.1).

## 7. Auditoría del daño histórico en prod (read-only)

> **Sólo `SELECT`.** Los tres conteos preliminares del propose dieron **0**; se re-miden acá y se guarda la salida completa en `baseline/prod_damage_audit_<fecha>.md`.

- [ ] 7.1 Movimientos de caja cuya sesión pertenece a un tenant distinto del de la **orden** que los originó:
  ```sql
  SELECT count(*) FROM public.cash_movements cm
    JOIN public.cash_sessions cs ON cs.id = cm.session_id
    JOIN public.cashboxes cb     ON cb.id = cs.cashbox_id
    JOIN public.branches b       ON b.id  = cb.branch_id
    JOIN public.sales_orders so  ON so.id = cm.reference_id
   WHERE so.account_id IS DISTINCT FROM b.account_id;
  ```
- [ ] 7.2 Espejo por **venta** (el camino del formulario, `reference_id = operation_id`):
  ```sql
  SELECT count(*) FROM public.cash_movements cm
    JOIN public.cash_sessions cs ON cs.id = cm.session_id
    JOIN public.cashboxes cb     ON cb.id = cs.cashbox_id
    JOIN public.branches b       ON b.id  = cb.branch_id
    JOIN public.sales s          ON s.operation_id = cm.reference_id
   WHERE s.account_id IS DISTINCT FROM b.account_id;
  ```
- [ ] 7.3 Eventos con `processed_at` seteado que **nunca** produjeron su asiento (síntoma del consumidor lesivo):
  ```sql
  SELECT count(*) FROM public.events e
   WHERE e.processed_at IS NOT NULL
     AND e.event_type IN ('SaleConfirmed','PurchaseCreated','SaleOperationCreated',
                          'SaleOperationAdjusted','PaymentReceived','PaymentMade',
                          'CreditNoteIssued','SaleOperationDeleted','PurchaseDeleted')
     AND NOT EXISTS (SELECT 1 FROM public.journal_entries j WHERE j.source_event_id = e.id);
  ```
- [ ] 7.4 Espejo del anterior para el consumer de notificaciones (`CashSessionClosed`, `StockBelowMinimum`, `FiscalDocumentRejected`, `QuoteAccepted`, `TransferDispatched` procesados sin fila en `notifications`), descontando el caso legítimo de cierre de caja con diferencia cero.
- [ ] 7.5 Contexto de los ceros, para que no sean triviales: `count(*)` de `cash_movements`, `cash_sessions` (y cuántas abiertas), `events` (y cuántos pendientes), `journal_entries`, y `count(DISTINCT account_id)` de eventos. Referencia del propose: 65 / 4 (3 abiertas) / 626 (0 pendientes) / 465 / 10.
- [ ] 7.6 🛑 **Checkpoint**: reportar los conteos al PO. Esperado: **0** en 7.1-7.4.
- [ ] 7.7 🛑 **[OQ-5, sólo si 7.6 > 0]** Script de reparación en `scripts/sql/`, **nunca** dentro de `supabase/migrations/`, gateado por conteos re-medidos inmediatamente antes y firmado por el PO. Atención a RN-99: un movimiento fantasma en una sesión ya **cerrada con arqueo firmado** no se borra — se corrige con contra-movimiento.

## 8. Verificación post-merge (contra prod, sólo `SELECT`)

- [ ] 8.1 Confirmar en prod que `MAX(version)` es `20261012000001` (o el número final tras la re-verificación de 1.1) y el total de migraciones.
- [ ] 8.2 Confirmar por `has_function_privilege` contra **prod** (gotcha #432): `rpc_process_outbox_batch` y `rpc_mark_event_processed` → `anon=false`, **`authenticated=false`**, `service_role=true`; `rpc_process_outbox_dispatch` sin cambios; `_c29_confirm_order_core` y `c28_register_cash_movement` con su `authenticated=true` intacto.
- [ ] 8.3 Confirmar en prod que las dos funciones reescritas tienen **una sola** definición por nombre (gotcha 42725) y que su cuerpo **vivo** contiene el guard: `cash_optin_requires_open_session` en `_c29_confirm_order_core`, y la resolución por `branches` + `current_account_ids()` en `c28_register_cash_movement`.
- [ ] 8.4 Re-correr la query de 6.2 contra prod y confirmar que la lista de funciones que recorren el outbox coincide **exactamente** con la del chequeo (5), sin entradas sobrantes.
- [ ] 8.5 Verificar en prod que el pg_cron job `relay-process-outbox` sigue activo y que `events` no acumula pendientes (`processed_at IS NULL` estable cerca de 0) tras el deploy: es la prueba de que retirar el relay Python no rompió el despacho real.
- [ ] 8.6 🛑 **Demo al PO**: una venta POS en efectivo real, y el intento de disparar `POST /outbox/process-pending` con un usuario no admin (403). Requiere sesión autenticada.
- [ ] 8.7 Registrar en `CHANGES.md` el estado final y actualizar el puntero "Próximo change recomendado" del `CLAUDE.md`. Verificar que **todo** se mergeó vía PR — cero commits directos a `main`, incluidos los fixes triviales post-merge.
- [ ] 8.8 Guardar en engram (`topic_key: opsx/tenancy-guard-caja-outbox/apply`) el resultado: decisiones tomadas, número final de migración, resultado de la auditoría, y cualquier hallazgo lateral nuevo para `CHANGES.md`.
