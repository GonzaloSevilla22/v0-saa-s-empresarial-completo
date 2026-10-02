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

- **El alta persiste la sucursal resuelta.** `rpc_create_sale_operation_v2` y la rama legacy de `rpc_create_sale_operation` guardan en `sales.branch_id` y en `stock_movements.branch_id` **la misma** sucursal contra la que validan y descuentan el stock, la caja y el banco: la elegida o, si no hay, la principal. Son seis `INSERT` en total. Si la cuenta no tiene ninguna sucursal, el alta falla con `P0422 no_branch_found` antes de escribir nada, igual que el POS (`rpc_quick_sale`) y "Facturar venta manual". Firma, `COMMENT` y ACLs sin cambios.
- **La edición tampoco deja ventas sin sucursal.** En `rpc_atomic_update_sale_operation`, una sucursal informada como `NULL` o una sucursal vigente `NULL` (fila histórica que haya quedado sin asignar) se resuelve a la principal antes de la reversa. **BREAKING (contrato de edición)**: para la venta desaparece la intención "desimputar la sucursal" del contrato tri-estado; para la compra no cambia nada.
- **Las ventas históricas sin sucursal pasan a la principal.** Migración de datos aparte, idempotente y que informa sus propios conteos. Cada venta histórica sin sucursal toma:
  - la sucursal de su orden de venta, si fue facturada con "Facturar venta manual";
  - si no, la sucursal de las otras filas de su misma operación, cuando esa operación ya tiene una sola;
  - si no, la principal vigente.

  Los movimientos de stock de esas ventas toman la misma sucursal. No se toca ningún movimiento de caja, de banco, de cuenta corriente ni asiento contable.
- **Formulario de venta.** El selector de sucursal deja de ofrecer "Sin sucursal (general)". Abre con la sucursal principal ya elegida, marcada "(principal)", con un rótulo "Sucursal". Compras y gastos, que comparten `BranchSelect`, no cambian.
- **Una sola definición de "la principal" en el cliente.** Nace `lib/default-branch.ts`, espejo exacto de `c26_default_branch`: la primera sucursal activa **y operativa** por antigüedad. La consumen el selector, `useCashOptin` y `useDefaultBranchNotice`. Esos dos hooks hoy toman `branches[0]` aunque esa sucursal esté **cerrada**, mientras el servidor la saltea; el desfasaje se corrige de paso.
- **Error traducido.** `no_branch_found` se traduce en `lib/operation-errors.ts`; hoy sólo el POS lo traduce.
- **Backend sin cambio de lógica.** FastAPI ya transporta `branch_id: null` y la resolución vive en la RPC. Sólo se corrigen los comentarios que afirman que "`None` conserva `branch_id` NULL".
- **Gates.**
  - Nace `supabase/tests/test_ventas_sucursal_por_defecto.sql`. Ejecuta las tres RPCs y la migración de datos dos veces.
  - Los bloques 2 y 6 de `test_ventas_formulario_sucursal.sql` cambian **a propósito**: hoy fijan el contrato "sin sucursal → NULL", que este change reemplaza.
  - Las dos migraciones se suman al final de la cadena de reaplicación de `KPI_Validation.yml`.

Fuera de alcance:

- compras (siguen guardando `NULL` si no se elige);
- la edición de gastos (`rpc_update_expense` todavía admite desimputar);
- una restricción `NOT NULL` sobre `sales.branch_id`;
- el gate de stock global de la edición (candidato (d) de #606);
- una sucursal principal configurable.

Todos quedan como candidatos u Open Questions del design.

## Capabilities

### New Capabilities

Ninguna.

### Modified Capabilities

- `branches`:
  - La venta deja de tener asociación opcional a una sucursal: toda venta nueva o editada queda en una sucursal (la elegida o la principal), y las históricas sin sucursal se asignan.
  - El selector de la venta reemplaza "Sin sucursal (general)" por la principal preseleccionada.
  - "La principal" del cliente pasa a ser la misma que la del servidor: excluye las sucursales cerradas, y eso alcanza también al aviso de cambio de sucursal por defecto.
  - La asociación sigue siendo opcional para compras y movimientos de stock de compras.
- `branch-stock`:
  - La venta sin sucursal elegida valida y descuenta el stock de la principal, y lo deja registrado en la fila y en el movimiento. Se reescribe el escenario "Venta sin sucursal elegida".
  - De paso se corrige un desfasaje de la spec: hoy dice "gate global (`SUM`)" para el alta, pero el alta compara contra la sucursal efectiva. Es el candidato (f) de #606.
- `operation-edit-context`: en el contrato tri-estado de sucursal, informar `NULL` al editar una **venta** asigna la principal en vez de desimputar. La compra conserva las tres intenciones.

## Impact

- **Base de datos**:
  - `supabase/migrations/20261069000001_ventas_sucursal_por_defecto.sql`: reescribe `rpc_create_sale_operation_v2`, `rpc_create_sale_operation` (wrapper con rama legacy) y `rpc_atomic_update_sale_operation` desde su `pg_get_functiondef` **vivo de producción**. Sin cambio de firma (sin `DROP`, sin riesgo de overload `42725`). Se conservan `COMMENT` y ACLs.
  - `supabase/migrations/20261069000002_ventas_sucursal_por_defecto_backfill.sql`: datos solamente.
  - Las dos numeraciones quedan reservadas después de las de `presupuestos-modulo` (`20261067000001`/`20261068000001`), que no toca ninguna de estas funciones.
- **Frontend**:
  - `frontend/lib/default-branch.ts` (nuevo);
  - `frontend/components/branches/BranchSelect.tsx` (prop opt-in, sin cambio para compras y gastos);
  - `frontend/components/forms/sale-form.tsx`;
  - `frontend/hooks/use-cash-optin.ts`;
  - `frontend/hooks/use-default-branch-notice.ts`;
  - `frontend/lib/operation-errors.ts`;
  - comentarios de `frontend/hooks/data/use-sales.ts`;
  - tests de cada uno.
- **Backend**: `backend/schemas/sales.py` y `backend/services/sales.py`, sólo comentarios y descripción del campo.
- **Gates y CI**:
  - gate nuevo `test_ventas_sucursal_por_defecto.sql`;
  - bloques 2 y 6 de `test_ventas_formulario_sucursal.sql`;
  - reaplicación en `KPI_Validation.yml`.
  - Hay que volver a correr los gates que fijan cuerpo, firma o ACL de estas funciones: `test_confirm_core_integrity`, `test_cuenta_corriente_party_guard`, `test_operacion_party_guard`, `test_pos_rpc_signatures`, `test_cobranzas_vencimientos_schema`, `test_function_acl_gate` y el resto de los 23 que las llaman.
- **Lectores (cambio de un día para otro, sin tocar su código)**:
  - El tramo "Sin sucursal" de `rpc_sales_breakdown` y de `rpc_branch_report` deja de recibir ventas. Sólo conserva el residuo que la migración no pueda asignar.
  - El Tablero y las estadísticas filtrados por la principal pasan a sumar las ventas que antes quedaban afuera.
  - El "stock sin rotación" filtrado por una sucursal que **no** es la principal deja de contar como rotación las ventas históricas que hoy son `NULL` (fail-open de `kpi-branch-consistency` D4).
  - El export de `generate-export` muestra el nombre real de la sucursal en vez de "Principal".
- **Governance**: MEDIA con tramo **ALTO**. Reescribe las funciones que mueven stock, caja y banco, y modifica en masa una columna de `sales` en producción. Nada se aplica sin el checkpoint del cuerpo vivo de producción, y el PO mergea la migración de datos.
- **Superficie frontend**: sí. El formulario de venta (`/ventas`, modal "Nueva venta" y edición) se verifica en escritorio y móvil, con tema claro y oscuro.
