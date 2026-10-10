# Design — `ventas-sucursal-por-defecto`

> Governance: **MEDIA con tramo ALTO**. Reescribe las tres funciones que mueven stock, caja y banco en el alta y la edición de ventas, y actualiza en masa una columna de `sales` en producción. Ninguna línea de SQL se escribe antes del checkpoint 0 (cuerpo **vivo de producción**). La migración de datos la mergea el PO.

## Context

### La decisión

El 2026-10-01 el PO decidió *«sí, que las ventas sin sucursal queden con la principal»*. Cuando se le propuso medir antes, preguntó *«¿para qué querés medir?»*. La respuesta está en §"Por qué no hace falta medir antes", y el diseño está armado para no depender de ninguna medición previa.

### Estado actual

Todo lo que sigue está verificado contra el repo (`origin/main` `f61820ac`) y la base local (las 313 migraciones de `main`, `MAX = 20261066000001`; la base local compartida suma además `20261067000001`, aplicada por el apply en curso de `presupuestos-modulo`, que no toca ninguna de estas funciones).

**Alta de venta.** La última definición de `rpc_create_sale_operation_v2` y la del wrapper `rpc_create_sale_operation` están en `supabase/migrations/20261062000001_ventas_unidades_conversion.sql`. El wrapper se redefinió ahí; la definición de `20261022000001` que citaba el brief ya no es la viva.

- **v2** (L330-697):
  - L436-448 valida la sucursal recibida: ajena o inactiva da `P0404`, cerrada da `P0422 branch_closed`.
  - L450: `v_gate_branch := COALESCE(p_branch_id, public.c26_default_branch(v_account_id))`.
  - Con `v_gate_branch` se hace el gate de stock, el descuento `c21_apply_branch_stock_delta`, el opt-in de caja (L634 compara la sucursal de la sesión contra `v_gate_branch`) y el movimiento bancario (L662, `_pay_register_operation_bank_movement(..., v_gate_branch, NULL)`).
  - Pero los `INSERT` guardan **`p_branch_id` crudo**: `sales` en L552 (línea con producto) y L602 (línea de servicio), `stock_movements` en L583.
- **Wrapper** (L2629-2957; desde L2959 sigue DDL ajeno a la función, §8 de esa migración): lee el flag `sale_items_rpc_v2` (L2669). Sin fila, el flag vale `true` (L2671) y delega en la v2. Con `false` ejecuta una **rama legacy** completa, con el mismo `COALESCE` (L2760) y los mismos tres `INSERT` crudos (L2858, L2877, L2890).
- **Edición**: `rpc_atomic_update_sale_operation`, redefinida por última vez en `20261070000001_remitos_venta_conversion.sql` (remitos-venta tanda B: suma el guard `delivery_note_sale_locked` P0423 antes del bloque fiscal). **Corregido en el apply (2026-10-09)**: la propuesta la citaba en `20261062000001` (L1594-2260), donde ya no es la viva; las referencias de línea de `20261062000001` valen sólo para la v2 y el wrapper.
  - Tri-estado de sucursal (el bloque que fija `v_final_branch_id`, verificado contra el cuerpo vivo): `p_branch_provided` con valor reimputa (valida `P0422 branch_invalid`), con `NULL` desimputa, y sin informar conserva `v_old_branch_id`.
  - La pata REVERSE devuelve el stock a `v_old_sale.branch_id`.
  - La pata APPLY y los dos `INSERT` en `sales` usan `v_final_branch_id`.
  - `op_stock_movement` ya escribe `COALESCE(p_branch_id, c26_default_branch(...))` en `stock_movements.branch_id`, así que en la edición sólo la **fila de venta** puede quedar `NULL`.
  - El gate de stock de la edición es **global** (`Σ branch_stock`).
- **Integridad de función en la última reescritura**: `20261062000001` abre con un bloque `DO` de *preflight* (L107-170) que compara `md5(replace(prosrc, E'\r', ''))` de sus diez funciones contra dos listas: el cuerpo de partida (`v_expected`, verificado contra producción el 2026-09-25) y el que ella deja (`v_rewritten`, L142-146). Si no coincide ninguno, aborta. En la base local, la v2 y el wrapper miden exactamente su `v_rewritten` de `20261062000001` (v2 `23f9f29a…`, wrapper `577f86d2…`). **Corregido en el apply**: el cuerpo de partida de la edición ya no es el `e8687db5…` de `20261062000001` sino el de `20261070000001`, `ae7e818e3ef9328c62ea0cf1a7c74b5c`; el orquestador verificó el `md5(replace(prosrc, E'\r', ''))` de las tres funciones contra **producción** el 2026-10-09 (321 migraciones, `max(version) = 20261074000001`) y coincide con el local.
- **Sucursal principal**: `c26_default_branch(uuid)` (`20260625000001_c26_branch_as_root.sql:135`, `STABLE`) devuelve la sucursal más antigua con `is_active AND status = 'active'` por `created_at ASC`. Si no hay ninguna, devuelve la más antigua a secas, aunque esté inactiva o cerrada. No tiene desempate. `COMMENT`: *"C-26: branch default operativa de una cuenta…"*.
- **Baja de sucursales**: sólo `rpc_close_branch` impide dejar a la cuenta sin sucursal operativa (`P0409 last_active_branch`). `rpc_deactivate_branch` (la invoca `frontend/hooks/data/use-branches.ts:217`) sólo exige que la sucursal esté vacía (`_branch_assert_empty`), y `trg_guard_branch_decommission` tampoco cuenta las restantes. Una cuenta sin stock, sin caja abierta y sin transferencias puede desactivar **todas** sus sucursales; entonces `c26_default_branch` devuelve su fallback, una sucursal inactiva.
- **Reversas**:
  - `rpc_delete_sale_operation` (viva en `20261061000001`) repone el stock con `rpc_reverse_stock_movement`, que usa `stock_movements.branch_id` del movimiento original y, **desde `20261074000001` (stock-ledger-solo-rpc tanda B, corregido en el apply)**, aplica el delta con `_stock_apply_delta` (ya no con `rpc_apply_product_stock_delta`, que ahora es un envoltorio de `_stock_manual_adjustment`) y escribe el contramovimiento con el `branch_id` del movimiento **original** (un `NULL` sigue `NULL`). Con `NULL`, `_stock_apply_delta` resuelve la principal **vigente al momento del borrado** (`c26_default_branch`). Con una sucursal explícita, sólo la busca por `id` y `account_id` y sólo rechaza `status = 'closed'` (`P0422 branch_closed`): **no mira `is_active`**. `rpc_delete_sale_operation` (redefinida por `20261070000001`) además no repone el stock de una venta nacida de un remito (la mercadería sigue retenida por el remito) y exige la sucursal del remito activa y abierta (`delivery_note_branch_inactive` P0422). Una sucursal **desactivada** (`is_active = false`, `status = 'active'`) recibe el stock sin error. `rpc_deactivate_branch` sólo exige que la sucursal esté vacía al desactivarla, nada impide que después le vuelva a entrar stock, y no existe ninguna RPC de reactivación (las de sucursal son `rpc_create_branch`, `rpc_open_branch`, `rpc_close_branch` y `rpc_deactivate_branch`). Ese stock no se ve ni se vende (`useBranches` filtra `is_active`): es la clase del incidente del 22-08. Hoy le pasa a toda venta con sucursal **elegida**; con `NULL`, la reversa cae en la principal operativa.
  - La edición devuelve a `sales.branch_id`, que con `NULL` vuelve a caer en `op_stock_movement` → principal vigente (verificado contra el cuerpo vivo: `op_stock_movement` sigue escribiendo `COALESCE(p_branch_id, c26_default_branch(...))`).
  - **No toda venta `NULL` tiene su movimiento en `NULL`.** `op_stock_movement` escribe `COALESCE(p_branch_id, c26_default_branch(...))` en el movimiento, así que la pata APPLY de toda edición de una venta `NULL` dejó un movimiento `'sale'` con la principal **de aquel momento**. Además, `scripts/sql/backfill_stock_movements_operaciones.sql` (L103, ejecutado el 2026-08-19) insertó los movimientos `'sale'` de las operaciones editadas con el mismo `COALESCE`. Para esas ventas, el borrado repone en la sucursal **registrada en el movimiento**, no en la principal vigente.
- **Ledger de stock**: RN-21 (`knowledge-base/05_reglas_de_negocio.md:120`) y `openspec/specs/inventory-single-ledger/spec.md` (L179, L202, L242, L253) declaran `stock_movements` *append-only*: toda corrección es un movimiento nuevo. El PO ya aplicó esa regla a la historia: los 139 huérfanos de `stock-movements-edicion` quedaron «sin tocar» y los `unit_cost_snapshot` previos quedaron nulos. Completar `branch_id` en movimientos existentes es una excepción a esa regla (OQ-5).
- **Otros caminos de venta**: en el servidor persisten la sucursal resuelta y no se tocan. Son `rpc_quick_sale` (`COALESCE` + `P0422 no_branch_found` si no hay ninguna), `_c29_confirm_order_core` (toma la sucursal de la orden, `sales_orders.branch_id NOT NULL`) y `rpc_accept_quote`.
- **El POS en el cliente** sí toma "la principal" por su cuenta: `app/(dashboard)/ventas/pos/page.tsx:166` hace `activeBranch = branches[0]`. Con esa sucursal busca la caja y la sesión (L168), arma el enlace «Ir a caja de …» (L744-749) y la manda **explícita** como `branch_id` (L618). Si la sucursal más antigua está cerrada, el POS manda esa y `_c29_confirm_order_core` rechaza con `P0422 branch_closed`.
- **"Facturar venta manual"** (`rpc_promote_legacy_sale_to_order`, viva en `20261061000001`): resuelve `COALESCE(sales.branch_id, c26_default_branch)` para la **orden**, pero no actualiza `sales.branch_id`. Su helper `_sales_order_sync_from_operation` levanta `P0422 operation_inconsistent` si las filas de una operación mezclan `NULL` y no-`NULL`.
  - La promoción **no valida que la sucursal opere**: sólo rechaza `NULL` (`P0422 no_branch_found`, L103-109 de su `pg_get_functiondef` local). Hoy una venta `NULL` se promueve a la principal **operativa** del momento. Una venta con sucursal escrita se promueve a esa sucursal aunque después se haya cerrado o desactivado, y la orden, la factura y las notas de crédito quedan allí.
- **Una venta facturada es inmutable.** `_fiscal_void_pending_for_sale_edit` es el **primer** paso de `rpc_atomic_update_sale_operation` y de `rpc_delete_sale_operation`. Levanta `P0423` cuando el comprobante está `authorized` y también cuando está `pending_cae` con marca de envío (`cae_submit_started_at` o `cae_submit_unconfirmed_at`), L67-85 de su `pg_get_functiondef` local. `_sales_order_sync_from_operation` rechaza con `sales_order_has_live_invoice` una orden con comprobante vigente. Para esas operaciones no hay próxima edición ni borrado: la orden **nunca** se vuelve a sincronizar con la venta. Sólo una orden sin comprobante, o con uno `rejected`, `voided` o `pending_cae` sin marca, se re-sincroniza al editar la venta (`branch_id = COALESCE(v_hdr.branch_id, so.branch_id)`).
- **Notas de crédito**: `reporting_credit_notes_in_window` las imputa por `sales_orders.branch_id` (`so.branch_id = p_branch_id`), como pide `reporting-invariants` (la NC va a la sucursal de su documento de origen). Los ingresos se imputan por `sales.branch_id`. Si venta y orden quedan en sucursales distintas, con el Tablero filtrado la venta suma en una sucursal y su NC resta en otra.
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
  - `components/branches/BranchSelect.tsx` lo comparten la venta, la compra, el gasto y el importador de gastos. No se renderiza sin el módulo de sucursales (`return null`, L29). Sólo acepta `value`, `onChange`, `placeholder` y `className` (L9-14): no tiene `id` ni rótulo propio. Su primera opción vale `null` y lleva el texto del `placeholder`: "Sin sucursal (general)" por defecto (L23), y "Sin sucursal por defecto" en el importador de gastos (`expense-import-dialog.tsx:691`). El patrón canónico del proyecto pone el rótulo **dentro** del selector, con `useId` (`PaymentMethodSelect.tsx:95-108`, `CostCenterSelect.tsx`).
  - Radix `Select` sólo emite `onValueChange` cuando el valor **cambia** (`@radix-ui/react-use-controllable-state`: `if (value2 !== prop)`, verificado en las versiones 1.1.0 y 1.2.2 instaladas).
  - `hooks/data/use-branches.ts` lista las sucursales con `is_active = true` ordenadas por `created_at`, **sin filtrar `status`**.
  - `hooks/use-cash-optin.ts:103` (`effectiveBranchId = branchId || branches[0]?.id`), `hooks/use-default-branch-notice.ts:49` y el POS (`ventas/pos/page.tsx:166`) toman `branches[0]` como "la principal". Si la sucursal más antigua está **cerrada**, el cliente la toma como principal y el servidor (`c26_default_branch`, que exige `status = 'active'`) no.
  - `useCashOptin` tiene **cinco** consumidores: venta (`sale-form.tsx:265`), compra (`purchase-form.tsx:214`), gasto (`expense-form-v2.tsx:70`), cobro de cuenta corriente (`customer-accounts/RegisterPaymentForm.tsx:76`) y pago a proveedor (`supplier-accounts/RegisterPaymentMadeForm.tsx:67`); los dos últimos con `branchId: null`. El servidor no valida la sesión igual en todos: venta y gasto la comparan contra la sucursal efectiva (`COALESCE`); cobro y pago sólo exigen una sesión abierta; la **compra** la compara contra `p_branch_id` **crudo** (`20261062000001`, bloque del opt-in de `rpc_create_purchase_operation`, L1037-1057). Una compra sin sucursal elegida ve el opt-in ofrecido por el hook, y el servidor lo rechaza siempre con `P0422 cash_optin_requires_open_session`. Es preexistente, y `__tests__/components/purchase-form-cash-optin.test.tsx:204-213` (con `BranchSelect` mockeado a `null`) fija ese payload.
  - `no_branch_found` ya se traduce en cuatro lugares, con textos distintos: el POS (`ventas/pos/page.tsx:100`), `hooks/data/use-promote-to-order.ts:49`, `hooks/data/use-quotes.ts:74` y `hooks/data/use-sales-orders.ts:172`. `lib/operation-errors.ts` lo deja pasar a propósito, y `__tests__/lib/operation-errors-branch.test.ts:44-49` lo fija.
  - El formulario de venta valida y muestra «Stock insuficiente (disponible: N)» con el stock **agregado** de la cuenta (`selectedProduct.stock`, `sale-form.tsx:405` y `:470-471`): candidato (c) de #606.
- **Precedentes**:
  - Gasto (`gastos-forma-pago` D6): el alta persiste el `COALESCE`, los 175 gastos históricos no tienen backfill y la edición (`rpc_update_expense`) todavía permite desimputar.
  - Compra (`caja-compras-cobranzas` D3): persiste `p_branch_id` crudo y no tiene backfill.
  - Ventas: el fix #606 dejó los bloques 2 y 6 de `supabase/tests/test_ventas_formulario_sucursal.sql` fijando el contrato "sin sucursal → `NULL`" **para que este change los cambie a conciencia**. Hasta #606 (2026-10-01) el formulario **descartaba** la sucursal elegida: toda venta del formulario quedó `NULL` aunque el usuario hubiera elegido otra sucursal, y su stock salió de la principal del momento (`CHANGES.md:3891`).
  - CI: **corregido en el apply (2026-10-09)**. La propuesta decía que `KPI_Validation.yml` reaplicaba `20261062000001` después de la reconvergencia y que este change tenía que retirar ese bloque. Ya lo retiró remitos-venta tanda B (`20261070000001`, cumpliendo la regla que el propio workflow dejó escrita: una migración posterior que redefina cualquiera de sus diez funciones hace abortar ese preflight). La cadena termina hoy con un segundo `supabase db reset` (remitos-compra) y los reapply de `20261070000001` y `20261071000001`; el de `20261070000001` **re-instala el cuerpo de `rpc_atomic_update_sale_operation` y su COMMENT**, que este change reescribe.
  - `presupuestos-modulo` (propose en `main`, apply en curso) reserva `20261067000001`/`20261068000001` y no toca ninguna de las diez funciones. Pero su apply suma dos consumidores de `BranchSelect`: `QuoteForm` y `ConvertQuoteDialog`, y este último **registra una venta** («`BranchSelect` con el default», su `tasks.md:239` y `design.md:461`). Además migra la lógica de carrito de `sale-form.tsx` a `lib/cart-utils.ts` (su `tasks.md:118-124`), así que los dos changes tocan `sale-form.tsx`.

### Por qué no hace falta medir antes

Lo que se quería medir servía para **elegir** entre dejar las ventas históricas, asignarlas todas, o asignar sólo las de cuentas con una única sucursal. El PO ya eligió: asignarlas. Con esa decisión tomada, ningún número cambia lo que hay que hacer:

1. **La migración resuelve todos los casos sin intervención** (D6): sin ningún dato extra decide qué hacer con cuenta de una sucursal, cuenta de varias, operación mixta, venta cuyo movimiento ya registró una sucursal, venta facturada a mano (con o sin comprobante vigente), sucursal no operativa y fila sin cuenta. Lo que el PO firma antes de escribirla son las **reglas** (OQ-4, OQ-5 y OQ-6), no números: ningún conteo cambia cuál regla es la correcta.
2. **La migración se autoinforma**: emite `NOTICE` con los conteos por regla, el residuo que no pudo asignar, las discrepancias que deja (venta ≠ movimiento, venta ≠ orden), los movimientos que no completó por no poder demostrar su origen y cuántas ventas tenían evidencia de otra sucursal en caja o banco. Además deja una fila de auditoría por cuenta (D7). Nadie tiene que contar nada a mano para saber qué pasó.
3. **El orden de magnitud ya se conoce**: el 75 % de las filas de `sales` estaba sin sucursal, y en agosto había una sola cuenta con más de una sucursal. Para todas las demás cuentas "la principal" es su única sucursal: no hay ambigüedad posible.
4. **Lo único que se corre en producción son verificaciones posteriores** (tarea 12): tres `SELECT` que confirman que no quedó nada sin asignar. No deciden nada; confirman.

### Medición en producción (2026-10-01, posterior a la redacción de este diseño)

Después de escrito lo anterior, el PO pidió medir igual («sí, medí también»). Se corrieron dos consultas de **sólo lectura y sólo agregados** contra producción. No cambian ninguna regla de D6; le ponen tamaño a las preguntas OQ-4, OQ-5 y OQ-6 y actualizan el punto 3 de arriba (hoy son **dos** las cuentas con más de una sucursal, no una).

| Tipo de cuenta | Cuentas con ventas | Filas de `sales` | Sin sucursal | Operaciones sin sucursal | Filas sin sucursal, últimos 30 días |
|---|---|---|---|---|---|
| Una sola sucursal | 7 | 610 | 392 | 159 | 248 |
| Dos o más sucursales | 2 | 495 | 488 | 246 | 78 |
| **Total** | **9** | **1.105** | **880 (80 %)** | **405** | **326** |

Las 9 cuentas que venden tienen ventas sin sucursal. La primera es del 2026-03-07 y la última del día de la medición.

Detalle de las dos cuentas con más de una sucursal (sin identificarlas):

| Cuenta | Sucursales (activas) | Segunda sucursal desde | Sucursales con stock | Operaciones sin sucursal | Anteriores a la segunda sucursal | Posteriores | Operaciones con sucursal |
|---|---|---|---|---|---|---|---|
| A | 2 (2) | 2026-06-22 | 1 | 16 | 6 | 10 | 2 |
| B | 3 (1) | 2026-08-22 | 1 | 230 | 162 | 68 | 2 |

Lectura:

- **Las 7 cuentas de sucursal única (392 filas, 159 operaciones) no tienen ambigüedad**: "la principal" es su única sucursal, hoy y cuando se hizo cada venta.
- **En las dos cuentas con varias sucursales el stock vive en una sola**, así que el stock de esas ventas salió de la principal de aquel momento.
- **La cuenta B es la del incidente del 22-08** (sucursal original desactivada y stock migrado a otra): sus 162 operaciones anteriores a la segunda sucursal ocurrieron en una sucursal que hoy está inactiva. Es el caso concreto detrás de OQ-4 (a qué sucursal van) y de OQ-5 (qué movimientos de stock se pueden completar con origen demostrable): con las opciones recomendadas, esas ventas van a la principal de hoy y sus movimientos de stock nulos **no** se completan, porque la sucursal que se les asigna no existía cuando ocurrieron (la única de entonces era otra, hoy inactiva). Los contadores que la migración ya informa (D7) son los que le muestran ese número al PO.
- **La cuenta A tiene las dos sucursales activas** y 10 operaciones sin sucursal posteriores a la segunda: son las únicas donde el usuario pudo haber elegido la otra sucursal y el formulario la descartó (defecto corregido en #606).

## Goals / Non-Goals

**Goals:**

1. Ninguna venta **nueva ni editada** queda con `sales.branch_id = NULL`. La sucursal guardada es, por construcción, **la misma variable** con la que se descontó el stock y, en el alta, con la que se validó el stock y se resolvieron la caja y el banco (la edición conserva su gate de stock global, Non-Goals). Las tres funciones del alcance son las únicas que escriben ventas sin sucursal desde la aplicación; los dos `rpc_atomic_create_sale` legacy (sólo `service_role`, sin llamadores) quedan como excepción nombrada hasta D8.
2. Las ventas **históricas** con `branch_id NULL` pasan a la principal, salvo que su operación ya tenga asentada otra sucursal (en otras filas, en su orden facturada a mano o en su movimiento de stock; D6). Si el PO acepta la excepción a RN-21 (OQ-5), sus movimientos de stock nulos toman la misma sucursal **sólo donde se puede demostrar que de ahí salió el stock**. Todo de forma idempotente, trazable y sin disparar efectos laterales.
3. En el formulario de venta, la opción "Sin sucursal (general)" deja de existir y la principal se ve como lo que es.
4. Una sola definición de "la principal" en el cliente, idéntica a la del servidor, para todos los que hoy la toman de `branches[0]`: el selector, el opt-in de caja, el aviso de cambio y el POS.
5. Cero regresiones: POS, órdenes, presupuestos, compras, gastos, borrado, edición con sucursal explícita, gates de integridad, firmas y ACLs.

**Non-Goals:**

- **Compras**: el alta y la edición siguen guardando `NULL` si no se elige sucursal. Las compras históricas no se tocan. Tampoco se corrige el opt-in de caja de una compra sin sucursal, que el hook ofrece y el servidor rechaza siempre (preexistente, Context). Todo va al change hermano (OQ-3).
- **Gastos**: la edición todavía puede desimputar, y la opción "Sin sucursal (general)" del formulario de gasto ya miente, porque el alta guarda la principal. Va al change hermano (OQ-3).
- **`NOT NULL` o `CHECK` sobre `sales.branch_id`** (D8: candidato posterior).
- **Validar el stock de la edición contra la sucursal efectiva** (candidato (d) de #606). La edición conserva su gate global.
- **Mostrar en el formulario el stock de la sucursal efectiva** (candidato (c) de #606). El formulario sigue validando y mostrando «Stock insuficiente (disponible: N)» con el stock agregado de la cuenta. Con la principal a la vista, el usuario puede ver un «disponible» que suma otras sucursales y recibir `P0409` del servidor contra la principal. Se avisa en el humo (H1).
- **Guard de "última sucursal operativa" en `rpc_deactivate_branch`**: hoy no existe (Context). Este change sólo hace que la venta rechace ese estado (D3); el guard en el ciclo de vida de sucursales queda como candidato.
- **Qué hacen la reversa y "Facturar venta manual" cuando la sucursal guardada de una venta deja de operar** (OQ-8): hoy la reversa repone en una sucursal desactivada y la promoción crea la orden en una sucursal cerrada o desactivada. Le pasa ya a toda venta con sucursal elegida, y este change lo extiende a todas. Se declara, el gate lo ejecuta y queda como candidato.
- **Unificar las traducciones de `no_branch_found`** del POS, órdenes, presupuestos y promoción: este change sólo agrega la del formulario (tarea 6.3).
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
| `rpc_create_sale_operation_v2` | `sales.branch_id` (L552, L602) y `stock_movements.branch_id` (L583) pasan de `p_branch_id` a `v_gate_branch`. Después de L450 y **antes** del `INSERT` en `operation_idempotency`, cuando `p_branch_id IS NULL`: si `v_gate_branch` es `NULL` o la sucursal resuelta no está operativa (`is_active AND status = 'active'`), `RAISE 'no_branch_found…' USING ERRCODE = 'P0422'` (D3). Una sucursal **elegida** sigue validándose como hoy (L436-448). |
| `rpc_create_sale_operation` (rama legacy, `v_flag_on = false`) | Los mismos tres cambios (L2858, L2877, L2890) y el mismo guard después de L2760. La rama v2 del wrapper (delegación) no cambia. |
| `rpc_atomic_update_sale_operation` | Después del bloque tri-estado y **antes del REVERSE**: si `v_final_branch_id` quedó `NULL`, `v_final_branch_id := public.c26_default_branch(v_account_id)` y el mismo guard `P0422 no_branch_found` (resuelta `NULL` o no operativa). La validación de una sucursal explícita (`P0422 branch_invalid`) no cambia, y una sucursal vigente no nula se preserva sin revalidar, como hoy. La pata REVERSE sigue devolviendo a `v_old_sale.branch_id`. |

Reglas de la reescritura:

- Se parte del `pg_get_functiondef` **vivo de producción**.
- La migración abre con un bloque `DO` de **preflight**, molde de `20261062000001` L107-170:
  - `v_expected`: el `md5(replace(prosrc, E'\r', ''))` de partida de cada función, confirmado contra producción en el checkpoint 0.2 (local y producción, verificados el 2026-10-09: `23f9f29a…`, `577f86d2…` y, para la edición, `ae7e818e…`: ver la corrección de «Estado actual»). Tiene que ser también el cuerpo que dejan los **archivos** de migración, porque CI y todo stack local construyen la base desde ellos: si producción diverge de los archivos, ver Migration Plan;
  - `v_rewritten`: el que deja esta migración, medido en el stack local después de aplicarla;
  - si el cuerpo vivo no es ninguno de los dos, `RAISE EXCEPTION` sin reescribir nada. Así una migración intermedia que nadie reconcilió aborta el `db push` en vez de pisarse en silencio;
  - si ya es el reescrito, `NOTICE 'ventas-sucursal-por-defecto: % ya es el cuerpo de esta migración (reaplicación)'`, que la reaplicación de CI cuenta (D13).
- `CREATE OR REPLACE` con la misma firma: sin `DROP`, sin overload y sin `42725`.
- Se re-declara el `COMMENT` vivo. Sólo la edición tiene uno; la v2 y el wrapper no tienen, y eso se verifica en el checkpoint. El de la edición dice «preserva branch_id/canal/unit_id al editar (F1, tri-estado para branch_id/canal)», que deja de ser cierto para un `branch_id` nulo de la venta: se conserva el texto vivo completo y se le agrega al final la excepción de D5 («ventas-sucursal-por-defecto: un branch_id nulo, vigente o informado, se resuelve a la principal»). Ningún gate fija ese texto (verificado con grep en `supabase/tests/`).
- Se re-emiten las ACLs vivas: `authenticated` y `service_role` con `EXECUTE`, `anon` sin `EXECUTE`.
- El diff contra el cuerpo vivo tiene que ser **exactamente** los cambios de esta tabla y un comentario de cabecera por función.
- *Alternativa — helper `_sale_effective_branch(account, branch)`*. **Rechazada**: la parte compartida es una línea (`COALESCE` sobre la función canónica). La validación de la sucursal explícita difiere entre el alta (`P0404`/`P0422 branch_closed`) y la edición (`P0422 branch_invalid`), y un helper más sumaría una entrada al gate de ACLs (chequeo (4)) sin quitar duplicación real.
- *Alternativa — seguir insertando el movimiento de una venta nueva con `p_branch_id` crudo*. **Rechazada**: la reversa del borrado lee la sucursal **del movimiento**. Si la venta queda en A y su movimiento en `NULL`, el borrado repone en la principal vigente en ese momento, que puede no ser A. Para los movimientos **nuevos** no hay tensión con RN-21: el valor se escribe una única vez, en el `INSERT`, y es exactamente la sucursal de la que salió el stock. Los movimientos históricos son otro asunto (D6, OQ-5). Costo declarado: con el movimiento en A, si A se vacía y se **desactiva** después, borrar la venta repone el stock en A desactivada (Context, "Reversas"); con `NULL` caía en la principal operativa. Es lo que ya le pasa hoy a toda venta con sucursal elegida, y se decide en OQ-8.

### D3 — Sin sucursal operativa a la cual resolver: `P0422 no_branch_found`

Cuando la venta no trae sucursal y la principal resuelta **no existe o no está operativa**, el alta y la edición fallan con `P0422 no_branch_found`. Es el mismo token y el mismo código que usan `rpc_quick_sale` y `rpc_promote_legacy_sale_to_order` **cuando la cuenta no tiene ninguna sucursal** (los dos sólo miran si `c26_default_branch` devuelve `NULL`). Con sucursales pero ninguna operativa, esos dos caminos se comportan distinto: el POS termina en `P0404 branch_not_found` o `P0422 branch_closed` (`_c29_confirm_order_core` L222/L226) y la promoción pasa con el fallback no operativo (Context). Hay dos estados:

- **Cuenta sin ninguna sucursal** (`c26_default_branch` devuelve `NULL`). Es inalcanzable por la interfaz: el aprovisionamiento crea "Casa Central" y las sucursales no se pueden borrar. Hoy, en ese estado, una venta con producto falla con `P0409` (el gate busca stock en una sucursal `NULL`) y una sólo de servicios **pasa con `NULL`**.
- **Cuenta sin ninguna sucursal operativa** (todas inactivas o cerradas). Es **alcanzable**: `rpc_deactivate_branch` no impide desactivar la última (Context). `c26_default_branch` devuelve entonces su fallback, una sucursal inactiva o cerrada. Hoy la venta descuenta el stock de esa sucursal (si lo tiene) y una de servicios pasa con `NULL`. Persistir ese fallback dejaría la venta en una sucursal que el formulario no lista y que la edición rechaza (`branch_invalid`).

Rechazar los dos estados es coherente con cómo se valida una sucursal **elegida**: inactiva da `P0404` y cerrada da `P0422 branch_closed`. Una venta nunca queda, por resolución implícita, en una sucursal que el usuario no podría elegir. Es un cambio de comportamiento sólo en el segundo estado de borde, y el formulario traduce el error con la salida: crear o reabrir una sucursal (tarea 6.3).

- *Alternativa — crear "Casa Central" al vuelo, como hace `c21_apply_branch_stock_delta`*. **Rechazada**: que una venta cree una sucursal es un efecto lateral oculto, y el POS, que es el camino de más volumen, ya eligió rechazar.
- *Alternativa — persistir el fallback inactivo o cerrado*. **Rechazada** por lo de arriba: la venta quedaría sin poder editarse desde el formulario.
- *Alternativa — agregar a `rpc_deactivate_branch` el guard de última sucursal operativa*. Fuera de alcance: toca el ciclo de vida de sucursales (`branch-decommission-guard`). Queda como candidato.

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

**BREAKING (contrato interno, OQ-7)**: el escenario "desimputar" del contrato tri-estado deja de aplicar a la sucursal de la **venta**, y el requirement «La edición de una operación preserva el contexto de su header» deja de preservar un `branch_id` vigente **nulo** de una venta. Los dos requirements de `operation-edit-context` declaran la excepción en su delta, para que la spec sincronizada no quede con dos SHALL incompatibles. Siguen igual el canal de la venta, todo el contrato de la compra y el del gasto. El requirement del gasto (`expense-operation`, «La edición de un gasto preserva su contexto mediante contrato tri-estado») remite al contrato «ya vigente en ventas y compras» y afirma que el nulo explícito desimputa: un delta de `expense-operation` le agrega la excepción de la venta, sin cambiar el comportamiento del gasto. No hay consumidor que dependa de desimputar: el formulario no podrá elegir "sin sucursal" (D9) y un `PUT /sales/{id}` con `branch_id: null` pasa a guardar la principal, que es exactamente la decisión del PO.

### D6 — Ventas históricas: a la principal, salvo que la operación ya tenga asentada otra sucursal

> Las reglas de esta decisión, la excepción a RN-21 y la precedencia entre movimiento y orden son decisiones del PO (OQ-4, OQ-5 y OQ-6) y **bloquean el grupo 3**: el apply no escribe la migración de datos sin su OK textual.

**Unidad de resolución: la operación** (`COALESCE(operation_id, id)`). Todas las filas `NULL` de una operación toman la misma sucursal. Resolver fila por fila podría dejar una operación mixta: una línea de servicio no tiene movimiento de stock, así que la regla del movimiento la saltearía y caería en otra sucursal. Y `_sales_order_sync_from_operation` rechaza con `P0422 operation_inconsistent` una operación con filas de distinta sucursal, o que mezcla `NULL` y no `NULL`.

**Reglas, en orden de precedencia.** Para cada operación con filas `branch_id IS NULL` y `account_id IS NOT NULL`, gana la primera regla que dé una sucursal.

- **Filtro de sucursal operativa** (`is_active AND status = 'active'`), sólo en las reglas 3, 4 y 5. Una regla que da una sucursal no operativa se saltea y se cuenta (`salteadas_no_operativa`): asignar una sucursal cerrada o inactiva dejaría la venta sin poder editarse desde el formulario (la edición manda la sucursal precargada y recibe `branch_invalid`), cuando hoy se edita.
- **Las reglas 1 y 2 no pasan por ese filtro.** La operación ya vive en esa sucursal (regla 1) o ya es inmutable (regla 2), así que asignar las filas nulas no cambia si la venta se puede editar. Cualquier otra elección dejaría la operación mixta, o la venta separada de su factura, para siempre. Esas asignaciones a una sucursal no operativa se cuentan aparte (`mixta_no_operativa`, `orden_facturada_no_operativa`).

1. **Operación mixta**: las filas no nulas de la misma operación tienen **exactamente una** sucursal. La operación es de una sola sucursal y así se cura el `P0422 operation_inconsistent` de "Facturar venta manual". Va primera porque cualquier otra elección dejaría la operación mixta para siempre. Con dos o más sucursales distintas no se elige ninguna y se pasa a la regla 2. (Una operación mixta no puede tener orden: la promoción la rechaza por `operation_inconsistent`.)
2. **Orden con comprobante vigente** (OQ-6): hay una `sales_orders` con `sale_operation_id = operation_id` (índice único `sales_orders_sale_operation_id_uq`), de la misma cuenta, cuyo comprobante está `authorized`, o `pending_cae` con marca de envío (`cae_submit_started_at` o `cae_submit_unconfirmed_at`). La venta toma **la sucursal de la orden**. Esa venta es inmutable (`P0423` en el primer paso de la edición y del borrado), y la orden nunca se vuelve a sincronizar con ella (Context). Si quedaran en sucursales distintas, quedarían así para siempre, y con el Tablero filtrado la venta sumaría en una sucursal y sus notas de crédito restarían en otra (`reporting_credit_notes_in_window`, spec `reporting-invariants`). Al no poder borrarse ni editarse, su movimiento de stock no se revierte mientras el comprobante siga vigente.
3. **Movimiento de stock propio** (OQ-6): los movimientos `type = 'sale'`, `reference_type = 'sale'`, con `reference_id` igual a una fila `NULL` de la operación y `branch_id` no nulo, registran **exactamente una** sucursal. Es donde quedó asentada la salida del stock (la pata APPLY de una edición o el backfill del 2026-08-19, Context) y es donde el borrado repone. Es el mismo principio de D1: la sucursal de la venta es la que movió el stock. Así, borrar y editar la venta devuelven el stock al mismo lugar.
4. **Orden sin comprobante vigente**: hay una `sales_orders` de la operación sin comprobante, o con uno `rejected`, `voided` o `pending_cae` sin marca. La venta toma la sucursal de la orden. Hoy coincide con la principal salvo que esta haya cambiado después de facturar, y la promoción funciona recién desde #585 (2026-09-25). Esta venta sí se edita, y la edición re-sincroniza la orden con la venta (Context). Por eso, cuando ganó la regla 3 con otra sucursal, la orden queda distinta sólo hasta la próxima edición, y se cuenta (`discrepancia_orden`).
5. **Resto**: `c26_default_branch(account_id)` **vigente al aplicar la migración**, si está operativa.

**Residuo.** Quedan `NULL`, se informan con `NOTICE` y la migración no aborta:

- las filas sin `account_id`;
- las de una cuenta sin sucursal;
- las de una cuenta sin sucursal operativa (todas inactivas o cerradas), salvo que las reglas 1 o 2 les den una sucursal. Para el resto, `c26_default_branch` sólo da su fallback no operativo.

**Movimientos de stock (sujeto a OQ-5).** El stock de una venta sin sucursal salió de la principal **del momento de la venta** (`v_gate_branch` del alta), no necesariamente de la sucursal que asigna esta migración. Coinciden en la regla 5 cuando la principal no cambió desde la venta. Pueden no coincidir en las reglas 1, 2 y 4, y en toda cuenta cuya principal cambió, como la del incidente del 22-08. Completar el movimiento con una sucursal de la que el stock no salió falsearía el ledger. Además rompería el «Invariante de reconstrucción» por `(product_id, branch_id)` de `inventory-single-ledger`: borrar la venta repondría el stock en una sucursal donde nunca estuvo, y la sucursal de origen quedaría con faltante para siempre.

Con la recomendación de OQ-5, la (c), la migración completa `branch_id` sólo en los movimientos que cumplen todo esto:

- `type = 'sale'`, `reference_type = 'sale'` y `branch_id IS NULL`;
- son de ventas vivas asignadas en esta corrida;
- su **origen es demostrable**: cuando se escribió el movimiento (`stock_movements.created_at`), la sucursal asignada ya existía y era la **única** de la cuenta (ninguna otra sucursal de la cuenta tiene `created_at` menor o igual al del movimiento). `c26_default_branch` no pudo devolver otra, así que de ahí salió el stock.

En la práctica cubre a toda cuenta de una sola sucursal (en agosto, todas menos una). El resto queda `NULL` y se cuenta (`movimiento_origen_incierto`). Su borrado sigue reponiendo, como hoy, en la principal vigente al borrar, que es la de origen mientras la principal no cambie.

Sólo se completa `branch_id`: ninguna otra columna cambia, y cada id queda en la auditoría (D7). La excepción queda escrita en `inventory-single-ledger` (requirement nuevo) y en RN-21 (tarea 10.2). Con la opción (a) se completarían todos con la sucursal asignada; con la (b), ninguno.

**Discrepancias que la migración deja y cuenta.**

- **Venta ≠ movimiento** (`discrepancia_movimiento`): una venta asignada por las reglas 1, 2, 4 o 5 cuyo movimiento `'sale'` ya registraba **otra** sucursal. Pasa, por ejemplo, si la regla 3 se salteó porque esa sucursal está cerrada, o si mandaron la operación mixta o la orden facturada. Esos movimientos no se tocan. En esas ventas, el borrado repone en la sucursal del movimiento y la edición en la de la venta, igual que pasa hoy entre la principal vigente y la registrada. En las de la regla 2 no hay borrado ni edición mientras el comprobante siga vigente.
- **Venta ≠ orden** (`discrepancia_orden`): una venta con orden **sin** comprobante vigente, asignada por la regla 3 a una sucursal distinta de la de su orden. La orden no se toca (`sales_orders` queda fuera del backfill) y se re-sincroniza en la próxima edición de la venta. Mientras tanto, con el Tablero filtrado, una nota de crédito de esa orden restaría en la sucursal de la orden. Con orden **con** comprobante vigente esta discrepancia no puede darse, porque manda la regla 2.
- **Ventas sin movimiento completado** (`movimiento_origen_incierto`): ver el párrafo anterior.

**Qué no se toca:**

- los movimientos `'sale'` que ya registran una sucursal;
- los movimientos `'sale'` nulos cuyo origen no es demostrable (con OQ-5 (c));
- los movimientos de ventas ya borradas: el par original y su reversa quedan los dos en `NULL`, que es consistente;
- `cash_movements`, `bank_movements` (ya llevan la sucursal resuelta), `customer_account_movements`, `journal_entries`, `events`, `sales_orders`, `sale_items`, `branch_stock`.

**Por qué la principal vigente (regla 5) y no "la principal de aquel momento":**

1. **Es la decisión literal del PO.**
2. **Es lo que el sistema ya hace con esas ventas cuando no quedó nada asentado.** El alta resolvió la principal *del momento* para el stock, la caja y el banco. La reversa de un movimiento `NULL` y la edición de una fila `NULL` resuelven la principal *vigente*. El export las rotula "Principal". Cuando sí quedó asentada otra sucursal (otra fila de la operación, la orden o el movimiento de stock), las reglas 1 a 4 la respetan.
3. **"La de aquel momento", fuera de las reglas 1 a 4, sólo se conoce para las ventas con movimiento de caja o de banco**, y puede ser una sucursal hoy cerrada o desactivada (el caso típico es la cuenta del incidente del 22-08). Asignársela dejaría esas ventas **sin poder editarse** desde el formulario sin reabrir la sucursal (candidato (i) de #606).

El costo es que, en una cuenta cuya principal cambió, las ventas viejas sin nada asentado quedan atribuidas a la principal de hoy, que no es la sucursal de la que salió su stock. La migración **cuenta** cuántas ventas asignadas tienen un movimiento de caja (vía `cash_sessions → cashboxes.branch_id`) o de banco (`bank_movements.branch_id`) que registró **otra** sucursal, y lo informa (OQ-4). Sus movimientos de stock quedan `NULL` (OQ-5 (c)), así que no se falsea el ledger.

**Lo que la migración no puede saber: ventas anteriores al 2026-10-01.** Hasta #606 el formulario descartaba la sucursal elegida. Una venta que el usuario registró "en B" quedó `NULL` y su stock salió de la principal de ese momento. No queda rastro de esa elección: el banco se resolvió contra la principal, y el opt-in de caja buscaba la sesión de B pero el servidor la comparaba contra la principal y la rechazaba. La migración deja esas ventas en la principal. Eso coincide con la sucursal de la que salió el stock mientras la principal no haya cambiado desde entonces, pero no con lo que eligió el usuario. La corrección es venta por venta, **editándola a B**: la reversa devuelve el stock a la sucursal de la venta (la principal) y la reaplicación lo descuenta de B, así que se corrige también el stock. Se informa al PO en OQ-4 y en el humo.

- *Alternativa (c) del brief — sólo las cuentas con una única sucursal*. Superada por la decisión del PO. Además, el **mismo** argumento vale para las cuentas con varias sucursales, cuyo stock se movió en la principal.
- *Alternativa — cascada con la sucursal registrada en caja y banco como regla 0*. Rechazada por el punto 3 (OQ-4).
- *Alternativa — el movimiento siempre antes que la orden* (OQ-6 (b)). Rechazada: en una venta con comprobante vigente la orden nunca se re-sincroniza, así que venta y factura quedarían en sucursales distintas para siempre, y sus notas de crédito restarían en otra sucursal que la venta.
- *Alternativa — la orden siempre antes que el movimiento* (OQ-6 (c)). Rechazada: en las ventas sin comprobante vigente, que sí se editan y se borran, dejaría venta y movimiento en sucursales distintas, y borrar y editar devolverían el stock a lugares distintos.
- *Alternativa — filtro de sucursal operativa también en las reglas 1 y 2*. Rechazada: deja operaciones mixtas, o ventas separadas de su factura, para siempre, sin ganar editabilidad.
- *Alternativa — resolver fila por fila*. Rechazada: puede crear operaciones mixtas (ver la unidad de resolución).

### D7 — Mecánica del backfill: archivo propio, orden global de locks, trazable e idempotente

- **Dos archivos**: `20261075000001_ventas_sucursal_por_defecto.sql` (funciones) y `20261075000002_ventas_sucursal_por_defecto_backfill.sql` (datos solamente: sin DDL, sin funciones, sin ACLs). Primero entran los cuerpos nuevos y después corre el backfill. Así se achica la ventana de ventas "en vuelo" (D13 y Risks), el PO puede mergear la migración de datos con la regla vigente (los sub-agentes no mergean migraciones de datos) y cada archivo se reaplica por separado en `KPI_Validation.yml`.
- **RN-21**: el `UPDATE` de `stock_movements` es la excepción de OQ-5, acotada en el requirement nuevo de `inventory-single-ledger`: sólo `branch_id` nulo, sólo movimientos `'sale'` de ventas vivas asignadas en esta corrida, sólo los de origen demostrable (D6), cada id en la auditoría. Si el PO elige (b), la pata de movimientos no se escribe; si elige (a), se quita el criterio de origen demostrable.
- **Locks**: antes de actualizar, las filas candidatas se toman con `FOR UPDATE` en **orden ascendente de `id`**. Es la regla dura del proyecto (orden global único: `sales` por `id` → `sales_orders` → `fiscal_documents` → resto), la misma que usan la edición, el borrado y la promoción, así que el backfill no puede entrar en deadlock con ninguno de los tres. `stock_movements` va después ("resto"). **No** se usa `LOCK TABLE`: con escritores que toman `sales` y `stock_movements` en órdenes distintos (el alta inserta `sales` antes que el movimiento y el borrado inserta la reversa antes del `DELETE`), un lock de tabla sí puede entrar en deadlock.
- **Trazabilidad**: se escribe **una fila de `audit_logs` por cuenta afectada**, con estos campos:
  - `action = 'sales_branch_backfill'`
  - `entity_type = 'account'`
  - `entity_id = account_id`
  - `account_id`
  - `user_id = NULL` (sistema; mismo criterio que la autoría nula del alta automática de sucursales)
  - `metadata = {change, sale_ids[], movement_ids[], por_regla{operacion, orden_facturada, movimiento, orden, principal}, mixta_no_operativa, orden_facturada_no_operativa, salteadas_no_operativa, discrepancia_movimiento, discrepancia_orden, movimiento_origen_incierto, branch_ids[], evidencia_otra_sucursal}`

  `audit_logs` no tiene disparadores, y su política de lectura (vía `company_id`) no expone estas filas a los usuarios. Así queda registrado qué asignó el sistema frente a lo que eligió el usuario, y hay un camino de reversión exacto (Migration Plan).
- **Idempotencia**:
  - el `WHERE branch_id IS NULL` hace que una segunda corrida no encuentre filas;
  - con cero filas no se escribe ninguna fila de auditoría;
  - el gate la ejecuta dos veces (molde `test_unidades_decisiones_8_9.sql`), y la cadena de reaplicación de CI compara el fingerprint del esquema.
- **Sin efectos laterales**: `sales` sólo tiene disparadores `AFTER INSERT`, así que el `UPDATE` no dispara margen bajo, analytics, eventos, notificaciones ni Realtime. El gate lo asierta comparando los conteos de `events`, `notifications` y `analytics_events` antes y después, **acotados a las cuentas del fixture**: `pg_cron` corre `relay-process-outbox` y `relay-process-pending-cae` cada minuto en el stack local y en CI, y bajo `READ COMMITTED` un conteo global vería las filas que el relay inserta entre las dos mediciones.
- **Nunca aborta por datos**. Se informan con `NOTICE`: los conteos por regla, las asignaciones de las reglas 1 y 2 a una sucursal no operativa, las reglas salteadas por sucursal no operativa, los movimientos completados y los de origen incierto, el residuo, las discrepancias venta ≠ movimiento y venta ≠ orden, y la evidencia de otra sucursal en caja o banco.

### D8 — Sin `NOT NULL` ni `CHECK` sobre `sales.branch_id` en este change

- `ALTER COLUMN … SET NOT NULL`: **rechazado ahora**.
  - Si queda residuo (filas sin `account_id`), el `ALTER` falla y **aborta el deploy**.
  - Los dos `rpc_atomic_create_sale` legacy (sólo `service_role`) insertan sin sucursal y empezarían a fallar.
  - La FK `ON DELETE SET NULL` quedaría contradiciendo la restricción.
- `CHECK (branch_id IS NOT NULL) NOT VALID`: **rechazado**. Postgres evalúa el `CHECK` en **cualquier** `UPDATE` de la fila, así que un `UPDATE sales SET product_id = NULL` (`rpc_safe_delete_product`) sobre una fila residual empezaría a fallar y bloquearía el borrado de productos.
- **Candidato** (en `CHANGES.md` al archivar): con el residuo verificado en 0 en producción, una migración propia retira los `rpc_atomic_create_sale` muertos, cambia la FK a `RESTRICT` y agrega `NOT NULL`.

### D9 — Formulario de venta: sin "Sin sucursal", con la principal a la vista

- `BranchSelect` suma props opt-in cuyos valores por defecto dejan a compra, gasto e importador de gastos **idénticos**:
  - `allowUnassigned?: boolean`, por defecto `true`;
  - `label?: string`. El rótulo se renderiza **dentro** del componente, con `useId`, `<Label htmlFor>` e `id` en el `SelectTrigger`: es el patrón de `PaymentMethodSelect.tsx:95-108` y `CostCenterSelect`. Como el componente devuelve `null` sin el módulo de sucursales, el rótulo desaparece junto con el control. Un `<Label>` puesto afuera, en `sale-form.tsx`, quedaría huérfano en las cuentas sin módulo y no tendría un `id` al que apuntar.
  - `fallbackBranchId?: string | null`: la sucursal que **el servidor** va a usar si el usuario no elige otra, cuando no es la principal (por ejemplo, la del documento de origen). Sólo cambia el valor mostrado con el estado en `null`; no se emite por `onChange`;
  - con `allowUnassigned={false}`, un placeholder propio que nunca dice «Sin sucursal»: «Cargando sucursales…». Lo muestra el disparador mientras `useBranches` carga, cuando el valor mostrado todavía es `undefined`.
- En la venta se usa `allowUnassigned={false}` y `label="Sucursal"` (hoy el selector no tiene rótulo, a diferencia de Fecha y Canal), y se retira el `placeholder="Sin sucursal (general)"` que hoy pasa `sale-form.tsx:944`:
  - no aparece la opción `__none__`;
  - el valor mostrado es `value ?? fallbackBranchId ?? resolveDefaultBranch(branches)?.id` (la venta no pasa `fallbackBranchId`, así que muestra la principal);
  - la principal se lista como "Nombre (principal)".
- El **estado** del formulario sigue en `null` hasta que el usuario elige. Con `null` el alta manda `branch_id: null` y **el servidor** decide con datos vivos.
  - Se ve la principal y se guarda la principal, porque el helper del cliente es espejo exacto de `c26_default_branch` (D10).
  - La única ventana de diferencia es el caché de cinco minutos de `useBranches` si la principal cambia mientras el modal está abierto. En ese caso el servidor guarda la principal **real**.
- Si el usuario elige **otra** sucursal, viaja su id. Elegir la principal que ya se muestra **no cambia nada**: Radix no emite `onValueChange` cuando el valor no cambia (Context), así que el estado sigue en `null`, viaja `null` y el servidor resuelve la misma principal. Para fijarla de forma explícita hay que elegir otra y volver a ella, y entonces sí viaja su id.
- **Edición**:
  - precarga `editingOperation.branchId`;
  - después del backfill toda venta tiene sucursal;
  - si quedó residuo, se muestra la principal y viaja `null`, que el servidor resuelve a la principal (D5).
- **Cuenta sin módulo de sucursales**: el selector y su rótulo no se renderizan (sin cambio), viaja `null` y la venta queda en la principal de la cuenta. Es su única sucursal si tiene una sola. Si conserva varias de un plan anterior (bajar de plan no desactiva sucursales), es la más antigua operativa. El opt-in de caja ya usaba esa misma sucursal.
- **Toda superficie que registre una venta con un selector de sucursal usa `allowUnassigned={false}` y muestra, de entrada, la sucursal que el servidor va a usar si el usuario no elige otra.** En el formulario de venta es la principal. `presupuestos-modulo` suma `ConvertQuoteDialog`, que crea una venta. Su núcleo `_quote_accept_core` **no** resuelve la principal sin más: su spec (`openspec/changes/presupuestos-modulo/specs/quote/spec.md`, requirement «Quote.accept() crea un SalesOrder…») fija la precedencia «la indicada por la conversión, la del presupuesto o la sucursal por defecto de la cuenta», y su design (L461) usa como valor por defecto del diálogo «sucursal del presupuesto o la de la cuenta». Si el diálogo mostrara la principal con el estado en `null`, un presupuesto de B mostraría «A (principal)» mientras el servidor guarda B. Por eso nace `fallbackBranchId`: el diálogo pasa la sucursal del presupuesto (o precarga su estado con ella; lo que importa es que lo mostrado sea lo que se guarda). Coordinación (tarea 6.7): el change que aplique **segundo** pasa el diálogo a `allowUnassigned={false}` con `label="Sucursal"` y la sucursal del presupuesto como respaldo, y resuelve el conflicto en `sale-form.tsx`, que los dos tocan (aquél migra el carrito a `lib/cart-utils.ts`, éste el selector). `QuoteForm`, el presupuesto en sí, conserva el valor por defecto: un presupuesto no mueve stock ni es una venta.
- *Alternativa — preseleccionar el id explícito en el estado (`useEffect` y bandera "tocado")*. **Rechazada**: suma un efecto y congela la vista cacheada del cliente en el dato que se guarda. Con `null`, la fuente de verdad sigue siendo una sola: el servidor.
- *Alternativa — conservar una opción `null` rotulada "Sucursal principal (Casa Central)"*. **Rechazada**: lista dos opciones que significan lo mismo ("Sucursal principal (Casa Central)" y "Casa Central"). Queda como opción (b) de OQ-2.

### D10 — `lib/default-branch.ts`: una sola definición de "la principal" en el cliente

`resolveDefaultBranch(branches: Branch[]): Branch | null` recibe las sucursales activas ordenadas por `createdAt`, tal como las devuelve `useBranches`:

- devuelve la primera con `status === "active"`;
- si no hay ninguna, devuelve la primera de la lista;
- con la lista vacía, devuelve `null`.

La consumen `BranchSelect` (D9) y todos los lugares del cliente que hoy toman `branches[0]` como "la principal":

- `useCashOptin`: `effectiveBranchId = branchId || resolveDefaultBranch(branches)?.id || null`. Alcanza a sus **cinco** consumidores: venta, compra, gasto, cobro de cuenta corriente y pago a proveedor (Context).
- `useDefaultBranchNotice`.
- **El POS** (`ventas/pos/page.tsx:166`): `activeBranch = resolveDefaultBranch(branches)`. Con esa sucursal busca la caja y la sesión, arma el enlace «Ir a caja de …» y la manda explícita como `branch_id`.

Con esto se cumple la Regla de Tres y se corrige un desfasaje real. El helper sólo difiere de `branches[0]` cuando la sucursal más antigua está **cerrada**. En ese caso, hoy:

- el opt-in de venta y de gasto busca la sesión en la cerrada, mientras el servidor exige la de la siguiente;
- el aviso anuncia como principal una sucursal cerrada;
- el POS manda la cerrada y `_c29_confirm_order_core` rechaza la venta con `branch_closed`;
- el cobro y el pago de cuenta corriente buscan la sesión en la caja de la cerrada (el servidor sólo exige que haya una sesión abierta). Desde este change ofrecen la sesión de la principal operativa: cambia la superficie de dinero de cuentas corrientes, y se cubre con un caso de regresión (tarea 5.2).

**Paridad con el servidor, acotada.** Vale para venta, gasto, cobro, pago y POS. **No** vale para la compra: su RPC compara la sesión contra `p_branch_id` crudo, así que, sin sucursal elegida, el hook ofrece la sesión de la principal y el servidor la rechaza siempre. Es preexistente (pasa igual con `branches[0]`) y va al change hermano (OQ-3).

Límite declarado: si **ninguna** sucursal activa está operativa, el cliente muestra la primera activa (cerrada), y el servidor resuelve el fallback de `c26_default_branch` (la más antigua de **todas**, incluidas las inactivas) y rechaza la venta con `no_branch_found` (D3); el formulario traduce el error con la salida. El estado **es alcanzable**: `rpc_close_branch` rechaza cerrar la última operativa (`P0409 last_active_branch`), pero `rpc_deactivate_branch` no tiene ese guard (Context).

### D11 — Backend sin cambio de lógica

`SaleOperationIn.branch_id` y `SaleOperationUpdateIn.branch_id` ya transportan `None`, y el tri-estado viaja por `model_fields_set`. Sólo se corrigen los comentarios que afirman que "`None` conserva `branch_id` NULL" (`backend/services/sales.py` cerca de L147, `backend/schemas/sales.py` cerca de L50) y se agrega la descripción del campo en el esquema (OpenAPI): «sin sucursal se registra en la principal de la cuenta». También se corrige la prosa de los tests que afirma el contrato viejo, sin cambiar ninguna aserción (el transporte de `null` sigue igual): `backend/tests/test_sales_branch_id.py:75-77` y `:212`. Los errores nuevos (`P0422 no_branch_found`) llegan como RFC 7807 por el mapeo global de `asyncpg_error_handler`, como el resto de `P0422`.

### D12 — Lectores: ningún cambio de código; qué cambia de un día para otro

| Lector | Efecto |
|---|---|
| Tablero, estadísticas y márgenes **filtrados por la principal** | Suman las ventas que hoy quedan afuera por ser `NULL`. En cuentas sin módulo de sucursales no hay filtro, así que no cambia nada visible. |
| Tramo "Sin sucursal" (`rpc_sales_breakdown`, `rpc_branch_report`) | Deja de recibir ventas; sólo conserva el residuo. `rpc_branch_report` lee `sales` y `expenses` (no compras), así que su fila "Sin sucursal" sigue mostrando los gastos históricos sin sucursal. El fundamento de `sales-statistics` («en producción son la mayoría de las operaciones») deja de valer para la sucursal y se actualiza con un delta. |
| Stock sin rotación **filtrado por una sucursal que no es la principal** | Las ventas históricas sin sucursal dejan de contar como rotación ahí: ahora pertenecen a su sucursal asignada por la migración (en general, la principal vigente al aplicarla). En las cuentas cuya principal no cambió, coincide con la sucursal de la que salió su stock; en las que cambió, no necesariamente (D6). Incluye las ventas anteriores a #606 que el usuario había elegido en otra sucursal (D6): en los períodos pasados, el Tablero filtrado por esa sucursal puede mostrar como sin rotación productos que se vendieron "ahí". El *fail-open* de `kpi-branch-consistency` D4 queda vigente para el residuo. Su fundamento («lo contrario marcaría como estancado a casi todo el catálogo») deja de ser cierto y se actualiza con un delta de `dashboard-kpi-summary`, para que el PO lo acepte en el sign-off. |
| Export (`generate-export`) | Muestra el nombre real de la sucursal en vez de "Principal". |
| `/sucursales/:id` e inventario | Sin cambios: leen `branch_stock`, que este change no toca. |

*Alternativa — retirar el fail-open o la etiqueta "Sin sucursal"*. **Rechazada**: siguen haciendo falta para el residuo, las compras y los gastos, y tocarlos exigiría reescribir las RPCs de reporte desde su cuerpo vivo sin necesidad. Lo que cambia es sólo el fundamento escrito en las specs, no el comportamiento.

### D13 — Gates: ejecutan las RPCs y la migración, con controles de introspección y mutaciones

Gate nuevo: `supabase/tests/test_ventas_sucursal_por_defecto.sql`. Sigue el patrón del proyecto: acumula fallos en `text[]`, usa anchors sintéticos vía `handle_new_user`, `created_at` explícito y asertado, y limpieza completa. Bloques:

- **(0) Introspección**: los cuerpos **vivos** de las tres funciones persisten la sucursal resuelta y su `md5(replace(prosrc, E'\r', ''))` es el `v_rewritten` del preflight de `20261075000001`. La edición conserva su `COMMENT`. Hay una sola firma por función y las ACLs no cambiaron. Falla explícito si una reaplicación posterior de CI pisa un cuerpo (lección de `candidatos-db-backend`).
- **(1)** Alta v2 sin sucursal, en una cuenta con A (principal) y B, con dos líneas (una de servicio): `sales.branch_id = A` en todas las filas, `stock_movements.branch_id = A`, el stock baja en A y B queda intacta.
- **(2)** Lo mismo por la **rama legacy** (flag `sale_items_rpc_v2 = false` para la cuenta del fixture).
- **(3)** Con la principal **cerrada**: `c26_default_branch` resuelve B, y la venta y el stock van a B.
- **(3b)** Cuenta con **todas** sus sucursales sin operar: una desactivada (`is_active = false`, permitido por `trg_guard_branch_decommission` porque está vacía) y otra cerrada. `P0422 no_branch_found` en la v2, en la legacy y en la edición sin sucursal, sin filas nuevas y sin cambios en `branch_stock`. Este fixture no necesita `session_replication_role`.
- **(4)** Cuenta sin ninguna sucursal: `P0422 no_branch_found` en la v2 y en la legacy, sin filas en `sales`, `operation_idempotency` ni `stock_movements`. Fixture: el borrado de la sucursal sembrada exige `session_replication_role = replica` para esquivar `trg_guard_branch_decommission`, y en ese modo **no corren las acciones de FK**. Por eso se borran explícitamente, antes del `DELETE` de la sucursal, sus dependencias en cascada: `cashboxes` (que `handle_new_user` siembra y que no tiene `account_id`, así que la limpieza por cuenta no la alcanza) y `branch_stock`. Al final, el gate asierta residuo cero de cajas y de stock de esas sucursales (mismo gotcha que `test_admin_kpis.sql`).
- **(5) Edición**:
  - venta en B editada con `p_branch_provided = true` y `NULL` → A (el REVERSE devuelve a B y el APPLY descuenta de A);
  - fila residual `NULL` editada sin informar sucursal → A;
  - reimputación explícita → sin cambios.
- **(6) Caja y banco**: sin sucursal elegida, la venta, su movimiento de stock y su movimiento bancario llevan **la misma** sucursal (A).
- **(7) Backfill**, ejecutando el archivo de datos **dos veces** (`\i`):
  - mono-sucursal → su sucursal;
  - multi-sucursal → principal;
  - operación mixta (B más `NULL`) → B, en una operación con una línea de servicio (sin movimiento), para probar que la operación no queda mixta;
  - operación mixta con B **cerrada** → B igual (la regla 1 no pasa por el filtro), y se cuenta en `mixta_no_operativa`;
  - venta `NULL` con orden y comprobante `authorized` en B, y movimiento `'sale'` en X ≠ B → B (regla 2): el movimiento sigue en X y se cuenta una `discrepancia_movimiento`;
  - lo mismo con el comprobante `pending_cae` con marca de envío → B;
  - venta `NULL` con su movimiento `'sale'` en X operativa ≠ principal A, sin orden → X (regla 3), y el movimiento sigue en X;
  - venta `NULL` con su movimiento `'sale'` en X operativa y orden **sin** comprobante en B → X (regla 3), la orden sigue en B y se cuenta una `discrepancia_orden`;
  - venta `NULL` con su movimiento `'sale'` en X **cerrada** → principal A, el movimiento sigue en X y se cuenta una `discrepancia_movimiento`;
  - con orden sin comprobante en B (sin movimiento con sucursal) → B (regla 4);
  - con orden sin comprobante en una sucursal **cerrada** → principal, y se cuenta la regla salteada;
  - cuenta con todas sus sucursales sin operar → sigue `NULL` (residuo);
  - sin `account_id` → sigue `NULL` (residuo);
  - movimientos `NULL` de las asignadas (si OQ-5 = (c)): en una cuenta cuya única sucursal existía al escribirse el movimiento → toman esa sucursal; en una cuenta que ya tenía otra sucursal en ese momento → siguen `NULL` y se cuentan en `movimiento_origen_incierto`;
  - movimientos de ventas borradas → intactos;
  - una fila de `audit_logs` por cuenta con los ids y los conteos;
  - la segunda corrida no cambia filas ni escribe auditoría (contado sobre las cuentas del fixture);
  - `events`, `notifications`, `analytics_events`, `cash_movements`, `bank_movements`, `customer_account_movements` y `journal_entries` sin cambios, **contados sólo sobre los `account_id` de las cuentas del fixture**. `pg_cron` corre `relay-process-outbox` y `relay-process-pending-cae` cada minuto en el stack local y en CI, y un conteo global puede cambiar por el relay sin ningún defecto. El archivo de datos es global y también asigna las ventas `NULL` que otros gates hayan dejado en la base de CI, así que ninguna aserción de (7) mira filas fuera del fixture.
- **(8)** Después del backfill, `rpc_promote_legacy_sale_to_order` **ejecutada** sobre la operación antes mixta ya no levanta `P0422 operation_inconsistent`.
- **(8b)** Una venta con sucursal escrita B (alta con B explícita), con B **cerrada** después: `rpc_promote_legacy_sale_to_order` **ejecutada** se comporta como firme el PO en OQ-8. Con la recomendación (a), el caso fija a propósito el comportamiento actual (la orden nace en B cerrada) con un mensaje que nombra el candidato, para que su arreglo lo cambie a conciencia.
- **(9)** `rpc_delete_sale_operation` **ejecutada** sobre ventas asignadas por el backfill repone el stock donde dice su movimiento: en la sucursal asignada cuando el movimiento se completó (origen demostrable), en X para la venta asignada por la regla 3, y en la principal vigente para un movimiento que quedó `NULL` por origen incierto.
- **(9b)** Una venta nueva sin sucursal elegida (movimiento en A por D2). Después se vacía A y se **desactiva**, y se borra la venta con `rpc_delete_sale_operation` **ejecutada**. El resultado se asierta según OQ-8. Con la recomendación (a), el caso fija a propósito el comportamiento actual (el stock vuelve a A desactivada) con un mensaje que nombra el candidato.

**Mutaciones** que el apply ejecuta sobre los cuerpos locales, dentro de una transacción con `ROLLBACK`, y que el gate tiene que detectar con mensaje propio:

- M1: v2 con `p_branch_id` crudo en `sales`;
- M2: la legacy, crudo;
- M3: v2 con `stock_movements` crudo;
- M4: edición sin `COALESCE`;
- M5: backfill sin la pata de movimientos (si OQ-5 = (a) o (c));
- M5b: backfill sin el criterio de origen demostrable, que completa también los movimientos de origen incierto (si OQ-5 = (c));
- M6: backfill sin la regla de la orden sin comprobante;
- M6b: backfill sin la regla de la orden con comprobante vigente (el movimiento gana sobre la factura);
- M7: backfill sin la regla del movimiento;
- M8: backfill sin el filtro de sucursal operativa en las reglas 3 a 5;
- M8b: backfill con el filtro de sucursal operativa también en la regla 1 (la operación queda mixta);
- M9: guard de `no_branch_found` que sólo mira `NULL` y deja pasar la sucursal no operativa.

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

**CI (`KPI_Validation.yml`)** — **reescrito en el apply (2026-10-09)**, porque el estado del workflow cambió desde la propuesta:

- **No hay bloque de `20261062000001` para retirar**: ya lo retiró remitos-venta tanda B. Lo que sí se hizo fue actualizar los comentarios que se apoyaban en él (los de `20261063000001`, `20261064000001`, `20261066000001` y `20261068000001`) y el del paso «Run ventas formulario sucursal gate», que ahora cita este change y el contrato nuevo. Las otras siete funciones de `20261062000001` siguen cubiertas por `test_ventas_unidades_conversion.sql` y su prueba de carrera.
- **Reaplicación** de `20261075000001` y `20261075000002` **al final de la cadena**, después de los reapply de `20261070000001` y `20261071000001` (que re-instalan el cuerpo de la edición y su COMMENT). Consecuencia: la **primera** pasada de `20261075000001` toma la rama de reescritura de la edición (la v2 y el wrapper conservan el cuerpo de esta migración desde el reset) y la **segunda** exige los tres `NOTICE` «ya es el cuerpo de esta migración» (conteo con `grep -cF`), el OK de la introspección y el `schema_snapshot` idéntico. El archivo de datos corre sobre una base recién reconvergida: su `NOTICE` final tiene que decir `0 ventas asignadas en 0 cuentas`, con el `schema_snapshot` idéntico. Una migración posterior que redefina cualquiera de las tres funciones tiene que retirar ese bloque en el mismo PR (regla escrita en el workflow).
- El gate nuevo se cablea como **paso propio** (`Run ventas sucursal por defecto gate`), después del de `test_ventas_formulario_sucursal.sql`.

**Otros cambios respecto de la propuesta (apply)**:

- `test_facturar_venta_manual.sql` (0) **sí** fija el `md5` del COMMENT de la edición (la propuesta decía que ningún gate lo fijaba): se actualiza al `md5` del comentario de esta migración (`1478b13b…`).
- Los contadores de la auditoría y del `NOTICE` del backfill se cuentan **por fila de venta**, no por operación (salvo los movimientos, que se cuentan por movimiento).
- El backfill se escribe **por JOIN** sobre tablas temporales con clave: una primera versión con subconsultas correlacionadas por fila tardó 6 min 17 s con 50.000 filas sintéticas en 5 cuentas; la definitiva, 24 s.
- `BranchSelect` ya traía `required` y `alwaysVisible` de remitos-venta; `allowUnassigned`, `label` y `fallbackBranchId` son aditivas y compatibles. `ConvertQuoteDialog` ya resolvía la principal con una copia local (`find(b => b.status !== "closed")`): se migra a `resolveDefaultBranch`, y `SaleCheckoutFields` pasa a `allowUnassigned={false}` con el rótulo dentro del selector. `lib/branch-selection.ts` (remitos) no se reduce a `operativeBranches`: su criterio no tiene el fallback a una sucursal cerrada, a propósito.
- Tarea 4.3: no se hizo `supabase db reset` (la base local es compartida); se emuló la cola de la cadena (reapply de `20261070000001` y `20261071000001`, y las dos pasadas de esta migración), que es donde está el riesgo.

## Risks / Trade-offs

- **[Ventas "en vuelo" durante el deploy]** Una llamada al cuerpo **viejo** que empezó antes del commit de `20261075000001` y commitea después de que corrió el `UPDATE` de `20261075000002` deja una fila `NULL`. → El archivo de funciones va primero (si el CLI aplica cada archivo en su transacción, la ventana es de milisegundos; si los aplica en una sola, es la duración del push). La verificación posterior (tarea 12.3) **no** puede buscarlas por `created_at`: `sales.created_at` es `DEFAULT now()`, el inicio de la transacción, así que una venta en vuelo tiene un `created_at` **anterior** al deploy. Las busca por estado: filas `NULL` con `account_id` cuya cuenta tiene una sucursal operativa, que son exactamente las que el backfill habría asignado y tienen que ser 0. Si hay alguna, con OK del PO se re-ejecuta el bloque idempotente del archivo de datos (`npx supabase db query --linked`). Es el único caso que necesita intervención.
- **[Atribución histórica en cuentas cuya principal cambió]** Sus ventas viejas sin nada asentado quedan en la principal de hoy (D6). → La migración cuenta las que tienen evidencia de otra sucursal en caja o banco, la fila de auditoría permite revertir o reasignar por id, y OQ-4 deja la alternativa a decisión del PO.
- **[Ventas anteriores a #606 que el usuario había elegido en otra sucursal]** El formulario descartaba la elección y no quedó rastro (D6). Esas ventas quedan en la principal: coinciden con la sucursal de la que salió el stock mientras la principal no haya cambiado, pero no con lo que eligió el usuario. → No hay forma de recuperarlo en masa. Se declara en OQ-4, y la salida, venta por venta, es editarla a la sucursal correcta, que también corrige el stock. Efecto en el Tablero filtrado por esa otra sucursal: D12.
- **[Discrepancia venta ≠ movimiento]** Una venta asignada por las reglas 1, 2, 4 o 5 puede conservar un movimiento en otra sucursal (D6). En ella, borrar y editar devuelven el stock a sucursales distintas, como ya pasa hoy (en las de la regla 2 no hay borrado ni edición mientras el comprobante siga vigente). → La migración las cuenta, la tarea 12.4 las vuelve a medir en producción y se informan al PO.
- **[Discrepancia venta ≠ orden]** Una venta con orden sin comprobante vigente, asignada por el movimiento a otra sucursal, queda distinta de su orden hasta la próxima edición; mientras tanto una NC de esa orden restaría en la sucursal de la orden (D6). Con comprobante vigente no pasa: manda la orden (regla 2). → Se cuenta (`discrepancia_orden`) y la tarea 12.4 la re-mide.
- **[Movimientos de origen incierto]** Con OQ-5 (c), los movimientos nulos de las cuentas que ya tenían más de una sucursal al momento de la venta quedan `NULL`. Su borrado sigue reponiendo en la principal vigente al borrar, como hoy, y edición y borrado pueden devolver el stock a lugares distintos si la principal cambia después. → Se cuentan (`movimiento_origen_incierto`), la tarea 12.4 los re-mide, y es el precio de no escribir en el historial de stock una sucursal de la que el stock no salió.
- **[Una venta cuya sucursal guardada deja de operar después]** Le pasa a las históricas asignadas y a toda venta nueva sin sucursal elegida (D2), que antes quedaban `NULL` y caían siempre en la principal operativa del momento. Hoy ya le pasa a toda venta con sucursal elegida.
  - **Cerrada**: no se puede editar ni borrar sin reabrirla (`P0422 branch_closed`), igual que cualquier venta con sucursal (candidato (i) de #606). La salida es reabrir, o transferir y volver a cerrar.
  - **Desactivada** (vaciada y dada de baja, que `rpc_deactivate_branch` permite): el borrado repone el stock **en silencio** en esa sucursal (`rpc_apply_product_stock_delta` no mira `is_active`, Context), que no se ve ni se puede reactivar. Es la clase del incidente del 22-08.
  - **"Facturar venta manual"** sobre esa venta crea la orden y la factura en la sucursal cerrada o desactivada (`rpc_promote_legacy_sale_to_order` sólo rechaza `NULL`), y sus NC se imputan ahí.

  → Decisión del PO en OQ-8 (recomendado: declararlo y dejarlo como candidato con nombre propio). Los bloques (8b) y (9b) del gate lo ejecutan.
- **[Cambio visible del KPI "stock sin rotación" filtrado]** Ver D12. → Se avisa al PO en el humo y en la ficha de `CHANGES.md`, y el delta de `dashboard-kpi-summary` lo deja escrito.
- **[Cuenta sin ninguna sucursal operativa]** Una venta que hoy pasaba (servicios, o con stock en la sucursal inactiva) pasa a rechazarse con `no_branch_found` (D3). → Estado de borde; el formulario traduce el error con la salida.
- **[Orden de merge con `presupuestos-modulo`]** Los dos changes tocan `sale-form.tsx` y aquél suma un diálogo que registra ventas con `BranchSelect` (D9). → El que mergee segundo resuelve el conflicto y pasa `ConvertQuoteDialog` a `allowUnassigned={false}` con la sucursal del presupuesto como respaldo (tarea 6.7). Los números de migración no chocan: aquél usa `20261067000001`/`20261068000001`.
- **[Retiro del bloque de reaplicación de `20261062000001`]** Se pierde la reaplicación de su gate embebido (sección 14) y de su DDL de `min_stock`. → Es lo que pide la regla del propio workflow; las tres funciones reescritas quedan bajo el preflight y el gate nuevos, y las otras siete bajo `test_ventas_unidades_conversion.sql` y su prueba de carrera (D13).
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
   - medir `md5(replace(prosrc, E'\r', ''))` (la medida del preflight) y compararlo con el local y con el `v_rewritten` de `20261062000001`; además, comparar el cuerpo por líneas sin `\r`;
   - leer `COMMENT`, ACLs y `MAX(version)`;
   - confirmar que `20261075000001`/`000002` están libres.

   Si algún cuerpo de producción diverge del que dejan los archivos de migración (hoy, local, los `v_rewritten` de `20261062000001`), se reescribe sobre el **vivo** y se documenta. Pero el `v_expected` **no** puede guardar sólo el md5 vivo: CI (`supabase start` y la reconvergencia `supabase db reset` de `KPI_Validation.yml`) y todo stack local construyen la base desde los archivos, donde antes de `20261075000001` el cuerpo es el de `20261062000001`. Con sólo el md5 de producción, el preflight no encontraría ni el de partida ni el reescrito y abortaría en toda base nueva. Hay dos salidas, a elegir en el checkpoint con el PO:
   - reconciliar primero los archivos con el cuerpo vivo, con una migración propia anterior a `20261075000001`;
   - o que `v_expected` acepte los **dos** md5 (el de los archivos y el de producción), con el desvío documentado en la cabecera y en el PR.

   En cualquiera de los dos casos, antes del PR el apply corre `supabase db reset` local con el preflight definitivo (tarea 4.3).
2. **Sign-off de datos** (OQ-4, OQ-5 y OQ-6): sin el OK textual del PO, registrado en este design, el apply no escribe `20261075000002`.
3. **Merge del PR** (lo mergea el PO, porque lleva una migración de datos). El pipeline (`deploy.yml`) aplica `20261075000001` y después `20261075000002` con `supabase db push`, Vercel despliega el frontend y Render el backend (verificar `GET /deploys`).
4. **Verificación posterior** (tarea 12): cuerpos y ACLs vivos; cero filas `NULL` de cuentas con sucursal operativa (las de ventas en vuelo, buscadas por estado y no por `created_at`); residuo igual al informado; movimientos `'sale'` nulos de ventas existentes iguales a los de origen incierto (OQ-5 (c)) o cero (OQ-5 (a)); las discrepancias venta ≠ movimiento y venta ≠ orden; y humo del PO.

**Rollback:**

- **Funciones**: una migración nueva que re-declara los cuerpos capturados en el checkpoint 0, con su `COMMENT` y sus ACLs. Es reversible sin pérdida, porque con los cuerpos viejos las ventas nuevas vuelven a guardar `NULL`. En el **mismo PR** la migración de reversión tiene que:
  - retirar de `KPI_Validation.yml` el bloque de reaplicación de `20261075000001`. Sobre el estado reconvergido, los cuerpos son los viejos, que son justo el `v_expected` de su preflight: la reaplicación tomaría la rama de **reescritura**, volvería a instalar los cuerpos nuevos en la base de CI, imprimiría 0 de 3 `NOTICE` y pondría `validate-kpis` en rojo. Es la misma regla que este change aplica a `20261062000001`. También retira el de `20261075000002` si se revierten los datos;
  - llevar su propio preflight (cuerpo nuevo → viejo);
  - reemplazar el bloque (0) del gate nuevo, que asierta los cuerpos nuevos.
- **Datos**: reversibles por id desde `audit_logs`:

  ```sql
  UPDATE sales SET branch_id = NULL
  WHERE id IN (SELECT jsonb_array_elements_text(metadata->'sale_ids')::uuid
               FROM audit_logs WHERE action = 'sales_branch_backfill');
  ```

  Lo mismo para `movement_ids` en `stock_movements` (sólo existen si OQ-5 = (a) o (c)). Sólo con decisión explícita del PO; no está previsto.

## Open Questions

| # | Pregunta | Opciones | Recomendación |
|---|---|---|---|
| OQ-1 | ¿Qué es "la principal"? | (a) La regla vigente, `c26_default_branch`: la sucursal activa y operativa más antigua. (b) Una sucursal principal **configurable**: `accounts.default_branch_id` y una acción "Usar como principal" en `/sucursales`. (c) Por nombre ("Casa Central"). | **(a)**. Ya decide hoy dónde se descuenta el stock y se cobra toda venta, gasto y venta de POS sin sucursal, y es lo que anuncia el aviso de cambio. (b) es una funcionalidad aparte que tocaría la resolución compartida con POS, gastos y compras; queda como candidato. (c) se rompe al renombrar. |
| OQ-2 | ¿Cómo se ve en el formulario de venta? | (a) Sin la opción "Sin sucursal (general)", con la principal elegida de entrada y marcada "(principal)", más el rótulo "Sucursal" (D9). (b) Mantener una opción rotulada "Sucursal principal (Casa Central)". (c) Dejar la interfaz como está. | **(a)**. (b) lista dos opciones que significan lo mismo. (c) deja un rótulo que contradice lo que se guarda. |
| OQ-3 | ¿Y compras y gastos? Comparten el selector, y el pedido fue sólo de ventas. | (a) Fuera de este change, con un **change hermano** `compras-gastos-sucursal-por-defecto` que cubra el alta y la edición de compras, el opt-in de caja de una compra sin sucursal (hoy se ofrece y el servidor lo rechaza siempre), la edición de gastos y el rótulo de gastos (hoy dice "Sin sucursal (general)" aunque el alta ya guarda la principal). **No** toca las compras históricas, que conservan su sucursal vacía como firmaste en `caja-compras-cobranzas` (spec `purchase-operation`, «La compra persiste su sucursal»: «una atribución inventada sería peor que la ausencia»). (a') El mismo change hermano, pero además asignando las compras históricas a la principal (el argumento de ventas aplica: el stock de una compra sin sucursal **entró** en la principal). Eso **deroga** aquella decisión tuya y tiene que decirlo. (b) Incluirlos acá. (c) Dejarlos así. | **(a)**. Mantiene este change del tamaño del pedido y no mezcla una segunda migración masiva (compras) con la de ventas. Si después querés también las compras viejas, (a') es una decisión aparte de ese change, que tiene que derogar explícitamente la anterior. |
| OQ-4 | ¿A qué sucursal van las ventas viejas que quedaron sin sucursal? | La regla general es **la principal de hoy**, como pediste. La migración agrega cuatro excepciones de coherencia, que pueden dejar una venta en **otra** sucursal: (1) la misma operación ya tiene otras filas en una sucursal; (2) ya la facturaste con "Facturar venta manual" y la factura salió (autorizada o enviada a ARCA): va a la sucursal de la factura; (3) su movimiento de stock ya registró una sucursal (porque la venta se editó, o por el arreglo de stock del 19-08); (4) la pasaste por "Facturar venta manual" sin factura emitida y su orden está en otra sucursal. Las excepciones 3 y 4 nunca asignan una sucursal cerrada o desactivada. La 1 y la 2 sí pueden, porque esa venta ya vive ahí (su operación o su factura) y no se ganaría nada saltándola. Hay dos casos que la migración no puede resolver mejor, y los **cuenta** para informarte: (i) ventas cuyo cobro en caja o banco quedó en otra sucursal porque la principal cambió después (por ejemplo, la cuenta del incidente del 22-08); (ii) ventas anteriores al 2026-10-01 en las que elegiste otra sucursal y el formulario la descartó. De (ii) no quedó registro, así que van a la principal; si querés corregir alguna, se edita a la sucursal correcta y el stock se acomoda solo. Opciones: (a) las reglas de D6 tal cual; (b) todas a la principal de hoy, sin excepciones; (c) como (a), pero las de (i) a la sucursal de su caja o banco. | **(a)**. (b) dejaría operaciones con filas en sucursales distintas, que "Facturar venta manual" rechaza, ventas separadas de su factura, y ventas en una sucursal distinta de la que movió su stock. (c) puede asignar una sucursal cerrada, y esas ventas no se podrían editar. **Bloquea el grupo 3.** |
| OQ-5 | ¿Se permite, por única vez, completar la sucursal vacía de los movimientos de stock de esas ventas? La regla RN-21 dice que el historial de stock no se modifica nunca: las correcciones se hacen con movimientos nuevos. **Dato clave**: el stock de esas ventas salió de la sucursal que era la principal **el día de la venta**. La migración asigna, en general, la principal de **hoy** (o la sucursal de la operación, de la factura o de la orden). Si la principal cambió desde la venta, o si mandó una de esas excepciones, la sucursal asignada **no** es la de la que salió el stock. | (a) Sí, todos, con la sucursal asignada a la venta. Costo: donde no coincide, el historial de stock registra una salida desde una sucursal de la que el stock nunca salió, y si después se borra la venta, el stock vuelve a esa sucursal en lugar de a la de origen (que queda con faltante para siempre). Ningún conteo lo detecta. (b) No, ninguno: esos movimientos quedan vacíos y, al borrar una de esas ventas, el stock vuelve a la sucursal principal que haya en ese momento, como hoy (que es la de origen mientras la principal no cambie). Editar la venta, en cambio, devuelve el stock a la sucursal asignada, así que borrar y editar pueden devolverlo a lugares distintos. (c) Sí, pero sólo donde se puede demostrar que de ahí salió el stock: cuando se registró la venta, la sucursal asignada era la **única** de la cuenta. En la práctica son todas las cuentas de una sola sucursal (en agosto, todas menos una). El resto queda vacío, como en (b), y la migración te dice cuántos son. En todos los casos se completa sólo la sucursal, sólo en movimientos de venta de ventas vigentes, con cada movimiento anotado en la auditoría para poder revertirlo, y la excepción queda escrita en la spec `inventory-single-ledger` y en RN-21. | **(c)**. Nunca escribe en el historial de stock un dato falso, completa todo lo que se puede completar con certeza, y en el resto se comporta como hoy. (a) es más simple, pero puede registrar una salida de stock desde una sucursal de la que no salió y, al borrar la venta, reponer el stock en el lugar equivocado. (b) es la más fiel a RN-21, pero deja vacíos incluso los movimientos cuyo origen es seguro. **Bloquea el grupo 3.** |
| OQ-6 | Si una venta vieja tiene su movimiento de stock en una sucursal y su orden de venta ("Facturar venta manual") en otra, ¿cuál manda? **Dato clave**: una venta cuya factura ya salió (autorizada, o enviada a ARCA y sin respuesta) no se puede editar ni borrar, y su orden no se vuelve a sincronizar nunca. | (a) Depende de la factura. Si ya salió, manda la **orden**: venta, orden, factura y notas de crédito quedan en la misma sucursal, y como la venta no se puede borrar ni editar, el stock no vuelve a moverse. Si no salió, manda el **movimiento**: de ahí salió el stock y ahí lo repone el borrado, y la orden se corrige sola en la próxima edición de la venta. (b) Siempre el movimiento: en las ventas facturadas, la venta y su factura quedarían en sucursales distintas para siempre, y con el Tablero filtrado la venta sumaría en una sucursal y sus notas de crédito restarían en otra. (c) Siempre la orden: en las ventas sin factura emitida, la venta quedaría en una sucursal y su movimiento de stock en otra, y borrar y editar devolverían el stock a lugares distintos. | **(a)**. Cada venta queda junto al documento que ya no puede cambiar: la factura si salió, el movimiento de stock si no. Es un caso de borde (una venta editada, pasada por "Facturar venta manual" y con la principal cambiada entre una cosa y otra). La migración cuenta las ventas que quedan distintas de su orden (sólo pueden ser sin factura emitida, hasta su próxima edición). **Bloquea el grupo 3.** |
| OQ-7 | Al editar una venta, ¿se puede seguir dejándola "sin sucursal"? | (a) No: si se edita sin sucursal, queda en la principal (D5). (b) Sí, como hoy. | **(a)**. Es la consecuencia directa de tu decisión: con (b), una edición volvería a crear exactamente lo que este cambio elimina. Es un cambio del contrato interno de edición (BREAKING), y no hay ninguna pantalla ni integración que dependa de dejarla sin sucursal. |
| OQ-8 | ¿Qué pasa si la sucursal guardada de una venta deja de operar después? Hoy ya le pasa a toda venta en la que elegiste sucursal; con este cambio le pasa a todas las del formulario, que antes quedaban vacías y caían siempre en la principal que estuviera funcionando. Hay dos efectos. **Borrar la venta**: si la sucursal está cerrada, el borrado se rechaza hasta reabrirla. Si la sucursal fue **desactivada** (se vació y se dio de baja), el stock vuelve en silencio a esa sucursal, que no se ve ni se puede reactivar desde la app: es el mismo tipo de problema del incidente del 22-08. **"Facturar venta manual"** sobre esa venta crea la orden y la factura en la sucursal cerrada o desactivada. | (a) Declararlo y dejarlo como mejora aparte, con nombre propio. El arreglo toca funciones que comparten todas las reversas de stock (también las de compras) y la facturación manual, y tiene su propia decisión: rechazar o caer a la principal. Las pruebas de este cambio ejecutan los dos casos y dejan fijado el comportamiento actual a propósito, para que esa mejora lo cambie a conciencia. (b) Arreglarlo acá: el borrado repone en la principal operativa cuando la sucursal del movimiento está desactivada, y la facturación manual usa la principal si la sucursal de la venta no opera. Son dos funciones más para reescribir. (c) Arreglarlo acá rechazando: borrar o facturar una venta de una sucursal desactivada da error. Como no hay forma de reactivar una sucursal, esas ventas quedarían imposibles de borrar. | **(a)**. Es preexistente para toda venta con sucursal elegida, y necesita el vaciado previo de la sucursal, así que es un caso poco frecuente. El arreglo correcto es común a compras y ventas y merece su propio diseño. No bloquea. |

OQ-1, OQ-2, OQ-3, OQ-7 y OQ-8 no bloquean: se aplica su recomendación salvo que el PO diga otra cosa antes del merge. **OQ-4, OQ-5 y OQ-6 bloquean el grupo 3** (la migración de datos): el apply escribe las funciones, el frontend y los gates, pero no escribe `20261075000002` sin el OK textual del PO sobre las tres, registrado en la sección "Sign-off del PO". Es una modificación en masa de datos de producción (governance ALTO), y las tres cambian qué se escribe.

### Sign-off del PO (2026-10-09)

Respuesta textual del PO, dada en el chat de la sesión: «vamos con todo lo recomendado».

**Resueltas el 2026-10-09 por el PO: todas por la recomendación.**

| OQ | Resolución |
|---|---|
| OQ-1 | (a) La principal es `c26_default_branch`. |
| OQ-2 | (a) El selector de la venta sin «Sin sucursal (general)», con la principal a la vista marcada «(principal)». |
| OQ-3 | (a) Compras y gastos no se tocan acá (change hermano `compras-gastos-sucursal-por-defecto`). |
| OQ-4 | (a) Las ventas históricas van a la principal de hoy, con las cuatro excepciones de D6 (operación mixta, orden con comprobante vigente, movimiento de stock propio, orden sin comprobante). |
| OQ-5 | (c) Los movimientos de stock nulos se completan sólo donde el origen es demostrable (excepción única y auditada a RN-21). |
| OQ-6 | (a) Manda la orden si hay comprobante vigente; si no, el movimiento. |
| OQ-7 | (a) Al editar no se puede dejar una venta sin sucursal. |
| OQ-8 | (a) Declarar el comportamiento actual y dejar la mejora como candidato aparte; los bloques (8b) y (9b) del gate lo fijan a propósito. |

Con esto el grupo 3 (migración de datos) queda **desbloqueado** para escribirse. La migración de datos la sigue mergeando el PO.
