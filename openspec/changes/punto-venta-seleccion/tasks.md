> **Governance MEDIA** (dominio fiscal; el change sólo elige un dato que la RPC ya valida). **Sign-off del PO recibido el 2026-09-26** ("arrancá la implementación con lo recomendado"): OQ-1..OQ-5 resueltas por su recomendación (`design.md` §Sign-off del PO). TDD estricto: cada grupo abre con su RED (test que falla por la razón correcta) antes de escribir producción. Todo commit vía PR, nunca a `main`.

## 0. Checkpoints previos (sólo lectura)

- [x] 0.1 Releer de prod `pg_get_functiondef('public.rpc_emit_pending_cae(text, numeric, uuid, uuid, integer, text, numeric, numeric, integer)'::regprocedure)` y su `obj_description` INMEDIATAMENTE antes de escribir la migración; compararlo línea a línea (sin `\r`) contra `20261059000001_fiscal_marca_previa_e_insert_interno.sql` L516-660. Si difiere, partir del vivo y anotar el desvío.
- [x] 0.2 Guardar el `md5(pg_get_functiondef(...))` vivo de `rpc_emit_subscription_payment_cae(text, uuid, integer, text)` para el gate de D5.
- [x] 0.3 Confirmar que `20261063000001` sigue libre (`ls supabase/migrations`, PRs abiertos, `list_migrations` de prod); renumerar si no.
- [x] 0.4 SAFETY NET — correr y registrar el baseline de: `backend/tests/test_c27_point_of_sale_repository.py` y los tests de `routers/fiscal.py`; `frontend/__tests__/components/emit-invoice-button-label.test.tsx`, `sale-operations-list-facturar.test.tsx`, `operations-count-plural.test.tsx`, `sale-operations-list-payment-lock.test.tsx`, `components/fiscal/__tests__/*`, `__tests__/v22-emit-comprobante.test.ts`, `__tests__/c27-fiscal-profile.test.ts`. Un fallo preexistente se reporta, no se arregla.

## 1. Migración: `is_default` + resolución por predeterminado en la RPC de ventas

- [x] 1.1 RED — gate nuevo `supabase/tests/test_punto_venta_predeterminado.sql` que **ejecuta** `rpc_emit_pending_cae` como un owner real (`SET LOCAL ROLE authenticated` + claims), con fixtures propios y cleanup asertado, cubriendo: (a) 1 PV activo sin explícito → usa ese; (b) 2 activos sin predeterminado sin explícito → `P0422` y `document_sequences` sin cambios; (c) 2 activos con predeterminado sin explícito → `pending_cae` con `punto_de_venta` del predeterminado; (d) explícito ≠ predeterminado → gana el explícito; (e) explícito inactivo con predeterminado → `P0404`; (f) índice único: segundo predeterminado en la misma cuenta falla, en otra cuenta pasa; (g) CHECK: predeterminado inactivo falla; (h) `rpc_emit_subscription_payment_cae` con 2 activos + predeterminado y sin explícito sigue dando `P0422` y su `md5` es el de 0.2. Verlo fallar contra el esquema actual.
- [x] 1.2 GREEN — `supabase/migrations/20261063000001_punto_venta_predeterminado.sql`: `ADD COLUMN IF NOT EXISTS is_default boolean NOT NULL DEFAULT false`; CHECK `points_of_sale_default_is_active` (`NOT is_default OR is_active`) idempotente; índice único parcial `points_of_sale_one_default_per_account ON (account_id) WHERE is_default` con `IF NOT EXISTS`; `CREATE OR REPLACE rpc_emit_pending_cae` desde el cuerpo de 0.1 con el ÚNICO cambio de la rama `v_active_pv_count > 1` (buscar el predeterminado activo antes de `P0422`, D3); re-aplicar el `COMMENT` vivo extendido con una línea de este change; `REVOKE ALL … FROM PUBLIC, anon` + `GRANT EXECUTE … TO authenticated, service_role, postgres`.
- [x] 1.3 Bloque `DO` de introspección al final de la migración (sólo catálogo, sin datos): columna, CHECK, índice, la RPC contiene la rama del predeterminado, ACLs sin `anon`, `md5` de la RPC de suscripciones igual al de 0.2.
- [x] 1.4 Cablear el gate en `.github/workflows/KPI_Validation.yml` (en el orden real del workflow) y comprobar que la migración re-aplicada dos veces seguidas no falla (idempotencia).
- [x] 1.5 TRIANGULATE — verificar que `test_facturar_venta_manual.sql`, `test_fiscal_emit_consumidor_final.sql` y `test_function_acl_gate.sql` siguen verdes con la RPC nueva. (El stack local lo comparte otro workflow: coordinar el turno antes de `supabase db reset`.)

## 2. Backend: predeterminado en repository, service, router y schema

- [ ] 2.1 RED — `backend/tests/test_c27_point_of_sale_repository.py`: `set_default` corre las dos sentencias en orden y filtra por `account_id` en ambas; devuelve `None` si el PV es de otra cuenta o inactivo; `clear_default` filtra por `account_id`; `deactivate` escribe `is_default = false` junto con `is_active = false`.
- [ ] 2.2 GREEN — `PointOfSaleRepository.set_default(pv_id, account_id)`, `clear_default(account_id)` y `deactivate` extendido (D9).
- [ ] 2.3 RED — tests del service/router: `POST /fiscal/points-of-sale/{id}/default` → 200 con `is_default = true`; 404 para PV ajeno/inactivo/inexistente sin cambiar la marca; `DELETE /fiscal/points-of-sale/default` → 204; `member` → 403 en los dos (guard `require_account_role(conn, auth, CAN_CONFIGURE)`); `GET /fiscal/points-of-sale` incluye `is_default`.
- [ ] 2.4 GREEN — `fiscal_profile_service.set_default_point_of_sale` / `clear_default_point_of_sale` con el guard; 2 endpoints en `routers/fiscal.py` (sin lógica en el router; `/default` como sub-recurso, D9); `PointOfSaleOut.is_default: bool`; actualizar la docstring de rutas del router.
- [ ] 2.5 REFACTOR + coverage: `pytest` completo del backend, coverage ≥ 87 %.

## 3. Frontend: regla de preselección y selector compartido

- [ ] 3.1 RED — `frontend/__tests__/lib/fiscal-point-of-sale.test.ts`: `resolvePreselectedPointOfSale` en los cinco escenarios de "Resolución del punto de venta preseleccionado al facturar" (predeterminado, última elección gana, última elección inactiva se ignora, varios sin nada → `null`, inactivo de menor número nunca aparece); `activePointsOfSale`; `formatPointOfSaleNumber(3) === "0003"`.
- [ ] 3.2 GREEN — `frontend/lib/fiscal-point-of-sale.ts` (puro, sin `python-client`; reutiliza el padding de `lib/fiscal-comprobante.ts`).
- [ ] 3.3 RED — `use-points-of-sale`: `mapRow` expone `isDefault`; `useSetDefaultPointOfSale` / `useClearDefaultPointOfSale` llaman a los endpoints de 2.4 e invalidan `queryKeys.pointsOfSale.all()`.
- [ ] 3.4 GREEN — extender `frontend/hooks/data/use-points-of-sale.ts`.
- [ ] 3.5 RED — `components/fiscal/__tests__/PointOfSaleSelect.test.tsx`: un solo activo → texto "Único PV activo", sin combobox; varios → combobox con etiqueta asociada, sólo activos, badge "Predeterminado" en el que corresponde, `onValueChange` con el id.
- [ ] 3.6 GREEN — `frontend/components/fiscal/PointOfSaleSelect.tsx` (PascalCase, tokens semánticos, sin `any`).

## 4. Frontend: emitir con selección en `/ventas` y `/ventas/ordenes`

- [ ] 4.1 RED — `EmitirComprobanteDialog`: abre con la preselección recibida y confirmar habilitado; sin preselección y varios activos → confirmar deshabilitado; confirmar llama `onConfirm(id)`; cancelar no llama `onConfirm`; delegación no autorizada muestra aviso **sin** deshabilitar confirmar (D10/OQ-4); sin clases de paleta literales (`amber-`).
- [ ] 4.2 GREEN — ajustar `EmitirComprobanteDialog` (usa `PointOfSaleSelect`, tokens `warning`, formato de 4 dígitos, recibe la preselección como prop).
- [ ] 4.3 RED — `emit-invoice-button` (extender `emit-invoice-button-label.test.tsx` o archivo hermano): 1 PV activo → emite al primer clic con `point_of_sale_id` explícito y sin diálogo; 2 activos → abre el diálogo; confirmar emite con el id elegido (nunca `null`); tras un OK se escribe `fiscal:last-pv:<accountId>` en sessionStorage y la siguiente apertura lo preselecciona; cancelar no escribe; 0 activos → aviso "Sin punto de venta" con enlace a `/configuracion/fiscal` y sin botón; PV inactivo nunca se envía. Conservar verdes `label` y `onEmitFailed`.
- [ ] 4.4 GREEN — `EmitInvoiceButton`: lee `usePointsOfSale`, resuelve con `resolvePreselectedPointOfSale` + `useSessionStorage` (D8), elimina la prop `pointOfSaleId`.
- [ ] 4.5 RED — `sale-operations-list-facturar.test.tsx`: actualizar la expectativa (hoy fija "se emite por el primero de dos") a la nueva: con dos PV activos se abre el diálogo. Y un test de `/ventas/ordenes` equivalente (con dos activos ya no se envía `null`).
- [ ] 4.6 GREEN — quitar el cálculo de PV de `components/ventas/sale-operations-list.tsx` (L159-163) y de `app/(dashboard)/ventas/ordenes/page.tsx` (L46-49), y la prop en sus `EmitInvoiceButton`. Verificar con `grep` que no queda ningún caller pasando `pointOfSaleId`.
- [ ] 4.7 `EmitirSuscripcionDialog` pasa a usar `PointOfSaleSelect` y preselecciona el predeterminado (sin cambiar su regla de habilitación ni su llamada al backend); sus tests existentes siguen verdes y se agrega el caso de preselección.

## 5. Frontend: "Predeterminado" en Configuración → Datos fiscales

- [ ] 5.1 RED — test de `PointsOfSaleSection` (`FiscalSettings`): badge "Predeterminado"; acción "Usar como predeterminado" en los activos que no lo son y "Quitar predeterminado" en el que lo es (botones con nombre accesible, no sólo icono); la línea explicativa aparece con ≥ 2 activos y ningún predeterminado; formato `0003`.
- [ ] 5.2 GREEN — implementar en `components/settings/FiscalSettings.tsx` con los hooks de 3.4 y manejo de error visible (patrón `deactivateError` existente).

## 6. Verificación

- [ ] 6.1 Suites completas: backend (`pytest`, coverage ≥ 87 %) y frontend (`pnpm vitest run`), `tsc --noEmit` sin errores nuevos, `token-contrast-aa` verde.
- [ ] 6.2 Verificación visual con el stack local (coordinando el turno): diálogo de emisión en `/ventas` y `/ventas/ordenes` con dos PV, y la sección de Puntos de venta, en desktop y 375 px, tema claro y oscuro (4 combinaciones); medir que no hay desborde horizontal y que el botón de confirmar es visible.
- [ ] 6.3 Humo local de punta a punta con dos PV: facturar una venta del POS desde `/ventas/ordenes` eligiendo el 9999 → `fiscal_documents.punto_de_venta = 9999`; marcar el 3 como predeterminado → el diálogo abre con el 3; desactivar el predeterminado → la cuenta queda sin predeterminado.
- [ ] 6.4 Actualizar `CHANGES.md` (ficha del change + candidatos que deja: PV por sucursal, unificar los guards heredados de crear/desactivar PV a `require_account_role`, higiene "PV 9999" del diagnóstico del 21-09) y el puntero del `CLAUDE.md` sólo si corresponde a una regla; `python scripts/ci/check_docs_sync.py --fix` si se toca `CLAUDE.md`.

## 7. Post-merge (prod, sólo lectura salvo pedido explícito)

- [ ] 7.1 Verificar en prod: `MAX(version) = 20261063000001` (o el número final), columna/índice/CHECK presentes, cuerpo vivo de `rpc_emit_pending_cae` con la rama del predeterminado y el `COMMENT`, ACLs sin `anon`, `md5` de `rpc_emit_subscription_payment_cae` igual al de 0.2, 0 PV con `is_default = true` (sin backfill), y que Render desplegó (`GET /deploys`).
- [ ] 7.2 Humo real del PO en Sumar: facturar una venta eligiendo el PV (3 o 9999) desde `/ventas` y una del POS desde `/ventas/ordenes`; opcionalmente marcar un predeterminado en Configuración.

## TDD Cycle Evidence

| Task | Test File | Layer | Safety Net | RED | GREEN | TRIANGULATE | REFACTOR |
|------|-----------|-------|------------|-----|-------|-------------|----------|
| 0.4 | backend `test_c27_point_of_sale_repository.py` + fiscal (6 archivos) / frontend 9 archivos | — | ✅ backend 195 passed + 1 skipped; frontend 102/102 | — | — | — | — |
| 1.1-1.3 | `supabase/tests/test_punto_venta_predeterminado.sql` | SQL gate (ejecuta la RPC) | ✅ 0.1: md5 local == prod `8c10f8ca…` | ✅ (0) falla: sin columna/CHECK/índice/rama/COMMENT; (a-h) falla: columna `is_default` inexistente | ✅ migración `20261063000001` → PASS (0), (a-h), (z) | ✅ 9 casos (a,b,c,d,e,e2,f,g,h) + mutantes: RPC vieja cae en (0)+(c); predeterminado sin filtrar cuenta cae en (e2) | ✅ residuo cero dinámico (toda tabla con `account_id`) |
| 1.4-1.5 | `KPI_Validation.yml` (paso nuevo + reapply de 20261063000001) | CI | ✅ | — | ✅ `db reset` 310 migraciones; paso de reapply completo EXIT=0 (schema idéntico) | ✅ `test_facturar_venta_manual`, `test_fiscal_emit_consumidor_final`, `test_function_acl_gate`, `test_errcode_5char_gate`, `test_venta_editable_sin_cae` verdes | — |
