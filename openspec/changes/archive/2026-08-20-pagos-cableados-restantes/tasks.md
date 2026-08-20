> **Governance MEDIUM** — toca dinero, íntegramente sobre helpers ya en producción. Implementar en pasos y exponer al PO las decisiones no obvias (OQ-1..OQ-5 de `design.md`).
> **Strict TDD obligatorio**: cada grupo de implementación va RED → GREEN → TRIANGULATE → REFACTOR, con red de seguridad previa (baseline de tests existentes) antes de tocar archivos existentes.
> **Regla anti-regresión-julio**: todo cuerpo de RPC que se reescriba parte de la definición **VIVA** capturada con `pg_get_functiondef`, nunca del archivo del repo.

## 1. Línea base y red de seguridad

- [x] 1.1 Capturar con `pg_get_functiondef` de prod (SOLO SELECT) las definiciones vivas de `_c29_confirm_order_core`, `rpc_create_sale_operation`, `rpc_create_sale_operation_v2`, `rpc_create_purchase_operation` y `_journal_post_from_event`, y archivarlas en `openspec/changes/pagos-cableados-restantes/baseline/` como referencia anti-regresión — 6 archivos (más `rpc_atomic_update_sale_operation`/`rpc_atomic_update_purchase_operation` para D6)
- [x] 1.2 Re-verificar `MAX(version)` en `supabase_migrations.schema_migrations` de prod y confirmar que `20261001000001` sigue libre (valor conocido al proponer: `20260930000001`) — confirmado idéntico
- [x] 1.3 Correr la suite existente y registrar el baseline numérico: `pytest` backend (≥87% coverage), `pnpm vitest run` frontend, gates SQL de `supabase/tests/`. Cualquier rojo previo se reporta como fallo preexistente y NO se arregla acá — backend 1412 passed/89%, frontend 1183 passed, SQL 20/20
- [x] 1.4 Registrar las cifras de prod que justifican el change (0 `customer_account_movements`, 343 vs 120 operaciones, 158 asientos, 38 `PurchaseCreated` con literal `credit`, 0 `suppliers`) como evidencia en el PR — reverificadas de primera mano el día del PR: 361 vs 120 (241 del formulario, la cifra creció respecto al 223 capturado por el design un día antes), resto exacto

## 2. Gate de integridad transitivo (RED antes de la migración)

- [x] 2.1 Reescribir `supabase/tests/test_confirm_core_integrity.sql` a verificación transitiva según D3: cadena `_c29_confirm_order_core` → `_pay_register_party_charge` → helpers C-30, más la cobertura nueva de `rpc_create_sale_operation_v2`
- [x] 2.2 Ejecutar el gate nuevo contra la definición viva actual y **verificar que falla** (evidencia RED real, capturada en el PR) — sin este paso el gate no prueba nada
- [x] 2.3 Añadir al gate la verificación de que `rpc_create_purchase_operation` NO contiene el literal `'payment_method', 'credit'` hardcodeado

## 3. Helper compartido de cargo en cuenta corriente (OQ-D, núcleo)

- [x] 3.1 RED: tests SQL del helper `_pay_register_party_charge` — cargo a cliente, cargo a proveedor, `invalid_party_kind`, creación lazy de la cuenta, evento emitido, todo en la misma transacción
- [x] 3.2 GREEN: implementar `_pay_register_party_charge(p_account_id, p_party_kind, p_party_id, p_amount, p_reference_id, p_operation_id)` con `SECURITY DEFINER` + `SET search_path = public, pg_temp`, despachando sobre los helpers C-30 existentes (D1)
- [x] 3.3 TRIANGULATE: segundo caso por rama (cliente con cuenta preexistente vs. sin cuenta; proveedor ídem) verificando `balance_after` acumulado
- [x] 3.4 `REVOKE ALL ... FROM PUBLIC` + `REVOKE EXECUTE ... FROM anon` + `GRANT EXECUTE ... TO authenticated` sobre el helper (D9 — el `REVOKE FROM anon` explícito NO es redundante)

## 4. POS: extraer el bloque inline al helper (OQ-D)

- [x] 4.1 RED: test de comportamiento que postea una venta a crédito por el POS y verifica cargo + evento (debe pasar con la definición actual — es la red que protege la extracción) — cubierto por `test_pos_confirm_payment_method.sql` caso (5), preexistente, que sigue verde post-refactor
- [x] 4.2 GREEN: `CREATE OR REPLACE` de `_c29_confirm_order_core` partiendo de la definición viva de 1.1, reemplazando el bloque `credit` inline por la llamada al helper. Bloque fiscal C-27 y bloque de caja copiados **sin tocar una línea** (gate OQ-G de `pos-catalogo-pagos`)
- [x] 4.3 Verificar que el gate de 2.1 pasa a GREEN
- [x] 4.4 Verificar equivalencia: el cargo posteado por el POS antes y después de la extracción produce filas idénticas en signo, `type`, `reference_id` y `balance_after` — probado por la continuidad verde de `test_pos_confirm_payment_method.sql` (5)

## 5. Formulario de venta a cuenta corriente (OQ-D)

- [x] 5.1 RED: tests de `rpc_create_sale_operation_v2` — venta a crédito postea cargo, venta a crédito sin cliente falla con `credit_requires_client`, venta no-crédito no toca la cuenta corriente
- [x] 5.2 GREEN: derivar el `kind` desde `p_payment_method_id` en `rpc_create_sale_operation_v2`, añadir el guard `credit_requires_client` **antes** del descuento de stock, y postear el cargo vía el helper
- [x] 5.3 Propagar el mismo comportamiento a la rama legacy de `rpc_create_sale_operation` (flag `sale_items_rpc_v2` en `false`) para que ambas ramas del strangler sean consistentes
- [x] 5.4 TRIANGULATE: cliente sin cuenta previa vs. cliente con saldo acumulado; verificar `balance_after` — cubierto por §5a (client2 sin cuenta previa) + acumulación posterior en la sección "legacy" (mismo cliente, mismo change)

## 6. Opt-in de caja en el formulario de venta (OQ-C)

- [x] 6.1 RED: tests de las tres condiciones de servidor — `cash_optin_requires_cash_kind`, `cash_optin_requires_open_session` (incluido el caso de sesión abierta en OTRA sucursal), `cash_optin_requires_today` (fecha de ayer)
- [x] 6.2 GREEN: añadir `p_cash_session_id` trailing a `rpc_create_sale_operation` y `rpc_create_sale_operation_v2`; validar las tres condiciones (D4) y reutilizar `c28_register_cash_movement` — sin escribir aritmética de caja nueva
- [x] 6.3 Verificar que el guard de fecha usa el canon `America/Argentina/Mendoza` de `business-day-timezone`, no `current_date` del servidor — usa `public.reporting_local_today()`, mismo helper que `_c29_confirm_order_core`
- [x] 6.4 TRIANGULATE: venta con opt-in que sí genera movimiento vs. venta idéntica sin opt-in que no lo genera; verificar `expected_balance` de la sesión en ambos casos

## 7. Compras: kind real al evento (OQ-E entra / OQ-B productor)

- [x] 7.1 RED: test que verifica que una compra imputada a `kind='transfer'` emite `PurchaseCreated` con `payment_method='transfer'` (falla hoy: literal `'credit'`)
- [x] 7.2 GREEN: en `rpc_create_purchase_operation`, derivar el kind desde `p_payment_method_id` y emitirlo en el payload con `COALESCE(..., 'credit')` para preservar el comportamiento sin forma de pago imputada — sin cambio de firma (corrección al Impact summary del design, documentada en el commit)
- [x] 7.3 TRIANGULATE: compra con `cash`, compra con `credit`, compra sin forma de pago — tres contrapartidas distintas verificadas en `journal_lines`

## 8. Consumidor contable: `wallet` al ruteo bancario (OQ-B)

- [x] 8.1 RED: test que verifica que un `SaleConfirmed` con `payment_method='wallet'` acredita/debita `1110 Banco` (falla hoy: cae en `1100 Caja`)
- [x] 8.2 GREEN: `CREATE OR REPLACE` de `_journal_post_from_event` partiendo de la definición viva de 1.1, agregando `'wallet'` al predicado `v_is_bank` — hallazgo: sólo **tres** ramas tienen ese predicado (`SaleConfirmed`, `PaymentReceived`, `PaymentMade`); `PurchaseCreated` no lo tiene (binario cash/resto), documentado en el código — el design sobregeneralizaba "las cuatro ramas"
- [x] 8.3 Verificar en cada rama que el invariante Σdébito = Σcrédito (`ASSERT`, `P0450`) sigue satisfecho
- [x] 8.4 TRIANGULATE: los 7 `kind` del catálogo, cada uno con su cuenta esperada, en una tabla de casos

## 9. Inmutabilidad de operaciones con cargo o movimiento (D6)

- [x] 9.1 RED: tests de `rpc_atomic_update_sale_operation` — editar una venta con cargo de cuenta corriente falla con `P0423`; editar una venta con movimiento de caja falla con `P0423`; editar una venta sin ninguno de los dos procede — incluye ambas convenciones de `reference_id` (operation_id del formulario, sales_orders.id del POS)
- [x] 9.2 GREEN: añadir el guard antes del ciclo REVERSE→DELETE→INSERT, con mensaje que distingue la causa (cargo vs. caja) y sugiere la nota de crédito
- [x] 9.3 Espejar el guard en `rpc_atomic_update_purchase_operation`
- [x] 9.4 Verificar que el handler global RFC 7807 mapea `P0423` a HTTP 409 sin plomería nueva (ya lo hace para el bloqueo fiscal de `edicion-preserva-contexto` F2) — confirmado por lectura de `backend/core/errors.py`, ya en `_BUSINESS_ERRCODE_STATUS`
- [x] 9.5 Confirmar contra prod (SOLO SELECT) que el impacto retroactivo es cero: 0 `customer_account_movements` y los 63 `cash_movements` pertenecen todos al POS

## 10. Migración

- [x] 10.1 Escribir `supabase/migrations/20261001000001_pagos_cableados_restantes.sql` en un solo archivo, idempotente extremo a extremo, en el orden: helper → confirm-core → RPCs de venta → RPC de compra → consumidor → guards de edición → `REVOKE`/`GRANT`
- [x] 10.2 Usar `DROP FUNCTION IF EXISTS` con la lista de tipos **exacta capturada de prod** para las RPCs que cambian de firma (evita `42725`); `CREATE OR REPLACE` para las que conservan firma — sólo las 2 RPCs de venta cambian de firma (corrección: `rpc_create_purchase_operation` NO cambia, ver task 7.2)
- [x] 10.3 `REVOKE ALL ... FROM PUBLIC` + `REVOKE EXECUTE ... FROM anon` + `GRANT EXECUTE ... TO authenticated` en **cada** función tocada (D9 — gotcha `ALTER DEFAULT PRIVILEGES`, descubierto en CI en #420, #421 y #423)
- [x] 10.4 Verificar que ningún `RAISE EXCEPTION ... USING ERRCODE` usa un código de 4 caracteres (revienta en runtime en plpgsql — gotcha de #419) — verificado por grep; los únicos de 4 chars son los preexistentes de `rpc_create_purchase_operation` preservados byte a byte, fuera de alcance (bug documentado, no nuevo)
- [x] 10.5 Aplicar la migración en local y re-correr toda la suite del paso 1.3 comparando contra el baseline — más un hallazgo real: `CREATE FUNCTION` (no `CREATE OR REPLACE`) rompía el reapply idempotente, corregido antes del PR; y un segundo hallazgo en CI (reapply G1/G4 fuera de orden dejaba un overload fantasma), corregido en `.github/workflows/KPI_Validation.yml` tras el primer push

## 11. Backend FastAPI

- [x] 11.1 RED: tests de `backend/services/sales.py` y `backend/services/purchases.py` para los parámetros nuevos, incluido el tri-estado del opt-in de caja — 7 tests nuevos (`cash_session_id` passthrough + `is_payment_locked` en sales/purchases)
- [x] 11.2 GREEN: `cash_session_id` opcional en el schema Pydantic v2 de alta de venta; propagación por routers → services → repositories sin lógica de negocio en el router
- [x] 11.3 Verificar que el error de dominio (`credit_requires_client`, `cash_optin_*`, `P0423`) llega al cliente como RFC 7807 con el status correcto — cero plomería nueva, ya cubierto por `_BUSINESS_ERRCODE_STATUS`
- [x] 11.4 Confirmar coverage ≥87% en CI — 1417 passed, 89%

## 12. Superficie frontend (regla PO 2026-08-02)

- [x] 12.1 RED: tests de componente de `sale-form.tsx` — el checkbox de caja aparece sólo con las tres condiciones; el cliente pasa a obligatorio con `kind='credit'`
- [x] 12.2 GREEN: bloque `credit` en `sale-form.tsx` con cliente obligatorio y saldo actual/proyectado vía `useCustomerAccount` (D8), reutilizando el patrón visual ya establecido en el POS
- [x] 12.3 GREEN: checkbox "Registrar en caja" en `sale-form.tsx`, con el motivo explícito cuando alguna condición no se cumple (no ocultarlo en silencio)
- [x] 12.4 Deshabilitar la acción de editar con razón visible en `sale-operations-list.tsx` y `purchase-operations-list.tsx` para operaciones con cargo o movimiento posteado (D6, spec `operation-edit-context`) — icono de candado + `title`/`aria-label`, cubierto por tests de componente nuevos
- [x] 12.5 Verificar el texto de apoyo del selector: la superficie declara qué efecto tiene cada `kind` (spec `payment-method`) — `PaymentMethodSupportText` actualizado (antes decía explícitamente que `credit`/`cash` en el form NO tenían efecto; ahora sí lo declaran)
- [x] 12.6 Verificación visual en **desktop y mobile** y en **tema claro y oscuro**, con tokens semánticos del design system — **honesto: verificado por tests + revisión de código** (reutiliza 1:1 las clases de `/ventas/pos`, ya validadas visualmente en `pos-catalogo-pagos`: `bg-accent/20`, `text-muted-foreground`, `text-amber-700 dark:text-amber-400`), NO se tomaron capturas de pantalla en este pase

## 13. Regresión y cierre

- [x] 13.1 Verificar verdes los gates existentes: `test_confirm_core_integrity.sql` (transitivo), `token-contrast-aa.test.ts`, `test_function_acl_gate.sql`, `validate-kpis` — los 4 verdes (validate-kpis verde en CI tras el fix de reconvergencia)
- [x] 13.2 Verificar sin regresión los changes de la saga: #415 (líneas), #417 (ledger espejo), #419 (catálogo + tri-estado), #421 (POS credit), #423 (acarreo de contexto + inmutabilidad fiscal) — 21/21 gates SQL verdes en reset limpio
- [x] 13.3 Verificar que el bloque fiscal C-27 quedó byte a byte idéntico al capturado en 1.1 — diff programático, idéntico
- [x] 13.4 Abrir PR (NUNCA commitear a `main` — todo cambio vía PR, incluidos fixes trivales de seguimiento) con la evidencia RED/GREEN del gate y las cifras de prod — PR #425, mergeado
- [x] 13.5 Verificación post-merge en prod (SOLO SELECT): una venta a crédito produce fila en `customer_account_movements` (hoy 0); una compra emite `PurchaseCreated` con kind real (hoy siempre `credit`) — verificado ESTRUCTURALMENTE (funciones/ACLs correctas, MAX(version) actualizado); la verificación TRANSACCIONAL (una venta/compra real) queda pendiente de uso orgánico o del PO — no se fabricaron datos de prod (regla SOLO SELECT)
- [x] 13.6 Registrar en `CHANGES.md` el cierre de OQ-B (parcial), OQ-C, OQ-D y OQ-E (parcial), y dar de alta los changes derivados `asiento-venta-formulario` y `compras-proveedor-cuenta-corriente`
