# Tasks — delete-guard-ledgers

> Governance **MEDIO-ALTO** (dinero en cuatro libros). Strict TDD activo: cada grupo con escritura arranca por su test en rojo.
> Cánones: reutilización agresiva (todos los helpers existen — este change los cablea), día ART, `COALESCE`, migración idempotente.
> MAX(version) prod verificado: **`20261004000002`**. Toda migración nueva usa timestamp posterior.

## 1. Baseline e integridad de funciones

- [x] 1.1 Capturar en `openspec/changes/delete-guard-ledgers/baseline/` el `pg_get_functiondef` **vivo en prod** de: `_journal_post_from_event`, `_pay_register_party_charge`, `c30_register_customer_account_movement`, `c28_register_cash_movement`, `_register_bank_movement`, `_pay_register_operation_bank_movement`, `rpc_reverse_stock_movement`.
- [x] 1.2 Confirmar `MAX(version)` en prod inmediatamente antes de fijar el timestamp de la migración; si avanzó respecto de `20261004000002`, recalcular.
- [x] 1.3 Registrar en `design.md` (§D7) el hash o la marca de la versión base de `_journal_post_from_event` usada para la reescritura.
- [x] 1.4 **Censo de códigos de error** — re-correr en prod el barrido `P04xx` sobre `pg_get_functiondef` de todo `public` **y** sobre `backend/core/errors.py` inmediatamente antes de fijar los códigos. `P0424` está **ocupado** (conciliación bancaria cerrada, `pos-banco-movimientos` D4); este change usa `P0425` y `P0426`. Si alguno dejó de estar libre, recorrer al siguiente y actualizar specs + `errors.py` + toasts en el mismo commit.

## 2. Gate de preservación del consumidor contable (RED primero)

- [x] 2.1 **RED** — `supabase/tests/test_delete_guard_ledgers.sql`: test que ejercita las 7 ramas preexistentes de `_journal_post_from_event` (`SaleConfirmed` con y sin desglose fiscal, `PurchaseCreated`, `SaleOperationCreated`, `SaleOperationAdjusted`, `PaymentReceived`, `PaymentMade`, `CreditNoteIssued`) y verifica su resultado observable. Debe pasar **contra la función actual** antes de tocarla — es la red de seguridad, no un test del cambio.
- [x] 2.2 Capturar el baseline de conteos: asientos por `source_doc_type` y `status`, para comparar después de la migración.
- [x] 2.3 Verificar que el bloque fiscal de `SaleConfirmed` (lookup `sales_orders` → `fiscal_documents`, desglose 4100/4200) queda declarado intocable en el test.

## 3. Vocabulario de tipos — CHECK de `cash_movements`

- [x] 3.1 **RED** — test que inserta un `cash_movements` de tipo `sale_reversal` y falla por el CHECK actual.
- [x] 3.2 **GREEN** — migración idempotente que amplía `cash_movements_movement_type_check` con `sale_reversal` (`DROP CONSTRAINT IF EXISTS` + `ADD CONSTRAINT`), preservando los 5 tipos existentes.
- [x] 3.3 **TRIANGULATE** — verificar que los 5 tipos previos siguen aceptados y que un tipo inventado sigue rechazado.
- [x] 3.4 Confirmar que **no** hace falta tocar los CHECK de `customer_account_movements` (`credit_note` ya existe), `bank_movements` (`transfer_out` ya existe) ni `sales_orders` (`canceled` ya existe).

## 4. Helper de reversión de cargo de tercero

- [x] 4.1 **RED** — test pgTAP: revertir un cargo de cliente deja el saldo en el valor previo; revertir un cargo de proveedor hace lo propio.
- [x] 4.2 **GREEN** — helper de reversión espejo de `_pay_register_party_charge`, despachando por `party_kind` (`customer` → movimiento `credit_note` negativo; `supplier` → equivalente), emitiendo el evento de reversión correspondiente. `SECURITY DEFINER` + `SET search_path`.
- [x] 4.3 **TRIANGULATE** — `party_kind` inválido falla con `P0400`; reversión sobre cuenta inexistente falla con `P0404`.
- [x] 4.4 **TRIANGULATE** — reversión que dejaría el saldo negativo falla con `P0425` (no con el `P0409` genérico del helper C-30), con mensaje que nombre la devolución del pago.
- [x] 4.5 Verificar que `created_by` del movimiento de reversión queda atribuido al usuario de la sesión (`auth.uid()` bajo el pool JWT-passthrough).

## 5. Ramas contables de borrado

- [x] 5.1 **RED** — test: un evento `SaleOperationDeleted` de una operación con asiento `SaleOperation` posteado produce contra-asiento con lados invertidos, `reversal_of` apuntando al original, original en `reversed`, y **ningún** asiento nuevo de reemplazo.
- [x] 5.2 **GREEN** — rama `SaleOperationDeleted` en `_journal_post_from_event`, reescrita **desde el baseline vivo** (task 1.1). La contra-entry lleva su `source_event_id` (es la única entry del evento — ventaja sobre `SaleOperationAdjusted`, §D7).
- [x] 5.3 **TRIANGULATE** — venta del POS: el asiento original es de tipo `SalesOrder`; la rama lo resuelve por la segunda convención y revierte igual.
- [x] 5.4 **TRIANGULATE** — sin asiento `posted` para ninguna convención → `P0451`, evento pendiente, lote no aborta.
- [x] 5.5 **TRIANGULATE** — reproceso del mismo evento no postea un segundo contra-asiento (idempotencia por `operation_idempotency`).
- [x] 5.6 **GREEN** — rama `PurchaseDeleted`, mismo molde, preservando `cost_center_id` por línea en la reversión.
- [x] 5.7 **TRIANGULATE** — contra-asiento desbalanceado → `P0450`.
- [x] 5.8 **REFACTOR** — extraer la localización del asiento vigente por doble convención a un helper si las dos ramas la duplican (Regla de Tres: sólo si aparece una tercera vez, si no dejar explícito).
- [x] 5.9 Re-correr el gate de la task 2.1: las 7 ramas preexistentes siguen dando idéntico resultado.

## 6. RPC atómica de borrado de venta

- [x] 6.1 **RED** — **test estrella**: crear una venta `credit` → borrarla → el saldo del cliente vuelve **exacto** al previo, el kardex se repone, caja y banco quedan compensados, y existe el contra-asiento.
- [x] 6.2 **GREEN** — `rpc_delete_sale_operation`, `SECURITY DEFINER` + `SET search_path`, en este orden: resolver `(operation_id, sales_order_id)` → guard fiscal → guards de saldo y de caja → compensar cuenta corriente, caja, banco → reversa de stock (`rpc_reverse_stock_movement`, sin cambios) → emitir `SaleOperationDeleted` → cancelar la `sales_order` → `DELETE` → limpiar `operation_idempotency`.
- [x] 6.3 **TRIANGULATE** — venta con comprobante `authorized` → `P0423`, nada se toca. Ídem `pending_cae`.
- [x] 6.4 **TRIANGULATE** — venta a crédito ya cobrada → `P0425`, saldo intacto.
- [x] 6.5 **TRIANGULATE** — venta con caja cuya sesión original **cerró** y hay sesión abierta → contra-movimiento en la abierta, sesión cerrada intacta.
- [x] 6.6 **TRIANGULATE** — venta con caja y **sin** sesión abierta → `P0426`.
- [x] 6.7 **TRIANGULATE** — venta del POS → la `sales_order` queda `canceled`, con la transición registrada en el historial.
- [x] 6.8 **TRIANGULATE** — venta con movimiento bancario ya conciliado → espejo `unreconciled` posteado, original conserva su conciliación.
- [x] 6.9 **TRIANGULATE** — venta sin dinero posteado (sólo stock) → se borra como hoy, sin movimientos financieros nuevos.
- [x] 6.10 **TRIANGULATE** — atomicidad: forzar el fallo de una pata de compensación y verificar que la venta sigue existiendo y ningún libro quedó tocado.
- [x] 6.11 Firma nueva ⇒ `DROP FUNCTION IF EXISTS` + `CREATE` + `GRANT EXECUTE` explícito a `anon` y `authenticated` **en el mismo archivo** de migración.

## 7. RPC atómica de borrado de compra

- [x] 7.1 **RED** — crear una compra a crédito de proveedor → borrarla → saldo del proveedor vuelve exacto, kardex repuesto, contra-asiento presente.
- [x] 7.2 **GREEN** — `rpc_delete_purchase_operation`, mismo molde que 6.2 sin la pata fiscal ni la de `sales_order`.
- [x] 7.3 **TRIANGULATE** — compra ya pagada al proveedor → `P0425`.
- [x] 7.4 **TRIANGULATE** — compra con movimiento bancario → espejo invertido.
- [x] 7.5 **TRIANGULATE** — compra sin dinero posteado → se borra como hoy.
- [x] 7.6 Mismo tratamiento de firma/GRANT que 6.11.

## 8. Backend Python — caller fino

- [x] 8.1 **Safety net** — correr `backend/tests/test_sales.py`, `test_purchases.py`, `test_c21_checkpoint2_single_write.py`, `test_sale_items.py` y registrar el baseline de tests en verde. Cualquier rojo previo se reporta, no se arregla.
- [x] 8.2 **RED** — test: `delete_by_id` llama la RPC nueva exactamente una vez con `(sale_id, operation_id, reason)` y no emite la secuencia anterior.
- [x] 8.3 **GREEN** — `SalesRepository.delete_by_id` y `delete_by_operation` a llamada única. Ídem `PurchaseRepository`.
- [x] 8.4 **TRIANGULATE** — operación inexistente sigue devolviendo `False` → 404 en el servicio, sin llamar compensaciones.
- [x] 8.5 **RED/GREEN** — `backend/core/errors.py` mapea `P0425` y `P0426` a respuestas RFC 7807 con mensaje accionable; `P0423` reusa el mapeo existente. Test en `test_errors_business_codes.py`.
- [x] 8.6 **TRIANGULATE** — `require_role` sigue rechazando roles sin permiso antes de tocar la RPC.
- [x] 8.7 Verificar cobertura pytest ≥ umbral de CI (87%).

## 9. Superficie frontend

- [x] 9.1 **RED** — test de componente: una operación no borrable renderiza el control de borrado deshabilitado con su razón visible.
- [x] 9.2 **GREEN** — exponer el estado de borrabilidad en el listado, **derivado de lectura** (nunca columna denormalizada), reusando el `so`/`fd` ya montado en `list_paginated_by_operation`; extender `SaleOperation`/`PurchaseOperation` en `frontend/lib/group-operations.ts`.
- [x] 9.3 **GREEN** — reemplazar el `confirm()` nativo de `sale-operations-list.tsx` por un `AlertDialog` del design system que enumere las compensaciones concretas antes de confirmar.
- [x] 9.4 **GREEN** — mismo diálogo en `purchase-operations-list.tsx`.
- [x] 9.5 **TRIANGULATE** — operación sin dinero posteado: el diálogo confirma sin enumerar compensaciones.
- [x] 9.6 Toast de error legible para `P0423`, `P0425` y `P0426`, cada uno nombrando la acción que destraba.
- [x] 9.7 Verificación visual en **escritorio y móvil**, **tema claro y oscuro**, con tokens semánticos del design system.

## 10. Grupo de reparación histórica (GATEADO — requiere OQ-4 resuelta)

- [x] 10.1 Re-medir en prod los conteos de `design.md` §Auditoría inmediatamente antes de correr; si no coinciden, **abortar sin escribir**.
- [x] 10.2 Migración de reparación separada, idempotente, cada paso gateado por su conteo verificado.
- [x] 10.3 Caja: compensar los **2** movimientos huérfanos ($8.000) en su sesión (abierta), escribiendo **directo** con `created_by` heredado del movimiento original — los helpers no sirven acá (`auth.uid()` es NULL en migración, §D9).
- [x] 10.4 Contable: revertir los **10** asientos huérfanos (3 `SaleOperation` + 3 `SalesOrder` + 4 `Purchase`) con contra-asiento y `status='reversed'`, `posted_at` de hoy (§OQ-5).
- [x] 10.5 Órdenes: cancelar las **3** `sales_orders` colgadas.
- [x] 10.6 Excluir explícitamente el par fantasma+ajuste de cuenta corriente ya compensado a mano, con el filtro documentado.
- [x] 10.7 Banco: verificar que sigue sin huérfanos reales (el `transfer_in`/`payment_received` es un cobro de cliente, falso positivo) — **no escribir nada**.
- [x] 10.8 Post-condición: re-correr las seis consultas de auditoría y dejar los conteos en el PR.

## 11. Flujo completo y cierre

- [x] 11.1 **Test del flujo real de ayer**: crear venta a crédito → intentar editarla (recibe `P0423`) → borrarla → recrearla corregida → los cuatro libros reflejan **sólo** la operación recreada, sin remanentes.
- [x] 11.2 Verificar que los gates transitivos de CI quedan verdes: `validate-kpis`, vitest, pytest (≥87%), Playwright E2E, `test_function_acl_gate.sql`.
- [x] 11.3 Verificar ACLs de las funciones nuevas y de `_journal_post_from_event` tras el `DROP+CREATE` (gotcha de 5 antecedentes).
- [x] 11.4 Actualizar `CHANGES.md` con el estado del change y el próximo recomendado.
- [x] 11.5 Registrar en el PR los conteos de huérfanos antes/después y las OQ resueltas por el PO.
