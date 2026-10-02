# Design — `ventas-sucursal-por-defecto`

> Governance: **MEDIA con tramo ALTO**. Reescribe las tres funciones que mueven stock, caja y banco en el alta y la edición de ventas, y actualiza en masa una columna de `sales` en producción. Ninguna línea de SQL se escribe antes del checkpoint 0 (cuerpo **vivo de producción**). La migración de datos la mergea el PO.

## Context

### La decisión

El 2026-10-01 el PO decidió *«sí, que las ventas sin sucursal queden con la principal»*. Cuando se le propuso medir antes, preguntó *«¿para qué querés medir?»*. La respuesta está en §"Por qué no hace falta medir antes", y el diseño está armado para no depender de ninguna medición previa.

### Estado actual

Todo lo que sigue está verificado contra el repo (`origin/main` `f61820ac`) y la base local (313 migraciones, `MAX = 20261066000001`).

**Alta de venta.** La última definición de `rpc_create_sale_operation_v2` y la del wrapper `rpc_create_sale_operation` están en `supabase/migrations/20261062000001_ventas_unidades_conversion.sql`. El wrapper se redefinió ahí; la definición de `20261022000001` que citaba el brief ya no es la viva.

- **v2** (L330-699):
  - L436-448 valida la sucursal recibida: ajena o inactiva da `P0404`, cerrada da `P0422 branch_closed`.
  - L450: `v_gate_branch := COALESCE(p_branch_id, public.c26_default_branch(v_account_id))`.
  - Con `v_gate_branch` se hace el gate de stock, el descuento `c21_apply_branch_stock_delta`, el opt-in de caja (L634 compara la sucursal de la sesión contra `v_gate_branch`) y el movimiento bancario (L662, `_pay_register_operation_bank_movement(..., v_gate_branch, NULL)`).
  - Pero los `INSERT` guardan **`p_branch_id` crudo**: `sales` en L552 (línea con producto) y L602 (línea de servicio), `stock_movements` en L583.
- **Wrapper** (L2629-3044): lee el flag `sale_items_rpc_v2` (L2669). Sin fila, el flag vale `true` (L2671) y delega en la v2. Con `false` ejecuta una **rama legacy** completa, con el mismo `COALESCE` (L2760) y los mismos tres `INSERT` crudos (L2858, L2877, L2890).
- **Edición**: `rpc_atomic_update_sale_operation` (L1594-2262).
  - Tri-estado de sucursal en L1923-1936: `p_branch_provided` con valor reimputa (valida `P0422 branch_invalid`), con `NULL` desimputa, y sin informar conserva `v_old_branch_id`.
  - La pata REVERSE (L1985) devuelve el stock a `v_old_sale.branch_id`.
  - La pata APPLY (L2109) y los dos `INSERT` en `sales` (L2070, L2125) usan `v_final_branch_id`.
  - `op_stock_movement` ya escribe `COALESCE(p_branch_id, c26_default_branch(...))` en `stock_movements.branch_id`, así que en la edición sólo la **fila de venta** puede quedar `NULL`.
  - El gate de stock de la edición es **global** (`Σ branch_stock`).
- **Sucursal principal**: `c26_default_branch(uuid)` (`20260625000001_c26_branch_as_root.sql:135`, `STABLE`) devuelve la sucursal más antigua con `is_active AND status = 'active'` por `created_at ASC`. Si no hay ninguna, devuelve la más antigua a secas. No tiene desempate. `COMMENT`: *"C-26: branch default operativa de una cuenta…"*.
- **Reversas**:
  - `rpc_delete_sale_operation` (viva en `20261061000001`) repone el stock con `rpc_reverse_stock_movement`, que usa `stock_movements.branch_id` del movimiento original. Con `NULL`, `rpc_apply_product_stock_delta` resuelve la principal **vigente al momento del borrado**.
  - La edición devuelve a `sales.branch_id`, que con `NULL` vuelve a caer en `op_stock_movement` → principal vigente.
- **Otros caminos de venta**: persisten la sucursal resuelta y no se tocan. Son `rpc_quick_sale` (`COALESCE` + `P0422 no_branch_found` si no hay ninguna), `_c29_confirm_order_core` (toma la sucursal de la orden, `sales_orders.branch_id NOT NULL`) y `rpc_accept_quote`.
- **"Facturar venta manual"** (`rpc_promote_legacy_sale_to_order`, viva en `20261061000001`): resuelve `COALESCE(sales.branch_id, c26_default_branch)` para la **orden**, pero no actualiza `sales.branch_id`. Su helper `_sales_order_sync_from_operation` levanta `P0422 operation_inconsistent` si las filas de una operación mezclan `NULL` y no-`NULL`.
- **Escritores de `sales`**: hay seis funciones vivas que hacen `INSERT` en `sales`, más un `UPDATE` de `product_id` en `rpc_safe_delete_product`. Cuatro son las de arriba. Las otras dos son los overloads legacy `rpc_atomic_create_sale(...)`, que insertan **sin `account_id` ni `branch_id`**, sólo tienen `EXECUTE` para `postgres`/`service_role` y ningún archivo de `backend/`, `frontend/` ni `supabase/functions/` las llama (sólo aparecen en `database.types.ts`).
- **Tabla `sales`**:
  - `branch_id uuid NULL`, con FK `ON DELETE SET NULL`.
  - Disparadores: sólo `AFTER INSERT` (`on_sale_insert_margin_check`, `trg_analytics_operation_created`). **Ningún disparador de `UPDATE`**.
  - No está en ninguna publicación de Realtime. `audit_logs` no tiene disparadores.
  - Las sucursales no se pueden borrar: `trg_guard_branch_decommission` lo prohíbe siempre.
  - Toda cuenta tiene al menos una sucursal: "Casa Central" la crea `handle_new_user` y el backfill A.1 de `20260812000001_v3_provisioning_seed.sql`. Localmente, 6 de 6 cuentas tienen sucursal.
- **Medición previa ya disponible**: en producción, el 2026-08-11, había `sales = 581` filas, de las cuales **436 (75 %) tenían `branch_id NULL`**. Había `branches = 36` y **una sola cuenta con más de una sucursal** (`openspec/changes/archive/2026-08-12-kpi-branch-consistency/design.md:25`). El mismo dato está en el comentario vivo del fail-open de `rpc_dashboard_kpi_summary`.
- **Lectores**:
  - Filtran por igualdad y dejan las `NULL` fuera del filtro por sucursal: `get_dashboard_financials`, `rpc_dashboard_kpi_summary`, `rpc_dashboard_channel_margin` y `reporting_sales_lines_in_window`.
  - Rotulan las `NULL` como "Sin sucursal": `rpc_branch_report` (`COALESCE(b.name, 'Sin sucursal')`) y `rpc_sales_breakdown`.
  - El stock sin rotación es *fail-open* para las `NULL` (`kpi-branch-consistency` D4).
  - `supabase/functions/generate-export/index.ts:74` muestra las `NULL` como "Principal".
- **Frontend**:
  - `components/branches/BranchSelect.tsx` lo comparten la venta, la compra, el gasto y el importador de gastos. No se renderiza sin el módulo de sucursales. Su primera opción, "Sin sucursal (general)", vale `null`.
  - `hooks/data/use-branches.ts` lista las sucursales con `is_active = true` ordenadas por `created_at`, **sin filtrar `status`**.
  - `hooks/use-cash-optin.ts:103` (`effectiveBranchId = branchId || branches[0]?.id`) y `hooks/use-default-branch-notice.ts` toman `branches[0]` como "la principal". Si la sucursal más antigua está **cerrada**, el cliente la toma como principal y el servidor (`c26_default_branch`, que exige `status = 'active'`) no.
- **Precedentes**:
  - Gasto (`gastos-forma-pago` D6): el alta persiste el `COALESCE`, los 175 gastos históricos no tienen backfill y la edición (`rpc_update_expense`) todavía permite desimputar.
  - Compra (`caja-compras-cobranzas` D3): persiste `p_branch_id` crudo y no tiene backfill.
  - Ventas: el fix #606 dejó los bloques 2 y 6 de `supabase/tests/test_ventas_formulario_sucursal.sql` fijando el contrato "sin sucursal → `NULL`" **para que este change los cambie a conciencia**.

### Por qué no hace falta medir antes

Lo que se quería medir servía para **elegir** entre dejar las ventas históricas, asignarlas todas, o asignar sólo las de cuentas con una única sucursal. El PO ya eligió: asignarlas. Con esa decisión tomada, ningún número cambia lo que hay que hacer:

1. **La migración resuelve todos los casos sin intervención** (D6): sin ningún dato extra decide qué hacer con cuenta de una sucursal, cuenta de varias, venta facturada a mano, operación mixta y fila sin cuenta.
2. **La migración se autoinforma**: emite `NOTICE` con los conteos por regla, el residuo que no pudo asignar y cuántas ventas tenían evidencia de otra sucursal en caja o banco. Además deja una fila de auditoría por cuenta (D7). Nadie tiene que contar nada a mano para saber qué pasó.
3. **El orden de magnitud ya se conoce**: el 75 % de las filas de `sales` estaba sin sucursal, y en agosto había una sola cuenta con más de una sucursal. Para todas las demás cuentas "la principal" es su única sucursal: no hay ambigüedad posible.
4. **Lo único que se corre en producción son verificaciones posteriores** (tarea 12): tres `SELECT` que confirman que no quedó nada sin asignar. No deciden nada; confirman.

## Goals / Non-Goals

**Goals:**

1. Ninguna venta **nueva ni editada** queda con `sales.branch_id = NULL`. La sucursal guardada es, por construcción, **la misma variable** con la que se validó y descontó el stock y se resolvieron la caja y el banco.
2. Las ventas **históricas** con `branch_id NULL` pasan a la principal (o a la sucursal de su orden, si fue facturada a mano). Sus movimientos de stock toman la misma sucursal, de forma idempotente, trazable y sin disparar efectos laterales.
3. En el formulario de venta, la opción "Sin sucursal (general)" deja de existir y la principal se ve como lo que es.
4. Una sola definición de "la principal" en el cliente, idéntica a la del servidor.
5. Cero regresiones: POS, órdenes, presupuestos, compras, gastos, borrado, edición con sucursal explícita, gates de integridad, firmas y ACLs.

**Non-Goals:**

- **Compras**: el alta y la edición siguen guardando `NULL` si no se elige sucursal. Las compras históricas no se tocan (OQ-3).
- **Gastos**: la edición todavía puede desimputar, y la opción "Sin sucursal (general)" del formulario de gasto ya miente, porque el alta guarda la principal. Va al change hermano (OQ-3).
- **`NOT NULL` o `CHECK` sobre `sales.branch_id`** (D8: candidato posterior).
- **Validar el stock de la edición contra la sucursal efectiva** (candidato (d) de #606). La edición conserva su gate global.
- **Sucursal principal configurable** (OQ-1) y **desempate de `c26_default_branch`** (D4).
- **Ocultar el selector cuando la cuenta tiene una sola sucursal** (RN-93 lo pide). No se toca acá.
- **Tocar los lectores**: ninguno cambia su código (D12).
- **Backend**: no cambia de lógica (D11).

## Decisions

### D1 — Un solo contrato, resuelto en la RPC: la sucursal que se guarda es la que movió el stock

Las tres funciones persisten la sucursal **ya resuelta**:

- en la v2 y la rama legacy, `v_gate_branch` en los tres `INSERT`;
- en la edición, `v_final_branch_id` con el `COALESCE` aplicado.

No hace falta ninguna función nueva: `c26_default_branch` ya es la definición canónica y la usan el POS, "Facturar venta manual", el gasto y el propio gate de stock.

- *Alternativa A — disparador `BEFORE INSERT` en `sales` que complete `NULL` con la principal* (un único punto de paso).
  - **Rechazada como mecanismo principal**: resolvería la principal en **otra sentencia** que la del gate de stock. Bajo `READ COMMITTED`, un cierre concurrente de sucursal entre las dos dejaría la venta en una sucursal y el stock descontado de otra, que es justo el invariante que este change quiere garantizar por construcción.
  - Además esconde la regla fuera de la RPC y no cubre `stock_movements`.
  - Queda como candidato de defensa en profundidad junto con D8.
- *Alternativa B — resolverla en FastAPI*. **Rechazada**: duplica la regla de la principal en Python, no cubre las llamadas por PostgREST (`rpc_create_sale_operation` tiene `EXECUTE` para `authenticated`) y el servidor ya la resuelve.
- *Alternativa C — sólo preseleccionarla en la interfaz*. **Rechazada**: no cubre la cuenta sin módulo de sucursales (el selector no se renderiza), ni `POST /sales` sin el campo, ni las ventas históricas.

### D2 — Alcance de la reescritura: las tres funciones, en paridad, y también `stock_movements`

| Función (viva en `20261062000001`) | Cambio |
|---|---|
| `rpc_create_sale_operation_v2` | `sales.branch_id` (L552, L602) y `stock_movements.branch_id` (L583) pasan de `p_branch_id` a `v_gate_branch`. Después de L450 y **antes** del `INSERT` en `operation_idempotency`: `IF v_gate_branch IS NULL THEN RAISE 'no_branch_found…' USING ERRCODE = 'P0422'` (D3). |
| `rpc_create_sale_operation` (rama legacy, `v_flag_on = false`) | Los mismos tres cambios (L2858, L2877, L2890) y el mismo guard después de L2760. La rama v2 del wrapper (delegación) no cambia. |
| `rpc_atomic_update_sale_operation` | Después del bloque tri-estado (L1923-1936) y **antes del REVERSE**: `v_final_branch_id := COALESCE(v_final_branch_id, public.c26_default_branch(v_account_id))`, más el mismo guard `P0422 no_branch_found`. La validación de una sucursal explícita (`P0422 branch_invalid`) no cambia. La pata REVERSE sigue devolviendo a `v_old_sale.branch_id`. |

Reglas de la reescritura:

- Se parte del `pg_get_functiondef` **vivo de producción**.
- `CREATE OR REPLACE` con la misma firma: sin `DROP`, sin overload y sin `42725`.
- Se re-declara el `COMMENT` vivo. Sólo la edición tiene uno; la v2 y el wrapper no tienen, y eso se verifica en el checkpoint.
- Se re-emiten las ACLs vivas: `authenticated` y `service_role` con `EXECUTE`, `anon` sin `EXECUTE`.
- El diff contra el cuerpo vivo tiene que ser **exactamente** los cambios de esta tabla y un comentario de cabecera por función.
- *Alternativa — helper `_sale_effective_branch(account, branch)`*. **Rechazada**: la parte compartida es una línea (`COALESCE` sobre la función canónica). La validación de la sucursal explícita difiere entre el alta (`P0404`/`P0422 branch_closed`) y la edición (`P0422 branch_invalid`), y un helper más sumaría una entrada al gate de ACLs (chequeo (4)) sin quitar duplicación real.
- *Alternativa — dejar `stock_movements` como está*. **Rechazada**: la reversa del borrado lee la sucursal **del movimiento**. Si la venta queda en A y su movimiento en `NULL`, el borrado repone en la principal vigente en ese momento, que puede no ser A.

### D3 — Una cuenta sin ninguna sucursal falla con `P0422 no_branch_found`

Es el mismo token y el mismo código que `rpc_quick_sale` y `rpc_promote_legacy_sale_to_order`. Hoy, en ese estado:

- una venta con producto falla con `P0409`, porque el gate busca stock en una sucursal `NULL`;
- una venta sólo de servicios **pasa con `NULL`**: es el único camino que dejaría una venta sin sucursal después de este change.

El estado es inalcanzable por construcción (aprovisionamiento más la prohibición de borrar sucursales), así que el guard es *fail-closed* y ruidoso ante un estado imposible.

- *Alternativa — crear "Casa Central" al vuelo, como hace `c21_apply_branch_stock_delta`*. **Rechazada**: que una venta cree una sucursal es un efecto lateral oculto, y el POS, que es el camino de más volumen, ya eligió rechazar.

### D4 — "La principal" es `c26_default_branch`, sin cambios

`c26_default_branch` ya decide hoy dónde se descuenta el stock y dónde se cobra cada venta sin sucursal, y es lo que anuncia el aviso de cambio de sucursal por defecto (`useDefaultBranchNotice`). Persistirla no inventa un criterio nuevo: deja asentado el que ya rige.

- **Desempate**: no se agrega. Los empates de `created_at` sólo ocurren entre sucursales creadas en la **misma transacción**, como los fixtures de los gates. Ningún camino de producto crea dos sucursales de una cuenta en una transacción: el aprovisionamiento crea una sola. Agregar `ORDER BY created_at, id` tocaría la función que resuelve **toda** operación sin sucursal del sistema, sin beneficio observable. Los gates siguen forzando `created_at` distintos y asertándolos.
- **Volatilidad**: la principal cambia si la más antigua se desactiva o se cierra. Desde este change eso **no mueve ventas ya registradas**, porque quedaron con su sucursal escrita. Sólo cambia dónde caen las ventas nuevas sin sucursal elegida, que es lo que anuncia el aviso.
- *Alternativa — sucursal principal configurable* (`accounts.default_branch_id` y "Usar como principal" en `/sucursales`). Es una funcionalidad de producto, no la pidió el PO, y tocaría la función que comparten POS, gastos y compras (OQ-1).

### D5 — Edición: para la venta, `NULL` significa "la principal"

| Llamada | Antes | Después |
|---|---|---|
| `p_branch_provided = false`, fila con sucursal X | conserva X | conserva X |
| `p_branch_provided = false`, fila con `NULL` (residuo) | conserva `NULL` | **principal** |
| `p_branch_provided = true`, `p_branch_id = X` válido | reimputa a X | reimputa a X |
| `p_branch_provided = true`, `p_branch_id = NULL` | desimputa (`NULL`) | **principal** |
| `p_branch_provided = true`, X ajena o cerrada | `P0422 branch_invalid` | sin cambios |

El `COALESCE` corre antes del REVERSE, igual que la validación (gate 2.9 de `edicion-preserva-contexto`: una edición inválida no revierte ni reaplica stock). El REVERSE de una fila con `NULL` ya caía en la principal vigente (`op_stock_movement`) y el APPLY ahora descuenta de esa misma sucursal: el neto es cero, igual que hoy.

**BREAKING (contrato interno)**: el escenario "desimputar" del contrato tri-estado deja de aplicar a la sucursal de la **venta**. Siguen igual el canal de la venta y todo el contrato de la compra. No hay consumidor que dependa de desimputar: el formulario no podrá elegir "sin sucursal" (D9) y un `PUT /sales/{id}` con `branch_id: null` pasa a guardar la principal, que es exactamente la decisión del PO.

### D6 — Ventas históricas: a la principal, con dos excepciones de coherencia

**Reglas, en orden de precedencia.** Para cada fila de `sales` con `branch_id IS NULL` y `account_id IS NOT NULL`:

1. **Venta facturada con "Facturar venta manual"**: hay una `sales_orders` con `sale_operation_id = sales.operation_id` (índice único `sales_orders_sale_operation_id_uq`) y la misma cuenta. La venta toma **la sucursal de la orden**, que es la que figura en la orden y la factura. Hoy coincide con la principal salvo que esta haya cambiado después de facturar, y la promoción funciona recién desde #585 (2026-09-25).
2. **Operación mixta**: las otras filas de la misma `operation_id` tienen **exactamente una** sucursal distinta. La fila toma esa sucursal, porque una operación es de una sola sucursal y así se cura el `P0422 operation_inconsistent` de "Facturar venta manual". Con dos o más sucursales distintas no se elige ninguna y se aplica la regla 3.
3. **Resto**: `c26_default_branch(account_id)` **vigente al aplicar la migración**.

**Movimientos de stock.** Los movimientos `reference_type = 'sale'` con `reference_id` igual a una venta **asignada por esta migración** y `branch_id IS NULL` toman la sucursal de su venta.

**Qué no se toca:**

- los movimientos de ventas ya borradas: el par original y su reversa quedan los dos en `NULL`, que es consistente;
- `cash_movements`, `bank_movements` (ya llevan la sucursal resuelta), `customer_account_movements`, `journal_entries`, `events`, `sales_orders`, `sale_items`, `branch_stock`.

**Residuo.** Las filas sin `account_id` y las de una cuenta sin sucursal quedan `NULL`. Se informan con `NOTICE` y la migración no se aborta.

**Por qué la principal vigente y no "la principal de aquel momento":**

1. **Es la decisión literal del PO.**
2. **Es lo que el sistema ya hace hoy en cada camino de ejecución con esas ventas**: el borrado y la edición devuelven el stock a la principal *vigente*, y el export las rotula "Principal". La migración deja escrito el comportamiento que ya existía en vez de inventar uno nuevo.
3. **"La de aquel momento" sólo se conoce para las ventas con movimiento de caja o de banco**, y puede ser una sucursal hoy cerrada o desactivada (el caso típico es la cuenta del incidente del 22-08). Asignársela dejaría esas ventas **sin poder editarse ni borrarse** sin reabrir la sucursal, que es el candidato (i) de #606.

El costo es que, en una cuenta cuya principal cambió, las ventas viejas quedan atribuidas a la principal de hoy. La migración **cuenta** cuántas ventas asignadas tienen un movimiento de caja (vía `cash_sessions → cashboxes.branch_id`) o de banco (`bank_movements.branch_id`) que registró **otra** sucursal, y lo informa (OQ-4).

- *Alternativa (c) del brief — sólo las cuentas con una única sucursal*. Superada por la decisión del PO. Además, el **mismo** argumento vale para las cuentas con varias sucursales, cuyo stock se movió en la principal.
- *Alternativa — cascada con la sucursal registrada en caja y banco como regla 0*. Rechazada por el punto 3 (OQ-4).

### D7 — Mecánica del backfill: archivo propio, orden global de locks, trazable e idempotente

- **Dos archivos**: `20261069000001_ventas_sucursal_por_defecto.sql` (funciones) y `20261069000002_ventas_sucursal_por_defecto_backfill.sql` (datos solamente: sin DDL, sin funciones, sin ACLs). Primero entran los cuerpos nuevos y después corre el backfill. Así se achica la ventana de ventas "en vuelo" (D13 y Risks), el PO puede mergear la migración de datos con la regla vigente (los sub-agentes no mergean migraciones de datos) y cada archivo se reaplica por separado en la cadena de `KPI_Validation.yml`.
- **Locks**: antes de actualizar, las filas candidatas se toman con `FOR UPDATE` en **orden ascendente de `id`**. Es la regla dura del proyecto (orden global único: `sales` por `id` → `sales_orders` → `fiscal_documents` → resto), la misma que usan la edición, el borrado y la promoción, así que el backfill no puede entrar en deadlock con ninguno de los tres. `stock_movements` va después ("resto"). **No** se usa `LOCK TABLE`: con escritores que toman `sales` y `stock_movements` en órdenes distintos (el alta inserta `sales` antes que el movimiento y el borrado inserta la reversa antes del `DELETE`), un lock de tabla sí puede entrar en deadlock.
- **Trazabilidad**: se escribe **una fila de `audit_logs` por cuenta afectada**, con estos campos:
  - `action = 'sales_branch_backfill'`
  - `entity_type = 'account'`
  - `entity_id = account_id`
  - `account_id`
  - `user_id = NULL` (sistema; mismo criterio que la autoría nula del alta automática de sucursales)
  - `metadata = {change, sale_ids[], movement_ids[], por_regla{orden, operacion, principal}, branch_ids[], evidencia_otra_sucursal}`

  `audit_logs` no tiene disparadores, y su política de lectura (vía `company_id`) no expone estas filas a los usuarios. Así queda registrado qué asignó el sistema frente a lo que eligió el usuario, y hay un camino de reversión exacto (Migration Plan).
- **Idempotencia**:
  - el `WHERE branch_id IS NULL` hace que una segunda corrida no encuentre filas;
  - con cero filas no se escribe ninguna fila de auditoría;
  - el gate la ejecuta dos veces (molde `test_unidades_decisiones_8_9.sql`), y la cadena de reaplicación de CI compara el fingerprint del esquema.
- **Sin efectos laterales**: `sales` sólo tiene disparadores `AFTER INSERT`, así que el `UPDATE` no dispara margen bajo, analytics, eventos, notificaciones ni Realtime. El gate lo asierta comparando los conteos de `events`, `notifications` y `analytics_events` antes y después.
- **Nunca aborta por datos**. El residuo y las discrepancias se informan con `NOTICE`.

### D8 — Sin `NOT NULL` ni `CHECK` sobre `sales.branch_id` en este change

- `ALTER COLUMN … SET NOT NULL`: **rechazado ahora**.
  - Si queda residuo (filas sin `account_id`), el `ALTER` falla y **aborta el deploy**.
  - Los dos `rpc_atomic_create_sale` legacy (sólo `service_role`) insertan sin sucursal y empezarían a fallar.
  - La FK `ON DELETE SET NULL` quedaría contradiciendo la restricción.
- `CHECK (branch_id IS NOT NULL) NOT VALID`: **rechazado**. Postgres evalúa el `CHECK` en **cualquier** `UPDATE` de la fila, así que un `UPDATE sales SET product_id = NULL` (`rpc_safe_delete_product`) sobre una fila residual empezaría a fallar y bloquearía el borrado de productos.
- **Candidato** (en `CHANGES.md` al archivar): con el residuo verificado en 0 en producción, una migración propia retira los `rpc_atomic_create_sale` muertos, cambia la FK a `RESTRICT` y agrega `NOT NULL`.

### D9 — Formulario de venta: sin "Sin sucursal", con la principal a la vista

- `BranchSelect` suma una prop opt-in, `allowUnassigned?: boolean`, con valor por defecto `true`, para que compra, gasto e importador de gastos queden **idénticos**.
- En la venta se usa `allowUnassigned={false}`:
  - no aparece la opción `__none__`;
  - el valor mostrado es `value ?? resolveDefaultBranch(branches)?.id`;
  - la principal se lista como "Nombre (principal)";
  - el formulario suma el rótulo **"Sucursal"**: hoy el selector no tiene rótulo, a diferencia de Fecha y Canal.
- El **estado** del formulario sigue en `null` hasta que el usuario elige. Con `null` el alta manda `branch_id: null` y **el servidor** decide con datos vivos.
  - Se ve la principal y se guarda la principal, porque el helper del cliente es espejo exacto de `c26_default_branch` (D10).
  - La única ventana de diferencia es el caché de cinco minutos de `useBranches` si la principal cambia mientras el modal está abierto. En ese caso el servidor guarda la principal **real**.
- Si el usuario elige una sucursal, explícitamente o eligiendo la principal en la lista, viaja su id.
- **Edición**:
  - precarga `editingOperation.branchId`;
  - después del backfill toda venta tiene sucursal;
  - si quedó residuo, se muestra la principal y viaja `null`, que el servidor resuelve a la principal (D5).
- **Cuenta sin módulo de sucursales**: el selector no se renderiza (sin cambio), viaja `null` y la venta queda en su única sucursal. El opt-in de caja ya usaba esa misma sucursal.
- *Alternativa — preseleccionar el id explícito en el estado (`useEffect` y bandera "tocado")*. **Rechazada**: suma un efecto y congela la vista cacheada del cliente en el dato que se guarda. Con `null`, la fuente de verdad sigue siendo una sola: el servidor.
- *Alternativa — conservar una opción `null` rotulada "Sucursal principal (Casa Central)"*. **Rechazada**: lista dos opciones que significan lo mismo ("Sucursal principal (Casa Central)" y "Casa Central"). Queda como opción (b) de OQ-2.

### D10 — `lib/default-branch.ts`: una sola definición de "la principal" en el cliente

`resolveDefaultBranch(branches: Branch[]): Branch | null` recibe las sucursales activas ordenadas por `createdAt`, tal como las devuelve `useBranches`:

- devuelve la primera con `status === "active"`;
- si no hay ninguna, devuelve la primera de la lista;
- con la lista vacía, devuelve `null`.

La consumen tres lugares:

- `BranchSelect` (D9);
- `useCashOptin`: `effectiveBranchId = branchId || resolveDefaultBranch(branches)?.id || null`;
- `useDefaultBranchNotice`.

Con esto se cumple la Regla de Tres (tres consumidores) y se corrige un desfasaje real. Hoy, con la sucursal más antigua **cerrada**, el opt-in de caja busca la sesión en la cerrada mientras el servidor exige la de la siguiente, y el aviso anuncia como principal una sucursal cerrada.

Límite declarado: si **ninguna** sucursal activa está operativa, el servidor cae a la más antigua de **todas**, incluidas las inactivas, y el cliente sólo ve las activas. Es un estado al que no se llega por la interfaz: `rpc_close_branch` rechaza cerrar la última operativa (`P0409 last_active_branch`).

### D11 — Backend sin cambio de lógica

`SaleOperationIn.branch_id` y `SaleOperationUpdateIn.branch_id` ya transportan `None`, y el tri-estado viaja por `model_fields_set`. Sólo se corrigen los comentarios que afirman que "`None` conserva `branch_id` NULL" (`backend/services/sales.py` cerca de L147, `backend/schemas/sales.py` cerca de L50) y se agrega la descripción del campo en el esquema (OpenAPI): «sin sucursal se registra en la principal de la cuenta». Los errores nuevos (`P0422 no_branch_found`) llegan como RFC 7807 por el mapeo global de `asyncpg_error_handler`, como el resto de `P0422`.

### D12 — Lectores: ningún cambio de código; qué cambia de un día para otro

| Lector | Efecto |
|---|---|
| Tablero, estadísticas y márgenes **filtrados por la principal** | Suman las ventas que hoy quedan afuera por ser `NULL`. En cuentas sin módulo de sucursales no hay filtro, así que no cambia nada visible. |
| Tramo "Sin sucursal" (`rpc_sales_breakdown`, `rpc_branch_report`) | Deja de recibir ventas; sólo conserva el residuo. `rpc_branch_report` lee `sales` y `expenses` (no compras), así que su fila "Sin sucursal" sigue mostrando los gastos históricos sin sucursal. |
| Stock sin rotación **filtrado por una sucursal que no es la principal** | Las ventas históricas sin sucursal dejan de contar como rotación ahí: ahora pertenecen a la principal. Es más fiel, porque el stock de esas ventas salió de la principal. El *fail-open* de `kpi-branch-consistency` D4 queda vigente y se vuelve vacuo, aunque sigue protegiendo el residuo. |
| Export (`generate-export`) | Muestra el nombre real de la sucursal en vez de "Principal". |
| `/sucursales/:id` e inventario | Sin cambios: leen `branch_stock`, que este change no toca. |

*Alternativa — retirar el fail-open o la etiqueta "Sin sucursal"*. **Rechazada**: siguen haciendo falta para el residuo, las compras y los gastos, y tocarlos exigiría reescribir las RPCs de reporte desde su cuerpo vivo sin necesidad.

### D13 — Gates: ejecutan las RPCs y la migración, con controles de introspección y mutaciones

Gate nuevo: `supabase/tests/test_ventas_sucursal_por_defecto.sql`. Sigue el patrón del proyecto: acumula fallos en `text[]`, usa anchors sintéticos vía `handle_new_user`, `created_at` explícito y asertado, y limpieza completa. Bloques:

- **(0) Introspección**: los cuerpos **vivos** de las tres funciones persisten la sucursal resuelta. La edición conserva su `COMMENT`. Hay una sola firma por función y las ACLs no cambiaron. Falla explícito si una reaplicación posterior de la cadena de CI pisa un cuerpo (lección de `candidatos-db-backend`).
- **(1)** Alta v2 sin sucursal, en una cuenta con A (principal) y B, con dos líneas (una de servicio): `sales.branch_id = A` en todas las filas, `stock_movements.branch_id = A`, el stock baja en A y B queda intacta.
- **(2)** Lo mismo por la **rama legacy** (flag `sale_items_rpc_v2 = false` para la cuenta del fixture).
- **(3)** Con la principal **cerrada**: `c26_default_branch` resuelve B, y la venta y el stock van a B.
- **(4)** Cuenta sin ninguna sucursal (fixture con `session_replication_role = replica` para esquivar el guard de borrado): `P0422 no_branch_found` en la v2 y en la legacy, sin filas en `sales`, `operation_idempotency` ni `stock_movements`.
- **(5) Edición**:
  - venta en B editada con `p_branch_provided = true` y `NULL` → A (el REVERSE devuelve a B y el APPLY descuenta de A);
  - fila residual `NULL` editada sin informar sucursal → A;
  - reimputación explícita → sin cambios.
- **(6) Caja y banco**: sin sucursal elegida, la venta, su movimiento de stock y su movimiento bancario llevan **la misma** sucursal (A).
- **(7) Backfill**, ejecutando el archivo de datos **dos veces** (`\i`):
  - mono-sucursal → su sucursal;
  - multi-sucursal → principal;
  - con orden facturada en B → B;
  - operación mixta (B más `NULL`) → B;
  - sin `account_id` → sigue `NULL`;
  - movimientos de las asignadas → misma sucursal;
  - movimientos de ventas borradas → intactos;
  - una fila de `audit_logs` por cuenta con los ids;
  - la segunda corrida no cambia filas ni escribe auditoría;
  - `events`, `notifications` y `analytics_events` sin cambios.
- **(8)** Después del backfill, `rpc_promote_legacy_sale_to_order` **ejecutada** sobre la operación antes mixta ya no levanta `P0422 operation_inconsistent`.
- **(9)** `rpc_delete_sale_operation` **ejecutada** sobre una venta asignada por el backfill repone el stock en la sucursal asignada.

**Mutaciones** que el apply ejecuta sobre los cuerpos locales, dentro de una transacción con `ROLLBACK`, y que el gate tiene que detectar con mensaje propio:

- M1: v2 con `p_branch_id` crudo en `sales`;
- M2: la legacy, crudo;
- M3: v2 con `stock_movements` crudo;
- M4: edición sin `COALESCE`;
- M5: backfill sin la pata de movimientos;
- M6: backfill sin la regla de la orden.

**Gate existente que cambia a propósito**: `test_ventas_formulario_sucursal.sql`.

- El bloque 2 pasa de "`NULL` y stock de la default" a "**principal** en `sales` y `stock_movements`, y stock de la principal".
- El bloque 6c pasa de "venta `NULL` y banco en la default" a "venta, movimiento y banco en la **misma** principal".
- El encabezado cita este change.

**Gates que alcanza la reescritura y se corren sin modificarse**: los 23 de `supabase/tests/` que nombran estas funciones. Entre ellos, los que fijan cuerpo, firma o ACL:

- `test_confirm_core_integrity.sql` (3), por subcadenas del cuerpo de la v2;
- `test_cuenta_corriente_party_guard.sql` (3.8-v2) y `test_operacion_party_guard.sql`, por el guard de cliente;
- `test_pos_rpc_signatures.sql` (1d), por una sola firma;
- `test_cobranzas_vencimientos_schema.sql`, por los parámetros;
- `test_ventas_unidades_conversion.sql`;
- `test_function_acl_gate.sql`.

Las dos migraciones se suman **al final** de la cadena de reaplicación de `KPI_Validation.yml` (después de `20261066000001` y de las de `presupuestos-modulo` si ya mergearon). El gate nuevo se cablea como paso propio.

## Risks / Trade-offs

- **[Ventas "en vuelo" durante el deploy]** Una llamada al cuerpo **viejo** que empezó antes del commit de `20261069000001` y commitea después de que corrió el `UPDATE` de `20261069000002` deja una fila `NULL`. → El archivo de funciones va primero (si el CLI aplica cada archivo en su transacción, la ventana es de milisegundos; si los aplica en una sola, es la duración del push). La verificación posterior (tarea 12) cuenta las filas `NULL` creadas después del deploy. Si hay alguna, con OK del PO se re-ejecuta el bloque idempotente del archivo de datos (`npx supabase db query --linked`). Es el único caso que necesita intervención.
- **[Atribución histórica en cuentas cuya principal cambió]** Sus ventas viejas quedan en la principal de hoy (D6). → La migración cuenta las que tienen evidencia de otra sucursal en caja o banco, la fila de auditoría permite revertir o reasignar por id, y OQ-4 deja la alternativa a decisión del PO.
- **[Una venta histórica asignada a la principal, que después se cierra]** No se puede editar ni borrar sin reabrir la sucursal, igual que cualquier venta con sucursal (candidato (i) de #606). Antes se borraba igual porque la reversa caía en la principal del momento. → Se declara. La salida es reabrir, o transferir y volver a cerrar.
- **[Cambio visible del KPI "stock sin rotación" filtrado]** Ver D12. → Se avisa al PO en el humo y en la ficha de `CHANGES.md`.
- **[Volumen del `UPDATE`]** En agosto había 436 filas. Hoy probablemente miles (no medido, no hace falta: D7). Con locks por fila en orden de `id`, bloquea sólo a quien edite o borre una de esas ventas durante la migración. → Aceptado.
- **[Reescritura de ~1.300 líneas de PL/pgSQL]** → Checkpoint 0 contra el cuerpo **vivo** de producción, diff acotado a la tabla de D2, gates de integridad existentes, gate nuevo con mutaciones, y paridad v2/legacy asertada en los bloques 1 y 2.
- **[Orden de despliegue frontend/backend/base]** Seguro en los dos sentidos:
  - frontend nuevo con base vieja: el formulario manda `null` como hoy y la base vieja guarda `NULL`, que el backfill alcanza si commitea antes;
  - base nueva con frontend viejo: el formulario viejo muestra "Sin sucursal (general)" y la base guarda la principal. Es el comportamiento final, con el rótulo viejo durante minutos.

  El backend no cambia de lógica. Igual se verifica que Render redespliegue (el auto-deploy no siempre dispara).
- **[El deploy aborta]** El archivo de datos nunca aborta por datos (D7). El de funciones puede fallar por un error de SQL, y entonces `db push` revierte ese archivo y el de datos no corre. → Se cubre con el humo en el stack local, la reaplicación en CI y el checkpoint 0.

## Migration Plan

1. **Checkpoint 0** (tarea 0, lo ejecuta o autoriza el PO, sólo lectura):
   - leer el `pg_get_functiondef` vivo de producción de las tres funciones (más `c26_default_branch`, `op_stock_movement` y `rpc_reverse_stock_movement`, sólo para leer);
   - compararlo por líneas sin `\r` contra el local y contra `20261062000001`;
   - leer `COMMENT`, ACLs y `MAX(version)`;
   - confirmar que `20261069000001`/`000002` están libres.

   Si algún cuerpo diverge, se reescribe sobre el **vivo** y se documenta.
2. **Merge del PR** (lo mergea el PO, porque lleva una migración de datos). El pipeline (`deploy.yml`) aplica `20261069000001` y después `20261069000002` con `supabase db push`, Vercel despliega el frontend y Render el backend (verificar `GET /deploys`).
3. **Verificación posterior** (tarea 12): cuerpos y ACLs vivos, cero `NULL` creadas después del deploy, residuo igual al informado, cero movimientos `'sale'` en `NULL` de ventas existentes, y humo del PO.

**Rollback:**

- **Funciones**: una migración nueva que re-declara los cuerpos capturados en el checkpoint 0, con su `COMMENT` y sus ACLs. Es reversible sin pérdida, porque con los cuerpos viejos las ventas nuevas vuelven a guardar `NULL`.
- **Datos**: reversibles por id desde `audit_logs`:

  ```sql
  UPDATE sales SET branch_id = NULL
  WHERE id IN (SELECT jsonb_array_elements_text(metadata->'sale_ids')::uuid
               FROM audit_logs WHERE action = 'sales_branch_backfill');
  ```

  Lo mismo para `movement_ids` en `stock_movements`. Sólo con decisión explícita del PO; no está previsto.

## Open Questions

| # | Pregunta | Opciones | Recomendación |
|---|---|---|---|
| OQ-1 | ¿Qué es "la principal"? | (a) La regla vigente, `c26_default_branch`: la sucursal activa y operativa más antigua. (b) Una sucursal principal **configurable**: `accounts.default_branch_id` y una acción "Usar como principal" en `/sucursales`. (c) Por nombre ("Casa Central"). | **(a)**. Ya decide hoy dónde se descuenta el stock y se cobra toda venta, gasto y venta de POS sin sucursal, y es lo que anuncia el aviso de cambio. (b) es una funcionalidad aparte que tocaría la resolución compartida con POS, gastos y compras; queda como candidato. (c) se rompe al renombrar. |
| OQ-2 | ¿Cómo se ve en el formulario de venta? | (a) Sin la opción "Sin sucursal (general)", con la principal elegida de entrada y marcada "(principal)", más el rótulo "Sucursal" (D9). (b) Mantener una opción rotulada "Sucursal principal (Casa Central)". (c) Dejar la interfaz como está. | **(a)**. (b) lista dos opciones que significan lo mismo. (c) deja un rótulo que contradice lo que se guarda. |
| OQ-3 | ¿Y compras y gastos? Comparten el selector, y el pedido fue sólo de ventas. | (a) Fuera de este change, con un **change hermano** `compras-gastos-sucursal-por-defecto`. Cubriría el alta, la edición y los históricos de compras (el mismo argumento aplica: el stock de una compra sin sucursal **entró** en la principal), la edición de gastos y el rótulo de gastos, que hoy dice "Sin sucursal (general)" aunque el alta ya guarda la principal. (b) Incluirlos acá. (c) Dejarlos así. | **(a)**. Mantiene este change del tamaño del pedido y no mezcla una segunda migración masiva (compras) con la de ventas. |
| OQ-4 | Ventas históricas cuyo cobro en caja o banco quedó registrado en **otra** sucursal porque la principal cambió después (por ejemplo, la cuenta del incidente del 22-08). | (a) Van a la principal de hoy, como todas (tu decisión literal), y la migración informa cuántas son. (b) Van a la sucursal que registró la caja o el banco. | **(a)**. (b) es más fiel al pasado, pero esa sucursal puede estar cerrada o desactivada, y esas ventas quedarían sin poder editarse ni borrarse sin reabrirla. **No bloquea el apply**: se aplica (a) salvo indicación contraria. |

Ninguna OQ bloquea el apply. Las cuatro se aplican por su recomendación salvo que el PO diga otra cosa antes del merge.
