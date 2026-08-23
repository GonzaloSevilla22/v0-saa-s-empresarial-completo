# Tasks — `cuenta-corriente-party-guard`

> **Strict TDD activo.** Cada task de código sigue RED → GREEN → TRIANGULATE → REFACTOR, con safety net previo sobre lo que se toca. Los tests van **antes** de la implementación, nunca después.
>
> **Governance MEDIUM** (tramo de severidad alta en el grupo 5). Los checkpoints 🛑 requieren mostrarle el resultado al PO antes de seguir.
>
> Las tasks marcadas **[OQ-n]** dependen de la respuesta del PO a la Open Question correspondiente de `design.md`. Sin respuesta, se implementa la **recomendación**.

## 1. Reconocimiento y safety net

- [ ] 1.1 Verificar el **MAX de `supabase_migrations.schema_migrations` vivo en prod** (`npx supabase migration list`, o `SELECT max(version) …`). Confirmar que el archivo nuevo se llama `20261008000001_cuenta_corriente_party_guard.sql` — `20261007000001` lo tomó `cuentas_billetera_tipo` (PR #447, mergeada mientras este propose estaba en revisión). Si prod está adelante de `20261007000001`, renumerar y anotarlo en el PR.
- [ ] 1.2 Correr la suite backend completa (`pytest`) y registrar el baseline `N/N passing` (esperado 1495/1495). Cualquier fallo preexistente se **reporta**, no se arregla en este change.
- [ ] 1.3 Levantar el stack local (`supabase db reset`) y correr los siete gates de dinero vigentes en el orden de CI, registrando el baseline: `test_function_acl_gate.sql`, `test_errcode_5char_gate.sql`, `test_idempotency.sql`, `test_pagos_cableados_restantes.sql`, `test_delete_guard_ledgers.sql`, `test_asiento_venta_formulario.sql` y `test_cuentas_billetera_tipo.sql` (PR #447).
- [ ] 1.4 🛑 **Gate de integridad de función.** Capturar `pg_get_functiondef` **vivo en prod** de las cinco funciones a reescribir y guardarlas en `openspec/changes/cuenta-corriente-party-guard/baseline/<nombre>.sql` con la cabecera de procedencia (molde: `openspec/changes/archive/2026-08-22-delete-guard-ledgers/baseline/`): `c30_get_or_create_customer_account(uuid,uuid)`, `c30_get_or_create_supplier_account(uuid,uuid)`, `rpc_register_payment_received(text,uuid,numeric,uuid,text,uuid)`, `rpc_register_payment_made(text,uuid,numeric,uuid,text,uuid)`, `rpc_register_supplier_charge(text,uuid,numeric,uuid)`. **El propose no pudo capturarlos** (sin contraseña en `supabase/.temp/pooler-url`, lectura de `backend/.env` denegada) — esta task es obligatoria.
- [ ] 1.5 🛑 Diffear cada baseline contra el archivo de migración de referencia: `20260907000001` L487 (`payment_received`) y L678 (`payment_made`), `20260720000001` L895 (`supplier_charge`), `20260720000001` L443 y L478 (los dos helpers). **Si difieren en una sola línea, reportar antes de escribir SQL** — es exactamente así como se perdió el bloque `credit` de C-30 en julio.
- [ ] 1.6 Auditar en **prod** el estado real de permisos de los helpers internos: `SELECT p.proname, pg_get_function_identity_arguments(p.oid), has_function_privilege('anon', p.oid, 'EXECUTE'), has_function_privilege('authenticated', p.oid, 'EXECUTE') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname='public' AND p.prosecdef AND (p.proname LIKE '\_%' OR p.proname LIKE 'c2_%' OR p.proname LIKE 'c30\_%')`. Guardar la salida — es el insumo de la allowlist del gate (6.2) y la línea de base del grupo 5. Recordar el gotcha #432: prod concede a `anon`/`authenticated` **directo**, no vía `PUBLIC`.
- [ ] 1.7 Confirmar que ningún consumidor de aplicación invoca los helpers a revocar: `grep -rn "_pay_register_party_charge\|_journal_post_from_event" frontend/ backend/ supabase/functions/ --include=*.ts --include=*.tsx --include=*.py`. Esperado: solo comentarios, tests de migración y `frontend/lib/database.types.ts` (generado). Anotar el resultado en el PR.

## 2. Test SQL — RED

- [ ] 2.1 **RED**: crear `supabase/tests/test_cuenta_corriente_party_guard.sql` con el molde de `test_delete_guard_ledgers.sql`: `DO $$ … $$` único, **dos tenants sintéticos** (A y B, cada uno con su `account`, su `client` y su `supplier`), sesión sintética vía `PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_id::text, 'role', 'authenticated')::text, true)` y el guard degrade-don't-fail (`IF auth.uid() IS DISTINCT FROM v_user_id THEN RAISE NOTICE … RETURN; END IF;`). Copiar el mecanismo **exactamente** como lo usan los tests existentes, sin inventar variantes.
- [ ] 2.2 **RED**: assert de `rpc_register_payment_received` con el `client_id` del tenant B desde la sesión del tenant A → se espera `P0404`. Debe **fallar hoy** (hoy la llamada tiene éxito y crea la fila).
- [ ] 2.3 **RED**: assert de `rpc_register_payment_made` con `supplier_id` ajeno → `P0404`. Debe fallar hoy.
- [ ] 2.4 **RED**: assert de `rpc_register_supplier_charge` con `supplier_id` ajeno → `P0404`. Debe fallar hoy.
- [ ] 2.5 **RED [OQ-1]**: assert de `rpc_create_sale_operation_v2` con forma de pago `kind='credit'` y `client_id` del tenant B → `P0404`, **y** cero filas nuevas en `sales`, `sale_items`, `customer_accounts`, `customer_account_movements`, `stock_movements` y `events`. Debe fallar hoy. (Si el PO responde OQ-1 = A, esta task se elimina junto con 2.6 y 3.x.)
- [ ] 2.6 **RED [OQ-1]**: espejo del anterior por el camino POS (`rpc_quick_sale` / confirmación de orden con `kind='credit'` y cliente ajeno) → `P0404`, orden no confirmada.
- [ ] 2.7 Verificar que el archivo corre y **falla** contra el schema actual (`psql -v ON_ERROR_STOP=1 … -f`), y anotar en el PR cuáles de los 5-6 asserts fallan. Eso es el RED del change entero.

## 3. Migración — guard en el choke point (opción B) [OQ-1]

- [ ] 3.1 Crear `supabase/migrations/20261008000001_cuenta_corriente_party_guard.sql` con la cabecera del proyecto (contexto, decisión, lista de funciones tocadas, nota de que ninguna firma cambia). **Sin BOM UTF-8** — hay gate en CI.
- [ ] 3.2 **GREEN**: `CREATE OR REPLACE FUNCTION public.c30_get_or_create_customer_account(uuid, uuid)` partiendo del cuerpo capturado en 1.4, agregando **antes** del `INSERT ... ON CONFLICT` el guard canónico copiado de `rpc_create_customer_account` (`20260720000001` L537-542): `SELECT id INTO v_client FROM public.clients WHERE id = p_client_id AND account_id = p_account_id; IF NOT FOUND THEN RAISE EXCEPTION 'client_not_found: %', p_client_id USING ERRCODE = 'P0404'; END IF;`. Sin helper nuevo (Regla de Tres — ver D1).
- [ ] 3.3 **GREEN**: espejo exacto en `c30_get_or_create_supplier_account(uuid, uuid)` contra `public.suppliers`, con `supplier_not_found: %` y el mismo `P0404`.
- [ ] 3.4 ACLs de los dos helpers: `REVOKE ALL ON FUNCTION … FROM PUBLIC, anon, authenticated;` **sin `GRANT`** (son internos, y copiar el bloque REVOKE+GRANT del "patrón uniforme" es literalmente el bug del grupo 5). `COMMENT ON FUNCTION` actualizado citando el guard.
- [ ] 3.5 **TRIANGULATE**: control positivo — cliente/proveedor **del mismo tenant** sin cuenta corriente previa: la cuenta se crea en el mismo commit y el movimiento queda con el `balance_after` esperado. Sin este assert el guard podría estar rechazando todo.
- [ ] 3.6 **TRIANGULATE**: identificador **inexistente** (no pertenece a ningún tenant) → mismo `P0404`, mismo mensaje. El error no distingue "ajeno" de "inexistente" (no filtrar información entre tenants).
- [ ] 3.7 **TRIANGULATE**: verificar que `rpc_create_customer_account` y `rpc_create_supplier_account` —que ya validaban— siguen comportándose igual, con el guard ahora duplicado. Redundancia deliberada, no regresión.
- [ ] 3.8 Verificar que los asserts 2.5 y 2.6 (venta a crédito con cliente ajeno, formulario y POS) pasan **sin haber tocado** `rpc_create_sale_operation_v2` ni `_c29_confirm_order_core`. Es la prueba de que el choke point cubre.

## 4. Migración — guard explícito en las tres RPCs de pago

- [ ] 4.1 **GREEN**: `CREATE OR REPLACE FUNCTION public.rpc_register_payment_received(text, uuid, numeric, uuid, text, uuid)` partiendo del baseline de 1.4, insertando el guard de cliente **después** de la validación de `bank_account` y **antes** del `INSERT` en `operation_idempotency` (D2). Enumerar en el PR cada bloque preservado byte a byte: `auth.uid()` guard, `current_account_ids()`, `is_account_writer`, validación de `amount`, taxonomía de `payment_method`, bloque `bank_accounts` (`P0412`), idempotencia y su rama de replay, `c30_register_customer_account_movement`, `payments_received`, `_register_bank_movement` con `reporting_local_today()`, y el evento `PaymentReceived` con `payment_method`/`bank_account_id`.
- [ ] 4.2 **GREEN**: espejo en `rpc_register_payment_made(text, uuid, numeric, uuid, text, uuid)` con el guard de proveedor. Enumerar los bloques preservados (mismos que 4.1, con `transfer_out` y `payments_made`).
- [ ] 4.3 **GREEN**: espejo en `rpc_register_supplier_charge(text, uuid, numeric, uuid)`. Es la única de las tres nunca redefinida desde C-30, así que el diff de 1.5 debería ser vacío — confirmarlo explícitamente en el PR.
- [ ] 4.4 ACLs de las tres RPCs: `REVOKE ALL … FROM PUBLIC; REVOKE EXECUTE … FROM anon; GRANT EXECUTE … TO authenticated;` (son API pública, el `GRANT` acá **sí** corresponde). `COMMENT ON FUNCTION` actualizado nombrando `P0404`.
- [ ] 4.5 **TRIANGULATE**: la **clave de idempotencia no se quema** en el rechazo — un cobro rechazado por cliente ajeno, reintentado con la misma clave y un cliente válido, se registra normalmente (no devuelve `replayed = true`).
- [ ] 4.6 **TRIANGULATE**: el orden de los guards se respeta — un cobro con cliente ajeno **y** `amount = 0` falla con `P0400` (validación de payload primero), no con `P0404`. Congela el orden documentado en D2.
- [ ] 4.7 **TRIANGULATE**: cobro por transferencia con cliente ajeno → `P0404` y **cero** filas en `bank_movements`. El guard corta antes del ruteo bancario.
- [ ] 4.8 Gate anti-overload dentro de la migración: `SELECT count(*) FROM pg_proc WHERE proname IN ('rpc_register_payment_received','rpc_register_payment_made','rpc_register_supplier_charge','c30_get_or_create_customer_account','c30_get_or_create_supplier_account')` = 5. Ninguna firma cambió, así que cualquier valor distinto es un overload fantasma.
- [ ] 4.9 Reaplicar el archivo de migración **dos veces seguidas** en local y verificar que el segundo apply es no-op (sin error, sin cambio de fingerprint).

## 5. Migración — cierre de la primitiva de escritura cross-tenant [OQ-2 🛑]

> 🛑 **Checkpoint OQ-2 antes de empezar el grupo**: confirmar con el PO si este tramo entra en el change o se separa como hotfix inmediato al estilo #446. La recomendación es que entre acá. Lo que **no** es aceptable es dejarlo abierto esperando el apply.
>
> **Resuelto 2026-08-23 — se separó como hotfix** (orden del PO): ver `supabase/migrations/20261010000001_revoke_internal_money_helpers.sql` (rama `fix/revoke-internal-money-helpers`). Este grupo entero queda SUPERSEDED — el `REVOKE` de 5.3/5.4 ya está aplicado en `main`; no repetirlo acá. Ver nota en `design.md` OQ-2.

- [ ] 5.1 **RED**: assert en el test SQL — con `SET LOCAL ROLE authenticated`, invocar directamente `public._pay_register_party_charge(<account_id de B>, 'customer', <client_id de B>, 1000, …)` y esperar `insufficient_privilege` (42501). Debe **fallar hoy**: hoy la llamada tiene éxito y escribe en los libros del tenant B.
- [ ] 5.2 **RED**: espejo con `public._journal_post_from_event(<fila events forjada con account_id de B>)` → `insufficient_privilege`. Debe fallar hoy.
- [ ] 5.3 **GREEN**: en la migración, `REVOKE ALL ON FUNCTION public._pay_register_party_charge(uuid, text, uuid, numeric, uuid, uuid) FROM PUBLIC, anon, authenticated;` — sin tocar el cuerpo de la función. Molde: `_pay_reverse_party_charge` (`20261005000001` L186).
- [ ] 5.4 **GREEN**: `REVOKE ALL ON FUNCTION public._journal_post_from_event(public.events) FROM PUBLIC, anon, authenticated;`. Restaura el estado que tenía en `20260803000001` L517 y que se perdió en `20261001000001` L1914.
- [ ] 5.5 **TRIANGULATE**: control positivo — una venta a crédito completa (formulario y POS) sigue posteando su cargo después del revoke. Prueba que el `PERFORM` interno corre como definer y el revoke es transparente.
- [ ] 5.6 **TRIANGULATE**: el dispatcher del outbox (`rpc_process_outbox_dispatch`) sigue posteando asientos después del revoke de `_journal_post_from_event` — procesar un evento `SaleConfirmed` y verificar que el asiento existe y balancea.
- [ ] 5.7 `COMMENT ON FUNCTION` de ambos helpers: dejar escrito **por qué** no llevan `GRANT`, para que la próxima reescritura no vuelva a aplicar el patrón REVOKE+GRANT en piloto automático.

## 6. CI — gates y cadena de reapply

> **Nota 2026-08-23**: el hotfix de OQ-2 ya agregó un `check (3)` angosto a `supabase/tests/test_function_acl_gate.sql` (lista cerrada de 3 helpers). El gate **amplio** de este grupo (patrón de nombre + allowlist, 6.3-6.6) entra como **check (4)** — renumerar antes de escribirlo.

- [ ] 6.1 Agregar `psql -v ON_ERROR_STOP=1 "$DSN" -f supabase/migrations/20261008000001_cuenta_corriente_party_guard.sql` como **último eslabón** de la cadena del step "Verify G1/G4 migrations are idempotent on reapply" en `.github/workflows/KPI_Validation.yml`, con su comentario: esta migración no cambia ninguna firma (solo `CREATE OR REPLACE` + `REVOKE`), así que no puede generar overloads fantasma — es el eslabón más simple de la cadena, y el reapply prueba su idempotencia.
- [ ] 6.2 Descubrir la lista **real** de offenders del chequeo nuevo corriendo la query de 1.6 contra la DB de CI (post-migraciones) **y** contra prod. Comparar las dos listas y anotar las diferencias en el PR — la divergencia local/prod es el gotcha #432 y es información valiosa por sí sola.
- [ ] 6.3 **RED**: agregar a `supabase/tests/test_function_acl_gate.sql` el chequeo **(3)** —funciones `SECURITY DEFINER` no-trigger de nombre interno (`_%`, `c28\_%`, `c29\_%`, `c30\_%`) ejecutables por `authenticated`, con allowlist— **sin** poblar la allowlist todavía. Verificar que falla y lista exactamente los offenders de 6.2.
- [ ] 6.4 **GREEN [OQ-3]**: poblar la allowlist con los offenders preexistentes **que este change no revoca**, cada uno con su comentario de justificación (esperados: `c28_register_cash_movement`, `_c29_confirm_order_core` — este último valida `is_account_writer` sobre el `account_id` que lee de la orden, así que está expuesto pero no es primitiva cross-tenant). `_pay_register_party_charge` y `_journal_post_from_event` **NO** entran a la allowlist: el grupo 5 los revoca. Verificar que el gate pasa.
- [ ] 6.5 Documentar en el encabezado del gate la regla de mantenimiento (achicar siempre válido; agregar exige justificación en el PR), el mecanismo que produjo el hallazgo (el patrón uniforme REVOKE+GRANT de `20261001000001`) y el gotcha prod≠local.
- [ ] 6.6 **TRIANGULATE**: verificar que el gate (3) **no** reporta las `rpc_*` públicas (control negativo — si las reportara, la allowlist sería inmantenible y el gate quedaría apagado de hecho).
- [ ] 6.7 Agregar el step nuevo `Run cuenta corriente party guard gates` a `.github/workflows/KPI_Validation.yml` corriendo `supabase/tests/test_cuenta_corriente_party_guard.sql` con `-v ON_ERROR_STOP=1`, con comentario explicando qué cubre.
- [ ] 6.8 Correr los siete gates del baseline 1.3 **después** de la migración y verificar que siguen verdes. Verificar además, con un `supabase db reset` limpio, que la corrida completa en el orden exacto de CI pasa.

## 7. Backend — propagación del error a HTTP (TDD)

- [ ] 7.1 **RED**: `backend/tests/test_cuenta_corriente_party_guard.py` — mock de `asyncpg` (molde de `backend/tests/test_c30_customer_supplier_accounts.py`) que hace que el repo levante un `PostgresError` con `sqlstate = 'P0404'`, y assert de que `customer_accounts.register_payment_received` lo traduce a `HTTPException(status_code=404)`.
- [ ] 7.2 **RED/GREEN**: espejos para `supplier_accounts.register_payment_made` y `supplier_accounts.register_supplier_charge`. Verificar que **pasan sin cambiar código**: `_ERRCODE_STATUS` ya mapea `"P0404": 404` en `backend/services/customer_accounts.py` L26 y `supplier_accounts.py` L23. Si pasan en verde a la primera, dejarlo explícito en el PR — el test es un **candado**, no un fix.
- [ ] 7.3 **TRIANGULATE**: assert de que el camino de venta (sin `try/except` propio en `sales.create_sale_operation`) también termina en 404 vía el handler global — `backend/core/errors.py` L92 + `backend/main.py:68`. Verificar el cuerpo RFC 7807 resultante, no solo el status.
- [ ] 7.4 **TRIANGULATE**: control negativo — un `sqlstate` no mapeado sigue dando 500. Evita que el test pase por un `except` demasiado ancho.
- [ ] 7.5 Correr la suite backend completa y comparar contra el baseline de 1.2.

## 8. Auditoría del daño histórico en prod (read-only)

- [ ] 8.1 Medir en prod, **solo con SELECT**: `SELECT count(*) FROM customer_accounts ca JOIN clients c ON c.id = ca.client_id WHERE c.account_id IS DISTINCT FROM ca.account_id;`. Anotar el número real en el PR.
- [ ] 8.2 Espejo: `supplier_accounts sa JOIN suppliers s ON s.id = sa.supplier_id WHERE s.account_id IS DISTINCT FROM sa.account_id`.
- [ ] 8.3 Medir `payments_received` y `payments_made` cuyo `client_id`/`supplier_id` no pertenezca a su propio `account_id` (join directo, sin pasar por la cuenta corriente — cubre el caso de una fila de pago con cuenta corriente ya borrada).
- [ ] 8.4 Medir movimientos y eventos derivados: `customer_account_movements` / `supplier_account_movements` colgando de una cuenta corriente incoherente, y `events` de tipo `CustomerAccountCharged`/`SupplierAccountCharged`/`PaymentReceived`/`PaymentMade` cuyo `payload->>'client_id'`/`'supplier_id'` no pertenezca al `account_id` del evento. Este último también detectaría un ataque por la vía del grupo 5 (que no deja rastro en las tablas de cuenta corriente del atacante, sino en las de la víctima).
- [ ] 8.5 Medir asientos contables (`journal_entries`) originados en los eventos de 8.4. Es el daño de segundo orden.
- [ ] 8.6 🛑 **Checkpoint**: reportar los seis conteos al PO. Esperado: **0** en todos (el vector exige conocer un UUID ajeno o un ataque deliberado). Si hay filas, **no** repararlas en este change: pasar a 8.7.
- [ ] 8.7 🛑 **[OQ-5, solo si 8.6 > 0]** Redactar `scripts/sql/cuenta_corriente_party_guard_backfill_<fecha>.sql` (fuera de `supabase/migrations/` — dato puntual, no schema), gateado por los conteos re-medidos inmediatamente antes de ejecutar, con dry-run validado en local. Ejecución **post-merge y firmada por el PO**, nunca automática. Mismo patrón que el backfill de `delete-guard-ledgers`.

## 9. Verificación post-merge

- [ ] 9.1 Confirmar en prod que `MAX(version)` en `supabase_migrations.schema_migrations` es `20261008000001` (o el número renumerado en 1.1) — el merge dispara build + deploy + migración automáticos.
- [ ] 9.2 Confirmar en prod que `has_function_privilege('authenticated', '<oid>', 'EXECUTE')` es **`false`** para `_pay_register_party_charge` y `_journal_post_from_event`, y que sigue siendo `true` para las tres `rpc_register_*` (que son API pública). Verificación contra prod, no contra CI (gotcha #432).
- [ ] 9.3 Confirmar en prod que las cinco funciones reescritas tienen **una sola** definición (`count(*) FROM pg_proc` por nombre) y que su cuerpo vivo contiene el guard (`pg_get_functiondef` con `client_not_found` / `supplier_not_found`).
- [ ] 9.4 Re-correr la query de 1.6 en prod y confirmar que la lista de helpers expuestos coincide con la allowlist del gate (6.4) menos los dos revocados.
- [ ] 9.5 Registrar en `CHANGES.md` el estado final del change y actualizar el puntero "Próximo change recomendado" del `CLAUDE.md` del proyecto. Verificar que todo el trabajo se mergeó **vía PR** y que no hay commits directos a `main`.
- [ ] 9.6 Guardar en engram (`topic_key: opsx/cuenta-corriente-party-guard/apply`) el resultado: opción de OQ-1 y OQ-2 finalmente aplicada, conteos de la auditoría 8.x, contenido final de la allowlist del gate, y el diff del baseline de 1.5 si hubo diferencias.
