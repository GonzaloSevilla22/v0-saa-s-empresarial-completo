## Why

El PO decidió el 2026-10-01, textual: *«sí, que las ventas sin sucursal queden con la principal»*. La decisión cierra el candidato (a) que dejó el fix `ventas-formulario-sucursal` (PR #606, `e0a87bd3`).

Hoy una venta registrada **sin sucursal elegida** se guarda con `sales.branch_id = NULL`. Pasa en tres casos: la cuenta no tiene el módulo de sucursales, el usuario deja la opción "Sin sucursal (general)", o se llama a `POST /sales` sin el campo. Pero esa venta **no ocurrió en ningún lado**: la RPC de alta resuelve `v_gate_branch := COALESCE(p_branch_id, c26_default_branch(cuenta))` y descuenta el stock, valida la sesión de caja y registra el movimiento bancario contra **la sucursal principal**. Sólo la fila de la venta y su movimiento de stock guardan el `p_branch_id` crudo, o sea `NULL`. El sistema mueve mercadería y plata en la principal y anota que la venta "no tiene sucursal".

Consecuencias visibles hoy:

- El Tablero, las estadísticas y los reportes filtrados por sucursal **no ven esas ventas**.
- "Sin sucursal" es un tramo propio que crece con cada venta.
- Las cuentas sin el módulo de sucursales tienen el 100 % de sus ventas sin sucursal.
- En agosto el 75 % de las filas de `sales` estaba en ese estado: 436 de 581, medido en producción el 2026-08-11 (`kpi-branch-consistency`, design L25).

Además contradice la regla del modelo: **RN-93** y **DEC-19** dicen que toda venta, compra, gasto y movimiento de caja lleva `branch_id`, con "Casa Central" como sucursal de la cuenta de un solo local. El gasto ya la cumple desde `gastos-forma-pago` (D6, `rpc_create_expense` persiste el `COALESCE`). La venta es el documento de más volumen y todavía no la cumple.

## What Changes

- **El alta persiste la sucursal resuelta.** `rpc_create_sale_operation_v2` y la rama legacy de `rpc_create_sale_operation` guardan en `sales.branch_id` y en `stock_movements.branch_id` **la misma** sucursal contra la que validan y descuentan el stock, la caja y el banco: la elegida o, si no hay, la principal. Son seis `INSERT` en total. Si no se eligió sucursal y la cuenta no tiene ninguna sucursal **operativa** a la cual resolver (ninguna sucursal, o todas inactivas o cerradas), el alta falla con `P0422 no_branch_found` antes de escribir nada, igual que el POS (`rpc_quick_sale`) y "Facturar venta manual". Firma, `COMMENT` y ACLs sin cambios. La migración abre con un *preflight* que aborta si el cuerpo vivo no es el verificado (molde de `20261062000001`).
- **La edición tampoco deja ventas sin sucursal.** En `rpc_atomic_update_sale_operation`, una sucursal informada como `NULL` o una sucursal vigente `NULL` (fila histórica que haya quedado sin asignar) se resuelve a la principal antes de la reversa. **BREAKING (contrato de edición, OQ-7)**: para la venta desaparece la intención "desimputar la sucursal" del contrato tri-estado, y deja de preservarse un `branch_id` vigente nulo; para la compra y el gasto no cambia nada.
- **Las ventas históricas sin sucursal pasan a la principal**, salvo que su operación ya tenga asentada otra sucursal operativa. Migración de datos aparte, idempotente y que informa sus propios conteos. Se resuelve por operación; gana la primera regla que dé una sucursal **operativa**:
  - la sucursal de las otras filas de su misma operación, cuando esa operación ya tiene una sola;
  - si no, la sucursal que ya registró su movimiento de stock (una edición o el arreglo del 2026-08-19);
  - si no, la sucursal de su orden de venta, si fue facturada con "Facturar venta manual";
  - si no, la principal vigente.

  Si el PO acepta una excepción única y auditada a RN-21 (el historial de stock es de sólo inserción), los movimientos de stock **sin sucursal** de esas ventas toman la misma sucursal. Los que ya tienen una no se tocan, y las discrepancias se informan. No se toca ningún movimiento de caja, de banco, de cuenta corriente ni asiento contable. **Las reglas, la excepción a RN-21 y la precedencia movimiento/orden (OQ-4, OQ-5 y OQ-6) bloquean la escritura de esta migración** hasta el OK del PO.
- **Formulario de venta.** El selector de sucursal deja de ofrecer "Sin sucursal (general)". Abre con la sucursal principal ya elegida, marcada "(principal)", con un rótulo "Sucursal" que vive dentro del selector (no aparece en las cuentas sin módulo de sucursales). Compras, gastos y el importador de gastos, que comparten `BranchSelect`, conservan su opción sin sucursal. Toda superficie futura que registre una venta con selector (como la conversión de presupuestos de `presupuestos-modulo`) sigue la misma regla.
- **Una sola definición de "la principal" en el cliente.** Nace `lib/default-branch.ts`, espejo exacto de `c26_default_branch`: la primera sucursal activa **y operativa** por antigüedad. La consumen el selector, `useCashOptin` (y con él sus cinco formularios: venta, compra, gasto, cobro y pago de cuenta corriente), `useDefaultBranchNotice` y el POS. Los tres últimos hoy toman `branches[0]` aunque esa sucursal esté **cerrada**, mientras el servidor la saltea: con la más antigua cerrada, el POS manda una sucursal que el servidor rechaza. El desfasaje se corrige de paso. Cambia también el opt-in de caja de cobros y pagos en ese caso (ofrece la sesión de la principal operativa). En la compra, el hook seguirá ofreciendo un opt-in que el servidor rechaza cuando no se elige sucursal (preexistente, va al change hermano).
- **Error traducido.** `no_branch_found` se traduce en `lib/operation-errors.ts`, reutilizando el texto que ya usa "Facturar venta manual". Hoy lo traducen el POS, la promoción, los presupuestos y las órdenes, con cuatro textos distintos, y `lib/operation-errors.ts` lo deja pasar a propósito; ese test cambia a conciencia.
- **Backend sin cambio de lógica.** FastAPI ya transporta `branch_id: null` y la resolución vive en la RPC. Sólo se corrigen los comentarios y la prosa de tests que afirman que "`None` conserva `branch_id` NULL".
- **Gates.**
  - Nace `supabase/tests/test_ventas_sucursal_por_defecto.sql`. Ejecuta las tres RPCs y la migración de datos dos veces.
  - Los bloques 2 y 6 de `test_ventas_formulario_sucursal.sql` cambian **a propósito**: hoy fijan el contrato "sin sucursal → NULL", que este change reemplaza.
  - En `KPI_Validation.yml` se **retira** el bloque de reaplicación de `20261062000001`, como exige la regla escrita en el propio workflow para toda migración que redefina sus funciones, y las dos migraciones nuevas se reaplican después de la reconvergencia.

Fuera de alcance:

- compras (siguen guardando `NULL` si no se elige), incluido su opt-in de caja sin sucursal;
- la edición de gastos (`rpc_update_expense` todavía admite desimputar);
- una restricción `NOT NULL` sobre `sales.branch_id`;
- el gate de stock global de la edición (candidato (d) de #606);
- el stock de la sucursal efectiva en el aviso del formulario (candidato (c) de #606);
- un guard de "última sucursal operativa" al desactivar sucursales;
- una sucursal principal configurable.

Todos quedan como candidatos u Open Questions del design.

## Capabilities

### New Capabilities

Ninguna.

### Modified Capabilities

- `branches`:
  - La venta deja de tener asociación opcional a una sucursal: toda venta nueva o editada queda en una sucursal (la elegida o la principal), y las históricas sin sucursal se asignan a una sucursal operativa.
  - El selector de la venta reemplaza "Sin sucursal (general)" por la principal preseleccionada.
  - "La principal" del cliente pasa a ser la misma que la del servidor: excluye las sucursales cerradas, y eso alcanza al aviso de cambio de sucursal por defecto, al opt-in de caja y al POS.
  - La asociación sigue siendo opcional para compras, gastos (cuya alta ya resuelve la principal) y movimientos de stock de compras.
- `branch-stock`:
  - La venta sin sucursal elegida valida y descuenta el stock de la principal, y lo deja registrado en la fila y en el movimiento. Se reescribe el escenario "Venta sin sucursal elegida".
  - De paso se corrige un desfasaje de la spec: hoy dice "gate global (`SUM`)" para el alta, pero el alta compara contra la sucursal efectiva. Es el candidato (f) de #606.
- `operation-edit-context`: en el contrato tri-estado de sucursal, informar `NULL` al editar una **venta** asigna la principal en vez de desimputar, y el requirement de preservación del contexto deja de preservar una sucursal vigente nula de una venta. La compra y el gasto conservan las tres intenciones.
- `inventory-single-ledger`: se agrega la única excepción auditada al carácter append-only (sujeta a OQ-5): completar la sucursal nula de los movimientos de venta de las ventas asignadas por este change.
- `dashboard-kpi-summary`: el fundamento del fail-open del stock sin rotación se actualiza: sólo alcanza al residuo, y las ventas asignadas cuentan como rotación únicamente en su sucursal.
- `sales-statistics`: el fundamento del tramo "Sin sucursal" («en producción son la mayoría») se actualiza: queda para el residuo.

## Impact

- **Base de datos**:
  - `supabase/migrations/20261069000001_ventas_sucursal_por_defecto.sql`: reescribe `rpc_create_sale_operation_v2`, `rpc_create_sale_operation` (wrapper con rama legacy) y `rpc_atomic_update_sale_operation` desde su `pg_get_functiondef` **vivo de producción**, detrás de un preflight de `md5`. Sin cambio de firma (sin `DROP`, sin riesgo de overload `42725`). Se conservan `COMMENT` y ACLs.
  - `supabase/migrations/20261069000002_ventas_sucursal_por_defecto_backfill.sql`: datos solamente; se escribe recién con el OK del PO sobre OQ-4, OQ-5 y OQ-6.
  - Las dos numeraciones quedan reservadas después de las de `presupuestos-modulo` (`20261067000001`/`20261068000001`), que no toca ninguna de estas funciones.
- **Frontend**:
  - `frontend/lib/default-branch.ts` (nuevo);
  - `frontend/components/branches/BranchSelect.tsx` (prop opt-in, sin cambio para compras y gastos);
  - `frontend/components/forms/sale-form.tsx`;
  - `frontend/hooks/use-cash-optin.ts`, que alcanza a sus cinco consumidores (`sale-form.tsx`, `purchase-form.tsx`, `expense-form-v2.tsx`, `customer-accounts/RegisterPaymentForm.tsx` y `supplier-accounts/RegisterPaymentMadeForm.tsx`);
  - `frontend/hooks/use-default-branch-notice.ts`;
  - `frontend/app/(dashboard)/ventas/pos/page.tsx` (la sucursal activa del POS);
  - `frontend/lib/operation-errors.ts`;
  - comentarios de `frontend/hooks/data/use-sales.ts` y prosa de sus tests;
  - tests de cada uno.
  - Coordinación con `presupuestos-modulo`: los dos tocan `sale-form.tsx`, y su `ConvertQuoteDialog` registra ventas con `BranchSelect`; quien mergee segundo lo ajusta.
- **Backend**: `backend/schemas/sales.py`, `backend/services/sales.py` y la prosa de `backend/tests/test_sales_branch_id.py`, sólo comentarios y descripción del campo.
- **Gates y CI**:
  - gate nuevo `test_ventas_sucursal_por_defecto.sql`;
  - bloques 2 y 6 de `test_ventas_formulario_sucursal.sql`;
  - en `KPI_Validation.yml`, retiro del bloque de reaplicación de `20261062000001` y reaplicación de las dos migraciones nuevas después de la reconvergencia.
  - Hay que volver a correr los gates que fijan cuerpo, firma o ACL de estas funciones: `test_confirm_core_integrity`, `test_cuenta_corriente_party_guard`, `test_operacion_party_guard`, `test_pos_rpc_signatures`, `test_cobranzas_vencimientos_schema`, `test_function_acl_gate` y el resto de los 23 que las llaman.
- **Lectores (cambio de un día para otro, sin tocar su código)**:
  - El tramo "Sin sucursal" de `rpc_sales_breakdown` y de `rpc_branch_report` deja de recibir ventas. Sólo conserva el residuo que la migración no pueda asignar.
  - El Tablero y las estadísticas filtrados por la principal pasan a sumar las ventas que antes quedaban afuera.
  - El "stock sin rotación" filtrado por una sucursal que **no** es la principal deja de contar como rotación las ventas históricas que hoy son `NULL` (fail-open de `kpi-branch-consistency` D4). Eso incluye las ventas anteriores a #606 que el usuario había elegido en esa sucursal y el formulario descartó: quedan en la principal, de donde salió su stock.
  - El export de `generate-export` muestra el nombre real de la sucursal en vez de "Principal".
- **Governance**: MEDIA con tramo **ALTO**. Reescribe las funciones que mueven stock, caja y banco, y modifica en masa una columna de `sales` (y, con OQ-5, de `stock_movements`) en producción. Nada se aplica sin el checkpoint del cuerpo vivo de producción, la migración de datos no se escribe sin el OK del PO sobre sus reglas, y el PO la mergea.
- **Superficie frontend**: sí. El formulario de venta (`/ventas`, modal "Nueva venta" y edición) se verifica en escritorio y móvil, con tema claro y oscuro. El POS y el modal de cobro de cuenta corriente se verifican en el humo con la sucursal más antigua cerrada.
