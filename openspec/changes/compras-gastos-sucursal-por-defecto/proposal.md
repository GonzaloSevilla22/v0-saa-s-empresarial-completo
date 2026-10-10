## Why

Es el change hermano que dejó `ventas-sucursal-por-defecto` (archivado el 2026-10-10). Al firmar ese change, el PO eligió para compras y gastos la opción recomendada de su OQ-3: *un change hermano para el alta y la edición de compras y la edición de gastos, sin tocar las compras viejas*. El 2026-10-10 pidió «arrancá».

Hoy una **compra** registrada sin sucursal elegida se guarda con `purchases.branch_id = NULL`, pero no ocurrió "en ningún lado": su stock **entra en la sucursal principal** (`c21_apply_branch_stock_delta` resuelve `c26_default_branch`). Pasa en tres casos: la cuenta no tiene el módulo de sucursales (3 de los 4 planes), el usuario deja «Sin sucursal (general)», o se llama a `POST /purchases` sin el campo. Consecuencias visibles hoy:

- La fila de la compra, su movimiento de stock y su movimiento bancario quedan en `NULL`, mientras el stock está en la principal. El ledger rompe su propio invariante de reconstrucción por `(producto, sucursal)`.
- **El opt-in de caja de esa compra falla siempre.** El formulario lo ofrece **pre-marcado** con la sesión de la principal, y el servidor compara la sesión contra el `p_branch_id` **crudo** (`NULL`) y rechaza la compra con `P0422 cash_optin_requires_open_session`. Le pasa a toda compra en efectivo de hoy en una cuenta sin módulo de sucursales que tenga la caja abierta, salvo que el usuario destilde la casilla.
- El Tablero y los reportes filtrados por sucursal no ven esas compras. Medido en producción el 2026-10-03 (`remitos-compra`): 106 de 127 operaciones de compra sin sucursal, 12 de las 33 de los últimos 30 días.

El **gasto** ya guarda la principal en el alta desde `gastos-forma-pago` (D6). Pero su **edición** todavía puede dejarlo sin sucursal, y el formulario y el importador de gastos muestran «Sin sucursal (general)» / «Sin sucursal por defecto» aunque el alta guarde la principal: el rótulo miente.

RN-93 y DEC-19 dicen que toda venta, compra, gasto y movimiento de caja lleva `branch_id`. La venta ya la cumple. Este change hace que también la cumplan la compra y el gasto.

## What Changes

- **El alta de compra persiste la sucursal resuelta.** `rpc_create_purchase_operation` resuelve una sola vez `v_gate_branch := COALESCE(p_branch_id, c26_default_branch(cuenta))` y la usa en los seis puntos que hoy usan el `p_branch_id` crudo:
  - los dos `INSERT` en `purchases` (con producto y sin producto);
  - el delta de stock;
  - el `INSERT` en `stock_movements`;
  - la condición de sucursal del opt-in de caja;
  - el movimiento bancario.

  Así se cierra el rechazo silencioso del opt-in de caja. Si no se eligió sucursal y la cuenta no tiene ninguna sucursal **operativa** a la cual resolver, el alta falla con `P0422 no_branch_found` antes de escribir nada: el mismo token que la venta. Antes de este change, la compra entraba el stock en una sucursal inactiva o creaba "Casa Central" al vuelo.
- **Sucursal elegida cerrada (OQ-2).** El alta de compra rechaza con `P0422 branch_closed` una sucursal elegida que está cerrada. Así lo dice ya la spec `branches` («Operaciones solo contra sucursales operativas»), y así lo hacen la venta y el gasto. Hoy la compra sólo mira `is_active`.
- **La edición de compra no deja compras sin sucursal.** En `rpc_atomic_update_purchase_operation`, una sucursal informada como `NULL`, o una sucursal vigente `NULL` (compra histórica), se resuelve a la principal **antes** de la reversa, con el mismo guard `no_branch_found`. **BREAKING (contrato interno de edición)**: para la compra desaparece la intención "desimputar la sucursal" del contrato tri-estado, igual que ya pasó con la venta.
- **La edición de gasto tampoco.** En `rpc_update_expense`, una sucursal `NULL`, informada o vigente, se resuelve con **la misma regla que ya aplica el alta del gasto** (`COALESCE` con la principal). El alta del gasto no cambia (OQ-3). **BREAKING (contrato interno de edición)** para el gasto.
- **Históricos sin backfill (OQ-1, recomendación).** Las compras y los gastos viejos sin sucursal **no** se reasignan en masa, como ya firmó el PO en `caja-compras-cobranzas` y `gastos-forma-pago`. Toman sucursal sólo cuando alguien los edita, por la regla de la edición. Si el PO prefiere verlos bajo el filtro de sucursal, la opción (b) es una migración de datos propia, con reglas y auditoría al estilo de la de ventas, que mergea el PO.
- **Formularios.** Los formularios de compra y de gasto, y el importador de gastos, dejan de ofrecer «Sin sucursal…» y muestran la sucursal principal ya elegida, marcada «(principal)», con su rótulo dentro del selector. Reutilizan lo que dejó `ventas-sucursal-por-defecto`, sin componente nuevo:
  - en compra y gasto, `BranchSelect` con `allowUnassigned={false}` y `label="Sucursal"`;
  - en el importador, `label="Sucursal por defecto"`, a juego con «Forma de pago por defecto» y «Centro de costo por defecto».

  El presupuesto (`QuoteForm`) conserva su opción: no mueve stock ni es una compra.
- **Backend sin cambio de lógica.** FastAPI ya transporta `branch_id: null` y el tri-estado. Sólo cambian los comentarios y la descripción de OpenAPI de los campos `branch_id` de compra y gasto.
- **Gates.**
  - Nace `supabase/tests/test_compras_gastos_sucursal_por_defecto.sql`, que **ejecuta** las tres RPCs (y la migración de datos, si OQ-1 = (b)).
  - `test_gastos_forma_pago.sql` (4.3b) cambia **a propósito**: hoy fija «el nulo explícito desimputa la sucursal del gasto».
  - En `KPI_Validation.yml`, la reaplicación de la migración nueva va al final de la cadena, sin tolerancia.

Fuera de alcance (quedan como candidatos u Open Questions del design):

- un `NOT NULL` sobre `purchases.branch_id` o `expenses.branch_id`;
- revocar la escritura directa de `authenticated` sobre `purchases` y `expenses` por PostgREST;
- retirar las funciones legacy `rpc_atomic_create_purchase` y `rpc_create_purchase_operation_v2` (sólo `service_role`, sin llamadores) y el `services.createExpense` muerto del frontend;
- qué hacen la reversa y la edición cuando la sucursal guardada de una compra deja de operar (es el candidato OQ-8 de ventas, que ahora alcanza también a compras);
- un guard de "última sucursal operativa" al desactivar sucursales;
- una sucursal principal configurable.

## Capabilities

### New Capabilities

Ninguna.

### Modified Capabilities

- `purchase-operation`: «La compra persiste su sucursal» pasa de "persiste la elegida o queda nula" a "persiste la elegida o la principal, con `no_branch_found` sin sucursal operativa y `branch_closed` para una elegida cerrada". Sus compras históricas siguen sin relleno (OQ-1). «La compra en efectivo descuenta de la caja…» aclara que la sucursal efectiva de una compra sin sucursal elegida es la principal, y suma el escenario que hoy falla.
- `expense-operation`: «El gasto persiste su sucursal» y «La edición de un gasto preserva su contexto mediante contrato tri-estado» suman la resolución de un nulo a la principal en la edición. Los gastos históricos siguen sin relleno hasta su próxima edición.
- `operation-edit-context`: en el contrato tri-estado de sucursal, la excepción que hoy es sólo de la venta se extiende a la **compra**. El escenario «desimputar la sucursal de una compra sigue permitido» se reemplaza.
- `branches`:
  - «Asociación opcional de operaciones a una sucursal» queda acotada a las compras y los gastos **históricos**.
  - «Operaciones solo contra sucursales operativas» suma el escenario de la compra en una sucursal cerrada.
  - «El selector de sucursal de la venta…» deja de afirmar que compra, gasto e importador conservan «Sin sucursal».
  - Nace el requirement del selector de compra, gasto e importador de gastos.
- `branch-stock`: el renglón «Compra sin `branch_id`: incrementa la sucursal principal» pasa a "incrementa la principal **y queda registrada en ella** (fila y movimiento)", con su escenario.

## Impact

- **Base de datos**: `supabase/migrations/20261076000001_compras_gastos_sucursal_por_defecto.sql`.
  - Reescribe, desde su `pg_get_functiondef` **vivo de producción**, detrás de un *preflight* de `md5` (molde `20261075000001`) y con `CREATE OR REPLACE` de la misma firma:
    - `rpc_create_purchase_operation`, o su núcleo `_purchase_operation_core` si `remitos-compra` tanda B mergea antes (D6);
    - `rpc_atomic_update_purchase_operation`;
    - `rpc_update_expense`.
  - Se conservan los `COMMENT` (al de `rpc_update_expense` se le agrega la excepción) y se re-emiten las ACLs.
  - Con OQ-1 = (b) se suma `20261076000002_compras_gastos_sucursal_por_defecto_backfill.sql`, sólo de datos; la mergea el PO.
  - Con OQ-3 = (b) se reescribe además `rpc_create_expense`.
  - Los números se re-confirman en el apply: `remitos-compra` tanda B toma "el siguiente libre" y puede llegar antes.
- **Frontend**:
  - `components/forms/purchase-form.tsx`, `components/forms/expense-form-v2.tsx` y `components/gastos/expense-import-dialog.tsx`: el selector;
  - el JSDoc de `components/branches/BranchSelect.tsx`;
  - la prosa de los tests del opt-in de caja de compra;
  - los tests de los tres componentes.
- **Backend**: `backend/schemas/purchases.py`, `backend/schemas/expenses.py` y `backend/services/purchases.py`, sólo comentarios y descripción del campo; un test de la descripción.
- **Gates y CI**:
  - el gate nuevo;
  - `test_gastos_forma_pago.sql` (4.3b), modificado a propósito;
  - el paso de reaplicación en `KPI_Validation.yml`;
  - se re-corren sin tocar los gates que ejecutan o inspeccionan las tres funciones: `test_purchase_cash_optin`, `test_compras_proveedor_cuenta_corriente`, `test_edicion_preserva_contexto`, `test_idempotency`, `test_confirm_core_integrity`, `test_ventas_unidades_conversion`, `test_stock_movements_edicion`, `test_pos_rpc_signatures`, `test_cobranzas_vencimientos_schema`, `test_function_acl_gate`, `test_remitos_compra`, `test_asiento_contable_gastos`, `test_expense_import_batch` y el resto que las nombra.
- **Lectores (cambio de un día para otro, sin tocar su código)**:
  - El Tablero filtrado por la principal (`rpc_dashboard_kpi_summary`, `get_dashboard_financials`) suma las compras nuevas sin sucursal elegida. "Ganancia neta" filtrada por la principal baja en consecuencia.
  - La fila «Sin sucursal» de `rpc_branch_report` (sólo lee gastos) pierde los gastos que se editen.
  - El export de compras muestra el nombre de la sucursal en vez de «Principal».
- **Coordinación**: `remitos-compra` tanda B (pendiente) extrae `_purchase_operation_core` desde `rpc_create_purchase_operation` y suma un `P0423` a `rpc_atomic_update_purchase_operation`. Las dos son funciones que este change reescribe: el que aplica segundo parte del cuerpo vivo (D6).
- **Governance**: MEDIA con tramo **ALTO**. Reescribe las funciones que mueven stock, caja y banco en el alta y la edición de compras. Nada se aplica sin el checkpoint del cuerpo vivo de producción. Si OQ-1 = (b), la migración de datos la mergea el PO.
- **Superficie frontend**: sí.
  - En `/compras` y `/gastos`: el modal de alta y edición de cada uno, y el importador de gastos.
  - Las tres pantallas se verifican en escritorio y en móvil, con tema claro y oscuro.
  - El opt-in de caja de una compra sin sucursal elegida se verifica en el humo.
