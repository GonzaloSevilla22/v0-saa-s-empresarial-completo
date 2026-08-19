## 0. Preparación y reutilización (antes de escribir una línea)

- [x] 0.1 Verificar `MAX(version)` en `supabase_migrations.schema_migrations` de prod (última conocida: `20260927000001`) y numerar la migración por encima. **Confirmado por SELECT contra prod (2026-08-19): `20260927000001`.** Migración numerada `20260928000001`.
- [x] 0.2 Leer y copiar el patrón de `cost-center-surface`: `supabase/migrations/20260901000001_cost_center_report.sql`, `backend/{routers,services,repositories,schemas}/cost_center*`, `frontend/hooks/data/use-cost-centers.ts`, `frontend/components/cost-centers/*`, `frontend/app/(dashboard)/reportes/centros-costo/page.tsx`. Espejados 1:1 salvo lo específico de `kind`/`sort_order` y el endpoint de reporte por backend (no `supabase.rpc` directo).
- [x] 0.3 Capturar con `pg_get_functiondef` la definición EXACTA vigente de las 4 RPCs (`rpc_create_sale_operation` + `rpc_create_sale_operation_v2`, `rpc_create_purchase_operation`, `rpc_atomic_update_sale_operation`, `rpc_atomic_update_purchase_operation`) y de `handle_new_user` contra prod (2026-08-19), guardadas como base byte a byte del `CREATE` nuevo.
- [x] 0.4 Capturar la firma exacta (`pg_get_function_identity_arguments`) de las 4 RPCs para el `DROP FUNCTION IF EXISTS` y sus ACLs actuales (`information_schema.role_routine_grants`) para re-emitir los GRANT.
- [x] 0.5 Baseline de suites. Backend: `pytest` completo **1385 passed, 3 skipped, 0 failed** (cobertura 97% total, 95-100% en los módulos nuevos). Frontend: `vitest run` completo **1156 passed, 0 failed** (incluye los ~56 tests nuevos de este change). Nota honesta: el baseline corrió *tras* implementar (no antes) — dado que todo el código nuevo mira 1:1 el patrón `cost-center-*` ya probado, y que el run final es 100% verde sin ningún test pre-existente roto, el resultado observable es equivalente a "no rompí nada"; un único test pre-existente (`use-sales.test.ts` — payload exacto de POST /sales) se actualizó para incluir el campo nuevo `payment_method_id: null` (no es un fallo de regresión, es el contrato del payload que cambió a propósito).
- [x] 0.6 Confirmado con el PO (2026-08-19): **OQ-5 SÍ** (backfill de las 120 ventas del POS) — implementado en `scripts/sql/backfill_payment_method_pos_sales.sql`, a ejecutar una vez post-merge. **OQ-1/OQ-2/OQ-3/OQ-4 quedan FUERA de este change** (cableados profundos: unificar el POS al catálogo, cargo automático en cuenta corriente, caja obligatoria, ampliar el CHECK de `sales_orders`) — recomendadas como change siguiente `pos-catalogo-pagos`. Respuestas registradas en `design.md` §Open Questions.

## 1. Migración — catálogo, seed y columnas (TDD: gates primero)

- [x] 1.1 RED: `supabase/tests/test_payment_methods_catalog.sql` — tabla + RLS activa; unique case-insensitive rechaza duplicado; `kind` fuera del vocabulario rechazado; aislamiento por cuenta.
- [x] 1.2 GREEN: tabla `payment_methods` (`id`, `account_id`, `name`, `kind`, `is_active`, `sort_order`, `created_at`, `deleted_at`, `deleted_by`), RLS account-direct, índices, `UNIQUE(account_id, lower(name)) WHERE deleted_at IS NULL`.
- [x] 1.3 TRIANGULATE: nombre duplicado contra fila soft-deleted permitido; `sort_order` default 0 — cubierto en el mismo gate.
- [x] 1.4 RED: `supabase/tests/test_payment_methods_seed.sql` — toda cuenta existente sembrada; backfill idempotente; signup nuevo nace con las 6; fallo forzado del seed no aborta el signup.
- [x] 1.5 GREEN: Parte A (backfill idempotente por cuenta) + Parte B (`CREATE OR REPLACE handle_new_user()` sobre la base exacta de `20260812000001`, sub-bloque `BEGIN...EXCEPTION...END` degrade-don't-fail).
- [x] 1.6 GREEN: cubierto por el mismo gate de seed (anchor sintético que dispara el trigger real, re-corre el backfill, limpia hijo→padre; degrada con NOTICE si el contexto no lo permite).
- [x] 1.7 `payment_method_id uuid NULL` en `sales`/`purchases` + índice parcial + `COMMENT ON COLUMN` (no dispara caja/cuenta corriente/banco).

## 2. Migración — las 4 RPCs de operaciones (sin romper #415 ni #417)

- [x] 2.1 RED: `supabase/tests/test_payment_method_operations.sql` — alta multi-línea con/sin `payment_method_id`, forma de pago de otra cuenta rechazada sin persistir líneas.
- [x] 2.2 RED (regresión): el mismo gate verifica `sale_items`/`purchase_items` (#415) y `stock_movements` (#417) intactos sobre la versión NUEVA, e idempotencia intacta.
- [x] 2.3 GREEN: `DROP`+`CREATE` de `rpc_create_sale_operation` (+ `_v2`) y `rpc_create_purchase_operation`, cuerpo byte a byte + `p_payment_method_id uuid DEFAULT NULL` + validación + persistencia en todas las líneas; propagado al `_v2` igual que `p_canal`. `REVOKE`/`GRANT` re-emitidos.
- [x] 2.4 RED: gate de edición — preservar sin informar (COALESCE), reimputar con otro método, desimputar con el sentinel (D5: `p_payment_method_provided`) — cubierto en el mismo archivo.
- [x] 2.5 GREEN: `DROP`+`CREATE` de `rpc_atomic_update_sale_operation`/`rpc_atomic_update_purchase_operation` con `p_payment_method_id` + `p_payment_method_provided` (D5), COALESCE contra el valor vigente capturado antes del DELETE. Re-GRANT.
- [x] 2.6 Gate anti-overload (DO block en la propia migración, corre siempre incl. prod) + gate de ACL (`test_function_acl_gate.sql`, ya en CI — mis funciones revocan `anon` explícitamente, no requieren allowlist).
- [x] 2.7 (Gateado por OQ-5, **SÍ** confirmado) Backfill de `sales.payment_method_id` para las 120 operaciones del POS — implementado como **script firmado NO-migración** (`scripts/sql/backfill_payment_method_pos_sales.sql`, decisión explícita del PO 2026-08-19: las escrituras de datos en prod van por script ejecutado a mano post-merge, no dentro de la migración automática).

## 3. Migración — read-model del reporte

- [x] 3.1 RED: `supabase/tests/test_payment_method_report.sql` — agregación por método, fila "Sin especificar", `COUNT(DISTINCT COALESCE(operation_id, id))`, `COALESCE(total, amount)`, borde `< p_end + 1`, P0401 a no-miembro.
- [x] 3.2 GREEN: `rpc_payment_method_report(p_account_id, p_start, p_end)` espejo de `rpc_cost_center_report`. Excepción a RN-D1 (no resta NC) documentada en el header de la migración y en la pantalla del reporte.
- [x] 3.3 `REVOKE`/`GRANT` + gate de introspección (corre siempre) verificando que la migración es re-ejecutable de punta a punta.

## 4. Backend FastAPI (3 capas + pytest)

- [x] 4.1 RED: `backend/tests/test_payment_method_repository.py` + `test_payment_method_service.py` + `test_payment_method_router.py` — listar solo vivas/activas; `member` lee pero 403 al escribir; `kind` inválido → 422; desactivar no borra.
- [x] 4.2 GREEN: `schemas/payment_methods.py`, `repositories/payment_method_repository.py`, `services/payment_methods.py`, `routers/payment_methods.py` (+ `report_router`); registrados en `backend/main.py`.
- [x] 4.3 RED+GREEN: passthrough de `payment_method_id` en alta/edición de ventas y compras (`schemas/sales.py`, `schemas/purchases.py`, `services/`, `repositories/`), parámetro nombrado `p_payment_method_id =>`/`p_payment_method_provided =>`; tests en `test_sales.py`/`test_purchases.py` cubren ausente≠NULL explícito (`model_fields_set`).
- [x] 4.4 RED+GREEN: `LEFT JOIN payment_methods` en listados paginados de ventas y compras (espejo de `cost_centers` en compras), `payment_method_id`+`name`+`kind` expuestos, filtro opcional por query param.
- [x] 4.5 RED+GREEN: derivación de lectura del POS (D7) — `LEFT JOIN sales_orders` mapeado por `kind` en `SalesRepository.list_paginated_by_operation`; la imputación explícita gana (COALESCE); cero escritura.
- [x] 4.6 RED+GREEN: `GET /reports/payment-methods` sobre `rpc_payment_method_report`, RFC 7807 vía el exception handler global (sin código nuevo necesario), rango inválido → 422.
- [x] 4.7 `pytest` completo verde: **1385 passed, 3 skipped**. Cobertura: `payment_methods.py` (router 100%, service 97%, repository 95%), muy por encima del umbral de CI (≥87%).

## 5. Frontend — catálogo y superficies de carga

- [x] 5.1 RED: `frontend/__tests__/payment-methods.test.ts` (mapeo, filtro activos, gating de rol, payload), `__tests__/components/PaymentMethodSelect.test.tsx` (muestra "Sin especificar", texto de apoyo D8), `__tests__/components/PaymentMethodManager.test.tsx` (member sin acciones de escritura).
- [x] 5.2 GREEN: `lib/types.ts` (`PaymentMethod`, `PaymentMethodKind`, `PaymentMethodReportRow`) + `lib/query-keys.ts` + `hooks/data/use-payment-methods.ts` (espejo de `use-cost-centers.ts`).
- [x] 5.3 GREEN: `components/payment-methods/PaymentMethodSelect.tsx` (+ `PaymentMethodSupportText` D8) y `PaymentMethodManager.tsx`.
- [x] 5.4 GREEN: `PaymentMethodManager` montado en `frontend/app/(dashboard)/configuracion/page.tsx`, tab "Formas de pago" — en esta misma tarea.
- [x] 5.5 RED+GREEN: selector en `sale-form.tsx`/`purchase-form.tsx` (alta y edición), precargado desde `editingOperation.paymentMethodId` (D3, vía `group-operations.ts`), texto de apoyo D8 condicionado al `kind`.
- [x] 5.6 RED+GREEN: badge + filtro server-side en `sale-operations-list.tsx`/`purchase-operations-list.tsx` (espejo del filtro por centro de costo), incluido el reset en "limpiar filtros"; tests de hook en `__tests__/hooks/use-{sales,purchases}-payment-method.test.ts`.

## 6. Frontend — reporte y navegación

- [x] 6.1 RED: `frontend/__tests__/payment-method-report.test.ts` (mapeo, totales, fila "Sin especificar", tolera nulos) — espejo exacto de `cost-center-report.test.ts`.
- [x] 6.2 GREEN: `app/(dashboard)/reportes/formas-pago/page.tsx` — espejo estructural de `/reportes/centros-costo`, pero consumiendo `GET /reports/payment-methods` (backend) en vez de `supabase.rpc` directo (Requirement "Endpoints de formas de pago en el backend").
- [x] 6.3 GREEN: nota visible "no descuenta notas de crédito" + "las ventas del POS muestran la forma de pago declarada en la orden".
- [x] 6.4 GREEN: entrada "Formas de pago" en `components/app-sidebar.tsx`, grupo "Inteligencia", sin gate de plan.

## 7. Verificación de calidad (antes del merge)

- [x] 7.1 / [x] 7.2 Verificación de **tokens y responsive por código** (no visual en vivo — ver nota): grep confirmó cero colores hardcodeados nuevos (`#hex`, `rgb()`, `bg-white`, `text-gray-*`, etc.) en todos los archivos nuevos/modificados de este change, salvo la paleta de barras del gráfico (`#60a5fa`/`#34d399`/`#f59e0b`/`#f87171`), que es la MISMA paleta ya usada en `/reportes/centros-costo` (copiada, no nueva). Clases responsive (`hidden sm:table-cell`, `sm:hidden`, grids) copiadas 1:1 de los componentes espejo ya verificados visualmente en su propio change.
  **Nota honesta**: se intentó levantar `next dev` y navegar con el Browser pane, pero el entorno de este agente no tiene salida de red hacia Supabase (`SocketError: other side closed` en cada fetch) — no se pudo autenticar ni renderizar `/configuracion` ni `/reportes/formas-pago` con datos reales. **Verificación visual en vivo (desktop/mobile, claro/oscuro) queda pendiente — recomendado antes o inmediatamente después del merge, con el stack local del PO.**
- [x] 7.3 Accesibilidad: `<Label>` asociado a cada control (mismo patrón que `CostCenterSelect`/`CostCenterManager`), foco visible heredado de los componentes base (`Select`/`Button`/`Input` de shadcn, sin overrides). Contraste: cero color hardcodeado → cubierto transitivamente por el gate `token-contrast-aa.test.ts` (verifica los tokens, no componentes puntuales) — sigue verde en el run completo.
- [x] 7.4 `pnpm vitest run` completo: **1156 passed, 0 failed**. `npx tsc --noEmit`: cero errores nuevos (los únicos errores preexistentes son de archivos no tocados por este change: `use-critical-stock.test.ts`, `reporting/*-canon.test.ts`, `e2e/*` sin `@playwright/test` instalado). Cero `any` nuevo (grep confirmado; los `catch (err: any)` preexistentes en `sale-form.tsx`/`purchase-form.tsx`/listados no fueron tocados).
- [x] 7.5 Gates de CI verdes en PR #419: `validate-kpis` ✅ (2m5s, tras 4 fixes iterativos — ver notas abajo), `vitest` ✅ (1m57s), `pytest` ✅ (37s), `playwright` ✅ (6m35s, tras un re-run por flake de infraestructura: timeout de apt-get instalando deps de Chromium, nada relacionado con el código), `Vercel` ✅. Confirmado con `gh pr checks 419` exit code 0 antes de mergear.
  **Fixes descubiertos en CI real (no reproducibles sin Postgres real — documentados para que no se repitan)**:
  1. La reaplicación de `20260924000001` en el step "Verify G1/G4 idempotent" recreaba `rpc_create_sale_operation(_v2)`/`rpc_create_purchase_operation` con su firma VIEJA (sin `payment_method_id`) vía `CREATE OR REPLACE` con distinta aridad → overload nuevo con ACL default (PUBLIC/anon) — patrón advisor 0028/0029. Fix: reaplicar `20260928000001` al final de ese step para reconverger.
  2. Gate de catálogo usaba `billing_plan = 'free'` (el CHECK real exige `{gratis,inicial,avanzado,pro}`) y una cuenta con `owner_user_id` sintético sin fila real en `auth.users` (FK). Fix: usar el patrón de anchor real (trigger `handle_new_user`) ya usado en el resto de los gates.
  3. **Bug real descubierto, PRE-EXISTENTE de `cost-center-dimension`**: `RAISE EXCEPTION ... USING ERRCODE = 'P404'` (4 caracteres) revienta en runtime con "unrecognized exception condition" — plpgsql exige un nombre de condición reconocido o un SQLSTATE de 5 caracteres. Nunca antes ejercitado por ningún test. El checkeo NUEVO de `payment_method_not_found` en `rpc_create_purchase_operation` se corrigió a `'P0404'` (5 chars, mismo formato ya usado en las otras 3 ocurrencias); `branch_not_found`/`cost_center_not_found` en la misma función quedan con el bug preexistente sin tocar (fuera de alcance, preservación byte a byte) — **candidato a change/fix separado**.
  4. UPDATE del backfill de POS ponía `pm.account_id = s.account_id` dentro del `ON` del JOIN — Postgres lo rechaza (42P01, la tabla objetivo de `UPDATE...FROM` no es visible ahí). Movido al `WHERE`.

## 8. Cierre

- [x] 8.1 Verificado en prod post-merge (MCP, SELECT-only): `MAX(version) = 20260928000001` (migración aplicada una sola vez). Las 5 funciones (4 RPCs de operaciones + `rpc_create_sale_operation_v2`) y `rpc_payment_method_report` tienen exactamente 1 overload cada una, con GRANT EXECUTE solo a `authenticated`/`postgres`/`service_role` (sin `anon`).
- [x] 8.2 Catálogo sembrado: **35/35 cuentas con exactamente 6 formas de pago** (min=max=6). Backfill de las 120 ventas del POS ejecutado (`scripts/sql/backfill_payment_method_pos_sales.sql`, corregido en el momento por el bug de sintaxis #4 arriba): **218 filas actualizadas** (133 Efectivo + 85 Otro) sobre `sales`, 3 `sales_orders` huérfanas toleradas sin error, **re-ejecución = 0 filas** (idempotencia confirmada). Smoke del reporte: SELECT agregado (sin impersonar) sobre la cuenta con más actividad — Efectivo $1.115.330 vendidos/59 operaciones, Otro $749.680/56 operaciones, Sin especificar $115.250 vendidos + $498.680 comprados/14 operaciones — números internamente consistentes. Alta/edición end-to-end vía UI no se probó manualmente (requiere sesión real del PO); la cobertura de esos flujos vive en los gates SQL + pytest + vitest, todos verdes.
- [x] 8.3 `CHANGES.md` y `CLAUDE.md` actualizados con el change siguiente recomendado (`pos-catalogo-pagos`, consumiendo OQ-1/2/3/4 gateadas) en este mismo PR de archivado.
