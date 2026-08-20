> **Strict TDD**: cada grupo con lógica va RED → GREEN → TRIANGULATE → REFACTOR, con la evidencia en la tabla del summary. Los gates SQL se corren en RED **contra la definición viva** antes de escribir la migración.
> **Governance MEDIUM**: se tocan RPCs de dinero y stock ya existentes. El bloque fiscal se copia sin tocar una línea. Prod (`gxdhpxvdjjkmxhdkkwyb`) SOLO lectura.

## 1. Preparación y captura del estado vivo

- [x] 1.1 Re-verificar `MAX(version)` en `supabase_migrations.schema_migrations` de prod y confirmar que la migración de este change es `20261002000001` (valor capturado 2026-08-20: `20261001000001`). — verificado 2026-08-20 vía MCP (SELECT-only): `MAX(version) = 20261001000001`.
- [x] 1.2 Capturar con `pg_get_functiondef` las definiciones vivas de las funciones a tocar y guardarlas como referencia de trabajo y de rollback. — capturadas las 8 funciones reales (`rpc_update_payment_method` **no existe en prod**: `pg_get_functiondef` vacío — ver nota de 3.4/D7 más abajo).
- [x] 1.3 Capturar la lista **exacta** de tipos de argumento de cada firma a dropear. — capturada vía `pg_get_function_identity_arguments`; usada literal en cada `DROP FUNCTION IF EXISTS` de la migración.
- [x] 1.4 Confirmar en prod, read-only, el estado base. — confirmado: `bank_movements=0`, columna `bank_account_id` inexistente, 6 `bank_accounts` activas en 1 sola cuenta, 0 sesiones de conciliación.

## 2. Gates en RED (antes de la migración)

- [x] 2.1 Extender `supabase/tests/test_confirm_core_integrity.sql` con el eslabón nuevo (D10). Corrido **RED** contra la DB local (misma definición que prod, `MAX(version)=20261001000001`) antes de aplicar la migración — falló en la sección (5) exactamente como se esperaba (`_c29_confirm_order_core` no llama a `_pay_register_operation_bank_movement`). Evidencia en el PR.
- [x] 2.2 Agregado el conteo de firmas en `supabase/tests/test_pos_rpc_signatures.sql` (extendido, no un archivo nuevo — mismo gate que ya cubría `rpc_quick_sale`/`rpc_confirm_sales_order`/`_c29_confirm_order_core`) para las 3 RPCs restantes con parámetro nuevo.
- [x] 2.3 Verificado: `test_function_acl_gate.sql` es genérico (escanea todo `pg_proc` `SECURITY DEFINER` de `public`) — cubre las funciones nuevas sin cambios. Corrido en GREEN post-migración.

## 3. Migración — catálogo y helpers

- [x] 3.1 `ALTER TABLE payment_methods ADD COLUMN IF NOT EXISTS bank_account_id` + índice parcial — hecho, idempotente (verificado con reapply local).
- [x] 3.2 `_pay_resolve_bank_account` — hecho tal cual D2.
- [x] 3.3 `_pay_register_operation_bank_movement` — hecho tal cual D5.
- [x] 3.4 **Desviación documentada del texto literal**: `rpc_update_payment_method` **no existe en prod** (verificado 1.2) — el catálogo `payment_methods` sigue el patrón establecido "sin RPC `SECURITY DEFINER` — este catálogo no maneja dinero" (`PaymentMethodRepository`, mismo criterio que `CostCenterRepository`, desde `metodos-pago-operaciones`). El contrato tri-estado de D7 y la validación de pertenencia/activa/no-borrada se implementan en Python (`PaymentMethodRepository.update` + `payment_methods` service), no en una RPC nueva que rompería ese patrón — ver grupo 8.

## 4. Migración — camino del mostrador

- [x] 4.1 `DROP`+`CREATE` de `_c29_confirm_order_core` con `p_bank_account_id` trailing — helper llamado después de caja/cuenta-corriente, antes del bloque fiscal.
- [x] 4.2 Verificado: bloques fiscal/caja/cuenta-corriente/outbox/status-history byte a byte iguales a la definición viva (diff mental línea por línea al armar la migración + gate de integridad transitivo en GREEN).
- [x] 4.3 `DROP`+`CREATE`+re-`GRANT` de `rpc_quick_sale` y `rpc_confirm_sales_order` con passthrough.

## 5. Migración — camino de los formularios

- [x] 5.1 `DROP`+`CREATE`+re-`GRANT` de `rpc_create_sale_operation` y `rpc_create_sale_operation_v2` (ambas ramas del strangler, incl. la legacy con flag off).
- [x] 5.2 `DROP`+`CREATE`+re-`GRANT` de `rpc_create_purchase_operation`.
- [x] 5.3 Verificado: el `kind` usado es siempre `v_kind` derivado del catálogo (nunca el texto crudo), y `COALESCE(v_kind, 'credit')` del payload de `PurchaseCreated` (#425 D7) queda intacto — el `bank_movement` de compra usa `v_kind` **crudo** (no el `COALESCE`), a propósito: sin `payment_method_id` imputado no debe escribir movimiento.

## 6. Migración — inmutabilidad de la edición

- [x] 6.1 `CREATE OR REPLACE rpc_atomic_update_sale_operation` con el tercer `EXISTS` sobre `bank_movements` (doble referencia `sales.operation_id` ∪ `sales_orders.id`, `source_doc_type='sale'`).
- [x] 6.2 `CREATE OR REPLACE rpc_atomic_update_purchase_operation` con el `EXISTS` equivalente (`source_doc_type='purchase'`).
- [x] 6.3 Verificado: los guards nuevos corren en el mismo punto que los guards existentes de caja/cuenta-corriente, antes del ciclo REVERSE→DELETE→INSERT.

## 7. Migración — cierre y gates en GREEN

- [x] 7.1 `REVOKE ALL`+`REVOKE anon`+`GRANT authenticated` en cada RPC recreada (incluidas las dos `CREATE OR REPLACE` de edición, por uniformidad defensiva con el patrón del proyecto).
- [x] 7.2 DO-block de gate embebido al final de la migración (§STEP 12): conteo de firmas, existencia de columna, integridad transitiva — corre siempre, sin mutar, sin necesitar datos reales.
- [x] 7.3 Comentario de cabecera con propósito/D1-D8/rollback. Idempotencia verificada: reapply local completo sin errores (`DROP FUNCTION IF EXISTS` de la firma vieja → "does not exist, skipping"; `ADD COLUMN IF EXISTS`/`CREATE INDEX IF NOT EXISTS` no-op).
- [x] 7.4 Gates 2.1–2.3 confirmados en **GREEN** post-migración (local, DB idéntica a prod). Evidencia RED→GREEN completa en la tabla TDD del PR.

## 8. Backend Python

- [ ] 8.1 RED: tests de `payment_methods` para `bank_account_id` en create/update/out y el tri-estado por `model_fields_set` (asignar, conservar, desasignar).
- [ ] 8.2 GREEN: `backend/schemas/payment_methods.py`, `payment_method_repository.py`, service y router.
- [ ] 8.3 RED: tests de ventas (`sales`, `sales_orders`) y compras para `bank_account_id` opcional en el payload y su passthrough hasta la RPC.
- [ ] 8.4 GREEN: schemas, repositories, services y routers de `sales`, `sales_orders` y `purchases`.
- [ ] 8.5 RED→GREEN: predicado `editable` de `sales_repository.py` y `purchase_repository.py` extendido con el `EXISTS` sobre `bank_movements` (espejo exacto del guard SQL de 6.1/6.2).
- [ ] 8.6 TRIANGULATE: caso sin cuenta resuelta (no escribe), caso con override, caso `P0412` (cuenta ajena/inactiva), caso `P0400` (cuenta sobre `kind` no bancario), caso `P0424` (período conciliado) — y su mapeo RFC 7807 (`P0424` → 409, agregado a `backend/core/errors.py`).
- [ ] 8.7 Coverage de backend ≥ el umbral vigente de CI (87%).

## 9. Frontend

- [ ] 9.1 RED: tests de `use-payment-methods` para el destino bancario (lectura y mutación tri-estado).
- [ ] 9.2 GREEN: `frontend/hooks/data/use-payment-methods.ts` (`bankAccountId` en el tipo de dominio y en el mapper) y `use-sales-orders.ts` (`bankAccountId` en el payload de cobro).
- [ ] 9.3 `PaymentMethodManager.tsx`: columna "Cuenta bancaria" con asignación/desasignación, rótulo explícito del estado sin destino, reutilizando `useBankAccounts` (sin duplicar fetch).
- [ ] 9.4 POS (`ventas/pos/page.tsx`): indicador del destino resuelto cuando el `kind` es bancario y hay cuentas cargadas, `Sheet` de override con botones ≥44px, y **cero render** cuando la organización no tiene cuentas bancarias. Nunca bloquea el cobro.
- [ ] 9.5 `PaymentMethodSelect.tsx` y formularios de venta y compra: selector de cuenta contiguo, condicionado al `kind` bancario, con texto de apoyo que nombra el efecto.
- [ ] 9.6 Superficie de edición: deshabilitar la acción de editar con la razón visible cuando la operación tiene movimiento bancario posteado (consume el `editable` de 8.5).
- [ ] 9.7 Verificación visual en desktop **y** mobile, en tema claro **y** oscuro, con tokens semánticos del design system.

## 10. Verificación de comportamiento y regresiones

- [ ] 10.1 Venta POS por transferencia con destino configurado → 1 `bank_movement` `+total`, `transfer_in`, `unreconciled`, `balance_after` correcto (era RED antes del change: hoy escribe 0 filas).
- [ ] 10.2 Default por método respetado; override de la operación gana sobre el default; sin destino no se escribe nada y la venta se comporta como antes.
- [ ] 10.3 Compra por transferencia → 1 `bank_movement` `−total`, `transfer_out`. Venta con tarjeta → `card_settlement` por el bruto.
- [ ] 10.4 Venta `credit` + cobro posterior por transferencia → exactamente **un** movimiento (el del cobro), sin doble contabilización.
- [ ] 10.5 Contrato con la conciliación: importar una línea de extracto que iguale el movimiento de la venta y verificar que la sugerencia 1:1 lo propone y el match lo deja `matched`; y el N:1 de tarjeta con el `fee` manual cerrando contra el neto.
- [ ] 10.6 Edición bloqueada con `P0423` (venta y compra) cuando hay movimiento posteado; editable cuando no lo hay.
- [ ] 10.7 `P0424` sobre una sesión cerrada; y el POS incapaz de dispararlo.
- [ ] 10.8 Regresiones verdes: #415 (líneas), #417 (espejo de stock), #419 (imputación), #421 (POS + cuenta corriente), #423 (edición), #425 (helper de cargo + opt-in de caja), bloque fiscal (C-27) y arqueo (C-28).

## 11. Cierre

- [ ] 11.1 PR con checks verdes (validate-kpis, vitest, pytest ≥87%, Playwright, Vercel) → merge → deploy y migración automáticos.
- [ ] 11.2 Verificación post-deploy **read-only** vía MCP: configurar el destino en la cuenta que tiene bancos, registrar una venta de prueba y confirmar la fila en `bank_movements` con su `balance_after` y `unreconciled`.
- [ ] 11.3 Documentar el procedimiento de conciliación de tarjeta (bruto + `fee` manual → match N:1) en la superficie de `/finanzas/conciliacion`.
- [ ] 11.4 Actualizar `CHANGES.md` y registrar en engram las decisiones (D1 inmediato-vs-esperado, D2 regla de resolución, D9 UX) y las OQ-1..4 abiertas para el PO.
