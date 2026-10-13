# Design — `compras-gastos-sucursal-por-defecto`

> **Governance**: MEDIA con tramo **ALTO**. Se reescriben las funciones que mueven stock, caja y banco en el alta y la edición de compras, y la edición de gastos.
>
> - Ninguna línea de SQL se escribe antes del checkpoint 0 (cuerpo **vivo de producción**).
> - Si el PO elige el backfill (OQ-1 = (b)), la migración de datos la mergea él.

## Context

### La decisión

El 2026-10-09 el PO firmó el change hermano `ventas-sucursal-por-defecto` con «vamos con todo lo recomendado». Su OQ-3 quedó en la opción (a):

> un change hermano `compras-gastos-sucursal-por-defecto` que cubra el alta y la edición de compras, el opt-in de caja de una compra sin sucursal (hoy se ofrece y el servidor lo rechaza siempre), la edición de gastos y el rótulo de gastos. **No** toca las compras históricas, que conservan su sucursal vacía como firmaste en `caja-compras-cobranzas`.

El 2026-10-10 pidió «arrancá». El molde de este documento es el design archivado de ventas (`openspec/changes/archive/2026-10-10-ventas-sucursal-por-defecto/design.md`, D1-D13): las decisiones que se heredan tal cual se citan, no se repiten.

### Estado actual

Verificado contra `origin/main` (`22c2bca6`) y contra la base local. La base local tiene 321 migraciones, con `MAX = 20261074000001`: le faltan las dos de `ventas-sucursal-por-defecto` (`20261075000001`/`2`), que no tocan ninguna de las funciones de este change (verificado con grep). Producción tiene 323, `MAX = 20261075000002` (dato del orquestador, 2026-10-10).

**Alta de compra** — `rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid, date)`:

- Última definición en `20261062000001_ventas_unidades_conversion.sql:700`. `md5(replace(prosrc, E'\r', ''))` local `0366977251522a469d123c4d143f42f9`, el mismo que `remitos-compra` midió en producción el 2026-10-03.
- `SECURITY DEFINER`, **sin `COMMENT`**, `EXECUTE` para `postgres`, `authenticated` y `service_role`; `anon` sin `EXECUTE`.
- Usa el `p_branch_id` **crudo** en la validación y en seis puntos más:
  1. la validación de la sucursal elegida (L821) sólo mira `is_active = TRUE`: una sucursal **cerrada** (`status = 'closed'`) pasa;
  2. el `INSERT` en `purchases` de la línea con producto (L962);
  3. `c21_apply_branch_stock_delta(v_account_id, producto, p_branch_id, qty)` (L988). Con `NULL` resuelve **por dentro** `c26_default_branch`. Si la cuenta no tiene ninguna sucursal, crea "Casa Central" al vuelo; si no tiene ninguna operativa, ingresa el stock en el *fallback* inactivo o cerrado;
  4. el `INSERT` en `stock_movements` (L999);
  5. el `INSERT` en `purchases` de la línea sin producto (L1013);
  6. el opt-in de caja (L1054): `v_cash_session_branch IS DISTINCT FROM p_branch_id`. El comentario del propio cuerpo lo dice: *«a diferencia del gasto, la compra no resuelve una sucursal por defecto»*. Con `p_branch_id NULL` **ninguna** sesión real satisface la condición, y el servidor rechaza con `P0422 cash_optin_requires_open_session`;
  7. y el movimiento bancario (L1075): `_pay_register_operation_bank_movement(…, p_date, p_branch_id, NULL)` escribe `bank_movements.branch_id = NULL`.

  (Los puntos 2 a 7 son los seis que persisten o comparan la sucursal; el 1 es la validación.)
- **Consecuencia sobre el ledger**: una compra sin sucursal suma el stock en la principal y escribe su movimiento con `branch_id = NULL`. Eso viola el «Invariante de reconstrucción» de `inventory-single-ledger`, que agrupa por `(product_id, branch_id)`.
- **Consecuencia sobre la caja** (el defecto que el PO nombró en la OQ-3 de ventas):
  - `useCashOptin` resuelve la sucursal efectiva como `branchId || resolveDefaultBranch(branches)` (`hooks/use-cash-optin.ts:107`) y ofrece la sesión de la principal;
  - el formulario de compra la ofrece **pre-marcada** (`purchase-form.tsx:174`, `registerInCash = true`) y la manda (`:665`);
  - el servidor la rechaza.

  Toda compra en efectivo de hoy sin sucursal elegida, con la caja de la principal abierta, falla al confirmar salvo que el usuario destilde la casilla. Les pasa a todas las cuentas sin módulo de sucursales, porque el selector no se muestra (`BranchSelect` devuelve `null`). El caso «elegible y tildado» de `__tests__/components/purchase-form-cash-optin.test.tsx` (L203-213, con `BranchSelect` mockeado y la sucursal en `null`) fija justamente ese payload: pasa en vitest y el servidor lo rechaza.

**Edición de compra** — `rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean)`:

- Última definición en `20261062000001:2263`, `md5` local `23558c073cf71d08ea4a0dfb15079555`, el mismo que midió `remitos-compra` en producción.
- `COMMENT` vivo de `caja-compras-cobranzas` (D8), que no menciona la sucursal. Misma ACL que el alta.
- Inmutable si tiene cargo en cuenta corriente, movimiento bancario o movimiento de caja (tres `P0423`, antes de cualquier escritura): sólo se editan compras **sin dinero posteado**.
- Tri-estado de sucursal (L2429-2442): informada con valor reimputa (`P0422 branch_invalid` si es ajena, inactiva o cerrada), informada con `NULL` desimputa, y sin informar conserva `v_old_branch_id`.
- La pata REVERSE devuelve el stock con `op_stock_movement(…, v_old_purchase.branch_id, …)`, y la pata APPLY usa `v_final_branch_id`.
- `op_stock_movement` escribe `COALESCE(p_branch_id, c26_default_branch(…))` en el movimiento: en la edición sólo la **fila** de compra puede quedar `NULL`.
- El formulario manda siempre `branchId` (`purchase-form.tsx:606`). Editar una compra histórica sin sucursal la deja `NULL`, y elegir «Sin sucursal (general)» la desimputa.

**Borrado de compra** — `rpc_delete_purchase_operation`, viva en `20261018000001`: no se toca.

- Repone el stock con `rpc_reverse_stock_movement`, que usa la sucursal **del movimiento** (con `NULL`, la principal vigente al borrar).
- Usa `_stock_apply_delta(…, p_allow_negative = TRUE)`, que con faltante hace *floor* a 0 con un ajuste `floor_on_purchase_delete`. Rechaza una sucursal cerrada (`P0422 branch_closed`) y no mira `is_active`.

**Alta de gasto** — `rpc_create_expense`, viva en `20261043000001:1258`, `md5` local `4a5b5ae1…`:

- Ya resuelve `v_gate_branch := COALESCE(p_branch_id, c26_default_branch(…))` (L1358) y lo usa en el `INSERT`, en el opt-in de caja y en el banco (`gastos-forma-pago` D6).
- Rechaza una sucursal elegida inactiva (`P0404`) o cerrada (`P0422 branch_closed`).
- **No** tiene guard de "sin sucursal operativa": persiste el *fallback* de `c26_default_branch` (inactivo o cerrado), o `NULL` si la cuenta no tiene sucursales.
- `rpc_import_expenses` llama a `rpc_create_expense` fila por fila, con la sucursal de la fila (por nombre) o `p_default_branch_id`. Con `NULL`, el alta resuelve la principal.

**Edición de gasto** — `rpc_update_expense`, viva en `20261043000001:1537`:

- `md5` local `360d4dc4320208b56eb106d82c7b38c3`. Su `COMMENT` (`gastos-forma-pago`) dice «aplica el contrato tri-estado … a forma de pago, sucursal y centro de costo».
- Inmutable con dinero posteado (`P0423`).
- Tri-estado de sucursal (L1665-1678): con `NULL` informado desimputa, y sin informar conserva `v_old.branch_id`.
- El formulario de gasto manda siempre `branchId` (`expense-form-v2.tsx:101-106`). Editar cualquier campo de un gasto histórico sin sucursal lo deja `NULL`.
- No mueve dinero ni stock.

**Sucursal principal y helpers del cliente** (heredados de ventas, sin cambios):

- `c26_default_branch(uuid)`, `md5` `4fb12c57…`: la sucursal activa y operativa más antigua; si no hay ninguna, la más antigua a secas.
- `frontend/lib/default-branch.ts` (`resolveDefaultBranch`) es su espejo en el cliente.
- `components/branches/BranchSelect.tsx` ya tiene `allowUnassigned`, `label` y `fallbackBranchId`.
- `lib/operation-errors.ts` ya traduce `no_branch_found`, `branch_closed` y `branch_invalid`.
- `purchase-form.tsx` usa `humanizeOperationError`. `expense-form-v2.tsx` no: muestra el mensaje crudo (preexistente).

**Superficies con «Sin sucursal…»**:

- `purchase-form.tsx:777-782`, `placeholder="Sin sucursal (general)"`;
- `expense-form-v2.tsx:231-236`, igual;
- `gastos/expense-import-dialog.tsx:688-693`, `placeholder="Sin sucursal por defecto"`;
- `quotes/QuoteForm.tsx:558-561`: el presupuesto queda fuera.

**Otros escritores** (inventario sobre la base local):

- Funciones con `INSERT` en `purchases`:
  - las del alcance;
  - `rpc_atomic_create_purchase` (dos overloads) y `rpc_create_purchase_operation_v2(text, date, text, jsonb)`: legacy, sólo `postgres`/`service_role`, **sin llamadores** en `backend/`, `frontend/` ni `supabase/functions/`.
- Funciones con `INSERT` en `expenses`: sólo `rpc_create_expense`.
- `authenticated` conserva `INSERT`/`UPDATE` a nivel tabla sobre `purchases` y `expenses`, con políticas `is_account_writer`.
- `frontend/lib/supabase/services.ts:68` (`services.createExpense`) inserta en `expenses` por PostgREST, pero ningún código de producto lo llama (sólo un test de identidad de sesión).
- `InvoiceAIButton` crea compras con `addPurchaseOperation`, sin sucursal: el servidor resolverá la principal.

**Lectores**:

- Filtran compras y gastos por igualdad de sucursal, y dejan las `NULL` fuera del filtro: `rpc_dashboard_kpi_summary` (gastos `e.branch_id`, compras `pu.branch_id`) y `get_dashboard_financials` (gastos y compras).
- `rpc_branch_report` lee ventas y **gastos** (no compras) y rotula las `NULL` como «Sin sucursal».
- `generate-export` muestra «Principal» para las compras y los gastos `NULL` (`index.ts:93`, `:118`).

**Histórico medido** (producción, sólo lectura, citado; no se re-mide en el propose):

- `caja-compras-cobranzas` (2026-09-02): 0 de 507 compras tenían sucursal.
- `remitos-compra` (2026-10-03): 663 filas en 127 operaciones de compra, **106 sin sucursal** (12 de las 33 de los últimos 30 días; las otras 21 eligieron sucursal desde que la cadena dejó de descartarla).
- `gastos-forma-pago`: 175 gastos históricos sin sucursal.

El apply re-mide los tres conteos en el checkpoint 0 (dato informativo, no bloquea).

**Changes activos que tocan lo mismo**:

- **`remitos-compra` tanda B** (sin aplicar):
  - extrae `_purchase_operation_core` **desde el cuerpo vivo** de `rpc_create_purchase_operation`, que queda como envoltorio fino (D8 de aquél);
  - reescribe `rpc_atomic_update_purchase_operation` para sumar el `P0423 delivery_note_purchase_locked` antes de los `P0423` de dinero (D9);
  - reescribe `rpc_delete_purchase_operation`.

  Su conversión remito → compra pasa siempre la sucursal del remito, que es obligatoria («Ingresa a», `BranchSelect required alwaysVisible`) y se valida activa y abierta. Su número de migración es "el siguiente libre" al momento de su apply (tarea 6.0). Sus deltas de spec sólo **agregan** requirements a `purchase-operation` y `operation-edit-context`, así que no chocan con los `MODIFIED` de este change.
- **`remitos-venta`**: sin migraciones pendientes.

## Goals / Non-Goals

**Goals:**

1. Ninguna compra **nueva ni editada** queda con `purchases.branch_id = NULL`. La sucursal guardada es, por construcción, la misma variable con la que entra el stock, se escribe el movimiento de stock, se valida la caja y se registra el banco.
2. Ningún gasto **editado** queda sin sucursal: la edición aplica la misma regla que el alta.
3. El opt-in de caja de una compra sin sucursal elegida deja de fallar: servidor y cliente usan la misma principal.
4. Los formularios de compra y de gasto y el importador de gastos dejan de mostrar «Sin sucursal…» y muestran lo que el servidor va a guardar.
5. Cero regresiones en compra directa, remito → compra (si ya existe), edición con sucursal explícita, borrado, caja, banco, cuenta corriente del proveedor, idempotencia, gastos, importador de gastos, firmas, ACLs y gates de integridad.

**Non-Goals:**

- **Relleno de compras y gastos históricos** (OQ-1, recomendación (a)). Se documenta la opción (b) por si el PO la elige.
- **`NOT NULL` o `CHECK`** sobre `purchases.branch_id` o `expenses.branch_id`, y **revocar la escritura directa por PostgREST** de `authenticated` sobre esas tablas. Va junto con el candidato `NOT NULL` de `sales.branch_id` (D8 de ventas).
- **Retirar** `rpc_atomic_create_purchase`, `rpc_create_purchase_operation_v2` y `services.createExpense` (D13).
- **Guard de "sin sucursal operativa" en el alta del gasto** (OQ-3, recomendación (a)).
- **Reversa y edición de una compra cuya sucursal guardada dejó de operar.**
  - Cerrada: el borrado y la edición rechazan con `P0422`.
  - Desactivada y vacía: la reversa del borrado hace *floor* a 0 en esa sucursal en vez de restar donde está el stock.

  Es el mismo candidato OQ-8 que dejó ventas: preexistente para toda compra con sucursal elegida, y desde este change alcanza a todas las nuevas. Queda nombrado.
- **Validar el stock de la edición contra la sucursal efectiva** y **guard de "última sucursal operativa" en `rpc_deactivate_branch`**: candidatos de ventas, sin cambios.
- **Sucursal principal configurable** y **desempate de `c26_default_branch`**: D4 de ventas, sin cambios.
- **El presupuesto** (`QuoteForm`) conserva «Sin sucursal (general)».
- **Traducir los errores del formulario de gasto** con `humanizeOperationError`. Preexistente; con OQ-3 = (a) este change no agrega ningún error nuevo al gasto. Si el PO elige (b), entra (tarea 7.4).
- **Lectores**: ninguno cambia su código (D11).
- **Backend**: no cambia de lógica (D10).

## Decisions

### D1 — Compra: un solo contrato, resuelto en la RPC

`rpc_create_purchase_operation` (o el núcleo `_purchase_operation_core`, D6) resuelve **una sola vez**, después de validar la sucursal elegida, `v_gate_branch := COALESCE(p_branch_id, public.c26_default_branch(v_account_id))`, y usa esa variable en los seis puntos del Context: los dos `INSERT` en `purchases`, `c21_apply_branch_stock_delta`, el `INSERT` en `stock_movements`, la condición de sucursal del opt-in de caja y `_pay_register_operation_bank_movement`.

Es el mismo principio que D1 de ventas: **la sucursal que se guarda es la que movió el stock**.

- Pasarle `v_gate_branch` explícita a `c21_apply_branch_stock_delta`, en vez de dejar que resuelva por dentro, hace que el delta y la fila usen la **misma lectura** de la principal. Bajo `READ COMMITTED`, un cierre concurrente de sucursal entre dos llamadas a `c26_default_branch` podría separarlas.
- El opt-in de caja compara contra `v_gate_branch`, como el gasto y la venta. Se cierra el rechazo silencioso del Context sin tocar el cliente: `useCashOptin` ya resuelve la misma principal (D10 de ventas).
- El banco recibe `v_gate_branch`, como el gasto («la sucursal EFECTIVA, la misma que se persistió en el gasto») y la venta.

Alternativas rechazadas (las mismas de D1 de ventas, por las mismas razones):

- un disparador `BEFORE INSERT` en `purchases`: resolvería la principal en otra sentencia y no cubre `stock_movements`;
- resolverla en FastAPI: duplica la regla y no cubre PostgREST, porque la RPC tiene `EXECUTE` para `authenticated`;
- sólo preseleccionarla en la interfaz: no cubre la cuenta sin módulo, ni `POST /purchases` sin el campo, ni `InvoiceAIButton`.

### D2 — Alcance de la reescritura

| Función | Cambio |
|---|---|
| `rpc_create_purchase_operation`, o `_purchase_operation_core` (D6) | (a) Validación de la sucursal elegida: además de `is_active`, `status = 'closed'` → `RAISE 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422'`. Es el bloque literal de `rpc_create_expense` (L88-99 de su `pg_get_functiondef`), sujeto a OQ-2. (b) `v_gate_branch` y, cuando `p_branch_id IS NULL`, el guard `P0422 no_branch_found` si la resuelta es `NULL` o no está operativa (`is_active AND status = 'active'`), **antes** del `INSERT` en `operation_idempotency` (D3). (c) `v_gate_branch` en los seis puntos de D1. |
| `rpc_atomic_update_purchase_operation` | Después del bloque tri-estado de sucursal y **antes** de cualquier escritura (la pata REVERSE): si `v_final_branch_id` quedó `NULL`, `v_final_branch_id := public.c26_default_branch(v_account_id)` y el mismo guard `P0422 no_branch_found`. La validación de una sucursal explícita (`P0422 branch_invalid`) no cambia, y una sucursal vigente no nula se preserva sin revalidar. La pata REVERSE sigue devolviendo a `v_old_purchase.branch_id`. Si `remitos-compra` tanda B ya mergeó, su `P0423 delivery_note_purchase_locked` se conserva tal cual (D6). |
| `rpc_update_expense` | Después del bloque tri-estado de sucursal y antes del `UPDATE`: `v_final_branch_id := COALESCE(v_final_branch_id, public.c26_default_branch(v_account_id))`. **Sin** guard de operativa: es la regla literal del alta del gasto (D4, OQ-3). |
| `rpc_create_expense` | **Sin cambios** con OQ-3 = (a). Con (b), el mismo guard `no_branch_found` cuando `p_branch_id IS NULL`, antes del `INSERT`. |

**El texto del guard** sigue el de ventas, ajustado a cada documento: `'no_branch_found: la cuenta no tiene una sucursal operativa a la cual asignar la compra'`. El cliente ya lo traduce: `lib/operation-errors.ts`, con `NO_BRANCH_FOUND_ERROR = /no_branch_found/`.

### D3 — Compra sin sucursal operativa: `P0422 no_branch_found`; sucursal elegida cerrada: `P0422 branch_closed`

Es la paridad con D3 de ventas.

**Sin sucursal operativa.** Hoy, en una cuenta sin sucursal operativa, la compra ingresa el stock en el *fallback* inactivo o cerrado: invisible e invendible, la clase del incidente del 22-08. En una cuenta sin ninguna sucursal, crea "Casa Central" como efecto lateral. Con el guard, la compra se rechaza con el mismo token que la venta, y el formulario traduce la salida: crear o reabrir una sucursal. Es un estado de borde: `rpc_deactivate_branch` permite desactivar la última sucursal vacía.

**Sucursal elegida cerrada** (OQ-2). La spec `branches` ya exige `P0422 branch_closed` para compras («Operaciones solo contra sucursales operativas»), y el alta de compra no lo cumple porque sólo mira `is_active`. Pasan dos cosas:

- con el guard de la principal y sin este chequeo, la compra rechazaría una sucursal no operativa resuelta **implícitamente** pero aceptaría la misma sucursal elegida **explícitamente**;
- la edición de compra ya rechaza una sucursal cerrada (`branch_invalid`). Una compra creada en una sucursal cerrada no se puede editar sin cambiar de sucursal.

Recomendación (a): rechazar, alineando el alta con la spec vigente. El apply mide en producción cuántas compras se registraron en una sucursal ya cerrada (tarea 0.3); el dato es informativo.

Alternativas:

- crear "Casa Central" al vuelo: rechazada, como en ventas;
- persistir el *fallback*: rechazada; la compra quedaría donde nadie la ve;
- no tocar el chequeo de cerradas y corregir la spec: es la OQ-2 (b).

### D4 — Gasto: la edición aplica la regla del alta; el alta no cambia

La edición resuelve un nulo, informado o vigente, con `COALESCE(…, c26_default_branch)`, **exactamente** como el alta (`rpc_create_expense` L1358). Lo que el gasto guarda al crearse y al editarse sale de la misma regla.

**Sin guard de operativa** (OQ-3, recomendación (a)):

- el alta del gasto persiste el *fallback* desde `gastos-forma-pago`, y el PO pidió explícitamente no tocar el alta;
- un gasto no mueve stock, así que el *fallback* no esconde mercadería;
- rechazar un gasto convierte un problema de configuración (todas las sucursales dadas de baja) en un problema de registro, la misma doctrina que `gastos-forma-pago` D1 aplicó a la caja.

El costo, declarado: en ese estado de borde un gasto puede quedar en una sucursal inactiva o cerrada que el formulario no lista. Su edición desde el formulario rechaza esa sucursal con `branch_invalid` hasta que se elija otra (preexistente para el alta). La opción (b) de OQ-3 lo cierra rechazando también el gasto, a costa de reescribir `rpc_create_expense` y de que el importador marque esas filas con error.

### D5 — Edición: `NULL` significa "la principal" para la compra y el gasto

| Llamada | Antes | Después (compra) | Después (gasto) |
|---|---|---|---|
| sin informar, fila con sucursal X | conserva X | conserva X | conserva X |
| sin informar, fila `NULL` (histórica) | conserva `NULL` | **principal** (o `no_branch_found`) | **principal** (o el *fallback*) |
| informada con X válida | reimputa a X | reimputa a X | reimputa a X |
| informada con `NULL` | desimputa | **principal** (o `no_branch_found`) | **principal** (o el *fallback*) |
| informada con X ajena o cerrada | `P0422 branch_invalid` | sin cambios | sin cambios |

En la compra, el `COALESCE` y el guard corren **antes** de la pata REVERSE, igual que la validación (gate 2.9 de `edicion-preserva-contexto`): una edición inválida no revierte ni reaplica stock.

- La pata REVERSE de una fila `NULL` ya caía en la principal vigente (`op_stock_movement`), y la APPLY ahora suma en esa misma sucursal: el neto es cero, igual que hoy.
- La pata REVERSE de una fila con sucursal B informada como `NULL` resta de B y la APPLY suma en la principal: es un traslado, igual que una reimputación explícita.

**BREAKING (contrato interno de edición).** Desaparece la intención "desimputar la sucursal" para la compra y el gasto, y deja de preservarse un `branch_id` vigente nulo. Es la consecuencia directa de la decisión del PO: con la desimputación viva, una edición volvería a crear exactamente lo que este change elimina.

- Ningún consumidor depende de desimputar: los formularios dejan de ofrecer «Sin sucursal» (D9).
- Un `PUT /purchases/operation` o `PUT /expenses/{id}` con `branch_id: null` pasa a guardar la principal.
- Los requirements de `operation-edit-context` y `expense-operation` declaran la excepción en su delta, para que la spec sincronizada no quede con dos SHALL incompatibles.
- El escenario de ventas «desimputar la sucursal de una compra sigue permitido» se reemplaza.

**Efecto sobre los históricos sin backfill.** Una compra o un gasto viejos toman la principal en su **primera edición**, aunque el usuario sólo haya cambiado el importe. Es la misma regla que ventas aplicó al residuo, y es la única vía por la que un histórico gana sucursal con OQ-1 = (a).

### D6 — Coordinación con `remitos-compra` tanda B: el que aplica segundo parte del cuerpo vivo

Los dos changes reescriben las mismas funciones de compra. Ninguno espera al otro. El checkpoint 0 de este apply mira si `public._purchase_operation_core` existe en producción:

**Caso A — este change mergea primero** (la tanda B no existe todavía):

- Este change reescribe `rpc_create_purchase_operation` entero.
- La tanda B extraerá su núcleo **desde este cuerpo**: su checkpoint 6.1 encontrará un `md5` distinto del de su propose y, por su propia regla, partirá del vivo y anotará el desvío.
- La resolución de `v_gate_branch` y el guard pasan al núcleo con el resto del cuerpo. En su modo remito, `p_branch_id` es siempre la sucursal del remito (nunca `NULL`), así que el guard no se activa y el `COALESCE` es la identidad.
- Este change deja escrita, en la cabecera de su migración, en el paso de CI y en el gate, la **regla para el PR siguiente**: una migración posterior que redefina cualquiera de las tres funciones tiene que retirar el bloque de reaplicación de `20261076000001` en el mismo PR (su preflight abortaría) y apuntar el bloque (0) del gate nuevo al cuerpo que la contenga (el núcleo). Es lo mismo que la tanda B ya tiene previsto para `test_idempotency.sql` y compañía (su tarea 6.4b).

**Caso B — la tanda B mergea primero**:

- Este change reescribe `_purchase_operation_core` (donde viven los `INSERT`, el delta, la caja y el banco) y deja intacto el envoltorio `rpc_create_purchase_operation`.
- En `rpc_atomic_update_purchase_operation` parte del cuerpo de la tanda B, con su `P0423 delivery_note_purchase_locked`.
- El `v_expected` del preflight es el `md5` de esos cuerpos.
- El paso de reaplicación va **después** del de la tanda B, que reinstala sus cuerpos. Como ya hizo ventas con `20261070000001`, la primera pasada toma la rama de reescritura y la segunda imprime los `NOTICE` de reaplicación.

**En los dos casos**:

- el checkpoint 0 decide cuál aplica y lo anota en `tasks.md`;
- el número de migración se elige al escribirla (D7);
- el gate nuevo ejecuta además la conversión remito → compra, si existe, para probar que la sucursal del remito se conserva (bloque (11)).

### D7 — Reglas de la reescritura

- **Una sola migración de funciones**: `20261076000001_compras_gastos_sucursal_por_defecto.sql`. Es el siguiente número libre después de `20261075000002`, el `MAX` de producción y de `main`. Ningún change activo reserva un número: `remitos-compra` tanda B toma "el siguiente libre" en su apply y `remitos-venta` no tiene migraciones pendientes. Si la tanda B llega antes y lo toma, se renumera al siguiente libre (tarea 0.4).
- **Con OQ-1 = (b)**: `20261076000002_compras_gastos_sucursal_por_defecto_backfill.sql`, sólo de datos (D8).
- **Partir del `pg_get_functiondef` vivo de producción** de cada función (checkpoint 0.2), comparado por líneas sin `\r` contra el local y contra el archivo que la definió.
- **Preflight** (bloque `DO` inicial, molde `20261075000001`):
  - `v_expected` con el `md5(replace(prosrc, E'\r', ''))` de partida de cada función, que tiene que ser también el que dejan los **archivos** de migración, porque CI y todo stack local construyen la base desde ellos. Referencia local: alta `03669772…`, edición de compra `23558c07…`, edición de gasto `360d4dc4…`; en el caso B, los del núcleo y la edición de la tanda B;
  - `v_rewritten`, medido en el stack local después de aplicarla;
  - si el vivo no es ninguno de los dos, `RAISE EXCEPTION` sin reescribir;
  - si ya es el reescrito, `NOTICE 'compras-gastos-sucursal-por-defecto: % ya es el cuerpo de esta migración (reaplicación)'`.

  Si producción diverge de los archivos, se elige con el PO entre reconciliar primero los archivos o aceptar los dos `md5` (Migration Plan de ventas).
- **`CREATE OR REPLACE` con la misma firma**: sin `DROP`, sin overload, sin `42725`.
- **`COMMENT`**:
  - el alta de compra no tiene y no se le agrega;
  - el de la edición de compra se re-declara **idéntico** (no menciona la sucursal);
  - el de `rpc_update_expense` se re-declara con su texto vivo completo más, al final, *«compras-gastos-sucursal-por-defecto: un branch_id nulo, vigente o informado, se resuelve a la sucursal por defecto, como en el alta»*, porque «aplica el contrato tri-estado … a sucursal» deja de ser cierto para el nulo.

  Se busca con grep si algún gate fija el `md5` de esos `COMMENT` (en ventas, `test_facturar_venta_manual.sql` lo hacía sin que el propose lo viera).
- **ACLs re-emitidas idénticas**: `REVOKE ALL … FROM PUBLIC, anon` y `GRANT EXECUTE … TO authenticated, service_role`. En el caso B, el núcleo conserva su ACL sin `authenticated`.
- **El diff** contra cada cuerpo vivo es **exactamente** la tabla de D2 más un comentario `-- compras-gastos-sucursal-por-defecto (Dn):` en cada punto tocado. Se adjunta como evidencia.
- **Orden de locks**: ni el guard ni el `COALESCE` toman locks nuevos. `c26_default_branch` es un `SELECT` sin `FOR UPDATE`.

### D8 — Históricos: sin backfill por defecto (OQ-1)

**Con (a), la recomendación**, no hay migración de datos:

- las compras y los gastos sin sucursal conservan `NULL` hasta su primera edición (D5);
- las specs lo dicen explícitamente;
- el Tablero filtrado por sucursal sigue sin verlos, y la fila «Sin sucursal» de `rpc_branch_report` sigue mostrando los gastos viejos.

Mantiene lo firmado dos veces:

- `caja-compras-cobranzas`: «una atribución inventada sería peor que la ausencia»;
- `gastos-forma-pago` D7: los 175 gastos sin backfill.

Y deja el change del tamaño de lo que se pidió.

**Con (b)**, una migración de **datos solamente**, molde de `20261075000002`. La mergea el PO, y sus reglas se firman antes de escribirla.

- **Compras, por operación** (`COALESCE(operation_id, id)`); gana la primera regla que dé una sucursal:
  1. **operación mixta**: las otras filas de la misma operación tienen exactamente una sucursal. Se toma esa, aunque no esté operativa, para no dejar la operación partida;
  2. **movimiento de stock propio con sucursal**: la pata APPLY de una edición la escribió con `op_stock_movement`. Se toma si está operativa;
  3. **principal vigente**, si está operativa;
  4. el **residuo** queda `NULL` y se cuenta: sin `account_id`, cuenta sin sucursal operativa.

  No hay regla de caja (una compra sin sucursal nunca pudo tener movimiento de caja: el opt-in siempre se rechazaba) ni de banco (su movimiento bancario también es `NULL`).
- **Gastos**: la principal vigente si está operativa; si no, residuo. Un gasto `NULL` es anterior a `gastos-forma-pago`, que nunca tocó caja ni banco. Se cuenta igual cualquier evidencia de caja (`cash_movements.reference_id`) por si existiera.
- **Movimientos de stock**: **no se tocan** (RN-21 sin excepción nueva). El movimiento `'purchase'` `NULL` de una compra histórica queda `NULL`. Su borrado sigue reponiendo, como hoy, contra la principal vigente al borrar, y su edición revierte contra la sucursal de la fila, que con (b) es la asignada. Pueden diferir si la principal cambió, igual que hoy.
- **Mecánica** (D7 de ventas):
  - `FOR UPDATE` por `id` ascendente;
  - una fila de `audit_logs` por cuenta (`action = 'purchases_branch_backfill'` y `'expenses_branch_backfill'`, `entity_type = 'account'`, `user_id = NULL`, `metadata` con ids y conteos por regla);
  - `NOTICE` con conteos y residuo;
  - idempotente (`WHERE branch_id IS NULL`), sin disparadores de `UPDATE` sobre `purchases` ni `expenses` (sólo `AFTER INSERT` de analytics, verificado), y nunca aborta por datos.
- **Reversión**: por id desde `audit_logs`.

### D9 — Frontend: compra, gasto e importador muestran la principal; nada nuevo

Se reutiliza todo lo que dejó ventas: `BranchSelect` (`allowUnassigned`, `label`), `resolveDefaultBranch` y la traducción de errores. No nace ningún componente, hook ni helper.

- **Formulario de compra** (`purchase-form.tsx:777`): `<BranchSelect allowUnassigned={false} label="Sucursal" …/>`, sin `placeholder`.
  - El estado sigue en `null` hasta que el usuario elige: viaja `null` y **el servidor** resuelve con datos vivos (D9 de ventas).
  - La edición precarga `editingOperation.branchId`. Una compra histórica `NULL` muestra la principal y viaja `null`, que el servidor resuelve a la principal (D5).
  - El opt-in de caja no cambia de código: ya ofrecía la sesión de la principal, y ahora el servidor la acepta.
- **Formulario de gasto** (`expense-form-v2.tsx:231`): lo mismo, con `label="Sucursal"`.
- **Importador de gastos** (`expense-import-dialog.tsx:688`): `allowUnassigned={false}` y `label="Sucursal por defecto"`, a juego con los dos selectores vecinos («Forma de pago por defecto», «Centro de costo por defecto»). Su estado `null` viaja como `p_default_branch_id = NULL`, y cada fila sin sucursal propia cae en la principal por el alta del gasto: lo mostrado es lo que se guarda.
- **`BranchSelect`**: sólo cambia el JSDoc de `allowUnassigned`. El valor por defecto `true` queda para el presupuesto. Hoy el JSDoc dice «compra, gasto e importador de gastos conservan su opción sin sucursal».
- **Errores**:
  - `purchase-form.tsx` ya pasa por `humanizeOperationError`, que traduce `no_branch_found` («No encontramos una sucursal activa en la cuenta. Creá una o reabrí una cerrada desde Sucursales…») y `branch_closed`;
  - el formulario de gasto no recibe errores nuevos con OQ-3 = (a).
- **Tests del opt-in de caja**: el caso «elegible y tildado» de `__tests__/components/purchase-form-cash-optin.test.tsx` manda la sesión de la principal con la sucursal en `null`. Desde este change el servidor lo acepta, y el bloque (6) del gate lo prueba del lado de la base. No cambia ninguna aserción; sólo se actualiza la prosa que describa ese payload como rechazado, si la hay (tarea 5.5).
- **Cuenta sin módulo**: ni selector ni rótulo (sin cambios). Viaja `null` y el servidor registra la principal.
- **Alternativa rechazada — rotular "Sucursal principal (Casa Central)" una opción `null`**: lista dos opciones que significan lo mismo (OQ-2 (b) de ventas).

### D10 — Backend sin cambio de lógica

`PurchaseOperationIn.branch_id`, `PurchaseOperationUpdateIn.branch_id`, `ExpenseCreate.branch_id` y `ExpenseUpdate.branch_id` ya transportan `None`. El tri-estado viaja por `model_fields_set`.

- Se corrigen los comentarios que describen el contrato viejo: `schemas/purchases.py:26-31` («sucursal EFECTIVA de la compra» sin resolución) y el docstring de la edición.
- Se agrega la descripción de OpenAPI de los cuatro campos: «sin sucursal, la compra/el gasto se registra en la sucursal principal de la cuenta».
- Un test asserta la descripción, molde de `test_schema_branch_id_documents_that_no_branch_means_the_principal` de ventas.
- `P0422 no_branch_found` y `branch_closed` llegan como RFC 7807 por el mapeo global de `asyncpg_error_handler`, como el resto de los `P0422`.

### D11 — Lectores: ningún cambio de código; qué cambia de un día para otro

| Lector | Efecto |
|---|---|
| Tablero filtrado por la principal (`rpc_dashboard_kpi_summary`, `get_dashboard_financials`) | Las compras nuevas sin sucursal elegida pasan a contar en la principal. «Compras» y «Ganancia neta» filtradas por la principal cambian desde el deploy: las compras del mes anteriores al deploy siguen afuera (OQ-1 (a)). Los gastos nuevos ya contaban desde `gastos-forma-pago`; se suman los gastos históricos que se editen. |
| Fila «Sin sucursal» de `rpc_branch_report` (sólo ventas y gastos) | Pierde los gastos que se editen. No lee compras. |
| Export (`generate-export`) | Las compras nuevas muestran el nombre de su sucursal en vez de «Principal». Las históricas siguen igual. |
| Conciliación bancaria y ledger bancario | El movimiento bancario de una compra nueva sin sucursal elegida lleva la principal en vez de `NULL`. Ninguna función de la base filtra `bank_movements` por sucursal (verificado en la base local con una búsqueda en `pg_proc` de `bank_movements` con un predicado sobre `branch_id`: cero resultados). |
| `/sucursales/:id` e inventario | Sin cambios: leen `branch_stock`, donde el stock ya entraba en la principal. |

*Alternativa rechazada — retirar el tramo «Sin sucursal» del reporte*: sigue haciendo falta para los históricos (OQ-1 (a)).

### D12 — Gates: ejecutan las RPCs, con introspección y mutaciones

**Gate nuevo**: `supabase/tests/test_compras_gastos_sucursal_por_defecto.sql`. Patrón del proyecto: fallos acumulados en `text[]`, anchors sintéticos vía `handle_new_user`, `created_at` explícito y asertado en las sucursales sintéticas (`c26_default_branch` no desempata), limpieza completa.

- **(0) Introspección**:
  - el `md5` vivo de las funciones reescritas es su `v_rewritten`;
  - hay una sola firma por función;
  - las ACLs son las de D7, con `anon` sin `EXECUTE`;
  - el `COMMENT` de `rpc_update_expense` contiene la excepción y el de la edición de compra se conserva;
  - el cuerpo del alta (o del núcleo) pasa `v_gate_branch` a `c21_apply_branch_stock_delta`.

  Falla explícito si una reaplicación de CI pisa un cuerpo.
- **(1) Alta sin sucursal**, en una cuenta con A (principal) y B, con dos líneas (una con producto y una sin producto):
  - las dos filas de `purchases` en A;
  - `branch_stock` de A sube y el de B no;
  - el movimiento de stock en A;
  - la suma de `quantity_delta` por `(product_id, branch_id)` iguala el cambio de `branch_stock`.
- **(2) Principal cerrada**: con A cerrada, la compra y su stock van a B.
- **(3) Cuenta sin sucursal operativa** (una sucursal desactivada vacía y otra cerrada, sin `session_replication_role`): `P0422 no_branch_found` con producto y sin producto. No quedan filas en `purchases`, `operation_idempotency` ni `stock_movements`, y `branch_stock` no cambia.
- **(4) Cuenta sin ninguna sucursal**: `P0422 no_branch_found` y **ninguna sucursal creada**: `c21` ya no llega a crear "Casa Central".
  - El fixture borra la sucursal sembrada bajo `session_replication_role = replica`, y antes borra explícitamente sus `cashboxes` y su `branch_stock`, que no cascadean en ese modo.
  - Al final asierta residuo cero (gotcha de `test_admin_kpis.sql`, como el bloque (4) de ventas).
- **(5) Sucursal elegida cerrada** (OQ-2 (a)): `P0422 branch_closed`, sin filas y sin stock.
- **(6) Caja**:
  - compra en efectivo de hoy sin sucursal, informando la sesión de la principal A: se registra en A con su movimiento de caja en esa sesión;
  - la misma compra informando la sesión de B: `cash_optin_requires_open_session` y nada escrito.
- **(7) Banco**: compra sin sucursal por transferencia con cuenta destino: `bank_movements.branch_id = purchases.branch_id = A`.
- **(8) Edición de compra**:
  - (a) en B, informada `NULL`: queda en A, con la REVERSE en B y la APPLY en A;
  - (b) fila residual `NULL` (insertada directo, con su stock en la principal) editada sin informar: queda en A, con el neto de stock en cero;
  - (c) la reimputación explícita sigue igual;
  - (d) en una cuenta sin sucursal operativa: `no_branch_found`, sin reversa ni reaplicación;
  - (e) el proveedor y el centro de costo se preservan.
- **(9) Edición de gasto**:
  - (a) en B, informada `NULL`: queda en A;
  - (b) residual `NULL` sin informar: queda en A;
  - (c) gasto histórico con sólo el importe cambiado: queda en A;
  - (d) la reimputación explícita sigue igual;
  - (e) en una cuenta sin sucursal operativa, persiste lo que devuelve `c26_default_branch` (OQ-3 (a)). Con (b), `no_branch_found`;
  - (f) la forma de pago y el centro de costo siguen desimputándose con `NULL`.
- **(10) Borrado ejecutado** (`rpc_delete_purchase_operation`) de una compra nueva sin sucursal elegida: repone en la sucursal **del movimiento** (A), y `branch_stock` de A vuelve a su valor inicial.
- **(11) Remito → compra**, sólo si `rpc_convert_delivery_note_to_purchase` existe (caso B o tanda B posterior): la compra convertida queda en la sucursal del remito y no se dispara ningún guard nuevo.
- **(12) Backfill**, sólo con OQ-1 = (b): ejecuta el archivo de datos **dos veces**, con un caso por regla de D8, residuo, auditoría, idempotencia y efectos laterales en cero, contados sólo sobre las cuentas del fixture (por el `pg_cron` del relay).

**Mutaciones**, en una transacción con `ROLLBACK`, cada una detectada con mensaje propio:

- M1: el alta con `p_branch_id` crudo en `purchases`;
- M2: crudo en `stock_movements`;
- M3: la caja comparada contra el crudo;
- M4: el banco con el crudo;
- M5: la edición de compra sin `COALESCE`;
- M6: el guard que sólo mira `NULL` (deja pasar la principal no operativa);
- M7: la edición de gasto sin `COALESCE`;
- M8: el alta sin el chequeo de `branch_closed` (si OQ-2 = (a));
- M9: `c21` con el crudo (sólo la detecta la introspección (0): con una sola sesión el comportamiento es indistinguible).

**Gates existentes que cambian a propósito**:

- `test_gastos_forma_pago.sql` (4.3b) asierta «el nulo explícito no desimputó la sucursal» (L1438-1440). Pasa a «el nulo explícito registra la sucursal por defecto». Los otros dos campos del tri-estado siguen desimputando.
- El apply re-mide con grep cualquier otro gate que fije «compra sin sucursal → `NULL`», «edición de compra/gasto con `NULL` → `NULL`» o la creación perezosa de "Casa Central" por una compra (tarea 0.6). Ningún otro apareció en el propose.

**Gates que alcanza la reescritura y se corren sin modificarse**: los que ejecutan o inspeccionan estas funciones.

- `test_purchase_cash_optin`, `test_purchase_delete_cash_compensation`, `test_compras_proveedor_cuenta_corriente`, `test_pagos_cableados_restantes` y `test_payment_method_operations`;
- `test_edicion_preserva_contexto`, `test_stock_movements_edicion`, `test_operation_edit_lines` y `test_unidades_decisiones_8_9`;
- `test_sale_items_rpc_v2_activation`, `test_stock_ledger_solo_rpc` y `test_pos_banco_movimientos`;
- `test_operacion_party_guard`, `test_idempotency` (8, 9, 11, 12), `test_confirm_core_integrity` (4, 5) y `test_ventas_unidades_conversion` (E), más su prueba de carrera;
- `test_branch_stock` (6.11, no cableado), `test_pos_rpc_signatures`, `test_cobranzas_vencimientos_schema` y `test_function_acl_gate`;
- `test_remitos_compra`, `test_asiento_contable_gastos`, `test_expense_import_batch`, `test_party_payment_cash` y `test_qa_integral_fixes`.

**CI (`KPI_Validation.yml`)**:

- **Reaplicación** de `20261076000001` (y de `20261076000002` si existe) **al final de la cadena**, después del bloque de `20261075000001`/`2`, sin tolerancia:
  - dos pasadas;
  - la segunda exige los `NOTICE` «ya es el cuerpo de esta migración», uno por función reescrita, contados con `grep -cF`;
  - el OK de la introspección;
  - y el `schema_snapshot` idéntico.

  Con el caso B, el paso va además después del de la tanda B (D6).
- **Regla para el PR siguiente**, escrita en el comentario del paso: una migración posterior que redefina cualquiera de estas funciones retira este bloque en el mismo PR.
- **Gate nuevo** cableado como paso propio. `test_gastos_forma_pago.sql` mantiene su paso.

### D13 — Escritores fuera del alcance: excepciones nombradas

El Goal 1 vale para los caminos **de la aplicación**: formulario, API, importador y conversión de remitos.

Quedan como excepción nombrada, y como candidato junto al `NOT NULL` de ventas:

- **`rpc_atomic_create_purchase`** (dos overloads) y **`rpc_create_purchase_operation_v2(text, date, text, jsonb)`**: legacy, sólo `service_role`, sin llamadores. No escriben `branch_id`.
- **La escritura directa de `authenticated` sobre `purchases` y `expenses` por PostgREST** (privilegios de tabla más políticas `is_account_writer`). La aplicación no la usa, salvo el `services.createExpense` muerto. Cerrarla es un `REVOKE` de tabla con su auditoría de callers, el mismo trabajo que `revoke_anon_table_writes` hizo para `anon`.
- **`frontend/lib/supabase/services.ts` `createExpense`**: código muerto con un test de identidad de sesión. Retirarlo es limpieza aparte.

*Alternativa — revocar y retirar en este change*: rechazada. Cambia la superficie de seguridad de dos tablas sin que el PO lo haya pedido, y obliga a auditar callers ajenos a la sucursal.

## Risks / Trade-offs

- **[Choque con `remitos-compra` tanda B]** Los dos changes reescriben el alta y la edición de compra. → D6: el checkpoint 0 decide el caso, el que llega segundo parte del vivo, preflight de `md5` y regla escrita para el PR siguiente en la migración, el gate y CI. El riesgo residual es que los dos applies corran a la vez en la base local compartida: se aplican **en serie** (gotcha conocido del stack local).
- **[Compras "en vuelo" durante el deploy]** Una llamada al cuerpo viejo que commitea después del deploy deja una fila `NULL`, igual que hoy. Sin backfill (OQ-1 (a)) no es un defecto nuevo: es un histórico más. Con (b), la verificación posterior las busca **por estado** (filas `NULL` de cuentas con sucursal operativa), nunca por `created_at`, y con el OK del PO se re-ejecuta el bloque idempotente.
- **[Cuenta sin sucursal operativa]** Una compra que hoy pasaba (con el stock ingresando en una sucursal invisible) pasa a rechazarse con `no_branch_found` (D3). → Estado de borde; el formulario traduce la salida.
- **[Compra en una sucursal elegida cerrada]** Hoy pasa, y con OQ-2 (a) se rechaza. → La spec ya lo exigía. El selector sigue listando las cerradas, como en ventas (`useBranches` no filtra `status`), y el error dice qué hacer. La tarea 0.3 mide cuántas compras se registraron así en producción.
- **[Edición de un histórico mueve su sucursal]** Editar sólo el importe de una compra o un gasto viejos los asigna a la principal (D5). → Es la regla de ventas para el residuo y la consecuencia de la OQ-7 de ventas. Se declara en las specs y en el humo. En la compra, la REVERSE de una fila `NULL` y la APPLY caen en la misma principal (neto cero).
- **[Cambio visible en el Tablero filtrado]** «Compras» y «Ganancia neta» filtradas por la principal empiezan a incluir las compras nuevas sin sucursal elegida, y el mes del deploy queda mezclado: las compras anteriores afuera, las nuevas adentro. → Se avisa en el humo y en la ficha de `CHANGES.md`. OQ-1 (b) es la salida si el PO quiere el mes completo.
- **[Compra cuya sucursal guardada deja de operar después]** Antes, una compra `NULL` revertía contra la principal operativa del momento; desde este change revierte contra la suya.
  - Si se cerró: `P0422` al borrar o editar, hasta reabrirla.
  - Si se desactivó (requiere vaciarla): la reversa hace *floor* a 0 allí, con un ajuste `floor_on_purchase_delete`, en vez de restar donde está el stock.

  → Es el candidato OQ-8 de ventas, preexistente para toda compra con sucursal elegida. Queda nombrado. El borrado de una compra cuya principal cambió **mejora**: resta de la sucursal en la que entró el stock, no de la principal del día del borrado.
- **[Reescritura de ~1.000 líneas de PL/pgSQL]** (alta de compra 405, edición de compra 365 y edición de gasto 233 líneas de `pg_get_functiondef`) → Checkpoint 0 contra el cuerpo vivo, diff acotado a D2, gate nuevo con mutaciones, gates existentes de comportamiento e introspección, y humo local.
- **[Orden de despliegue frontend/backend/base]** Seguro en los dos sentidos:
  - frontend nuevo con base vieja: los formularios mandan `null` como hoy;
  - base nueva con frontend viejo: el rótulo viejo «Sin sucursal» se ve unos minutos, pero se guarda la principal, que es el comportamiento final.

  El backend no cambia de lógica. Igual se verifica que Render redespliegue (`GET /deploys`).

## Migration Plan

1. **Checkpoint 0** (lo ejecuta o autoriza el PO; sólo lectura en producción):
   - `pg_get_functiondef`, `obj_description` y `proacl` de las tres funciones (más `rpc_create_expense`, `c26_default_branch` y `c21_apply_branch_stock_delta` para leer);
   - `md5(replace(prosrc, E'\r', ''))` comparado con el local y con los archivos;
   - existencia de `_purchase_operation_core` (D6);
   - `MAX(version)`;
   - los conteos informativos (tarea 0.3).
2. **Sign-off**: las OQ sin respuesta se aplican por su recomendación. Con OQ-1 = (b), el archivo de datos no se escribe sin el OK textual del PO sobre las reglas de D8.
3. **Merge del PR** (con OQ-1 = (b), lo mergea el PO). `deploy.yml` aplica la migración con `supabase db push`, Vercel despliega el frontend y Render el backend (verificar `GET /deploys`).
4. **Verificación posterior** (tarea 12):
   - cuerpos, `COMMENT` y ACLs vivos;
   - el conteo de operaciones de compra y de gastos con `branch_id NULL` **no crece** respecto del medido en el checkpoint 0. No se buscan por `created_at`: es el inicio de la transacción, y una compra en vuelo tendría uno anterior al deploy. Con OQ-1 (a), una compra en vuelo es un histórico más;
   - las compras registradas después del deploy tienen sucursal, y sus movimientos de stock también;
   - el humo del PO.

**Rollback**:

- **Funciones**: una migración nueva que re-declara los cuerpos capturados en el checkpoint 0, con su `COMMENT` y sus ACLs. Es reversible sin pérdida: con los cuerpos viejos, las compras nuevas vuelven a guardar `NULL`. En el mismo PR:
  - retirar de `KPI_Validation.yml` el bloque de reaplicación de `20261076000001`, porque su preflight tomaría la rama de reescritura y reinstalaría los cuerpos nuevos (D13 de ventas);
  - llevar su propio preflight;
  - reemplazar el bloque (0) del gate.
- **Datos** (sólo con OQ-1 = (b)): por id desde `audit_logs`, con decisión explícita del PO.

## Open Questions

| # | Pregunta | Opciones | Recomendación |
|---|---|---|---|
| OQ-1 | **Compras y gastos viejos sin sucursal.** Hoy quedan unas 106 operaciones de compra (medido el 2026-10-03) y 175 gastos sin sucursal. ¿Los dejamos así o los asignamos a una sucursal? | (a) **Dejarlos así**, como ya firmaste en `caja-compras-cobranzas` y `gastos-forma-pago`. Siguen sin sucursal hasta que alguien los edite, y entonces toman la principal. El Tablero filtrado por sucursal sigue sin verlos. (b) **Asignarlos**, como hicimos con las ventas: cada compra a la sucursal que ya tenga otra fila de su misma operación, o la de su movimiento de stock si se editó, o si no a la principal de hoy; cada gasto a la principal de hoy. Una migración de datos aparte, con registro de qué asignó el sistema para poder deshacerlo, que mergeás vos. No toca el historial de stock. Esto **deroga** aquellas dos decisiones tuyas. | **(a)**. Es lo que firmaste dos veces y lo que pediste para este change («sin tocar las compras viejas»). Elegí (b) sólo si querés ver las compras y los gastos viejos bajo el filtro de sucursal del Tablero y del reporte. |
| OQ-2 | **Compra en una sucursal cerrada.** Hoy se puede registrar una compra eligiendo una sucursal **cerrada**, y la mercadería entra ahí. La venta y el gasto ya lo rechazan, y la regla escrita del sistema dice que la compra también. ¿La rechazamos? | (a) **Sí**: se rechaza con el mensaje de sucursal cerrada («reabrila o elegí otra»), igual que la venta y el gasto. (b) **No**: queda como hoy, y se corrige la regla escrita para que no prometa algo que no pasa. | **(a)**. Es lo que la regla ya dice. Además, una compra en una sucursal cerrada después no se puede editar sin cambiarla de sucursal. Mido en producción cuántas compras se registraron así (dato informativo). |
| OQ-3 | **Gasto en una cuenta sin ninguna sucursal funcionando** (todas dadas de baja o cerradas). La venta y la compra se rechazan en ese caso («creá o reabrí una sucursal»). El gasto hoy se registra igual, en una sucursal dada de baja que no se ve. | (a) **Igual que hoy**: el gasto se registra y la edición usa la misma regla que el alta. No se toca el alta. (b) **Como la venta y la compra**: el gasto (alta, importación y edición) se rechaza hasta que haya una sucursal funcionando. Exige cambiar también el alta y el importador. | **(a)**. El gasto no mueve mercadería. Es un caso de borde (hay que dar de baja todas las sucursales), y frenar el registro de gastos por eso convierte un problema de configuración en uno de carga. |

**Resueltas el 2026-10-11 por el PO: todas por la recomendación.** Respuesta textual: «vamos con todo lo recomendado».

- **OQ-1 = (a)**: compras y gastos históricos **sin backfill**; toman la principal cuando alguien los edita. El grupo 3 de `tasks.md` no se ejecuta y `20261076000002` no se usa.
- **OQ-2 = (a)**: una compra en una sucursal **cerrada** se rechaza con `P0422 branch_closed`.
- **OQ-3 = (a)**: un gasto en una cuenta sin sucursal operativa se registra **como hoy**: sin guard en el alta ni en la edición del gasto, y `rpc_create_expense` no se reescribe.

Texto original, conservado como contexto:

OQ-1, OQ-2 y OQ-3 no bloquean el grupo de funciones: el apply aplica la recomendación salvo que el PO diga otra cosa antes del merge.

- **Si OQ-1 = (b)**: se suma el grupo de la migración de datos, que no se escribe sin el OK textual del PO sobre las reglas de D8 y que mergea él.
- **Si OQ-2 = (b)**: se retiran el chequeo de `branch_closed`, el bloque (5), la mutación M8 y el escenario de compra del delta de `branches`, y el requirement «Operaciones solo contra sucursales operativas» se modifica para excluir la compra.
- **Si OQ-3 = (b)**: se suman la reescritura de `rpc_create_expense`, el error de fila del importador y la traducción en el formulario de gasto.

## Notas de implementación del apply (2026-10-11)

Desvíos y hallazgos respecto de lo escrito arriba. Ninguno cambia una decisión firmada.

- **D9 — `BranchSelect` descarta la emisión vacía de Radix** (desvío sobre «sólo cambia el JSDoc»). El humo local con una carga en frío encontró que **2 de 6** compras en efectivo con la principal mostrada se rechazaban con `422 «Input should be a valid UUID»` sobre `branch_id`: el formulario mandaba `branch_id: ""`. Causa: Radix Select sincroniza su `<select>` nativo con un evento `change` cuando cambia el valor controlado; con las sucursales llegando, el valor mostrado pasa de `""` a la principal y, si la opción nativa aún no está registrada, emite `onValueChange("")`, que el componente reenviaba a `onChange` y el formulario guardaba. Es un defecto latente del modo `allowUnassigned={false}` que dejó `ventas-sucursal-por-defecto` (el formulario de venta lo tiene igual) y que este change extiende a la compra, el gasto y el importador. Se corrige en el componente compartido: en los dos modos sin la opción «Sin sucursal» (`required` y `allowUnassigned={false}`) una cadena vacía nunca es una elección y no llega a `onChange`. Dos tests deterministas en `BranchSelect.test.tsx` (RED: 2 fallos; GREEN) y verificación en el navegador: 6 de 6 cargas en frío mandan `null`. En jsdom la carrera no se reproduce, por eso el test inyecta la emisión vacía por el doble de `Select`.
- **D9 — el selector de la compra ocupa la fila entera en móvil.** A 375 px la mitad de la fila truncaba «Casa Central (principal)» y la marca «(principal)» se perdía. `PurchaseForm` envuelve el selector en `col-span-2 sm:col-span-1 empty:hidden` (sin celda vacía en las cuentas sin el módulo). Verificado a 375 y 1280 px, tema claro y oscuro.
- **Hallazgo no bloqueante (sin tocar):** mientras la cuenta (`user.accountId`) todavía no se resolvió, `useBranches` devuelve `[]` sin estar «cargando» y `BranchSelect` muestra «Sin sucursal disponible» unos segundos en una carga en frío. Es preexistente (viene de `ventas-sucursal-por-defecto`), transitorio y no pierde datos; queda anotado como candidato.
- **D12 — el gate nuevo no tiene bloque (12)** (OQ-1 (a): sin migración de datos) y su bloque (11) emite `SKIP` mientras no exista `rpc_convert_delivery_note_to_purchase`; cuando exista **falla** hasta que se complete (regla escrita en la cabecera del gate, de la migración y del paso de CI).
- **`test_gastos_forma_pago.sql` cambia en cuatro puntos**, no sólo en 4.3b: 4.3c reimputa a la sucursal A2 (con la default A1 no distinguiría un cambio real), 4.4 espera A2 tras 4.3c y 4.4b espera que el histórico tome la principal (no se inventa la forma de pago, sí la sucursal).
- **Base local compartida:** otro apply en vuelo (`stock-movimientos-sucursal-origen`, #631) hizo `supabase db reset` varias veces durante este apply y la migración de este change desapareció de la base cada vez; se volvió a aplicar con `psql` y se registró en `schema_migrations`. Efecto útil: la migración se aplicó limpia sobre una base reconstruida desde `main` + `20261077…`/`20261078…` (preflight por la rama «reescritura», 3 cuerpos), lo que confirma que el `md5` de partida de los archivos coincide con el de producción.
