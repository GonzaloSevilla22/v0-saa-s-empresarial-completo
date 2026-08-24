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

## 4. Migración — h2: cierre del outbox [OQ-1] ✅ CUMPLIDO EN EL HOTFIX

> **OQ-1 firmada por el PO: "h2 sale como hotfix ahora, h1 después".** Este
> grupo entero, más el grupo 5 y la parte de h2 del grupo 6, se ejecutó en el
> PR del hotfix `fix/outbox-cross-tenant-hotfix` — exactamente el desenlace
> que este archivo preveía. Migración: **`20261012000001_revoke_outbox_cross_tenant.sql`**
> (`MAX(version)` de prod re-verificado el 2026-08-24: `20261011000001`, 260
> migraciones). Los grupos de h1 (1.5/1.6/1.9, 2.x de caja, 3.x) **no se
> tocaron** y siguen pendientes en este change.
>
> ⚠️ **Consecuencia para h1**: el número `20261012000001` ya está tomado. La
> migración de h1 renumera —re-verificar el `MAX` vivo antes de escribirla,
> como manda la task 1.1— y deja de llamarse
> `20261012000001_tenancy_guard_caja_outbox.sql`.
>
> Lo que queda por hacer acá cuando arranque el apply de h1: sólo
> **verificar** que el estado sigue cerrado (mismo patrón que la
> reconciliación con #454 del change anterior). El gate final del hotfix ya
> deja esa verificación puesta y permanente.

- [x] 4.1 **GREEN**: `REVOKE ALL ON FUNCTION public.rpc_process_outbox_batch(integer) FROM PUBLIC, anon, authenticated;` — sin tocar el cuerpo. Enumerar los tres roles explícitamente (gotcha #432). `service_role` **no** se nombra: conserva su EXECUTE. → *Evidencia: `supabase/migrations/20261012000001_revoke_outbox_cross_tenant.sql` §1. ACL en local antes `authenticated=true` → después `false`; md5 del cuerpo idéntico antes y después (`b82e7ee2c5a9d33f15f64c4997e6c93f`), o sea que no se tocó ninguna definición.*
- [x] 4.2 **GREEN**: ídem para `public.rpc_mark_event_processed(uuid)`. → *Evidencia: mismo archivo §1; md5 del cuerpo intacto (`db29b2e2e7eda4ba762c716f6253e67e`).*
- [x] 4.3 `COMMENT ON FUNCTION` de ambas: abrir con **"SIN GRANT — NO AGREGAR UNO"**, explicar el vector concreto (recorren el outbox de todos los tenants sin filtro, por diseño), nombrar al único caller legítimo (el camino de servicio del disparador manual) y remitir al chequeo (5) del gate. → *Evidencia: mismo archivo §2.*
- [x] 4.4 Gate anti-overload + verificación de ACLs dentro de la migración: `count(*) = 1` por nombre, y assert de que las dos del outbox quedan `anon = false` y `authenticated = false` mientras `rpc_process_outbox_dispatch` sigue igual. Añadir la verificación —heredada del change anterior— de que `_pay_register_party_charge` y `_journal_post_from_event` **siguen** cerrados, con `RAISE EXCEPTION` apuntando a #454 si alguien los reabrió. → *Evidencia: mismo archivo §3, sub-gates (a) anti-overload, (b) NEG, (c) POS, (d) dispatcher sin cambios, (e) helpers de #454. **Desviación declarada**: el GATE POS afirma sólo `postgres`, no `service_role`. Medido el 2026-08-24: en prod `service_role` tiene EXECUTE sobre las tres RPCs del outbox y en local NO (nacieron con `REVOKE ALL FROM PUBLIC` + `GRANT` sólo a `authenticated`); como el gate corre contra local, afirmarlo rompía CI por una diferencia de entorno. Lo que importa —que ningún `REVOKE` de este archivo nombre a `service_role`— se sostiene por inspección y está documentado en el archivo.*
- [x] 4.5 Reaplicar el archivo **dos veces seguidas** en local y verificar que el segundo apply es no-op. → *Evidencia: **tres** aplicaciones seguidas; fingerprint (md5 del cuerpo + `anon`/`authenticated`/`service_role` + md5 del `COMMENT`) de las tres RPCs del outbox idéntico entre la 1ª, la 2ª y la 3ª. Además la migración corre como último eslabón de la cadena de reapply de CI sobre una DB recién reseteada, con su gate en verde.*

## 5. Backend — h2 bis: un solo despachador [OQ-3] ✅ CUMPLIDO EN EL HOTFIX

- [x] 5.1 **RED**: `backend/tests/outbox/test_process_pending_endpoint.py` — `POST /outbox/process-pending` con un usuario **no** admin de plataforma → 403. Debe fallar hoy (hoy devuelve 200). → *Evidencia: RED ejecutado y fallando con el mensaje exacto previsto: `AssertionError: ... Recibido: 200 {"processed":0}` / `assert 200 == 403`. 16 de los 19 tests del archivo nacieron en rojo.*
- [x] 5.2 **GREEN**: reescribir `backend/routers/outbox.py` — `get_service_conn` en lugar de `get_db_conn`, `await require_platform_admin(conn, auth)` importado de `backend.core.guards` (**reutilizar**, molde en `backend/routers/fiscal.py` L225-226), y delegar en `OutboxRepository.run_dispatch`. **Corregir el docstring**. → *Evidencia: el router quedó en 3 capas finas (router → repository → RPC), sin capa de servicio; el docstring ahora dice que el cron ejecuta `SELECT rpc_process_outbox_dispatch(100)` directo contra la DB y que este endpoint es el disparador manual. Candado: `test_docstring_del_router_corregido` falla si vuelve la frase vieja.*
- [x] 5.3 **GREEN**: agregar `OutboxRepository.run_dispatch(batch_limit)`. Retirar los cinco métodos del relay. **Conservar `emit_event`**. → *Evidencia: `run_dispatch` con default 100 (el mismo lote del pg_cron) y normalización de `None` a `0`; los cinco retiros cubiertos por un test parametrizado (`test_metodos_del_relay_retirado_no_existen`) y `emit_event` por `test_emit_event_se_conserva`. `purchase_repository` y `stock_repository` siguen verdes.*
- [x] 5.4 **GREEN**: eliminar `backend/services/outbox_relay_service.py`. Verificar por `grep` que no queda ninguna referencia fuera de tests. → *Evidencia: `git rm`; `grep` sobre `backend/` deja cero referencias vivas (la única mención restante es una línea de comentario en `backend/tests/migrations/test_events_reconcile.py` que nombra `claim_idempotency` al describir el contrato de `operation_idempotency`, no una llamada). Candado dinámico: `test_el_relay_python_ya_no_existe` exige `ModuleNotFoundError`.*
- [x] 5.5 **TRIANGULATE**: admin de plataforma → 200 y el cuerpo informa `processed`. → *Evidencia: `test_admin_gets_200_con_processed` (`{"processed": 7}`) y `test_admin_llama_al_dispatcher_completo`, que afirma que el SQL emitido nombra `rpc_process_outbox_dispatch` y **no** `rpc_process_outbox_batch` ni `rpc_mark_event_processed`.*
- [x] 5.6 **TRIANGULATE — candado del contrato del que depende D3 (OQ-6).** → *Evidencia: `TestServiceConnNoAdoptaRolDeAplicacion::test_no_adopta_authenticated_con_las_dos_palancas_encendidas` fija **las dos** palancas en `True` y exige cero sentencias emitidas y cero transacciones abiertas. Complementa —no duplica— al `test_get_service_conn_has_no_request_transaction_or_claims` existente, que sólo encendía el Paso 1. Segundo candado estático: `test_el_endpoint_cuelga_del_camino_de_servicio`.*
- [x] 5.7 Reemplazar los cinco archivos de tests del relay retirado. **No borrar cobertura sin reemplazarla**: anotar dónde vive ahora cada invariante. → *Evidencia: tabla invariante-por-invariante en el PR del hotfix. Resumen: las aserciones **estáticas** (orden y presencia de los 4 consumers, etiquetas de `consumer_type`, scoping del email, sentinel de idempotencia, `FOR UPDATE SKIP LOCKED`, "nunca UPDATE/DELETE sobre `audit_logs`", aislamiento por evento) ya vivían en `backend/tests/migrations/test_events_reconcile.py` y siguen corriendo; las de **comportamiento** —que los mocks simulaban— se mudaron a `supabase/tests/test_outbox_single_dispatcher.sql`, donde se afirman contra el despachador real en Postgres real. Se agregó cobertura que NO existía en ningún lado: la prueba en runtime de que un consumer fallido deja el evento pendiente **sin efectos parciales** y sin abortar el lote (gate (3)), y de que el retry lo preserva (gate (5)). Los dos archivos que no dependían del relay (`test_journal_consumer.py`, `test_producers.py`, 78 tests) se conservan intactos.*
- [x] 5.8 Correr la suite backend completa y comparar contra el baseline de 1.2. Explicar el delta. → *Evidencia: baseline **1604 passed / 3 skipped** → **1575 passed / 3 skipped**. Delta = **−29**, que cuadra exactamente: **−48** por los cinco archivos retirados (`test_relay_select` 13, `test_email_consumer` 13, `test_audit_consumer` 9, `test_e2e_outbox` 7, `test_idempotency` 6) **+19** del archivo nuevo. Cero fallos colaterales y cero cambios en los 3 skipped.*

## 6. CI — gates y cadena de reapply

> **Parcialmente cumplido en el hotfix de h2** (6.2-6.7 completas). Lo que
> queda es la parte de h1: su propio eslabón de reapply y el step de
> `test_tenancy_guard_caja_outbox.sql`. El chequeo (5) del gate de ACLs **ya
> está puesto y verde**, y el gate de comportamiento del outbox
> (`test_outbox_single_dispatcher.sql`) ya corre en CI con step propio.

- [ ] 6.1 Agregar `20261012000001_tenancy_guard_caja_outbox.sql` como **último eslabón** de la cadena del step "Verify G1/G4 migrations are idempotent on reapply", con comentario propio. Va último por el mismo motivo que el eslabón anterior: el reapply de migraciones viejas re-otorga GRANTs en silencio (`20261001000001` L137, `20261004000001` L1778), y el gate final de esta migración **audita** el estado que dejan los eslabones previos, incluido el de #454.
- [x] 6.2 Descubrir la lista **real** de funciones que leen (`FROM public.events`) o actualizan (`UPDATE public.events`) el outbox, contra la DB de CI post-migraciones **y** contra prod. Comparar y anotar diferencias. → *Evidencia (2026-08-24): **exactamente 4 en prod y las mismas 4 en local**, con firmas idénticas — `rpc_process_outbox_dispatch(p_batch_limit integer)` (no expuesta, modelo correcto), `rpc_process_outbox_batch(p_batch_limit integer)` y `rpc_mark_event_processed(p_event_id uuid)` (expuestas, las cierra el hotfix) y `rpc_atomic_update_sale_operation(...11 args...)` (expuesta y legítima). **Cero diferencias entre prod y local**, que era justamente el riesgo a descartar.*
- [x] 6.3 **RED**: agregar el **chequeo (5)** y verificar que falla listando exactamente los offenders. → *Evidencia: en vez de dejar la lista vacía (que habría listado también las dos legítimas y probado poco), el RED se hizo con dos controles positivos independientes en `BEGIN … ROLLBACK` — ver 6.7. El (5) quedó partido en (5a) "no enumerada" y (5b) "enumerada como no expuesta pero alcanzable", y los dos se probaron en rojo por separado.*
- [x] 6.4 **GREEN [OQ-7]**: poblar la lista con las 4 entradas y su **veredicto**. Criterio: leer o actualizar, **no** insertar. → *Evidencia: `v_cross_tenant_event_fns` (4 entradas, cada una con su veredicto en el comentario de al lado) + `v_cross_tenant_event_exposed_ok` (1 entrada: `rpc_atomic_update_sale_operation`, con la justificación de por qué su acceso al outbox está acotado a la operación que ella misma ya validó por tenant). Gate verde: "4 funciones que recorren el outbox enumeradas, de las cuales 1 con exposición justificada".*
- [x] 6.5 Documentar en el encabezado del gate el porqué del chequeo (5), el punto ciego que cubre, el criterio leer/actualizar, por qué **no** se intentó el chequeo de "account_id sin filtrar", y la regla de mantenimiento. → *Evidencia: bloque de comentario nuevo en la cabecera de `supabase/tests/test_function_acl_gate.sql`, con los cuatro puntos y el "lo que el (5) NO puede hacer, dicho en voz alta".*
- [x] 6.6 **TRIANGULATE**: control negativo — el chequeo (5) **no** reporta a los productores de eventos, y los chequeos (1)(2)(3)(4) siguen igual. → *Evidencia: en `BEGIN … ROLLBACK`, una función `SECURITY DEFINER` nueva que sólo hace `INSERT INTO public.events` (revocada, para no disparar los chequeos (2) y (4)) deja el gate **verde**. Y los 31 gates del workflow corren en verde sobre una DB reseteada + la cadena de reapply completa, con el (1)(2)(3)(4) dando los mismos conteos que el baseline (5 firmas / 3 helpers / 1 firma interna).*
- [x] 6.7 **Control positivo de cada chequeo nuevo**, en `BEGIN … ROLLBACK` por separado. → *Evidencia, tres controles: (a) `GRANT EXECUTE … TO authenticated` sobre `rpc_process_outbox_batch` → **(5b) falla** listando exactamente esa firma; (b) una función `SECURITY DEFINER` nueva que hace `SELECT ... FROM public.events`, revocada y sin enumerar → **(5a) falla** listándola; (c) tras cada `ROLLBACK`, `has_function_privilege('authenticated', ...)` vuelve a `false` y no queda ninguna función `rpc_probe%`. Además el gate de comportamiento nuevo tiene su propio control positivo por **mutación**: neutralizar `_journal_post_from_event` en una transacción hace fallar su gate (3) —"quedó cerrado sin su asiento"—, que es la prueba de que ese assert no pasa en falso.*
> Nota de 6.8/6.9 (hotfix de h2): el step del gate de **comportamiento** del
> outbox ya está puesto — `Run outbox single-dispatcher gates`, con
> `-v ON_ERROR_STOP=1` y comentario propio; el YAML valida con `yaml.safe_load`
> (37 steps). El chequeo (5) no necesitó step: vive dentro de
> `test_function_acl_gate.sql`, que ya corría. Lo que sigue pendiente de 6.8 es
> el step del gate de **h1** (`test_tenancy_guard_caja_outbox.sql`), que aún no
> existe.

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
