> **Governance MEDIUM** — toca dinero, íntegramente sobre helpers ya en producción. Implementar en pasos y exponer al PO las decisiones no obvias (OQ-1..OQ-5 de `design.md`).
> **Strict TDD obligatorio**: cada grupo de implementación va RED → GREEN → TRIANGULATE → REFACTOR, con red de seguridad previa (baseline de tests existentes) antes de tocar archivos existentes.
> **Regla anti-regresión-julio**: todo cuerpo de RPC que se reescriba parte de la definición **VIVA** capturada con `pg_get_functiondef`, nunca del archivo del repo.

## 1. Línea base y red de seguridad

- [ ] 1.1 Capturar con `pg_get_functiondef` de prod (SOLO SELECT) las definiciones vivas de `_c29_confirm_order_core`, `rpc_create_sale_operation`, `rpc_create_sale_operation_v2`, `rpc_create_purchase_operation` y `_journal_post_from_event`, y archivarlas en `openspec/changes/pagos-cableados-restantes/baseline/` como referencia anti-regresión
- [ ] 1.2 Re-verificar `MAX(version)` en `supabase_migrations.schema_migrations` de prod y confirmar que `20261001000001` sigue libre (valor conocido al proponer: `20260930000001`)
- [ ] 1.3 Correr la suite existente y registrar el baseline numérico: `pytest` backend (≥87% coverage), `pnpm vitest run` frontend, gates SQL de `supabase/tests/`. Cualquier rojo previo se reporta como fallo preexistente y NO se arregla acá
- [ ] 1.4 Registrar las cifras de prod que justifican el change (0 `customer_account_movements`, 343 vs 120 operaciones, 158 asientos, 38 `PurchaseCreated` con literal `credit`, 0 `suppliers`) como evidencia en el PR

## 2. Gate de integridad transitivo (RED antes de la migración)

- [ ] 2.1 Reescribir `supabase/tests/test_confirm_core_integrity.sql` a verificación transitiva según D3: cadena `_c29_confirm_order_core` → `_pay_register_party_charge` → helpers C-30, más la cobertura nueva de `rpc_create_sale_operation_v2`
- [ ] 2.2 Ejecutar el gate nuevo contra la definición viva actual y **verificar que falla** (evidencia RED real, capturada en el PR) — sin este paso el gate no prueba nada
- [ ] 2.3 Añadir al gate la verificación de que `rpc_create_purchase_operation` NO contiene el literal `'payment_method', 'credit'` hardcodeado

## 3. Helper compartido de cargo en cuenta corriente (OQ-D, núcleo)

- [ ] 3.1 RED: tests SQL del helper `_pay_register_party_charge` — cargo a cliente, cargo a proveedor, `invalid_party_kind`, creación lazy de la cuenta, evento emitido, todo en la misma transacción
- [ ] 3.2 GREEN: implementar `_pay_register_party_charge(p_account_id, p_party_kind, p_party_id, p_amount, p_reference_id, p_operation_id)` con `SECURITY DEFINER` + `SET search_path = public, pg_temp`, despachando sobre los helpers C-30 existentes (D1)
- [ ] 3.3 TRIANGULATE: segundo caso por rama (cliente con cuenta preexistente vs. sin cuenta; proveedor ídem) verificando `balance_after` acumulado
- [ ] 3.4 `REVOKE ALL ... FROM PUBLIC` + `REVOKE EXECUTE ... FROM anon` + `GRANT EXECUTE ... TO authenticated` sobre el helper (D9 — el `REVOKE FROM anon` explícito NO es redundante)

## 4. POS: extraer el bloque inline al helper (OQ-D)

- [ ] 4.1 RED: test de comportamiento que postea una venta a crédito por el POS y verifica cargo + evento (debe pasar con la definición actual — es la red que protege la extracción)
- [ ] 4.2 GREEN: `CREATE OR REPLACE` de `_c29_confirm_order_core` partiendo de la definición viva de 1.1, reemplazando el bloque `credit` inline por la llamada al helper. Bloque fiscal C-27 y bloque de caja copiados **sin tocar una línea** (gate OQ-G de `pos-catalogo-pagos`)
- [ ] 4.3 Verificar que el gate de 2.1 pasa a GREEN
- [ ] 4.4 Verificar equivalencia: el cargo posteado por el POS antes y después de la extracción produce filas idénticas en signo, `type`, `reference_id` y `balance_after`

## 5. Formulario de venta a cuenta corriente (OQ-D)

- [ ] 5.1 RED: tests de `rpc_create_sale_operation_v2` — venta a crédito postea cargo, venta a crédito sin cliente falla con `credit_requires_client`, venta no-crédito no toca la cuenta corriente
- [ ] 5.2 GREEN: derivar el `kind` desde `p_payment_method_id` en `rpc_create_sale_operation_v2`, añadir el guard `credit_requires_client` **antes** del descuento de stock, y postear el cargo vía el helper
- [ ] 5.3 Propagar el mismo comportamiento a la rama legacy de `rpc_create_sale_operation` (flag `sale_items_rpc_v2` en `false`) para que ambas ramas del strangler sean consistentes
- [ ] 5.4 TRIANGULATE: cliente sin cuenta previa vs. cliente con saldo acumulado; verificar `balance_after`

## 6. Opt-in de caja en el formulario de venta (OQ-C)

- [ ] 6.1 RED: tests de las tres condiciones de servidor — `cash_optin_requires_cash_kind`, `cash_optin_requires_open_session` (incluido el caso de sesión abierta en OTRA sucursal), `cash_optin_requires_today` (fecha de ayer)
- [ ] 6.2 GREEN: añadir `p_cash_session_id` trailing a `rpc_create_sale_operation` y `rpc_create_sale_operation_v2`; validar las tres condiciones (D4) y reutilizar `c28_register_cash_movement` — sin escribir aritmética de caja nueva
- [ ] 6.3 Verificar que el guard de fecha usa el canon `America/Argentina/Mendoza` de `business-day-timezone`, no `current_date` del servidor
- [ ] 6.4 TRIANGULATE: venta con opt-in que sí genera movimiento vs. venta idéntica sin opt-in que no lo genera; verificar `expected_balance` de la sesión en ambos casos

## 7. Compras: kind real al evento (OQ-E entra / OQ-B productor)

- [ ] 7.1 RED: test que verifica que una compra imputada a `kind='transfer'` emite `PurchaseCreated` con `payment_method='transfer'` (falla hoy: literal `'credit'`)
- [ ] 7.2 GREEN: en `rpc_create_purchase_operation`, derivar el kind desde `p_payment_method_id` y emitirlo en el payload con `COALESCE(..., 'credit')` para preservar el comportamiento sin forma de pago imputada
- [ ] 7.3 TRIANGULATE: compra con `cash`, compra con `credit`, compra sin forma de pago — tres contrapartidas distintas verificadas en `journal_lines`

## 8. Consumidor contable: `wallet` al ruteo bancario (OQ-B)

- [ ] 8.1 RED: test que verifica que un `SaleConfirmed` con `payment_method='wallet'` acredita/debita `1110 Banco` (falla hoy: cae en `1100 Caja`)
- [ ] 8.2 GREEN: `CREATE OR REPLACE` de `_journal_post_from_event` partiendo de la definición viva de 1.1, agregando `'wallet'` al predicado `v_is_bank` en las **cuatro** ramas (`SaleConfirmed`, `PurchaseCreated`, `PaymentReceived`, `PaymentMade`)
- [ ] 8.3 Verificar en cada rama que el invariante Σdébito = Σcrédito (`ASSERT`, `P0450`) sigue satisfecho
- [ ] 8.4 TRIANGULATE: los 7 `kind` del catálogo, cada uno con su cuenta esperada, en una tabla de casos

## 9. Inmutabilidad de operaciones con cargo o movimiento (D6)

- [ ] 9.1 RED: tests de `rpc_atomic_update_sale_operation` — editar una venta con cargo de cuenta corriente falla con `P0423`; editar una venta con movimiento de caja falla con `P0423`; editar una venta sin ninguno de los dos procede
- [ ] 9.2 GREEN: añadir el guard antes del ciclo REVERSE→DELETE→INSERT, con mensaje que distingue la causa (cargo vs. caja) y sugiere la nota de crédito
- [ ] 9.3 Espejar el guard en `rpc_atomic_update_purchase_operation`
- [ ] 9.4 Verificar que el handler global RFC 7807 mapea `P0423` a HTTP 409 sin plomería nueva (ya lo hace para el bloqueo fiscal de `edicion-preserva-contexto` F2)
- [ ] 9.5 Confirmar contra prod (SOLO SELECT) que el impacto retroactivo es cero: 0 `customer_account_movements` y los 63 `cash_movements` pertenecen todos al POS

## 10. Migración

- [ ] 10.1 Escribir `supabase/migrations/20261001000001_pagos_cableados_restantes.sql` en un solo archivo, idempotente extremo a extremo, en el orden: helper → confirm-core → RPCs de venta → RPC de compra → consumidor → guards de edición → `REVOKE`/`GRANT`
- [ ] 10.2 Usar `DROP FUNCTION IF EXISTS` con la lista de tipos **exacta capturada de prod** para las tres RPCs que cambian de firma (evita `42725`); `CREATE OR REPLACE` para las que conservan firma
- [ ] 10.3 `REVOKE ALL ... FROM PUBLIC` + `REVOKE EXECUTE ... FROM anon` + `GRANT EXECUTE ... TO authenticated` en **cada** función tocada (D9 — gotcha `ALTER DEFAULT PRIVILEGES`, descubierto en CI en #420, #421 y #423)
- [ ] 10.4 Verificar que ningún `RAISE EXCEPTION ... USING ERRCODE` usa un código de 4 caracteres (revienta en runtime en plpgsql — gotcha de #419)
- [ ] 10.5 Aplicar la migración en local y re-correr toda la suite del paso 1.3 comparando contra el baseline

## 11. Backend FastAPI

- [ ] 11.1 RED: tests de `backend/services/sales.py` y `backend/services/purchases.py` para los parámetros nuevos, incluido el tri-estado del opt-in de caja
- [ ] 11.2 GREEN: `cash_session_id` opcional en el schema Pydantic v2 de alta de venta; propagación por routers → services → repositories sin lógica de negocio en el router
- [ ] 11.3 Verificar que el error de dominio (`credit_requires_client`, `cash_optin_*`, `P0423`) llega al cliente como RFC 7807 con el status correcto
- [ ] 11.4 Confirmar coverage ≥87% en CI

## 12. Superficie frontend (regla PO 2026-08-02)

- [ ] 12.1 RED: tests de componente de `sale-form.tsx` — el checkbox de caja aparece sólo con las tres condiciones; el cliente pasa a obligatorio con `kind='credit'`
- [ ] 12.2 GREEN: bloque `credit` en `sale-form.tsx` con cliente obligatorio y saldo actual/proyectado vía `useCustomerAccount` (D8), reutilizando el patrón visual ya establecido en el POS
- [ ] 12.3 GREEN: checkbox "Registrar en caja" en `sale-form.tsx`, con el motivo explícito cuando alguna condición no se cumple (no ocultarlo en silencio)
- [ ] 12.4 Deshabilitar la acción de editar con razón visible en `sale-operations-list.tsx` y `purchase-operations-list.tsx` para operaciones con cargo o movimiento posteado (D6, spec `operation-edit-context`)
- [ ] 12.5 Verificar el texto de apoyo del selector: la superficie declara qué efecto tiene cada `kind` (spec `payment-method`)
- [ ] 12.6 Verificación visual en **desktop y mobile** y en **tema claro y oscuro**, con tokens semánticos del design system

## 13. Regresión y cierre

- [ ] 13.1 Verificar verdes los gates existentes: `test_confirm_core_integrity.sql` (transitivo), `token-contrast-aa.test.ts`, `test_function_acl_gate.sql`, `validate-kpis`
- [ ] 13.2 Verificar sin regresión los changes de la saga: #415 (líneas), #417 (ledger espejo), #419 (catálogo + tri-estado), #421 (POS credit), #423 (acarreo de contexto + inmutabilidad fiscal)
- [ ] 13.3 Verificar que el bloque fiscal C-27 quedó byte a byte idéntico al capturado en 1.1
- [ ] 13.4 Abrir PR (NUNCA commitear a `main` — todo cambio vía PR, incluidos fixes trivales de seguimiento) con la evidencia RED/GREEN del gate y las cifras de prod
- [ ] 13.5 Verificación post-merge en prod (SOLO SELECT): una venta a crédito produce fila en `customer_account_movements` (hoy 0); una compra emite `PurchaseCreated` con kind real (hoy siempre `credit`)
- [ ] 13.6 Registrar en `CHANGES.md` el cierre de OQ-B (parcial), OQ-C, OQ-D y OQ-E (parcial), y dar de alta los changes derivados `asiento-venta-formulario` y `compras-proveedor-cuenta-corriente`
