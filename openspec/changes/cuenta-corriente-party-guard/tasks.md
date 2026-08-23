# Tasks — `cuenta-corriente-party-guard`

> **Strict TDD activo.** Cada task de código sigue RED → GREEN → TRIANGULATE → REFACTOR, con safety net previo sobre lo que se toca. Los tests van **antes** de la implementación, nunca después.
>
> **Governance MEDIUM** (tramo de severidad alta en el grupo 5). Los checkpoints 🛑 requieren mostrarle el resultado al PO antes de seguir.
>
> Las tasks marcadas **[OQ-n]** dependen de la respuesta del PO a la Open Question correspondiente de `design.md`. Sin respuesta, se implementa la **recomendación**.
>
> **Estado del apply (2026-08-23)**: el PO no respondió ninguna OQ → se implementó la **recomendación** de cada una. OQ-1 = **B** (choke point + 3 RPCs). OQ-2 = **entra en este change**. OQ-3 = **allowlist con comentario** (una sola entrada: `_c29_confirm_order_core`). OQ-4 = fuera de alcance. OQ-5 = no aplica (0 filas). OQ-6 = no.
>
> **Rama**: `opsx/cuenta-corriente-party-guard-apply`. Sin push ni PR — eso lo hace la fase siguiente.

## 1. Reconocimiento y safety net

- [x] 1.1 Verificar el **MAX de `supabase_migrations.schema_migrations` vivo en prod** (`npx supabase migration list`, o `SELECT max(version) …`). Confirmar que el archivo nuevo se llama `20261008000001_cuenta_corriente_party_guard.sql` — `20261007000001` lo tomó `cuentas_billetera_tipo` (PR #447, mergeada mientras este propose estaba en revisión). Si prod está adelante de `20261007000001`, renumerar y anotarlo en el PR.
  > **Evidencia**: `MAX(version)` en prod = `20261007000001` (medido 2026-08-23) → el archivo nació como `20261008000001_cuenta_corriente_party_guard.sql`.
  > **RENUMERADO 2026-08-23 (post-rebase)**: `compras-proveedor-cuenta-corriente` (PR #452) se merguó mientras esta rama estaba en revisión y tomó `20261009000001`, que es el **MAX vivo de prod** ahora (258 migraciones). Un archivo con número menor al MAX remoto no lo aplica el push automático → el archivo pasa a `supabase/migrations/20261010000001_cuenta_corriente_party_guard.sql`.
- [x] 1.2 Correr la suite backend completa (`pytest`) y registrar el baseline `N/N passing` (esperado 1495/1495). Cualquier fallo preexistente se **reporta**, no se arregla en este change.
  > **Evidencia**: `python -m pytest backend/tests -q -p no:cacheprovider` → **1530 passed / 0 failed / 3 skipped** (31 s). El baseline real es 1530, no 1495 (el proposal citaba un número viejo). Cero fallos preexistentes.
- [x] 1.3 Levantar el stack local (`supabase db reset`) y correr los siete gates de dinero vigentes en el orden de CI, registrando el baseline: `test_function_acl_gate.sql`, `test_errcode_5char_gate.sql`, `test_idempotency.sql`, `test_pagos_cableados_restantes.sql`, `test_delete_guard_ledgers.sql`, `test_asiento_venta_formulario.sql` y `test_cuentas_billetera_tipo.sql` (PR #447).
  > **Evidencia**: DB local a `20261007000001`; los 7 gates verdes en el orden de CI (`test_idempotency` 17/17). Roles `anon`/`authenticated`/`service_role` presentes; `SET LOCAL ROLE authenticated` verificado como mecanismo viable para los asserts 5.1/5.2.
- [x] 1.4 🛑 **Gate de integridad de función.** Capturar `pg_get_functiondef` **vivo en prod** de las cinco funciones a reescribir y guardarlas en `openspec/changes/cuenta-corriente-party-guard/baseline/<nombre>.sql` con la cabecera de procedencia (molde: `openspec/changes/archive/2026-08-22-delete-guard-ledgers/baseline/`): `c30_get_or_create_customer_account(uuid,uuid)`, `c30_get_or_create_supplier_account(uuid,uuid)`, `rpc_register_payment_received(text,uuid,numeric,uuid,text,uuid)`, `rpc_register_payment_made(text,uuid,numeric,uuid,text,uuid)`, `rpc_register_supplier_charge(text,uuid,numeric,uuid)`. **El propose no pudo capturarlos** (sin contraseña en `supabase/.temp/pooler-url`, lectura de `backend/.env` denegada) — esta task es obligatoria.
  > **Evidencia**: 7 archivos en `openspec/changes/cuenta-corriente-party-guard/baseline/` (las 5 reescritas + los 2 helpers revocados) + `prod_acl_audit_2026-08-23.md`, con cabecera de procedencia y **md5 verificado contra prod**. Commit `e0099e0`.
- [x] 1.5 🛑 Diffear cada baseline contra el archivo de migración de referencia: `20260907000001` L487 (`payment_received`) y L678 (`payment_made`), `20260720000001` L895 (`supplier_charge`), `20260720000001` L443 y L478 (los dos helpers). **Si difieren en una sola línea, reportar antes de escribir SQL** — es exactamente así como se perdió el bloque `credit` de C-30 en julio.
  > **Evidencia**: las 5 son **byte-idénticas** a sus referencias locales. En particular `rpc_register_supplier_charge` (nunca redefinida desde C-30) tiene diff **vacío**, como anticipaba la task 4.3. Se partió igual del baseline (regla de la casa). Verificación adicional en la otra dirección: script que extrae los 5 cuerpos de la migración, les quita el guard y la variable declarada, y los diffea contra el baseline → **5/5 OK**, la única diferencia admisible es el guard.
- [x] 1.6 Auditar en **prod** el estado real de permisos de los helpers internos […]. Guardar la salida — es el insumo de la allowlist del gate (6.2) y la línea de base del grupo 5. Recordar el gotcha #432.
  > **Evidencia**: `baseline/prod_acl_audit_2026-08-23.md` (22 filas). Offenders reales del futuro chequeo (3) en prod: **exactamente 3** — `_c29_confirm_order_core`, `_journal_post_from_event`, `_pay_register_party_charge`.
  > **CORRECCIÓN al `design.md` y a la task 6.4**: `c28_register_cash_movement` **NO es SECURITY DEFINER** en prod ni en local → no es offender, y no entra a la allowlist.
  > **Gotcha #432 confirmado con datos**: `c30_get_or_create_customer_account`/`supplier_account` y `c30_register_*_account_movement` son **anon-executable EN PROD** (concesión directa) y **no** lo son en local. De ahí que todos los REVOKE nombren `PUBLIC, anon, authenticated`.
  > `service_role` tiene EXECUTE en los 3 offenders **en prod** (y en ninguno en local): no se lo nombra en ningún REVOKE, conserva su permiso.
- [x] 1.7 Confirmar que ningún consumidor de aplicación invoca los helpers a revocar […]. Anotar el resultado en el PR.
  > **Evidencia**: **0 consumidores reales**. Solo comentarios, tests que parsean el `.sql`, y `frontend/lib/database.types.ts` (generado) — cuya presencia confirma que PostgREST los expone.

## 2. Test SQL — RED

- [x] 2.1 **RED**: crear `supabase/tests/test_cuenta_corriente_party_guard.sql` con el molde de `test_delete_guard_ledgers.sql` […].
  > **Evidencia**: archivo creado con el molde exacto (`DO $$ … $$` único, `set_config('request.jwt.claims', …, true)`, degrade-don't-fail con `auth.uid()`), **dos tenants sintéticos** A y B provisionados por el trigger de `auth.users` → `account_members` (verificado: cuentas distintas, 7 formas de pago sembradas, `is_account_writer` true). Sin BOM (`head -c 3 | od -c` → `-  -  espacio`). ERRCODEs de 5 chars. Commit `36dbf5c`.
- [x] 2.2 **RED**: assert de `rpc_register_payment_received` con el `client_id` del tenant B → `P0404`. Debe **fallar hoy**.
  > **RED**: hoy devuelve `P0409 overpayment` — la fila cross-tenant en `customer_accounts` **se crea igual**, el error llega después desde el helper de movimientos. **GREEN**: `P0404` + 0 cuentas cross-tenant.
- [x] 2.3 **RED**: assert de `rpc_register_payment_made` con `supplier_id` ajeno → `P0404`.
  > **RED**: `P0409 overpayment` (mismo mecanismo que 2.2). **GREEN**: `P0404`.
- [x] 2.4 **RED**: assert de `rpc_register_supplier_charge` con `supplier_id` ajeno → `P0404`.
  > **RED**: la llamada **tuvo éxito** y dejó 1 `supplier_accounts` cross-tenant. **GREEN**: `P0404`.
- [x] 2.5 **RED [OQ-1]**: `rpc_create_sale_operation_v2` con `kind='credit'` y `client_id` del tenant B → `P0404`, **y** cero filas nuevas en `sales`, `sale_items`, `customer_accounts`, `customer_account_movements`, `stock_movements` y `events`.
  > **RED**: la venta **se creó normalmente**, con 1 cuenta corriente cross-tenant. **GREEN**: `P0404` + los 6 conteos sin cambios.
- [x] 2.6 **RED [OQ-1]**: espejo por el camino POS (`rpc_quick_sale` con `kind='credit'` y cliente ajeno) → `P0404`, orden no confirmada.
  > **RED**: la venta del POS **se confirmó**, dejando 1 `sales_orders` contra el cliente ajeno. **GREEN**: `P0404` + 0 `sales_orders`.
- [x] 2.7 Verificar que el archivo corre y **falla** contra el schema actual, y anotar cuáles de los 5-6 asserts fallan. Eso es el RED del change entero.
  > **Evidencia**: el gate (fail-fast, como el molde) aborta en 2.2. Para el inventario completo se corrió un **diagnóstico independiente** que prueba cada comportamiento por separado, versionado en `openspec/changes/cuenta-corriente-party-guard/baseline/red_probe_2026-08-23.sql` (read-only: todo dentro de `BEGIN … ROLLBACK`; el archivo documenta cómo reproducir el RED). Resultado — **todos los asserts del change en rojo**:
  > | assert | comportamiento HOY | esperado |
  > |---|---|---|
  > | choke point cliente | ÉXITO, **1 fila cross-tenant creada** | P0404 / 0 |
  > | choke point proveedor | ÉXITO, **1 fila cross-tenant creada** | P0404 / 0 |
  > | 2.2 / 2.3 | `P0409 overpayment` (la fila entra igual) | P0404 |
  > | 2.4 / 2.5 / 2.6 / 4.7a | **ÉXITO** | P0404 |
  > | 3.6 (id inexistente) | `23503` FK violation — **distinto** del caso "ajeno", o sea que hoy el error revela si el id existe en otro tenant | P0404 idéntico |
  > | 5.1 | **ÉXITO: 1 `customer_accounts` escrita en los libros REALES del tenant víctima** desde `SET LOCAL ROLE authenticated` | 42501 / 0 |
  > | 5.2 | **ÉXITO: 1 asiento contable posteado en el tenant víctima** con un evento forjado | 42501 / 0 |
  > Ya verdes hoy (son **candados de orden**, no fixes): 4.6 (`amount=0` → `P0400`) y 4.7b (bank inexistente → `P0412`).

## 3. Migración — guard en el choke point (opción B) [OQ-1]

- [x] 3.1 Crear `supabase/migrations/20261010000001_cuenta_corriente_party_guard.sql` (renumerada desde `20261008000001`, ver 1.1) con la cabecera del proyecto […]. **Sin BOM UTF-8**.
  > **Evidencia**: cabecera con las dos familias del hallazgo, D1/D2/D3/D5/D6, MAX de prod, procedencia del baseline, gotcha #432, nota de `service_role`, "ninguna firma cambia" y la declaración BREAKING. Sin BOM (verificado). Commit `c84d636`.
- [x] 3.2 **GREEN**: `c30_get_or_create_customer_account(uuid, uuid)` partiendo del cuerpo capturado en 1.4, con el guard canónico de `rpc_create_customer_account` (`20260720000001` L537-542) **antes** del `INSERT ... ON CONFLICT`. Sin helper nuevo.
  > **Evidencia**: guard + `v_client uuid;` en el DECLARE; el resto byte-idéntico al baseline. Sigue **SECURITY INVOKER** (no se convierte en DEFINER — D3 "sin rediseño").
- [x] 3.3 **GREEN**: espejo exacto en `c30_get_or_create_supplier_account(uuid, uuid)` contra `public.suppliers`, con `supplier_not_found: %` y el mismo `P0404`.
- [x] 3.4 ACLs de los dos helpers: `REVOKE ALL … FROM PUBLIC, anon, authenticated;` **sin `GRANT`**. `COMMENT ON FUNCTION` actualizado citando el guard.
  > **Evidencia**: ACL final en local `anon=f, authenticated=f` para ambos. Los `COMMENT` los nombran CHOKE POINT y explican que son internos.
- [x] 3.5 **TRIANGULATE**: control positivo — cliente/proveedor **del mismo tenant** sin cuenta corriente previa: la cuenta se crea en el mismo commit y el movimiento queda con el `balance_after` esperado.
  > **Evidencia**: 5 sub-casos verdes. 3.5a venta a crédito con cliente propio fresco → cuenta creada, `balance = 1000` (+1 evento `CustomerAccountCharged`); 3.5b cobro de 400 → `balance_after = 600`, `replayed = false`; 3.5c cargo de 700 a **`v_supplier_a2`, un proveedor virgen** → cuenta creada en el mismo commit con `balance = 700`; 3.5d cargo de 700 sobre `v_supplier_a` (que ya tenía 5000 desde 2.3) → `balance_after = 5700`; 3.5e pago de 300 → `balance_after = 5400`.
  > **CORRECCIÓN (2026-08-23)**: la versión original decía "proveedor propio FRESCO" pero usaba `v_supplier_a`, al que **2.3 ya le había creado la cuenta corriente con 5000** — por eso esperaba 5700. Con ese proveedor, "la cuenta se crea en el mismo commit" nunca se ejercitaba del lado proveedor. Se agregó `v_supplier_a2`, virgen, con una precondición explícita de 0 cuentas antes del cargo.
- [x] 3.6 **TRIANGULATE**: identificador **inexistente** → mismo `P0404`, mismo mensaje.
  > **Evidencia**: el assert compara los dos mensajes con el UUID normalizado a `<id>` y exige que sean idénticos. Antes de la migración **no** lo eran (`23503` vs. `P0409`) — el guard cierra también esa fuga de información.
- [x] 3.7 **TRIANGULATE**: `rpc_create_customer_account` y `rpc_create_supplier_account` siguen comportándose igual con el guard ahora duplicado.
  > **Evidencia**: 4 asserts (propio → OK con id devuelto; ajeno → `P0404`) por cliente y por proveedor. Redundancia deliberada confirmada.
- [x] 3.8 Verificar que 2.5 y 2.6 pasan **sin haber tocado** `rpc_create_sale_operation_v2` ni `_c29_confirm_order_core`.
  > **Evidencia**: la migración no contiene ninguna de esas dos funciones (`grep` sobre el archivo) y los dos asserts pasan. Es la prueba de que el choke point cubre todo caller, presente y futuro.

## 4. Migración — guard explícito en las tres RPCs de pago

- [x] 4.1 **GREEN**: `rpc_register_payment_received(...)` desde el baseline de 1.4, con el guard de cliente **después** de la validación de `bank_account` y **antes** del `INSERT` en `operation_idempotency` (D2). Enumerar cada bloque preservado byte a byte.
  > **Evidencia**: bloques preservados (verificado por script, diff vacío salvo el guard): `auth.uid()`, `current_account_ids()`, `is_account_writer`, `amount` (P0400), taxonomía de `payment_method` (P0400), bloque `bank_accounts` (P0412 not_found + inactive), idempotencia DEC-06 y su rama de replay, `c30_register_customer_account_movement` con signo negativo, `payments_received`, `_register_bank_movement` con `reporting_local_today()` (card → `card_settlement`, resto → `transfer_in`) y el evento `PaymentReceived` con `payment_method`/`bank_account_id`.
- [x] 4.2 **GREEN**: espejo en `rpc_register_payment_made(...)` con el guard de proveedor.
  > **Evidencia**: mismos bloques que 4.1, con `transfer_out` y `payments_made`. Diff contra baseline vacío salvo el guard.
- [x] 4.3 **GREEN**: espejo en `rpc_register_supplier_charge(...)`. Es la única de las tres nunca redefinida desde C-30, así que el diff de 1.5 debería ser vacío — confirmarlo explícitamente.
  > **Evidencia**: **confirmado, diff vacío**. Sin bloque bancario, el guard va directo después de la validación de `amount`.
- [x] 4.4 ACLs de las tres RPCs: `REVOKE ALL … FROM PUBLIC; REVOKE EXECUTE … FROM anon; GRANT EXECUTE … TO authenticated;`. `COMMENT ON FUNCTION` nombrando `P0404`.
  > **Evidencia**: ACL final `anon=f, authenticated=t` en las 3. Los `COMMENT` nombran `P0404` y la ubicación del guard.
- [x] 4.5 **TRIANGULATE**: la **clave de idempotencia no se quema** en el rechazo.
  > **Evidencia**: cobro rechazado por cliente ajeno con la clave `gate-ccpg-4-5-shared` → 0 filas en `operation_idempotency` para esa clave; reintento con la misma clave y un cliente válido → `replayed = false`, `payment_id` no nulo, `balance_after = 500`.
> **Dónde vive el candado de D2 (nota 2026-08-23)**: 4.5, 4.6 y 4.7 siguen siendo válidos como asserts de **comportamiento**, pero ninguno de ellos —ni ningún otro assert del gate— detecta que las 3 RPCs vuelvan a su cuerpo pre-guard: el choke point levanta el mismo `P0404` y todo queda verde. Verificado empíricamente (`BEGIN; <baseline/rpc_register_supplier_charge.sql>; ROLLBACK;` → el proveedor ajeno sigue dando `P0404`). El candado real de la capa 2 de D1 y de la ubicación de D2 es el bloque **(4.1-4.3)** que se agregó al gate: `pg_get_functiondef` de cada RPC, presencia del literal del guard y su `position()` **después** del último guard de payload (`bank_account_not_found` / `invalid_amount`) y **antes** del `INSERT INTO public.operation_idempotency`.

- [x] 4.6 **TRIANGULATE**: cliente ajeno **y** `amount = 0` → `P0400`, no `P0404`.
  > **Evidencia**: verde. Ya lo era antes de la migración — es un **candado de orden**, no un fix, y congela la ubicación de D2.
- [x] 4.7 **TRIANGULATE**: cobro por transferencia con cliente ajeno → `P0404` y **cero** filas en `bank_movements`.
  > **Evidencia**: 4.7a verde (antes de la migración esa llamada **tenía éxito**). Se agregó **4.7b**, no pedido pero necesario para que el assert de ordenamiento no sea vacuo: cliente ajeno + `bank_account` inexistente → `P0412`, no `P0404`, congelando que el bloque bancario corre **antes** del guard de parte.
- [x] 4.8 Gate anti-overload dentro de la migración: `count(*) = 5`.
  > **Evidencia**: `DO` block al final del archivo, contando por `pronamespace = 'public'::regnamespace`. Además verifica las ACLs de los 4 helpers cerrados y de las 3 RPCs públicas (control negativo: el REVOKE no se pasó de rosca). NOTICE: *"5 funciones con una sola definición, 4 helpers internos cerrados a anon/authenticated, 3 RPCs públicas con su GRANT intacto"*.
- [x] 4.9 Reaplicar el archivo **dos veces seguidas** en local y verificar que el segundo apply es no-op.
  > **Evidencia**: fingerprint `md5` de cuerpos + ACLs (`anon`/`authenticated`/`service_role`) + `COMMENT` de las **7** funciones tocadas, antes y después de dos reapplies: `ede70627516cce14346ec66696fd633a` → **idéntico**, sin error.

## 5. Migración — cierre de la primitiva de escritura cross-tenant [OQ-2 🛑]

> 🛑 **Checkpoint OQ-2**: el PO no respondió → se implementa la **recomendación**: el tramo **entra en este change**.
>
> **Resuelto 2026-08-23 — se separó como hotfix** (orden del PO): PR #454, ver `supabase/migrations/20261010000001_revoke_internal_money_helpers.sql` (rama `fix/revoke-internal-money-helpers`). Este grupo entero queda SUPERSEDED — el `REVOKE` de 5.3/5.4 ya está aplicado en `main`; no repetirlo acá. Ver nota en `design.md` OQ-2.

- [x] 5.1 **RED**: con `SET LOCAL ROLE authenticated`, invocar `_pay_register_party_charge(<account_id de B>, 'customer', <client_id de B>, 1000, …)` y esperar `insufficient_privilege` (42501).
  > **RED**: la llamada **tuvo éxito y escribió 1 `customer_accounts` en los libros reales del tenant víctima**. **GREEN**: `42501`, más un assert de `has_function_privilege('authenticated', …) = false`. El mecanismo `EXECUTE 'SET LOCAL ROLE authenticated'` / `EXECUTE 'RESET ROLE'` dentro del `DO` block resultó viable (probado antes de escribirlo) — no hizo falta el fallback de `has_function_privilege`, que se usa igual como assert adicional.
- [x] 5.2 **RED**: espejo con `_journal_post_from_event(<fila events forjada con account_id de B>)` → `insufficient_privilege`.
  > **RED**: la llamada **tuvo éxito y posteó 1 asiento contable en el tenant víctima**. **GREEN**: `42501`. El evento se forja e inserta **como `postgres`, antes** del cambio de rol: lo que se prueba es el EXECUTE, no el acceso a la tabla.
- [x] 5.3 **GREEN**: `REVOKE ALL ON FUNCTION public._pay_register_party_charge(uuid, text, uuid, numeric, uuid, uuid) FROM PUBLIC, anon, authenticated;` — sin tocar el cuerpo.
  > **Evidencia**: solo ACL + `COMMENT`; el cuerpo queda intacto (no aparece ningún `CREATE OR REPLACE` de esa función en el archivo).
- [x] 5.4 **GREEN**: `REVOKE ALL ON FUNCTION public._journal_post_from_event(public.events) FROM PUBLIC, anon, authenticated;`.
  > **Evidencia**: restaura el estado de `20260803000001` L517 perdido en `20261001000001` L1914.
- [x] 5.5 **TRIANGULATE**: una venta a crédito completa (formulario y POS) sigue posteando su cargo después del revoke.
  > **Evidencia**: formulario → 1 movimiento con `reference_id = operation_id` y `amount = 250`; POS → 1 movimiento con `reference_id = sales_order_id` y `amount = 300` (las **dos** convenciones de `reference_id`). Prueba que el `PERFORM` interno corre como definer.
- [x] 5.6 **TRIANGULATE**: `rpc_process_outbox_dispatch` sigue posteando asientos que balancean después del revoke.
  > **Evidencia**: evento `SaleConfirmed` por 1234 → `journal_entry` existe y balancea `debit = credit = 1234`.
- [x] 5.7 `COMMENT ON FUNCTION` de ambos helpers: dejar escrito **por qué** no llevan `GRANT`.
  > **Evidencia**: ambos comentarios abren con **"SIN GRANT — NO AGREGAR UNO"**, explican el vector concreto (account_id por parámetro / fila de `events` completa aceptada como JSON por PostgREST), citan la verificación empírica en local, nombran al único caller legítimo y remiten al chequeo (3) del gate.

## 6. CI — gates y cadena de reapply

> **Nota 2026-08-23**: el hotfix de OQ-2 ya agregó un `check (3)` angosto a `supabase/tests/test_function_acl_gate.sql` (lista cerrada de 3 helpers). El gate **amplio** de este grupo (patrón de nombre + allowlist, 6.3-6.6) entra como **check (4)** — renumerar antes de escribirlo.

- [x] 6.1 Agregar la migración como **último eslabón** de la cadena del step "Verify G1/G4 migrations are idempotent on reapply", con su comentario.
  > **Evidencia**: agregado tras `20261006000001`. El comentario explica algo que **no** estaba previsto en el propose y que se descubrió al reproducir la cadena en local: mi migración no va última sólo por ser la más nueva, sino porque **el reapply de `20261001000001` (L137) y `20261004000001` (L1778) vuelve a ejecutar el bloque REVOKE+GRANT que le devuelve el GRANT a `authenticated` a los dos helpers** — o sea, reabre el agujero. Sin este eslabón al final, el chequeo (3) fallaría en CI reportando los dos helpers ya revocados.
- [x] 6.2 Descubrir la lista **real** de offenders del chequeo nuevo contra la DB de CI (post-migraciones) **y** contra prod. Comparar y anotar las diferencias.
  > **Evidencia**:
  > | entorno | offenders del chequeo (3) |
  > |---|---|
  > | **prod**, hoy (pre-merge) | 3: `_c29_confirm_order_core`, `_journal_post_from_event`, `_pay_register_party_charge` |
  > | **local**, post-migración | **1**: `_c29_confirm_order_core` |
  > | **prod**, esperado post-merge | 1 (verificación 9.4) |
  > Diferencia local/prod adicional (gotcha #432): `c30_get_or_create_*` y `c30_register_*_account_movement` son anon-executable en prod y no en local — no caen en (3) porque son SECURITY INVOKER, pero la migración los revoca igual.
- [x] 6.3 **RED**: agregar el chequeo **(3)** **sin** poblar la allowlist. Verificar que falla y lista exactamente los offenders de 6.2.
  > **Evidencia**: corrida con `v_allowlist := ARRAY[]::text[]` → falla listando **exactamente** `public._c29_confirm_order_core(...)`, una sola línea.
- [x] 6.4 **GREEN [OQ-3]**: poblar la allowlist con los offenders preexistentes que este change no revoca, con su comentario. `_pay_register_party_charge` y `_journal_post_from_event` **NO** entran.
  > **Evidencia**: allowlist de **1 entrada** (`_c29_confirm_order_core`, con la justificación de que lee el `account_id` de la propia `sales_order` y aplica `is_account_writer` sobre él → expuesto pero **no** primitiva cross-tenant). Comentario negativo explícito de que los dos revocados no deben entrar.
  > **`c28_register_cash_movement` NO entra** — contra lo que anticipaba el design.md: **no es SECURITY DEFINER** (verificado en prod y en local). Anotado en el propio gate para que nadie lo agregue "por las dudas".
- [x] 6.5 Documentar en el encabezado del gate la regla de mantenimiento, el mecanismo que produjo el hallazgo y el gotcha prod≠local.
  > **Evidencia**: cabecera ampliada con (i) por qué existe el chequeo (3) y qué punto ciego cubre, (ii) el mecanismo — patrón uniforme REVOKE+GRANT de `20261001000001` L137/L1914, (iii) por qué filtra por convención de nombre y no por "todas las SECURITY DEFINER" (~76 `rpc_*` legítimas), (iv) el gotcha #432 con el caso real medido, (v) la regla de mantenimiento (achicar siempre válido; agregar exige justificación en el PR).
- [x] 6.6 **TRIANGULATE**: verificar que el gate (3) **no** reporta las `rpc_*` públicas (control negativo).
  > **Evidencia**: **0** de las **76** funciones `rpc_*` SECURITY DEFINER concedidas a `authenticated` caen en el filtro de nombre del chequeo (3). La allowlist se mantiene en 1 entrada — legible, y por lo tanto un gate encendido.
- [x] 6.7 Agregar el step nuevo `Run cuenta-corriente-party-guard gates` con `-v ON_ERROR_STOP=1`, con comentario explicando qué cubre.
  > **Evidencia**: último step del workflow, con el formato del step de `cuentas-billetera-tipo`. YAML validado con `yaml.safe_load` (35 steps, el nuevo es el último).
- [x] 6.8 Correr los siete gates del baseline 1.3 **después** de la migración y verificar que siguen verdes. Verificar además, con un `supabase db reset` limpio, que la corrida completa en el orden exacto de CI pasa.
  > **Evidencia**: stack recreado limpio (`MAX = 20261010000001`), **cadena de reapply de CI reproducida completa en local** en el orden exacto del workflow (incluido el fallo esperado y tolerado de `20260928000001` por su gate anti-overload), y después los **8 gates en orden de CI: los 8 VERDES**.
  > `ACL GATE OK: sin triggers SECURITY DEFINER expuestos; anon-executable dentro de la allowlist (5 firmas permitidas); helpers internos authenticated-executable dentro de su allowlist (1 firmas permitidas)`.

## 7. Backend — propagación del error a HTTP (TDD)

- [x] 7.1 **RED**: `backend/tests/test_cuenta_corriente_party_guard.py` — mock de `asyncpg` con `sqlstate = 'P0404'`, assert de que `customer_accounts.register_payment_received` lo traduce a `HTTPException(404)`.
  > **Evidencia**: 2 tests (`register_payment_received` y `create_account`), verdes. El `detail` conserva el mensaje del RPC (`client_not_found`).
- [x] 7.2 **RED/GREEN**: espejos para `supplier_accounts.register_payment_made` y `register_supplier_charge`. Si pasan en verde a la primera, dejarlo explícito — el test es un **candado**, no un fix.
  > **Evidencia**: **pasan en verde a la primera**, igual que 7.1. El mapeo `"P0404": 404` ya existía en `_ERRCODE_STATUS` de los dos services (`customer_accounts.py` L26, `supplier_accounts.py` L23). **Son candado, no fix**: lo que faltaba era que algo fallara el día que alguien saque `P0404` de esos mapas.
- [x] 7.3 **TRIANGULATE**: assert de que el camino de venta también termina en 404 vía el handler global. Verificar el cuerpo RFC 7807, no sólo el status.
  > **Evidencia**: verificado que `sales.create_sale_operation` **no** tiene `try/except` propio → el `PostgresError` sube a `asyncpg_error_handler`. El test hace `POST /sales` y assertea el cuerpo completo: `type = "about:blank"`, `status = 404`, `code = "P0404"`, `title` no vacío, `client_not_found` en `detail`, **ausencia** de la extensión `field` (P0404 no está en `_FIELD_BY_ERRCODE`) y `content-type: application/problem+json`.
- [x] 7.4 **TRIANGULATE**: control negativo — un `sqlstate` no mapeado sigue dando 500.
  > **Evidencia**: 3 controles negativos con `P0999` — en `customer_accounts`, en `supplier_accounts` y en el camino global. El del camino global además assertea que el mensaje crudo de la base **no** se filtra al cliente.
- [x] 7.5 Correr la suite backend completa y comparar contra el baseline de 1.2.
  > **Evidencia**: **1538 passed / 0 failed / 3 skipped** (18 s) contra el baseline **1530/0/3** → +8, que son exactamente los tests nuevos. Cero regresiones.

## 8. Auditoría del daño histórico en prod (read-only)

> Los 9 conteos se midieron en prod el 2026-08-23, **solo con `SELECT`**. Salida completa en `baseline/prod_acl_audit_2026-08-23.md`.

- [x] 8.1 `customer_accounts` cuya `clients.account_id` difiere → **0 filas**.
- [x] 8.2 `supplier_accounts` cuya `suppliers.account_id` difiere → **0 filas**.
- [x] 8.3 `payments_received` / `payments_made` con parte de otro tenant (join directo) → **0 y 0**.
- [x] 8.4 `customer_account_movements` / `supplier_account_movements` colgando de una cuenta incoherente, y `events` `CustomerAccountCharged`/`SupplierAccountCharged`/`PaymentReceived`/`PaymentMade` cuyo `payload->>'client_id'`/`'supplier_id'` no pertenezca al `account_id` del evento → **0 en todos**.
- [x] 8.5 `journal_entries` originados en los eventos de 8.4 → **0**.
  > **Contexto de los conteos**: el lado proveedor está **vacío** en prod (`suppliers = 0`, `supplier_accounts = 0`, `payments_made = 0`), así que sus ceros son triviales. Los del lado cliente **no** lo son: hay `customer_accounts = 2`, 5 movimientos, 1 `payment_received` y 4 eventos (`CustomerAccountCharged` ×3 + `PaymentReceived` ×1) — todos coherentes.
  > **Nota para el PR**: **no** citar "241 operaciones a crédito" como población afectada; esas operaciones no se reflejan en `customer_accounts` de prod.
- [ ] 8.6 🛑 **Checkpoint**: reportar los conteos al PO. Esperado: **0** en todos.
  > **Pendiente sólo del enterado del PO** — la medición ya está hecha: **0 filas en los 9 conteos**. No hay nada que reparar; el checkpoint es informativo.
- [ ] 8.7 🛑 **[OQ-5, solo si 8.6 > 0]** Script de backfill en `scripts/sql/`.
  > **No aplica**: 8.6 dio 0 en todos los conteos. OQ-5 queda cerrada por ausencia de datos ("decidirlo con los datos a la vista" → no hay datos que decidir).

## 9. Verificación post-merge

> Todo el grupo queda **pendiente**: son verificaciones contra prod que sólo se pueden hacer **después** del merge (que dispara build + deploy + migración automáticos). Este apply no hizo push ni PR.

- [ ] 9.1 Confirmar en prod que `MAX(version)` es `20261010000001`.
- [ ] 9.2 Confirmar en prod que `has_function_privilege('authenticated', …, 'EXECUTE')` es **`false`** para `_pay_register_party_charge` y `_journal_post_from_event`, y **`true`** para las tres `rpc_register_*`. Contra prod, no contra CI (gotcha #432).
  > Valores medidos en local post-migración, como referencia de lo que debe verse en prod: `_pay_register_party_charge` `anon=f auth=f`; `_journal_post_from_event` `anon=f auth=f`; `c30_get_or_create_customer_account`/`supplier_account` `anon=f auth=f`; las 3 `rpc_register_*` `anon=f auth=t`. En prod, además, verificar que `service_role` **conserva** su EXECUTE (ningún REVOKE lo nombra).
- [ ] 9.3 Confirmar en prod que las cinco funciones reescritas tienen **una sola** definición y que su cuerpo vivo contiene el guard.
- [ ] 9.4 Re-correr la query de 1.6 en prod y confirmar que la lista coincide con la allowlist del gate menos los dos revocados (3 → **1**: sólo `_c29_confirm_order_core`).
- [ ] 9.5 Registrar en `CHANGES.md` el estado final y actualizar el puntero "Próximo change recomendado" del `CLAUDE.md`. Verificar que todo se mergeó **vía PR**.
- [ ] 9.6 Guardar en engram (`topic_key: opsx/cuenta-corriente-party-guard/apply`) el resultado.

> ### Candidatos detectados durante el apply (para `CHANGES.md` en el archive)
>
> Cuatro hallazgos **pre-existentes** encontrados al auditar el vecindario del
> change. **Ninguno se corrige acá**: son dominio CRÍTICO (dinero y
> multi-tenancy) y quedan a decisión del PO —change propio o hotfix, con la
> disciplina de #446—. Detalle completo, con evidencia y fix sugerido, en
> `design.md` §"Hallazgos laterales de la revisión de seguridad".
>
> - **h1 — Caja de otro tenant escribible desde el POS (alta).**
>   `_c29_confirm_order_core` / `rpc_quick_sale` / `rpc_confirm_sales_order`
>   aceptan un `p_cash_session_id` ajeno y lo pasan a
>   `c28_register_cash_movement`, que no valida tenencia. Ingreso fantasma en el
>   arqueo de la víctima, reproducido en local. Fix: guard
>   `cs.id = p_cash_session_id AND cb.branch_id = v_gate_branch AND status='open'`
>   → `P0422`, o dentro de `c28_register_cash_movement` (choke point).
> - **h2 — Outbox sin filtro de tenant (alta).** `rpc_process_outbox_batch(int)`
>   y `rpc_mark_event_processed(uuid)` (`SECURITY DEFINER`, GRANT
>   `authenticated`, `20260718000001` L172/L203) devuelven y marcan eventos de
>   TODOS los tenants. Un `authenticated` de A lee el payload de eventos de B y
>   los marca procesados — el dispatcher real nunca postea ese asiento. Agravado
>   por `POST /outbox/process-pending` (`backend/routers/outbox.py` L32) sin
>   `require_admin`. Fix: `REVOKE` de ambas + `require_admin`. Nota: el chequeo
>   (3) **no** las atrapa (son `rpc_*`, fuera del filtro de nombre por D4).
> - **h3 — `c30_register_customer/supplier_account_movement` `anon`-executable en
>   prod.** `SECURITY INVOKER`; hoy los frena la RLS (esas tablas sólo tienen
>   policies de `SELECT`). Endurecimiento, no incidente.
> - **h4 — `get_account_ids_for_user(uuid)`** devuelve la membresía de cualquier
>   `user_id`, sin comparar contra `auth.uid()`. Fuga menor de membresía.
