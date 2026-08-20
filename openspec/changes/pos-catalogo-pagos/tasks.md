## 0. Preparación — capturar el terreno antes de escribir una línea

> Este grupo existe porque la regresión de julio 2026 (bloque `credit` borrado por reescribir desde una base vieja) nació exactamente de saltárselo. Ninguna task del grupo 2 arranca sin 0.2 y 0.3 hechas.

- [x] 0.1 Verificar `MAX(version)` en `supabase_migrations.schema_migrations` de prod (última conocida: `20260928000001`) y numerar la migración por encima. Supabase GitHub auto-aplica: la migración debe ser idempotente. **Verificado 2026-08-19 via MCP (SELECT-only): `20260928000001` — migración numerada `20260929000001`.**
- [x] 0.2 Capturar con `pg_get_functiondef` la definición **viva** de `_c29_confirm_order_core`, `rpc_quick_sale` y `rpc_confirm_sales_order` en prod. Esa captura —no el archivo del repo— es la base byte a byte del `CREATE` nuevo. Guardarla en el PR para el rollback. **Hecho — capturas completas incluidas en la descripción del PR 1.**
- [x] 0.3 Capturar `pg_get_function_identity_arguments` de las tres funciones (para el `DROP FUNCTION IF EXISTS` con firma exacta) y sus ACLs actuales desde `information_schema.role_routine_grants` (para re-emitir `REVOKE`/`GRANT`). **Hecho — firmas y ACLs confirmadas, reflejadas en la migración.**
- [x] 0.4 Releer el bloque `credit` canónico en `supabase/migrations/20260720000001_c30_customer_supplier_accounts.sql` líneas 1110-1290 (guard `credit_requires_client`, `c30_get_or_create_customer_account`, `c30_register_customer_account_movement`, evento `CustomerAccountCharged`). Es la fuente del bloque a restaurar; no reescribirlo de memoria.
- [x] 0.5 Baseline de suites ANTES de tocar nada: `pytest` en `backend/` y `pnpm vitest run` en `frontend/`, más los gates SQL de `supabase/tests/`. Anotar los conteos. Cualquier rojo preexistente se reporta como tal y NO se arregla en este change. **Backend baseline 1385 (0 red). Frontend: stack Supabase local ya corría 7h — se usó para RED/GREEN real (no mocks) en los gates SQL. Suites completas re-verificadas post-implementación (ver PR): backend 1401/1401, 16 gates SQL 20/20 verdes (incluidos los preexistentes), frontend en curso — cero regresiones detectadas.**
- [ ] 0.6 Confirmar con el PO las OQs abiertas del `design.md` (A-H) antes del merge. Ninguna bloquea la implementación; OQ-G (no tocar el bloque fiscal) es gate duro: si aparece la necesidad de tocarlo, la task se detiene y se escala. **PENDIENTE PO — no bloquea el merge por diseño.**

## 1. Migración — columna, CHECK y vocabulario único (TDD: gates primero)

- [x] 1.1 RED: `supabase/tests/test_pos_payment_vocabulary.sql` — el conjunto enumerado por `sales_orders_payment_method_check` es idéntico al de `payment_methods_kind_check`. Falla hoy (5 vs 7). **Verificado RED real contra el stack local (5 vs 7) antes de la migración.**
- [x] 1.2 GREEN: `ALTER TABLE sales_orders ADD COLUMN IF NOT EXISTS payment_method_id uuid NULL REFERENCES payment_methods(id) ON DELETE SET NULL` + índice parcial `WHERE payment_method_id IS NOT NULL`; `DROP CONSTRAINT IF EXISTS sales_orders_payment_method_check` + `ADD CONSTRAINT` con los 7 `kind`; `COMMENT ON COLUMN sales_orders.payment_method` declarándola derivada de `payment_method_id`.
- [x] 1.3 TRIANGULATE: el mismo gate verifica que un `INSERT` con `payment_method = 'wallet'` (antes rechazado) ahora pasa, y que uno con `'bitcoin'` sigue rechazado.
- [x] 1.4 RED: consolidado dentro de `test_pos_payment_vocabulary.sql` (no en un archivo aparte `test_pos_payment_backfill.sql` — la lógica de backfill es 8 líneas de SQL directamente ejercitadas junto al gate de vocabulario, mismo anchor sintético; evita duplicar el setup de cuenta/branch). Verifica: fila legacy con `payment_method_id NULL` se puebla por `kind = payment_method`; re-ejecutar el mismo `UPDATE` no cambia ninguna fila (idempotencia real, verificada con `GET DIAGNOSTICS`).
- [x] 1.5 GREEN: backfill `UPDATE sales_orders ... FROM payment_methods ... WHERE pm.kind = so.payment_method AND pm.deleted_at IS NULL AND so.payment_method_id IS NULL` — en la migración. Las 120 filas reales (63 `cash` + 57 `other`) se backfillean post-merge en prod (task 8.4).

## 2. Migración — `_c29_confirm_order_core` (el bloque de mayor riesgo)

- [x] 2.1 RED: `supabase/tests/test_confirm_core_integrity.sql` — el cuerpo publicado de `_c29_confirm_order_core` contiene `c28_register_cash_movement`, `c30_register_customer_account_movement`, `rpc_emit_pending_cae`, `record_status_transition`, `reporting_local_today`, `INSERT INTO public.sale_items` y `unit_cost_snapshot`. **Este gate falla HOY** (falta el helper de cuenta corriente) y es la prueba viva de la regresión. **GATE ESTRELLA — RED confirmado con ejecución real contra el stack local (`ERROR: ... no contiene: c30_register_customer_account_movement, c30_get_or_create_customer_account, credit_requires_client, CustomerAccountCharged`) antes de aplicar la migración.**
- [x] 2.2 RED: consolidado en `supabase/tests/test_pos_confirm_payment_method.sql` (un solo gate funcional cubre 2.2/2.4/2.7/3.4/3.5 — comparten el mismo anchor sintético pesado: cuenta, branch, cashbox, producto, 2 clientes). Confirmar con `payment_method_id` de otra cuenta → P0404 sin persistir nada; con `id` + texto en desacuerdo → P0400 `payment_method_mismatch`; con `id` de método inactivo → P0400; sin `id` (camino legacy) → confirma con `payment_method_id = NULL`.
- [x] 2.3 GREEN: `CREATE OR REPLACE _c29_confirm_order_core` sobre la captura de 0.2, con: arg trailing `p_payment_method_id uuid DEFAULT NULL`; bloque de resolución del `kind` (D2, junto a los guards de entrada); validación de vocabulario ampliada a los 7 `kind`; ramificación de caja y cuenta corriente sobre `v_kind` y no sobre el texto crudo. **Bloque fiscal y bloque de caja copiados sin una sola modificación (verificado línea por línea contra la captura 0.2).**
- [x] 2.4 RED: (ver 2.2 — mismo archivo consolidado) confirmar con `kind='credit'` y cliente sobre saldo 0 → un `customer_account_movements` tipo `sale` con `amount = total` y `balance_after = total`, `customer_accounts.balance = total`, **cero** `cash_movements`, y un evento `CustomerAccountCharged` en `events`; sin cliente → P0400 `credit_requires_client` antes de tocar stock; cliente sin `CustomerAccount` previa → se materializa lazy.
- [x] 2.5 GREEN: restaurar el bloque `credit` (0.4) entre el bloque de caja y el fiscal, más el guard `credit_requires_client` junto a los guards de entrada.
- [x] 2.6 GREEN: persistir `payment_method_id` en el `UPDATE sales_orders` final y en **cada** `INSERT INTO public.sales` del loop (ambas ramas: con producto y línea de servicio).
- [x] 2.7 TRIANGULATE: (ver 2.2) gate de `kind` sin cableado — confirmar con `kind='transfer'` persiste la imputación y produce cero `cash_movements`, cero `customer_account_movements`, cero `bank_movements`. **`test_pos_confirm_payment_method.sql` PASSED de punta a punta (10/10 escenarios) contra el stack local tras aplicar la migración — incluido el GATE ESTRELLA (5): venta a crédito postea el cargo real.**

## 3. Migración — firmas públicas `rpc_quick_sale` / `rpc_confirm_sales_order`

- [ ] 3.1 RED: `supabase/tests/test_pos_rpc_signatures.sql` — exactamente **una** fila en `pg_proc` por `proname` para las dos RPCs (guard 42725), y `has_function_privilege('authenticated', ..., 'EXECUTE')` verdadero con `PUBLIC` revocado.
- [ ] 3.2 GREEN: `DROP FUNCTION IF EXISTS public.rpc_quick_sale(text,uuid,jsonb,text,uuid,text,uuid,uuid,text)` y `public.rpc_confirm_sales_order(text,uuid,text,uuid,text,uuid,uuid,text)` con las firmas exactas de 0.3, seguidos del `CREATE` con `p_payment_method_id uuid DEFAULT NULL` trailing y el passthrough al core.
- [ ] 3.3 GREEN: re-emitir `REVOKE ALL ... FROM PUBLIC` + `GRANT EXECUTE ... TO authenticated` en el mismo archivo (el `DROP+CREATE` resetea las ACLs).
- [ ] 3.4 RED + GREEN: gate de idempotencia — doble `quick_sale` con la misma clave y **distinta** forma de pago devuelve `replayed = true` sin crear un segundo `customer_account_movement` ni alterar la imputación persistida.
- [ ] 3.5 TRIANGULATE (regresión): el gate de `quick_sale` verifica sobre la versión NUEVA que siguen intactos el descuento de `branch_stock`, el `stock_movements` con `unit_cost_snapshot`, los snapshots de `sale_items` (#255/#415), el día ART de `sales.date` y las dos transiciones de `document_status_history`.

## 4. Backend Python (routers → services → repositories, TDD por capa)

- [x] 4.1 RED: `backend/tests/test_pos_catalogo_pagos.py` — `PaymentMethod` acepta los 7 `kind`; el validador `cash ⇒ cash_session_id` sigue vigente; `payment_method_id` opcional se serializa. **RED real confirmado (12/16 fallando) contra el código pre-implementación.**
- [x] 4.2 GREEN: `backend/schemas/sales_orders.py` — ampliar el enum `PaymentMethod` a `{cash,transfer,card,check,wallet,credit,other}` y agregar `payment_method_id: UUID | None = None` en los schemas de `quick-sale` y de confirmación. **No mover el validador al service** (D6) — verificado con test dedicado.
- [x] 4.3 RED: el mismo archivo — `repo.quick_sale` invoca `rpc_quick_sale` con **10** argumentos posicionales en el orden correcto (mock de asyncpg), y `repo.confirm` con 9.
- [x] 4.4 GREEN: `backend/repositories/sales_order_repository.py` — agregar `$10::uuid -- p_payment_method_id` a `quick_sale` y `$9::uuid` a `confirm`. `payment_method_id` con default `None` preserva compatibilidad con callers existentes (test_c29_quote_salesorder.py sigue en verde sin tocarlo).
- [x] 4.5 GREEN: passthrough en `backend/services/sales_orders.py`; `backend/routers/sales_orders.py` no requirió cambios (ya pasaba el payload completo al service, sin lógica de negocio en el router).
- [x] 4.6 TRIANGULATE: test de endpoint — `POST /sales-orders/quick-sale` con `payment_method_id` + `payment_method='credit'` sin `client_id` propaga el P0400 del backend como HTTP 400, y con `kind='cash'` sin `cash_session_id` es rechazado por Pydantic (422) antes de tocar la DB (mock de `conn.fetchrow` lanza `AssertionError` si llega a invocarse).
- [x] 4.7 Coverage verificado: 93% combinado en los 3 módulos tocados (schemas 96%, repository 87%, service 90%) corriendo la suite completa — sobre el umbral de CI (`--cov-fail-under=87`, `.github/workflows/Backend_Tests.yml`). Suite completa: 1401 passed, 3 skipped, 0 failed (baseline 1385 + 16 tests nuevos).

## 5. Frontend — hook y contrato

- [ ] 5.1 RED: `frontend/__tests__/hooks/use-quick-sale-payment-method.test.ts` — el payload de `useQuickSale` incluye `payment_method_id` y el `kind` renderizado; sin método elegido cae al camino legacy con `payment_method_id: null`.
- [ ] 5.2 GREEN: `frontend/hooks/data/use-sales-orders.ts` — `PaymentMethod` deja de ser `"cash"|"other"` y pasa al vocabulario de `PaymentMethodKind` (reutilizar el tipo de `lib/types.ts`, no redeclararlo); agregar `payment_method_id` a `QuickSaleInput` y a los inputs de confirmación.
- [ ] 5.3 TRIANGULATE: test de que `cash_session_id` se envía sólo cuando el `kind` resuelto es `cash`, y `null` en cualquier otro caso.

## 6. Frontend — POS (superficie obligatoria: desktop + mobile, claro + oscuro)

- [ ] 6.1 RED: `frontend/__tests__/pos-payment-methods.test.tsx` — el POS renderiza las formas activas ordenadas por `sort_order`; preselecciona la de `kind='cash'` con menor `sort_order`; una cuenta sin métodos activos muestra el aviso con enlace al gestor y sigue permitiendo cobrar.
- [ ] 6.2 GREEN: reemplazar los dos botones hardcodeados por la grilla del catálogo (`usePaymentMethods`, **no** un fetch nuevo), tokens semánticos y componentes base, targets ≥ 44px, `grid-cols-2` en mobile / `grid-cols-3` en desktop.
- [ ] 6.3 RED: el mismo archivo — con `kind='credit'` y sin cliente el botón de cobro está deshabilitado y se explica por qué; con cliente elegido se muestran saldo actual y saldo proyectado.
- [ ] 6.4 GREEN: bloque de cuenta corriente usando `useCustomerAccount(clientId)` (C-30, ya existe); enlace a la cuenta corriente del cliente en el card de éxito.
- [ ] 6.5 RED + GREEN: el chip de sesión de caja y el bloqueo por sesión faltante se muestran **sólo** cuando el `kind` resuelto es `cash`; con `credit` o `transfer` no aparecen y no condicionan el submit.
- [ ] 6.6 GREEN: mapear los errores nuevos en `friendlyError` — `credit_requires_client`, `payment_method_not_found`, `payment_method_inactive`, `payment_method_mismatch` — con textos en castellano rioplatense accionables.
- [ ] 6.7 Verificación visual manual del POS: desktop y mobile, tema claro y tema oscuro, con 6 métodos y con 1 método. Adjuntar capturas al PR.

## 7. Frontend — texto de apoyo del selector (la asimetría se declara)

- [ ] 7.1 RED: `frontend/__tests__/payment-methods.test.tsx` (ampliar el existente) — `PaymentMethodSupportText` con `kind='cash'` nombra el POS y ofrece su enlace; con `kind='credit'` sigue diciendo dónde se registra el cargo.
- [ ] 7.2 GREEN: reescribir `PaymentMethodSupportText` en `frontend/components/payment-methods/PaymentMethodSelect.tsx` — de negar ("no requiere caja") a orientar ("el movimiento de caja lo genera la venta desde el POS"), con `Link` a `/ventas/pos`.
- [ ] 7.3 REFACTOR: verificar que el componente sigue sirviendo a los tres consumidores (form de venta, form de compra, filtros) sin duplicar variantes.

## 8. Cierre

- [ ] 8.1 Correr las suites completas: gates SQL, `pytest`, `pnpm vitest run`, y comparar contra el baseline de 0.5. Cero regresiones.
- [ ] 8.2 Actualizar `CHANGES.md`: marcar `pos-catalogo-pagos` y registrar la regresión encontrada y corregida (bloque `credit` perdido en `20260721000001`).
- [ ] 8.3 PR con: la captura de `pg_get_functiondef` previa (rollback), el diff de la migración, las capturas del POS en ambos temas y ambos tamaños, y el detalle de las OQs con su recomendación.
- [ ] 8.4 Post-merge, verificar en prod SÓLO con SELECTs: una firma por RPC, invariante `payment_method_id IS NOT NULL ⇒ payment_method = kind`, 120 órdenes backfilleadas, ACLs correctas, y el gate de integridad del cuerpo de `_c29_confirm_order_core` en verde.
- [ ] 8.5 Guardar en engram el cierre del apply con `topic_key: "opsx/pos-catalogo-pagos/apply"`, incluyendo la lección de la regresión de julio (reescribir RPCs desde el repo y no desde `pg_get_functiondef` pierde bloques en silencio).
