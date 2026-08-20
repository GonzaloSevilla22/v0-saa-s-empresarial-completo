> **Strict TDD**: cada grupo con lógica arranca por el gate en RED. Todo commit va por PR (nunca directo a `main`), rama nueva por cambio. Migración única `20261003000001_limpiezas_pagos_admin.sql`, idempotente. `npx supabase db push` — NUNCA MCP `apply_migration`.
>
> **Orden obligatorio**: G3 → G2 → G1. El DROP de la columna va último, cuando ya nada la escribe.

## 1. Preparación y baseline

- [ ] 1.1 Rama nueva desde `main` actualizado; verificar que `MAX(version)` de `supabase/migrations/` sigue siendo `20261002000001` y que ningún PR de la saga quedó sin mergear.
- [ ] 1.2 **Safety net**: correr localmente los gates que este change puede romper y anotar el baseline (`N tests passing`): `test_confirm_core_integrity.sql`, `test_pos_confirm_payment_method.sql`, `test_pos_rpc_signatures.sql`, `test_pos_payment_vocabulary.sql`, `test_pagos_cableados_restantes.sql`, `test_pos_banco_movimientos.sql`, `test_kpis.sql`, `test_kpis_edge_cases.sql`, `pytest backend/tests`, `pnpm vitest run`. Cualquier fallo previo se reporta como **pre-existing failure** y NO se arregla acá.
- [ ] 1.3 Guardar en `openspec/changes/limpiezas-pagos-admin/baseline/` el `pg_get_functiondef()` VIVO de prod de las funciones a tocar: `_c29_confirm_order_core`, `rpc_accept_quote`, `rpc_promote_legacy_sale_to_order`, `rpc_create_purchase_operation`, `rpc_dashboard_kpi_summary`, `rpc_dashboard_channel_margin`, `rpc_issue_credit_note`, `rpc_product_profitability`.
- [ ] 1.4 Crear el archivo de migración `supabase/migrations/20261003000001_limpiezas_pagos_admin.sql` con la cabecera de contexto (SCOPE / PROBLEMA / GOVERNANCE MEDIUM / APPLY / ROLLBACK), vacío de lógica.

## 2. G3 — ERRCODEs de 4 caracteres (RED primero)

- [ ] 2.1 **RED**: escribir `supabase/tests/test_errcode_5char_gate.sql` — falla si alguna función de `public`/`community` tiene `prosrc ~ 'ERRCODE\s*=\s*''[A-Za-z0-9]{1,4}'''`; el mensaje SHALL nombrar función y código. Correrlo contra la base local con todas las migraciones aplicadas y verificar que **FALLA** listando las 5 funciones esperadas.
- [ ] 2.2 **RED (triangulación)**: agregar al gate un segundo caso que fuerce el `RAISE` real de al menos un código corregido y verifique que el SQLSTATE recibido es el nuevo y el mensaje es el original (no `42704`). Debe fallar antes del fix.
- [ ] 2.3 **GREEN**: agregar a la migración el bloque `DO` dinámico (D4) que reescribe `P400|P403|P404|P409|P422` → `P04xx` vía `pg_get_functiondef` + `regexp_replace` + `CREATE OR REPLACE`, reutilizando literalmente el mecanismo de `20260624000001_fix_invalid_errcodes_5char.sql`. Correr el gate → PASA.
- [ ] 2.4 Agregar dentro de la migración el gate de residuo cero (aborta si queda algún código de <5 chars) **y** una verificación de que el conjunto reescrito es exactamente `{rpc_create_purchase_operation, rpc_dashboard_kpi_summary, rpc_dashboard_channel_margin, rpc_issue_credit_note, rpc_product_profitability}` — si aparece una función inesperada, abortar.
- [ ] 2.5 Verificar en la base local que las 5 funciones conservan `SECURITY DEFINER`, `search_path` y ACLs tras el `CREATE OR REPLACE` (no hubo `DROP`, así que no hay re-`GRANT` que reponer).
- [ ] 2.6 Cablear `test_errcode_5char_gate.sql` en `.github/workflows/KPI_Validation.yml`, junto a `test_function_acl_gate.sql`.
- [ ] 2.7 **Idempotencia**: re-ejecutar la migración completa sobre la misma base y confirmar que el `DO` no reescribe nada y ningún gate falla.

## 3. G2 — Baja de las 4 RPCs `get_admin_*` huérfanas

- [ ] 3.1 **RED**: escribir el gate de ausencia (dentro de `test_kpis.sql`, reemplazando §5/§7/§9): las 4 RPCs NO deben existir y `get_admin_community_interactions` SÍ debe existir y seguir siendo `SECURITY DEFINER`. Correr → FALLA (las 4 todavía están).
- [ ] 3.2 **GREEN**: agregar a la migración `DROP FUNCTION IF EXISTS public.get_admin_activation_rate(timestamptz, timestamptz)`, `..._umv_rate(...)`, `..._paid_conversion_rate(...)`, `..._insights_breakdown(...)` — con firma explícita, nunca por nombre pelado.
- [ ] 3.3 Agregar dentro de la migración el gate que verifica que `get_admin_community_interactions(timestamptz, timestamptz)` sigue existiendo y sigue siendo invocable por `rpc_admin_business_kpis` y `rpc_admin_kpi_overview` (abortar si desapareció).
- [ ] 3.4 Podar `supabase/tests/test_kpis.sql`: §5 "all five admin RPCs must exist" y §7 "SECURITY DEFINER" quedan con `get_admin_community_interactions` sola; §9 (firma de `get_admin_paid_conversion_rate`) se elimina completa.
- [ ] 3.5 Podar `supabase/tests/test_kpis_edge_cases.sql`: eliminar los bloques que hacen `PERFORM public.get_admin_paid_conversion_rate(...)` (§ del guard de admin y § 6 del rango invertido). Verificar que el resto del archivo sigue teniendo cobertura propia.
- [ ] 3.6 Confirmar que `supabase/tests/test_function_acl_gate.sql` **no** requiere edición: su allowlist solo lista los 5 helpers de RLS y las 4 RPCs nunca tuvieron `EXECUTE` para `anon`. Dejarlo explícito en el PR.
- [ ] 3.7 Correr `test_kpis.sql`, `test_kpis_edge_cases.sql`, `test_admin_kpis.sql`, `test_community_interactions.sql` y `test_function_acl_gate.sql` → todos verdes.
- [ ] 3.8 Verificar en el frontend vivo que no queda ninguna llamada: `adminAnalytics.ts` solo conserva el comentario explicativo y la llamada viva a `get_admin_community_interactions`. Actualizar ese comentario para decir que las 4 fueron dropeadas (no "no se tocan").

## 4. G1a — Los tres sitios de escritura dejan de escribir el texto

- [ ] 4.1 **RED**: escribir `supabase/tests/test_sales_order_payment_method_drop.sql` con el gate estático: `sales_orders` NO tiene columna `payment_method`, NO existe `sales_orders_payment_method_check`, y ninguna función de `public` referencia `payment_method` fuera de `payment_method_id`/`payment_methods`/la clave del payload. Correr → FALLA.
- [ ] 4.2 **GREEN (escrituras)**: agregar a la migración el `CREATE OR REPLACE` de `rpc_accept_quote` y `rpc_promote_legacy_sale_to_order` partiendo del baseline de 1.3, quitando la columna del INSERT (D7 — la orden nace con `payment_method_id = NULL`, sin literal `'other'`). Misma firma → sin `DROP`, sin re-`GRANT`.
- [ ] 4.3 **GREEN (confirm)**: `CREATE OR REPLACE` de `_c29_confirm_order_core` partiendo del baseline: (a) quitar `payment_method = v_kind` del UPDATE final, dejando solo `payment_method_id = p_payment_method_id`; (b) en la rama `ELSE` (camino legacy, D2), resolver la forma de pago viva y activa de la cuenta con `kind = v_kind` (desempate `sort_order`, luego `id`) y usar ese id en el UPDATE y en las filas de `sales`; si no resuelve, dejar `NULL` sin abortar.
- [ ] 4.4 Verificar que el payload del evento `SaleConfirmed` sigue emitiendo `'payment_method', v_kind` sin cambios — es contrato de `_journal_post_from_event`, que NO se toca.
- [ ] 4.5 **TRIANGULACIÓN**: extender `test_pos_confirm_payment_method.sql` con (i) confirm con `payment_method_id` explícito → orden imputada + evento con el `kind`; (ii) confirm legacy con texto `cash` sin id → orden imputada a la forma sembrada `cash`; (iii) confirm legacy con texto `check` (sin método sembrado) → orden con `payment_method_id = NULL`, confirmación exitosa, evento con `payment_method = 'check'`.
- [ ] 4.6 Correr `test_confirm_core_integrity.sql`, `test_pos_rpc_signatures.sql`, `test_pagos_cableados_restantes.sql`, `test_pos_banco_movimientos.sql`, `test_edicion_preserva_contexto.sql` → verdes, con la firma de `_c29_confirm_order_core` intacta (el parámetro `p_payment_method text` **se conserva**).

## 5. G1b — Los dos consumidores de lectura migran a `payment_method_id`

- [ ] 5.1 **RED (backend)**: agregar a `backend/tests/test_payment_method_service.py` (o al módulo de ventas que corresponda) un caso con **dos formas de pago vivas del mismo `kind`** en una cuenta y una venta del POS imputada a una de ellas, que asserte que el listado devuelve la operación **una sola vez** con la forma de pago correcta. Con el JOIN por `kind` actual debe FALLAR (fan-out, D3).
- [ ] 5.2 **GREEN (backend)**: en `backend/repositories/sales_repository.py`, cambiar el `LEFT JOIN payment_methods pos_pm` de `pos_pm.account_id = s.account_id AND pos_pm.kind = so.payment_method` a `pos_pm.id = so.payment_method_id`. Actualizar el comentario del bloque para reflejar la derivación por identidad. Verificar que `payment_method_name`/`payment_method_kind` de `SaleOut` siguen resolviendo igual para las ventas históricas.
- [ ] 5.3 **TRIANGULACIÓN (backend)**: caso con `sales.payment_method_id` explícito (gana sobre la derivación) y caso con ambos NULL (se muestra "Sin especificar" sin error).
- [ ] 5.4 **RED (frontend)**: agregar un test a `frontend/__tests__/` que cubra el render del detalle de orden para un `kind` no binario (p.ej. `wallet`) y espere el **nombre** de la forma de pago. Con el `payment_method === "cash" ? "Efectivo" : "Otro medio"` actual debe FALLAR.
- [ ] 5.5 **GREEN (frontend)**: en `frontend/app/(dashboard)/ventas/ordenes/[id]/page.tsx`, cambiar el `.select(...)` para traer `payment_method_id` y el nombre de la forma de pago vía el join embebido de PostgREST (`payment_methods(name, kind)`), actualizar la interfaz `SalesOrderRow` (sin `any`) y renderizar el nombre real; si no hay imputación, mostrar "Sin especificar".
- [ ] 5.6 Verificar la página en **desktop y mobile** y en **tema claro y oscuro** (regla PO 2026-08-02). No se agregan rutas ni entradas de menú: es una pantalla existente.
- [ ] 5.7 Grep final de repo confirmando que ningún archivo vivo (fuera de `.claude/worktrees/`, `database.types.ts` y migraciones históricas) lee `sales_orders.payment_method`.

## 6. G1c — DROP de la columna

- [ ] 6.1 Reescribir `supabase/tests/test_pos_payment_vocabulary.sql` (D6): el gate pasa a afirmar que `payment_methods_kind_check` enumera exactamente los 7 `kind` y que `sales_orders` ya no tiene columna `payment_method` ni su CHECK. Se elimina la comparación entre dos CHECKs y el ejercicio de backfill por `kind`.
- [ ] 6.2 **GREEN**: agregar a la migración, **al final**, `ALTER TABLE public.sales_orders DROP COLUMN IF EXISTS payment_method;` y el gate que verifica que ni la columna ni `sales_orders_payment_method_check` existen.
- [ ] 6.3 Correr `test_sales_order_payment_method_drop.sql` (de 4.1) → PASA. Correr `test_pos_payment_vocabulary.sql` reescrito → PASA.
- [ ] 6.4 **Idempotencia end-to-end**: re-ejecutar la migración completa sobre la base ya migrada → sin errores, sin cambios, todos los gates verdes.
- [ ] 6.5 Verificar el gate de integridad transitivo (`test_confirm_core_integrity.sql` y `check_backend_table_refs.py` / `check_frontend_table_refs.py`) → verde con la columna ausente.

## 7. Cierre

- [ ] 7.1 Suite completa local: todos los `.sql` de `supabase/tests/` que toca el workflow, `pytest backend/tests` con el umbral de coverage, `pnpm vitest run`, y el lint/typecheck del frontend.
- [ ] 7.2 Abrir el PR con: tabla de consumidores del TEXT y su destino, tabla de las 5 funciones con `código viejo → nuevo`, veredicto por cada RPC admin (4 dropeadas / 1 viva), y la justificación explícita de por qué `_journal_post_from_event` y el payload de `events` NO se tocan.
- [ ] 7.3 Esperar **todos** los checks verdes (`KPI_Validation`, `Backend_Tests`, `Frontend_Tests`, `E2E_Tests`, Vercel) y mergear. El merge dispara build + deploy + migración automáticos.
- [ ] 7.4 **Smoke en prod post-deploy** (solo SELECTs para verificar): venta POS con `cash` y con `transfer` desde la UI; confirmar que la orden queda con `payment_method_id`, que se emite el `SaleConfirmed` con `payment_method` correcto, que el asiento del outbox rutea a la cuenta esperada (`1100 Caja` / `1110 Banco`) y que el listado de ventas y `/reportes/formas-pago` siguen mostrando la forma de pago.
- [ ] 7.5 Verificar que las 4 RPCs admin ya no están en prod y que `rpc_admin_kpi_overview` sigue devolviendo `community_activity` con valor.
- [ ] 7.6 Forzar en prod (o en un entorno equivalente) al menos uno de los `RAISE` corregidos y confirmar que el backend devuelve el status HTTP correcto con el mensaje original, en vez de un 500 genérico.
- [ ] 7.7 Actualizar `CHANGES.md`: marcar OQ-F y OQ-3 admin como cerradas, registrar el change y las OQ nuevas (OQ-1 `check` sin sembrar, OQ-2 `database.types.ts`, OQ-3 fixture del gate de refs, OQ-4 worktree stale).
- [ ] 7.8 `mem_save` con `topic_key: "opsx/limpiezas-pagos-admin/apply"` y `/opsx:archive limpiezas-pagos-admin`.
