## Context

Tercer y último tramo de la saga de la edición de operaciones. Los dos anteriores curaron lo que el ciclo **REVERSE → DELETE → INSERT** destruía *hacia abajo*: `edicion-operaciones-lineas` (#415/#416) devolvió las líneas que el `ON DELETE CASCADE` se llevaba, y `stock-movements-edicion` (#417/#418) devolvió el rastro espejo en el ledger. Este cierra lo que el **INSERT nuevo nunca vuelve a escribir**: el contexto del header.

Estado verificado en prod (`gxdhpxvdjjkmxhdkkwyb`, `pg_get_functiondef` VIVO, 2026-08-20 — base #415 + #417 + #419 vigente):

- `rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean)` → el `INSERT INTO sales` escribe `user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id, payment_method_id`. La tabla tiene **17** columnas.
- `rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean)` → el `INSERT INTO purchases` escribe eso mismo menos `client_id`/`currency`, más `description` y las cuatro columnas snapshot. La tabla tiene **20**.
- Ambas cierran su `jsonb_to_recordset` con `AS x(product_id uuid, amount numeric, quantity integer)`.

Tres precedentes gobiernan el diseño y no se re-discuten acá:

1. **Captura antes del DELETE** (`v_old_snapshots`, #415): lo que se quiera conservar hay que leerlo antes de que el DELETE lo borre. Después no existe.
2. **Tri-estado por ausencia** (`p_payment_method_provided`, #419): "no informado" ≠ "informado NULL". El primero preserva; el segundo desimputa. Se distingue por parámetro booleano, y en Python por `model_fields_set` — **nunca** por `is None`.
3. **Espejo de patas** (#417): REVERSE contra la sucursal vieja, APPLY contra la efectiva, ambas en la misma transacción.

Constraint dura del contexto: la migración se aplica sola al mergear (CI/CD de Supabase GitHub), y el backend despliega en paralelo. Toda migración debe ser idempotente y **compatible hacia atrás durante la ventana de despliegue**.

## Goals / Non-Goals

**Goals:**

- Que editar una operación no destruya ningún atributo del header que el usuario o el sistema hayan puesto: sucursal, canal, unidad, proveedor, centro de costo.
- Que sucursal y canal sean además **corregibles** al editar, con el mismo contrato tri-estado que ya tiene la forma de pago.
- Que una operación con comprobante fiscal emitido no pueda editarse, y que el usuario entienda por qué y qué hacer en su lugar.
- Que una cantidad decimal sobreviva la edición igual que sobrevive la creación.
- Que la pata APPLY del ledger aterrice en la sucursal correcta en vez de la default.

**Non-Goals:**

- **No** se reconstruye lo perdido en ediciones pasadas (ver D10).
- **No** se toca el bloque de emisión fiscal, ni la numeración, ni el relay de CAE. F2 es un guard de entrada.
- **No** se implementa la nota de crédito: ya existe su productor (`20260803000003_credit_note_producer.sql`); acá solo se la nombra como camino correcto.
- **No** se elimina el ciclo REVERSE→DELETE→INSERT ni se migra la edición a un `UPDATE` en sitio. Es la reescritura correcta, pero es otro change y otro riesgo (ver D9).
- **No** se expone `supplier_id` ni `cost_center_id` como editables (ver OQ-1).
- **No** se toca la creación (`rpc_create_*`, `rpc_quick_sale`): ya hacen todo esto bien y son la referencia de comportamiento.

## Decisions

### D1 — El contexto se captura antes del DELETE, en el mismo bloque que el snapshot y la forma de pago

Un único `SELECT ... INTO` por operación, junto a `v_old_payment_method_id`, antes de `STEP 1: REVERSE`:

```
SELECT branch_id, canal, unit_id  INTO v_old_branch_id, v_old_canal, v_old_unit_id
FROM public.sales WHERE id = ANY(p_sale_ids) LIMIT 1;
```

`LIMIT 1` es correcto y no es descuido: estos atributos son **de la operación**, no de la línea — todas las filas del mismo `operation_id` los comparten. Es la misma justificación que #419 escribió para `payment_method_id` ("por operación (D3): cualquier fila alcanza").

Excepción: `unit_id` es **por línea** en el modelo real (`sale_items.unit_id`, y la creación lo recibe por ítem en el `jsonb_to_recordset`). Se resuelve en D7, no acá.

*Alternativa descartada*: releer desde `stock_movements` (que sí guarda `branch_id`). Solo cubre líneas con producto, no cubre `canal` ni `supplier_id`, y no existe para las operaciones anteriores a #417.

### D2 — Sucursal y canal se vuelven editables; unidad, proveedor y centro de costo se preservan en silencio

| Atributo | Trato | Por qué |
|---|---|---|
| `branch_id` (venta y compra) | **Editable** (`p_branch_id` + `p_branch_provided`) | El form ya tiene selector de sucursal al crear. Registrar una venta en la sucursal equivocada es un error frecuente y hoy no hay forma de corregirlo salvo borrar y rehacer. |
| `canal` (venta) | **Editable** (`p_canal` + `p_canal_provided`) | Ídem: el selector existe al crear, alimenta "Margen por Canal", y es exactamente el tipo de dato que se completa después ("ah, esta fue por Instagram"). |
| `unit_id` | Preservado, no expuesto | Viaja pegado al producto de la línea, no al header. Cambiar la unidad sin cambiar el producto es un caso raro que además reinterpretaría el stock ya aplicado. |
| `supplier_id` | Preservado, no expuesto | El form de edición de compra no tiene selector de proveedor hoy. Exponerlo arrastra la cuenta corriente de proveedor (C-30) a la transacción de edición → otro change. Ver OQ-1. |
| `cost_center_id` | Preservado, no expuesto | Ídem: sin selector en el form de edición. |
| `company_id` | **No se restaura** | Columna legacy pre-`account_id` (5 filas en prod, todas viejas). Restaurarla sería resucitar un eje de tenancy retirado por C-19. Se declara muerta, explícitamente, para que la omisión sea decisión y no olvido. |
| `created_at` | No se restaura | El `now()` de la fila nueva es correcto: es cuándo se escribió esta versión. `date` (la fecha del hecho económico) sí es parámetro y ya se preserva. |

*Alternativa descartada*: preservarlo todo en silencio y no tocar la firma. Evitaría el `DROP FUNCTION` (D4), pero deja al usuario sin manera de corregir una sucursal mal elegida — que es la mitad del reclamo original.

### D3 — Los nuevos parámetros usan el contrato tri-estado de #419, sin inventar nada

`p_branch_id uuid DEFAULT NULL` + `p_branch_provided boolean DEFAULT false`; `p_canal text DEFAULT NULL` + `p_canal_provided boolean DEFAULT false`. Lógica idéntica, línea por línea, a la que #419 dejó para `payment_method_id`:

- `provided = false` → `v_final_branch_id := v_old_branch_id` (preservar).
- `provided = true, valor = NULL` → desimputar (venta sin sucursal / sin canal).
- `provided = true, valor = X` → reimputar, **previa validación** de que la sucursal pertenece a la cuenta y está operativa (mismo guard que `branches` §"Operaciones solo contra sucursales operativas") y de que el canal está en el conjunto permitido.

En Python la distinción se hace con `model_fields_set`, nunca con `is None`. Este párrafo existe porque es exactamente el error que el patrón invita a cometer.

*Alternativa descartada*: `COALESCE(p_branch_id, v_old_branch_id)` a secas. Más corto, pero hace imposible desimputar — el usuario no podría sacarle la sucursal a una venta que no debía tenerla.

### D4 — Cambio de firma: `DROP FUNCTION` + `CREATE` + re-`GRANT` en la misma migración, con los parámetros nuevos al final

Agregar parámetros crea una **firma nueva**: `CREATE OR REPLACE` no reemplazaría la vieja, la dejaría como *overload* y las llamadas siguientes quedarían ambiguas (`42725 function is not unique`) — el error que ya mordió a este proyecto en julio. Orden obligatorio en el archivo:

1. `DROP FUNCTION IF EXISTS public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb, uuid, boolean);` — firma vieja **completa y explícita**.
2. `CREATE OR REPLACE FUNCTION ...` con la firma nueva.
3. `REVOKE ALL ON FUNCTION ... FROM PUBLIC;` + `GRANT EXECUTE ... TO authenticated;` — `DROP` **resetea las ACLs**; sin este paso la función queda con el default de PUBLIC y rompe el gate `test_function_acl_gate.sql`.

**Compatibilidad durante la ventana de despliegue**: los cuatro parámetros nuevos van **al final, todos con `DEFAULT`**. El backend viejo (que llama con los parámetros actuales, nombrados) resuelve contra la firma nueva sin cambios y obtiene el comportamiento "preservar" — que es el correcto. No hace falta coordinar el orden migración/deploy.

### D5 — F2: "tiene comprobante" se resuelve por join, no por flag denormalizado

No existe hoy ninguna columna en `sales` que diga "esta venta está facturada". El único vínculo real, verificado en prod, es:

```
sales.operation_id → sales_orders.sale_operation_id → sales_orders.fiscal_document_id → fiscal_documents
```

`sales_orders.sale_operation_id` tiene índice único parcial (lo aprovecha `rpc_promote_legacy_sale_to_order`, el "facturar venta manual"), así que el join es de una fila y barato. El guard se ejecuta **antes** del REVERSE:

```
IF EXISTS (
  SELECT 1 FROM public.sales_orders so
  JOIN public.fiscal_documents fd ON fd.id = so.fiscal_document_id
  WHERE so.sale_operation_id = v_old_operation_id
    AND fd.status IN ('pending_cae','authorized')
) THEN
  RAISE EXCEPTION 'invoiced_operation_immutable: ...' USING ERRCODE = 'P0423';
END IF;
```

**`pending_cae` bloquea igual que `authorized`.** La emisión es asíncrona (relay `pg_cron`): entre la reserva del número y el CAE hay una ventana en la que el comprobante ya reservó numeración ante ARCA. Editar ahí produciría un comprobante cuyo total no corresponde a ninguna venta existente. `rejected` **no** bloquea: ese comprobante nunca llegó a existir fiscalmente.

`P0423` sigue la familia de la casa (`P0400`/`P0403`/`P0404`/`P0409`/`P0422` ya en uso en estas mismas RPCs), es un ERRCODE de 5 caracteres válido, y se mapea a RFC 7807 en el router (`api-standards`).

*Alternativa descartada*: una columna `sales.is_invoiced` mantenida por trigger. Más rápida de leer, pero introduce un segundo lugar donde la verdad puede desincronizarse del comprobante — exactamente el patrón que la memoria del proyecto registra como fuente de bugs silenciosos (3 Edge Functions calculando su propio "plan efectivo").

**Impacto hoy: cero.** En prod hay 1 solo `fiscal_documents` (una factura de suscripción, `subscription_payment_id` no nulo) y **0** `sales_orders` con `fiscal_document_id`. El guard nace inerte y protege hacia adelante, que es cuando ARCA se habilite.

### D6 — F2 aplica solo a ventas; la compra queda fuera con razón declarada

La compra no lleva CAE **propio**: el comprobante lo emite el proveedor y nosotros lo registramos. No hay nada emitido por el sistema que la edición pueda contradecir. `purchases` no tiene ningún vínculo a `fiscal_documents` (verificado: la tabla no tiene columna de operación ni FK desde compras). Se declara fuera de alcance en vez de omitirse.

### D7 — F3 es una sola palabra en cada RPC, y ya se verificó que alcanza

Toda la cadena ya es decimal, verificado en prod:

| Elemento | Tipo hoy |
|---|---|
| `sales.quantity`, `purchases.quantity`, `sale_items.quantity`, `purchase_items.quantity` | `numeric(15,4)` |
| `branch_stock.quantity`, `stock_movements.quantity_delta` | `numeric(15,4)` |
| `op_stock_movement(p_delta ...)`, `c21_apply_branch_stock_delta(p_delta ...)` | `numeric` |
| `rpc_create_sale_operation`, `rpc_create_purchase_operation`, `rpc_quick_sale` | `quantity numeric` en el recordset |
| Pydantic (`SaleItemIn`, `SaleOperationUpdateItemIn`, …) | `Decimal` |
| Frontend (`unitInputStep`) | `step = 0.001` para unidades medibles |
| **`rpc_atomic_update_*` (recordset)** | **`quantity integer`** ← el único eslabón |

**Por eso NO hay `ALTER TYPE`, NO hay `DROP VIEW`/`CASCADE`, NO hay reconstrucción de vistas.** Se mapearon las dependencias con `pg_depend`: las únicas vistas colgadas de estas columnas son `v_sales_flat`, `v_purchases_flat` y `v_products_with_stock`, y ninguna se toca porque ninguna columna cambia de tipo. El plan de migración de tipo que el brief anticipaba resultó innecesario — la migración de tipo ya ocurrió, hace tiempo, y nadie actualizó el cast del recordset.

El fallo actual es **ruidoso, no silencioso**: `jsonb_to_recordset` levanta `22P02 invalid input syntax for type integer: "2.5"` (comprobado con `SELECT` en prod). No hay redondeo encubierto ni datos corrompidos por esta vía. Hay 57 ventas en prod con cantidad decimal que hoy **no se pueden editar**: fallan con 500.

Detalle de serialización ya verificado: el repositorio serializa `Decimal` **como string** (`_default` en `sales_repository.py`), de modo que el JSON lleva `"2.5"`. `jsonb_to_recordset` castea correctamente un string JSON a `numeric` (comprobado). No hace falta tocar la serialización.

`unit_id` se suma al recordset de la edición (`AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)`) para igualar la forma que ya tiene la creación, y se escribe tanto en el header como en la línea — hoy ambas RPCs insertan `unit_id => NULL` explícito en `sale_items`/`purchase_items`.

### D8 — La pata APPLY aterriza en la sucursal efectiva, no en la default

Hoy: REVERSE con `v_old_sale.branch_id`, APPLY con `p_branch_id => NULL` → `op_stock_movement` cae a la sucursal default. Editar una venta de una sucursal no-default **muda stock entre sucursales sin que nadie lo pida**. Hay 15 sucursales con stock en prod.

Nuevo contrato, que además es lo que hace posible reimputar sucursal (D2):

- REVERSE → **sucursal vieja** (devolver donde se sacó).
- APPLY → **sucursal efectiva** = la reimputada si `p_branch_provided`, la vieja si no.

Cuando el usuario cambia la sucursal de una venta, esas dos patas difieren, y el par espejo del ledger describe exactamente el traslado. Es el comportamiento correcto y queda auditable sin texto libre.

### D9 — La orden promovida sin comprobante se re-apunta; el `operation_id` se sigue regenerando

La edición regenera `operation_id`. Eso deja colgando `sales_orders.sale_operation_id` — 3 filas en prod, la OQ-C que el change anterior mandó a "revisión manual". La causa raíz es ésta, y se cierra con un `UPDATE` de tres líneas en la misma transacción, después del INSERT:

```
UPDATE public.sales_orders
SET    sale_operation_id = v_new_op_id
WHERE  sale_operation_id = v_old_operation_id
  AND  fiscal_document_id IS NULL;
```

La condición `fiscal_document_id IS NULL` es redundante con el guard de D5 (una orden facturada nunca llega hasta acá) y se deja igual: defensa en profundidad barata.

*Alternativa descartada*: **preservar** el `operation_id` viejo en vez de regenerarlo. Es la solución conceptualmente correcta — la operación es la misma, cambió su contenido — y haría innecesario este `UPDATE`. Pero `operation_id` es la clave de `operation_idempotency`, agrupa `stock_movements.operation_group_id` y distingue las patas del par espejo de #417. Cambiar eso es reescribir el contrato de idempotencia de las operaciones: otro change, otro riesgo, y no es lo que el PO firmó. Queda anotado como deuda consciente.

### D10 — Sin backfill, y la razón por la que no lo hay

Lo perdido en ediciones pasadas **no es reconstruible**: el registro viejo se borró con el `DELETE`, `stock_movements` solo conserva `branch_id` para líneas con producto y solo desde #417, y `canal`, `supplier_id` y `cost_center_id` no dejan rastro en ninguna parte. Inventar valores sería peor que el `NULL` honesto que hay: un `NULL` se lee como "no se sabe", un valor inventado se lee como dato. Se declara pérdida histórica asumida — a diferencia de #416 y #418, este change no trae script gateado.

### D11 — Superficie frontend: prefill, envío y bloqueo

El form de edición hoy es cómplice del bug: `branchId` y `canal` arrancan en `useState(null)` **sin mirar `editingOperation`**, y el payload de edición ni siquiera los incluye. Corregir solo la RPC dejaría el campo preservado en la base y vacío en la pantalla.

1. **Lectura**: `SaleItemOut` (Pydantic) y `SaleOperation` (`frontend/lib/group-operations.ts`) suman `branch_id`/`branchId`, `canal` y `unit_id`; el `SELECT` del repositorio los trae. Sin esto no hay con qué prefillear.
2. **Prefill**: `useState(() => editingOperation?.branchId ?? null)`, ídem canal — mismo patrón que ya usan `clientId`, `currency`, `date` y `paymentMethodId`.
3. **Envío**: el payload de edición incluye sucursal y canal siempre que el selector esté montado (el form manda el valor vigente, como ya hace con `paymentMethodId`, de modo que "preservar" y "reimputar con el mismo valor" son indistinguibles para quien edita).
4. **Bloqueo fiscal**: si la operación tiene comprobante, el form se abre en solo-lectura con un banner que dice qué pasa y qué hacer (nota de crédito + venta nueva). El botón de guardar queda deshabilitado con el motivo accesible, no simplemente gris. El `P0423` del backend sigue siendo la defensa real; el banner evita que el usuario llegue hasta el error.
5. Tokens semánticos del design system (nada de colores crudos), verificado en **desktop y mobile** y en **tema claro y oscuro**.

## Risks / Trade-offs

- **[`DROP FUNCTION` resetea las ACLs y deja la función abierta a PUBLIC]** → `REVOKE`/`GRANT` explícitos en el **mismo archivo**, inmediatamente después del `CREATE`; el gate `test_function_acl_gate.sql` lo verifica en cada PR.
- **[Overload fantasma → `42725 function is not unique`]** → `DROP` con la firma vieja completa y explícita antes del `CREATE`; task de verificación con `pg_get_function_arguments` post-merge para confirmar que quedó **una sola** función con cada nombre.
- **[Ventana de despliegue: migración aplicada antes que el backend nuevo]** → parámetros nuevos al final y todos con `DEFAULT`; la llamada vieja sigue resolviendo y obtiene "preservar", que es el comportamiento deseado.
- **[Sucursal reimputada a una sucursal cerrada o de otra cuenta]** → validación explícita contra `branches` (pertenencia a la cuenta + operativa) antes de aplicar; `P0422` si no cumple.
- **[F2 bloquea ediciones que hoy funcionan]** → impacto real hoy = 0 operaciones facturadas en prod; el guard nace inerte. Riesgo revisado, no teórico.
- **[Regresión sobre #415/#417/#419]** → los gates de esos tres changes corren sin modificación en el mismo CI; el cuerpo de las RPCs se reescribe completo, así que las tres conductas se re-verifican por gate, no por inspección.
- **[El usuario cambia sucursal y no entiende que movió stock]** → el par espejo del ledger lo deja auditable; el panel de movimientos ya muestra ambas patas. No se agrega UI de advertencia en esta iteración.

## Migration Plan

`supabase/migrations/20260930000001_edicion_preserva_contexto.sql`, idempotente. `MAX(version)` en prod verificado = `20260929000001`, idéntico al último archivo local (`20260929000001_pos_catalogo_pagos.sql`) → `20260930000001` está libre.

Orden dentro del archivo:

1. `DROP FUNCTION IF EXISTS` de ambas RPCs con firma vieja completa.
2. `CREATE OR REPLACE` de ambas, firma nueva, cuerpo completo (base #415 + #417 + #419 + F1 + F2 + F3).
3. `REVOKE ALL ... FROM PUBLIC` + `GRANT EXECUTE ... TO authenticated` para ambas.
4. Comentarios `COMMENT ON FUNCTION` apuntando a este change.

Rollback: re-aplicar el cuerpo anterior (recuperable de `20260928000001_payment_methods_operaciones.sql` + `20260927000001_stock_movements_edicion.sql`) con su firma vieja, mismo patrón `DROP` + `CREATE` + `GRANT`. Sin migración de datos ⇒ el rollback no pierde nada.

## Open Questions

- **OQ-1 — ¿`supplier_id` y `cost_center_id` deberían ser editables en la compra, no solo preservados?** Hoy no hay selector en el form de edición y hay 0 filas con valor en prod, así que preservar alcanza. En cuanto un usuario impute proveedor a una compra, no poder corregirlo será el mismo reclamo que motivó este change. Recomendación: **preservar ahora, exponer cuando el form de compra tenga los selectores** (change chico y posterior).
- **OQ-2 — ¿`pending_cae` debe bloquear la edición, o solo `authorized`?** El diseño bloquea ambos (D5). Si el PO prefiere permitir editar mientras no haya CAE, es cambiar un `IN` — pero hay numeración ya reservada ante ARCA en ese estado. Recomendación: **bloquear ambos**.
- **OQ-3 — ¿El banner de bloqueo ofrece el atajo a nota de crédito o solo lo explica?** El productor de notas de crédito existe (`20260803000003_credit_note_producer.sql`) pero no está verificado que tenga superficie de usuario. Recomendación: **explicar en esta iteración**, y conectar el atajo cuando se confirme que la nota de crédito tiene pantalla.
- **OQ-4 — ¿Debe rechazarse una cantidad decimal para un producto de unidad discreta?** El frontend ya lo previene (`step = 1` para unidades unitarias), pero la RPC lo aceptaría. Recomendación: **no agregar el guard en este change** — es una regla de unidades (`units-of-measure`), no de edición, y agregarla acá la dejaría aplicándose solo en la ruta de edición y no en la de creación, que es peor que no tenerla.
