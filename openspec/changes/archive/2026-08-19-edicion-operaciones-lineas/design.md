# Design — `edicion-operaciones-lineas`

## Context

### Lo que hacen HOY las RPCs de edición (verificado en prod `gxdhpxvdjjkmxhdkkwyb`, `pg_get_functiondef`, 2026-08-18)

Firmas vigentes (última migración que las define: `supabase/migrations/20260623000001_c21_checkpoint2_drop_products_stock.sql`):

```
rpc_atomic_update_sale_operation(p_sale_ids uuid[], p_client_id uuid, p_date date, p_currency text, p_items jsonb)
rpc_atomic_update_purchase_operation(p_purchase_ids uuid[], p_date date, p_description text, p_items jsonb)
```

Ambas son `SECURITY DEFINER`, `SET search_path = public`, identidad desde `auth.uid()`, tenancy desde `current_account_ids()`, `GRANT EXECUTE ... TO authenticated` + `REVOKE ... FROM anon`.

Estructura interna (idéntica en ambas):

1. **STEP 1 — REVERSE**: por cada fila vieja con `product_id NOT NULL`, `c21_apply_branch_stock_delta(account, product, branch_original, +qty)` (venta) / `-qty` (compra).
2. **STEP 2 — DELETE**: `DELETE FROM sales|purchases WHERE id = ANY(p_ids)`.
3. **STEP 3 — APPLY**: `v_new_op_id := gen_random_uuid()` y un `INSERT` nuevo por cada ítem de `p_items` (`x(product_id uuid, amount numeric, quantity integer)`), con gate de stock y `c21_apply_branch_stock_delta(..., NULL, -qty)`.

**Campos editables hoy** (todo lo demás no viaja en la firma): venta → `client_id`, `date`, `currency`, y la lista completa de ítems (`product_id`, `amount`, `quantity`); compra → `date`, `description` y los ítems. **No** son editables ni preservables: `branch_id`, `canal`, `unit_id`, `cost_center_id`.

**Quién las llama**: `PUT /sales/operation` y `PUT /purchases/operation` (`backend/routers/sales.py:99-109`, `purchases.py:80-92`) → `sales_service.update_sale_operation` → `SalesRepository.update_operation` (`backend/repositories/sales_repository.py:150-173`) / `PurchaseRepository.update_operation` (`purchase_repository.py:176-190`), vía `SELECT rpc_atomic_update_*_operation($1...)` sobre el pool con JWT-passthrough. Del lado del cliente: `frontend/hooks/data/use-sales.ts:191-215` y `use-purchases.ts:198-220`, disparados desde el modo edición de `frontend/components/forms/sale-form.tsx:380-407` y `purchase-form.tsx:361+`.

### El hueco

Ninguna de las dos RPCs menciona `sale_items` / `purchase_items`. Y como las FK son `ON DELETE CASCADE`:

```
sale_items_sale_id_fkey          FOREIGN KEY (sale_id)     REFERENCES sales(id)     ON DELETE CASCADE
purchase_items_purchase_id_fkey  FOREIGN KEY (purchase_id) REFERENCES purchases(id) ON DELETE CASCADE
```

...el STEP 2 **borra las líneas** y el STEP 3 no las recrea. **Toda edición deja la operación sin línea**, tuviera o no línea antes. No hay ningún trigger que compense: los únicos triggers en `sales`/`purchases` son `trg_analytics_operation_created` (telemetría) y `on_sale_insert_margin_check`.

### Estado de los datos en prod (2026-08-18)

| Métrica | Valor |
|---|---|
| `sales` / `sale_items` | 663 / 567 |
| ventas **sin** línea | **119** (ago 59, jul 54, jun 6) |
| `purchases` / `purchase_items` | 427 / 255 |
| compras **sin** línea | **190** (186 con producto, 4 de servicio) |
| compras sin línea **con** `unit_cost_snapshot` en el header | **179 / 186** |
| ventas con >1 línea | 23 (todas del 2026-04-18, dataset previo al write path v2) |
| operaciones con >1 fila de `sales` (`operation_id`) | 122 |
| `stock_movements` `reference_type='sale'` **huérfanos** | 62 |
| `sales_orders` con `sale_operation_id` colgando | **6 / 120** |
| `customer_account_movements` | **0 filas** (ledger cta cte todavía vacío) |

### Forma real del modelo (importa para la reconciliación)

- La operación legacy es **N filas de `sales`/`purchases` con el mismo `operation_id`**, una por producto (122 operaciones multi-fila en prod), y la ruta canónica de creación (`rpc_create_sale_operation_v2`) escribe **exactamente 1 `sale_items` por fila de header** → la relación viva es **1 header : 1 línea**.
- Las 23 ventas con 2 líneas son de un único día (2026-04-18) y solo una de sus líneas matchea el `product_id` del header: residuo del importador de variantes + backfill de C-20, no del write path actual.
- **RN-97 sigue vigente**: el header plano es la fuente que el usuario edita; la línea lo espeja.

## Goals / Non-Goals

**Goals**

1. Que después de editar una operación, sus líneas existan y espejen exactamente el header resultante (producto, cantidad, precio, subtotal).
2. Que la edición **no re-precifique la historia**: el costo congelado sobrevive a una corrección que no cambia el producto.
3. Reutilizar la lógica de congelamiento ya escrita en la ruta de creación en vez de duplicarla.
4. Preservar íntegros los guards, ACLs, idempotencia de stock y semántica de tenancy vigentes.

**Non-Goals** (documentados como OQ, no se tocan acá)

- Convertir la edición en un `UPDATE` in-place que preserve `sales.id` / `operation_id` (OQ-A).
- Emitir `stock_movements` en la edición (OQ-B).
- Bloquear la edición de operaciones ya promovidas a `SalesOrder` / facturadas (OQ-C).
- Preservar `branch_id`, `canal`, `unit_id`, `cost_center_id` a través de la edición (OQ-D).
- Ajustar `customer_account_movements` (OQ-E).
- Deduplicar telemetría: cada edición vuelve a emitir `operation_created` (OQ-F).

## Decisions

### D1 — Conservar la forma REVERSE → DELETE → APPLY; agregar la línea dentro del APPLY

**Decisión**: no reescribir la RPC a `UPDATE` in-place. Se mantiene el ciclo actual y se inserta la línea en el mismo `INSERT ... RETURNING` que crea la fila nueva de header, igual que `rpc_create_sale_operation_v2`.

**Por qué**: el DELETE+INSERT es lo que hace correcta la reversa de stock por branch original, es la semántica que el frontend ya asume (manda la lista completa de ítems, no un diff), y una conversión a `UPDATE` in-place cambiaría la identidad de la operación, la aritmética de stock y el contrato del endpoint a la vez — tres frentes en un change de governance MEDIUM. La regeneración de ids es un problema real (OQ-A) pero **preexistente** y ortogonal a "la línea sigue al header".

**Alternativa descartada**: `UPSERT` de la línea sobre el `sale_id` viejo. Imposible sin cambiar D1: el CASCADE ya borró la fila cuando llega el momento de escribir. El "UPSERT" que la reconciliación necesita se resuelve con D2 (acarreo de snapshot), que consigue el mismo efecto — la línea nueva hereda el snapshot de la vieja — sin pelearse con el DELETE.

### D2 — Política de snapshot en edición: acarreo por producto, re-congelado al cambiar de producto

**Regla**: antes del `DELETE`, capturar los snapshots de las líneas de la operación en un mapa **keyed por `product_id`**. Al insertar cada línea nueva:

- `product_id` **presente** en el mapa → la línea nueva **hereda** `name_snapshot`, `sku_snapshot`, `unit_cost_snapshot`, `iva_rate_snapshot` y el valor de `snapshot_backfilled` de la línea vieja. `quantity`, `price` y `subtotal` se recalculan desde el payload.
- `product_id` **ausente** (producto cambiado, ítem agregado, u operación que nunca tuvo línea) → snapshot **fresco** de `products` (`name`, `sku`, `cost`) leído en el mismo `SELECT ... FOR UPDATE` que la RPC ya hace para el guard de variantes → **cero lecturas extra**.
- `product_id IS NULL` (línea de servicio) → **no** se escribe línea, igual que en la creación.
- Colisión (mismo `product_id` en dos líneas viejas): `DISTINCT ON (product_id) ... ORDER BY product_id, id` → determinístico y reejecutable.

**Fundamento de dominio**: `modelo-dominio-aliadata-v3.md` congela el snapshot **a la emisión** porque el snapshot responde "¿cuánto me costaba ESTA cosa cuando la vendí?". Una corrección de cantidad o de precio de venta es la misma emisión con un dato administrativo corregido: el costo de adquisición no cambió porque el usuario arregló un typo. Re-congelar ahí significaría que **cada edición reescribe el margen histórico con el costo de hoy** — exactamente el bug que `v3-snapshot-pattern` vino a cerrar, reintroducido por la puerta de atrás. Cambiar el producto, en cambio, es otra cosa vendida: el snapshot viejo pasaría a mentir sobre un producto que la línea ya no referencia.

Esto **valida** la recomendación de partida del encargo y la ancla: el spec `document-snapshots` hoy dice "toda ruta de creación de línea confirmada SHALL congelar ... desde el maestro `products`"; el requirement no contempla la edición, y por eso este change lo extiende explícitamente en vez de dejar la ambigüedad viva.

**Alternativa descartada**: re-congelar siempre. Más simple de escribir (una rama menos) y consistente con "el snapshot refleja el maestro al momento de escribir la fila", pero convierte el editor de ventas en una máquina de reescribir la rentabilidad histórica: en un negocio con inflación mensual, editar una venta de julio en agosto le cambia el margen sin que nadie lo pida.

### D3 — Un solo interruptor: el flag `sale_items_rpc_v2` ya existente

La escritura de línea en edición se condiciona al mismo flag que la creación, con el patrón textual ya vigente en `rpc_create_purchase_operation`:

```sql
SELECT enabled INTO v_flag_on
FROM public.account_feature_flags
WHERE account_id = v_account_id AND flag_key = 'sale_items_rpc_v2'
LIMIT 1;
v_flag_on := COALESCE(v_flag_on, true);   -- ausencia de fila = ENCENDIDO (opt-out)
```

Un kill-switch que apagara la creación pero dejara la edición escribiendo produciría un estado híbrido peor que cualquiera de los dos consistentes. El flag es además el rollback barato: si el acarreo de snapshot resulta equivocado, se apaga por cuenta sin redeploy.

### D4 — Reutilización: helper SQL único para resolver el snapshot

Regla de proyecto: reutilizar antes que repetir. Lo que se repetiría cuatro veces (venta/compra × acarreo/fresco) es **la decisión** de qué snapshot usar, no el `INSERT` (que difiere de tabla). Por eso se extrae **una** función:

```sql
public.op_line_snapshot(p_prev jsonb, p_name text, p_sku text, p_cost numeric) RETURNS jsonb
-- p_prev = snapshot de la línea vieja de ese product_id (NULL si no había)
-- devuelve {name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot, snapshot_backfilled}
```

`IMMUTABLE`, `SECURITY INVOKER`, `SET search_path = public`, sin I/O (recibe los valores del maestro que la RPC ya leyó). ACL: `REVOKE ALL ... FROM PUBLIC, anon, authenticated` — se invoca únicamente desde adentro de las RPCs `SECURITY DEFINER`, donde el chequeo de EXECUTE corre contra el definer. Así no agrega superficie y no despierta `test_function_acl_gate.sql`.

**Alternativa descartada**: un helper gordo `write_operation_line(kind, ...)` que hiciera el INSERT en la tabla correcta con SQL dinámico. Menos líneas, pero mete `EXECUTE format(...)` en el corazón de dos RPCs `SECURITY DEFINER` — mala relación riesgo/beneficio.

### D5 — Compras: la línea **y** el snapshot del header

`rpc_create_purchase_operation` congela `name_snapshot`/`sku_snapshot`/`unit_cost_snapshot` **en el header `purchases`** (D2 de `v3-snapshot-pattern`: es el write path real de compra) *además* de escribir `purchase_items`. La RPC de edición no escribe ninguno de los dos. Este change repara **ambos**, con la misma regla de acarreo de D2 — si no lo hiciera, editar una compra dejaría el header con los snapshots en NULL y la valuación de inventario cayendo al costo actual.

### D6 — Backfill de las operaciones históricas sin línea — **GATEADO a sign-off del PO**

Alcance real: **119 ventas** y **186 compras con producto** (las 4 de servicio no llevan línea, por diseño).

La línea es **reconstruible** del header (`product_id`, `quantity`, `price = amount`, `subtotal = COALESCE(total, amount * quantity)`); el `account_id` sale del header. Lo **incognoscible** es el costo unitario real al momento de aquella venta.

**Recomendación, por tabla:**

| | `name`/`sku` | `unit_cost_snapshot` | `snapshot_backfilled` |
|---|---|---|---|
| **compras** con snapshot en el header (179/186) | del header | **del header** (es un snapshot genuino, solo guardado en el header) | `false` |
| **compras** sin snapshot en el header (7) | de `products` hoy | **NULL** | `true` |
| **ventas** (119) | de `products` hoy | **NULL** | `true` |

**Por qué NULL y no "el costo de hoy congelado"**, cuando el spec vigente de `document-snapshots` admite un backfill best-effort desde el maestro: porque el consumidor canónico ya resuelve `COALESCE(si.unit_cost_snapshot, pr.cost)`. Con NULL, el margen de esas operaciones se calcula **exactamente igual que hoy** — el backfill agrega la línea (que es lo que falta y desbloquea historial de cliente, rentabilidad por producto y KPIs) sin mover un solo número, y sin afirmar nada sobre el pasado. Congelar el costo de agosto sería una **afirmación positiva falsa** ("en julio esto costaba X") que, una vez escrita, es indistinguible de un snapshot genuino para cualquier consumidor que no mire `snapshot_backfilled` — y varios no lo miran. NULL miente menos: no dice nada.

**Sesgo que hay que documentar igual**: con NULL, la rentabilidad histórica de esas 119 ventas **sigue moviéndose** cuando el PO remarca el costo de un producto. Es el comportamiento actual, no una regresión, pero no es "la verdad": es un margen calculado a costo corriente. Queda declarado en el spec para que nadie lo lea como dato congelado.

**Forma de entrega**: `scripts/sql/backfill_operation_lines.sql`, idempotente (`WHERE NOT EXISTS`), con conteos dry-run al inicio, **no** como migración. El merge a `main` aplica migraciones automáticamente; un backfill de datos gateado a sign-off no puede viajar en ese tren.

### D7 — Gates de comportamiento (Strict TDD)

Archivo nuevo `supabase/tests/test_operation_edit_lines.sql`, registrado como paso propio en `.github/workflows/KPI_Validation.yml`. Se elige archivo nuevo y no extender `test_sale_items_rpc_v2_activation.sql` porque ese gate tiene una identidad cerrada (activación opt-out del flag en **creación**) y sus anchors ya están consumidos; se reutiliza sí su **patrón**: anchors sintéticos vía `handle_new_user`, simulación de sesión con `set_config` local a la transacción (**nunca contra prod**), acumulación de fallos en `text[]` y un único `RAISE EXCEPTION` final.

Casos RED→GREEN (cada uno con su triangulación):

1. Editar **cantidad** de una operación con línea → sigue habiendo exactamente 1 línea, con la cantidad nueva y el **mismo** `unit_cost_snapshot` — incluso después de mover `products.cost` entre la creación y la edición (control positivo del acarreo).
2. Editar **producto** → la línea apunta al producto nuevo con `unit_cost_snapshot` = costo **actual** del producto nuevo (control negativo: no hereda).
3. Editar una operación **sin línea previa** → la línea nace, con snapshot fresco.
4. Editar **precio** → `price` y `subtotal` nuevos, `unit_cost_snapshot` intacto.
5. **Compras**: espejo de 1-4, y además el header `purchases` queda con sus `*_snapshot` poblados.
6. **Línea de servicio** (`product_id NULL`) → ninguna línea, sin error.
7. **Kill-switch** (`enabled = false`) → la edición no escribe línea; el resto del comportamiento (stock, header) idéntico.
8. **Reejecución / doble submit**: la segunda llamada con los `sale_ids` ya borrados falla con `P0404` (comportamiento vigente) y **no** deja líneas duplicadas ni huérfanas.
9. **No regresión de stock**: `branch_stock` después de una edición es igual al valor pre-cambio (reversa + aplicación), y los guards (`P0409` sin stock, `P0403` producto ajeno, `P0422` producto con variantes, `P0400` cantidad ≤ 0) siguen disparando.

## Risks / Trade-offs

- **[El acarreo hereda un snapshot equivocado si el producto fue reemplazado conservando el `product_id`]** (mismo id, producto redefinido en el maestro) → el flag `sale_items_rpc_v2` apaga la escritura por cuenta sin redeploy; y el caso es indistinguible del legítimo por construcción, así que la alternativa (re-congelar siempre) tampoco lo resuelve: solo elige mentir en el otro sentido, y en todos los casos a la vez.
- **[La operación sigue cambiando de identidad en cada edición]** (`sales.id` y `operation_id` nuevos → `stock_movements` huérfanos, `sales_orders.sale_operation_id` colgando) → **no lo empeora ni lo arregla**; queda medido (62 y 6 filas en prod) y elevado como OQ-A/OQ-C con dueño.
- **[`p_items` declara `quantity integer` en el `jsonb_to_recordset` de la edición, mientras la creación usa `numeric`]** → editar una operación de cantidad fraccional la trunca. No se toca en este change (cambiaría el resultado del header, no solo la línea), pero **el gate 1 debe usar cantidad entera** para no atribuirle a la línea un bug del header. Queda como OQ-G.
- **[Cuerpo de la RPC crece ~40 líneas × 2]** → mitigado por D4 (la decisión de snapshot vive en un solo lugar) y por reusar el `SELECT ... FOR UPDATE` existente en vez de agregar lecturas.
- **[Migración auto-aplicada al mergear]** → `CREATE OR REPLACE` sin cambio de firma, idempotente por construcción, verificable con el mismo patrón de fingerprint before/after que ya usa `KPI_Validation.yml`. Rollback = re-aplicar la definición previa (`20260623000001`) o apagar el flag.

## Migration Plan

1. `supabase/migrations/20260926000001_edicion_operaciones_lineas.sql` (siguiente a `20260925000001`, el `MAX(version)` verificado en prod):
   - `CREATE OR REPLACE FUNCTION public.op_line_snapshot(...)` + `REVOKE ALL ... FROM PUBLIC, anon, authenticated`.
   - `CREATE OR REPLACE` de ambas RPCs de update, **misma firma exacta** → sin `DROP`, sin re-`GRANT` (los GRANT/REVOKE vigentes sobreviven), sin riesgo de `42725`.
   - Re-declarar de todos modos `GRANT EXECUTE ... TO authenticated` / `REVOKE ... FROM anon` al pie, como hacen las migraciones previas: es idempotente y protege si alguna vez cambia la firma.
2. Merge → Supabase GitHub aplica la migración; Vercel redeploya sin cambios de frontend.
3. Verificación post-deploy (solo SELECTs): editar una operación de prueba y comprobar `sale_items` presente con el snapshot esperado; conteo de ventas/compras sin línea no crece.
4. **Backfill**: recién tras sign-off del PO, ejecutando el script a mano con los conteos dry-run a la vista.
5. **Rollback**: `UPDATE account_feature_flags SET enabled = false` para la cuenta afectada (apaga línea en creación y edición), o re-aplicar la definición previa de las RPCs.

## Open Questions

- **OQ-A — Identidad de la operación**: la edición regenera `sales.id` y `operation_id`. Deja 62 `stock_movements` huérfanos y rompe cualquier referencia externa. *Recomendación*: change propio que convierta la edición en `UPDATE` in-place preservando ids, con la reversa de stock expresada como contramovimiento. No acá.
- **OQ-B — Ledger de stock en la edición**: la edición mueve `branch_stock` pero **no** escribe `stock_movements` (la creación sí). El ledger y el saldo divergen en cada edición. *Recomendación*: emitir `sale_return`/`sale` (y `purchase_return`/`purchase`) como hace `rpc_reverse_stock_movement` en el delete. Ya existió ese cableado (`20260527000002_wire_movements_to_rpcs.sql`) y **se perdió** en una redefinición posterior — vale la pena un gate anti-regresión cuando se retome.
- **OQ-C — Editar lo ya facturado**: `sales_orders` tiene 120 filas, **todas** con `sale_operation_id`, y 6 ya cuelgan de un `operation_id` inexistente. Editar una venta legacy ya promovida/facturada contradice el requirement "Líneas inmutables tras la confirmación del documento" de `document-snapshots`. **No se cambia la política acá** (la venta legacy es mutable por diseño; ver `openspec/explore/2026-06-27-promote-legacy-sale-to-order.md` §3), pero la inconsistencia de dominio queda registrada. *Recomendación*: bloquear la edición cuando existe `sales_orders.sale_operation_id = operation_id` con estado confirmado, y ofrecer nota de crédito.
- **OQ-D — Dimensiones que la edición pierde**: `branch_id` (las filas nuevas nacen con `NULL` → branch default: la reversa devuelve el stock a la sucursal original y lo descuenta de la default), `canal`, `unit_id`, `cost_center_id`. El gate de stock de la edición usa además `Σ branch_stock` global mientras la creación usa el gate **per-branch** de C-26. Divergencia real de C-26.
- **OQ-E — Cuenta corriente**: si una venta editada tuviera cargo en `customer_account_movements`, la RPC no lo ajusta. Hoy la tabla tiene **0 filas** en prod, así que el hueco es teórico — pero se vuelve real en cuanto se active cta cte.
- **OQ-F — Telemetría**: `trg_analytics_operation_created` es `AFTER INSERT`, así que cada edición vuelve a emitir `operation_created`. Las ediciones inflan el conteo de operaciones creadas.
- **OQ-G — `quantity integer` en la edición**: la creación acepta `numeric`; la edición trunca. Editar una operación de 2.5 unidades la convierte en 2.
