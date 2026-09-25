# Design — ventas-unidades-conversion

Ver `proposal.md` §Why para la motivación y los números de prod. Acá sólo el estado actual que condiciona el diseño y las decisiones.

## Context

**Cómo se mueve el stock hoy (verificado contra los cuerpos vivos, 2026-09-24).**

| Camino | Función | Conversión por unidad |
|---|---|---|
| Alta de venta (formulario) | `rpc_create_sale_operation` → `rpc_create_sale_operation_v2` | Sí, inline: `v_qty_norm := (quantity * factor)::numeric(15,4)` |
| POS (`quickSale`/`confirm`) | `rpc_quick_sale` → `_c29_confirm_order_core` | **No**: `v_qty_norm := v_item.quantity` |
| Edición de venta | `rpc_atomic_update_sale_operation` | **No**: reversa con `sales.quantity` cruda, aplicación con `-v_item.quantity` cruda, ambas vía `op_stock_movement` |
| Alta de compra | `rpc_create_purchase_operation` | Sí, inline (misma copia que la venta) |
| Edición de compra | `rpc_atomic_update_purchase_operation` | **No** (mismo molde que la edición de venta) |
| Borrado (venta/compra) | `rpc_reverse_stock_movement` | No aplica: revierte el `quantity_delta` guardado, siempre consistente |

Las dos conversiones existentes multiplican por `unit.factor` **a secas**, o sea relativo a la base del **tipo** (kg, L, m, u), no a la del producto. Coincide con la base del producto sólo porque hoy ningún producto tiene una unidad base derivada (medido en prod el 2026-09-25: 62 productos con unidad base — 61 en Unidad, 1 en Kilogramo; 59 sin borrar —, 5.470 sin unidad). El catálogo, en cambio, muestra el stock con el símbolo de la unidad base del producto (`formatStock(stock, baseUnit.symbol)`), y el alta de producto guarda el stock inicial crudo: la convención **implícita** de todo lo que se ve es "el stock está en la unidad base del producto". Este change la hace explícita.

**Catálogo de unidades vivo.** 10 unidades de sistema tipadas; las bases de cada tipo tienen `factor = 1` y `base_unit_id NULL` (Unidad, Kilogramo, Litro, Metro); las derivadas apuntan a su base (Gramo 0,001, Tonelada 1000, Mililitro 0,001, Centímetro 0,01, Docena 12, Caja x 6). Los selectores de POS, venta y compra listan las 10 sin filtrar.

**Umbral de stock mínimo.** `branch_stock.min_stock` es `integer` (única fuente de verdad de la alerta, RN-23); `products.min_stock` ya es `numeric(15,4)` en prod pero está deprecada; `rpc_set_product_min_stock(uuid, int)`; backend `min_stock: int` en `ProductIn`/`ProductUpdate`/import y en `_propagate_min_stock`. Ningún test SQL fija el tipo entero.

**Restricciones heredadas que aplican.**

- Toda RPC que se reescribe parte de su `pg_get_functiondef` vivo de prod, con md5 CR-stripped registrado en la migración (procedimiento de `20261060000001`); cinco gates existentes introspectan estos cuerpos (`test_confirm_core_integrity`, `test_operacion_party_guard`, `test_cuenta_corriente_party_guard`, `test_tenancy_guard_caja_outbox`, `test_document_status_transition_role_matrix`).
- Cambiar la firma de una función = `DROP FUNCTION` + `CREATE`, nunca `CREATE OR REPLACE` con `DEFAULT` (gotcha `42725`).
- Gate de ACLs: un helper de nombre interno (prefijo `_`) no puede quedar ejecutable por `authenticated`; todo `REVOKE` nombra `PUBLIC, anon, authenticated` (prod concede directo, no vía `PUBLIC`).
- Regla PO de reutilización: lo nuevo reusable nace en la capa canónica (`lib/unit-utils.ts` en el frontend, helper SQL en la base).

## Goals / Non-Goals

**Goals:**

- Un solo lugar que decida cuánto stock mueve una línea, consumido por los cinco caminos de escritura.
- Que el POS y la edición dejen de mover cantidades crudas.
- Que la UI no pueda ofrecer una combinación que el servidor rechaza (selector compatible) y que el servidor rechace lo que la UI no debería haber permitido (defensa en profundidad).
- Umbral de stock mínimo con la misma precisión que el stock.
- Ninguna cantidad de stock o de línea en pantalla sin su unidad.

**Non-Goals:**

- Asignar unidad base a los productos sin unidad que se venden por kilo (37 vendidos en kg en los últimos 30 días, 49 en todo el historial, 46 de ellos sin borrar; candidato, OQ-1 y decisión 9 del PO; hoy se muestran como "uds" y seguirán así hasta que el PO decida).
- Corregir el ranking de productos, que suma `sale_items.quantity` cruda mezclando unidades (candidato aparte, misma familia).
- Importador CSV de productos: sigue leyendo el stock mínimo como entero con aviso (`Math.ceil`); levantarlo es un ajuste barato para después de que la columna sea numérica.
- Unidades por tenant (`account_id`) en los selectores: se filtran por el mismo criterio de tipo, sin lógica adicional.
- Backfill del movimiento dañado del 2026-09-22 (ver Migration Plan).

## Decisions

### D1 — La normalización es relativa a la unidad base del PRODUCTO

`normalizada = round(cantidad × factor(unidad línea) ÷ factor(unidad base producto), 4)`. Sin unidad base, el divisor es 1.

*Por qué no dejar "× factor" (base del tipo)*: es lo que se ve en pantalla lo que define la unidad del stock, y el catálogo ya muestra el stock en la base del producto. Con base del tipo, un producto en gramos con stock 1000 mostraría "1000 g" y una venta de 450 g descontaría 0,45. La fórmula relativa al producto es la única consistente con el alta de producto (stock inicial crudo) y con la vista. Para los datos vigentes las dos fórmulas coinciden (0 productos con base derivada), así que no hay migración de datos.

*Por qué no guardar la cantidad normalizada en la línea*: la línea debe conservar lo que el usuario ingresó (450 g) para el ticket, la edición y la reimpresión; el ledger es el que se expresa en base. Ya es así hoy en el formulario.

*Variantes (auditoría post-apply, 2026-09-24)*: el formulario no le asigna `base_unit_id` propia a una variante (manda `undefined` y el backend sólo hereda `category_id` del padre) — pero **2 variantes en prod sí tienen una declarada** (medido 2026-09-25, las dos en Unidad), cargada por otro camino, y para ellas la propia prevalece. Un padre con variantes sólo se vende a través de ellas (`P0422`). Sin herencia, el helper trataba a toda variante sin base propia como "producto sin unidad base" — medido en prod: **163 variantes de padres con unidad base** habrían perdido las unidades derivadas (450 g rechazado con `unit_requires_base_unit`) y aceptado cualquier unidad base de cualquier tipo. La base efectiva de una variante es `COALESCE(propia, la del padre)`, en el helper y en `v_products_with_stock.base_unit_id` (que es lo que el frontend lee: el selector, `/stock` y el ticket la heredan sin código propio).

### D2 — Un helper SQL puro, `_uom_normalize_quantity`, es la definición única

`_uom_normalize_quantity(p_product_id uuid, p_unit_id uuid, p_quantity numeric) RETURNS numeric`, `LANGUAGE plpgsql`, `STABLE`, `SECURITY INVOKER`, `SET search_path = public`. Lee `products.base_unit_id` (con `LEFT JOIN` al padre, D1) y las dos filas de `units_of_measure`. Errores: `P0404` unidad inexistente (token existente), `P0400 unit_type_mismatch`, `P0400 unit_requires_base_unit`. *Guard de tenencia (auditoría post-apply)*: la unidad de la línea tiene que ser del sistema o de la cuenta del producto — el FK a `units_of_measure` no está scopeado por tenant y la conversión inline anterior tampoco lo verificaba; se responde el mismo `P0404` (no revela si existe en otra cuenta), como el guard del backend en D10. Hoy prod sólo tiene las 10 unidades del sistema (0 personalizadas), así que no hay dato vigente afectado.

*Por qué en SQL y no en Python*: el POS lee sus líneas desde `sales_order_items` dentro de `_c29_confirm_order_core`, sin pasar por el backend en ese punto; las RPCs son la unidad de trabajo (DEC-24) y el punto de paso obligado de los cinco caminos. Una definición en Python dejaría al POS fuera otra vez.

*Por qué `SECURITY INVOKER` y no `DEFINER`*: no necesita privilegio (lee dos catálogos que RLS ya expone) y así queda fuera del chequeo (4) del gate de ACLs por construcción. Igual se le revoca `EXECUTE` a `PUBLIC, anon, authenticated`: las RPCs `SECURITY DEFINER` la invocan como owner, y nadie más tiene por qué llamarla. El prefijo `_` sigue la convención "helper intra-transacción" del proyecto.

*Alternativa descartada*: función `IMMUTABLE`/`SQL` inlineable. `STABLE` alcanza (lee tablas) y `plpgsql` permite los `RAISE` con token.

### D3 — Producto sin unidad base: sólo unidades base (factor 1), lo demás se rechaza

Sin `base_unit_id` no existe referencia contra la cual convertir; aplicar `× factor` a secas es justo lo que produjo el `-0.0004` del 2026-09-22. Las dos cuentas que hoy venden por kilo sobre productos sin unidad no se ven afectadas (Kilogramo tiene factor 1). Docena, Caja x 6, Gramo, Mililitro, Centímetro y Tonelada pasan a exigir que el producto declare su base: 0 líneas históricas las usan (salvo la del accidente).

*Alternativas*: (a) status quo, que deja el accidente abierto; (b) inferir el tipo desde la unidad elegida y convertir a la base del tipo, que es exactamente el status quo con otro nombre; (c) asignar `base_unit_id` automáticamente en la primera venta, que muta el producto por un efecto lateral de una venta. Se elige el rechazo explícito con token propio, y el selector (D5) hace que el usuario nunca lo vea salvo por un cliente viejo o una llamada directa.

### D4 — Reescritura de las seis funciones desde el cuerpo vivo, con la conversión inline retirada

- `rpc_create_sale_operation_v2` y `rpc_create_purchase_operation`: se retira el bloque `v_unit_factor` y `v_qty_norm := _uom_normalize_quantity(product_id, unit_id, quantity)`. El `P0404` por unidad inexistente se conserva (lo emite el helper).
- `_c29_confirm_order_core`: `v_qty_norm := _uom_normalize_quantity(...)` en lugar de `:= v_item.quantity`. Nada más cambia: el gate de sucursal, el `P0409` y el movimiento usan `v_qty_norm` como hoy.
- `rpc_atomic_update_sale_operation` / `rpc_atomic_update_purchase_operation`: la pata de **aplicación** pasa `−normalizada` / `+normalizada` a `op_stock_movement`; la pata de **reversa** ver D6.
- `rpc_create_sale_operation` (auditoría post-apply): es el wrapper que el backend invoca; su rama legacy `sale_items_rpc_v2 = false` — el kill-switch documentado en `20260924000001` — conservaba la conversión inline relativa a la base del tipo, y ni el gate embebido ni el (E) la miraban. Pasa por el helper (sexto cuerpo, md5 verificado contra prod: `343e0f1f…`). Hoy 0 de 35 cuentas tienen el flag apagado, así que es un camino latente, no vivo — pero "una sola definición" no admite excepciones latentes. `rpc_create_purchase_operation_v2` también conserva la fórmula vieja, pero está revocada de `authenticated` y no tiene caller: se deja.
- Firmas intactas en las seis (`CREATE OR REPLACE`), ACLs verificadas iguales antes y después en el gate embebido.
- La migración registra el md5 CR-stripped de cada cuerpo de partida y aborta si el cuerpo vivo del stack difiere del esperado (mismo patrón que `20261060000001`), para no reescribir sobre una base desconocida.
- *Reconciliación con #585 (corrección post-revisión, 2026-09-25)*: `venta-editable-vs-promocion-legacy` (PR #585) mergeó antes que este PR, tomó la versión `20261061000001` y también reescribió `rpc_atomic_update_sale_operation` desde el mismo cuerpo base (`20261060000001`, md5 `a657c54b…`): lock temprano `FOR UPDATE` de las filas `sales` de la operación en orden de id (N1) y recálculo de la orden re-apuntada vía `_sales_order_sync_from_operation` (N3). Con #585 en prod, el preflight de este PR habría abortado el `db push` del deploy (cuerpo vivo `7c8c1b76…`). Se resolvió así: migración **renumerada a `20261062000001`**; el cuerpo de `rpc_atomic_update_sale_operation` es la **fusión en 3 vías** (base `20261060000001`, ours = #585, theirs = los hunks de unidades de este PR: `v_qty_norm` vía helper y reversa por `quantity_delta`), con 0 conflictos y verificada hunk a hunk; `v_expected` de esa función = `7c8c1b765ca669ad736e8fc181d471bb` (medido en prod) y los otros cinco re-verificados contra prod el 2026-09-25 (sin cambios); `v_rewritten` recalculado desde `pg_proc` del stack local tras aplicar el archivo final. Los gates de #585 (`test_facturar_venta_manual.sql` y su arnés de carrera) y de #582 pasan sobre el cuerpo fusionado. Con el cuerpo sin fusionar, `test_facturar_venta_manual.sql` falla (`sales_order_out_of_sync`): control negativo de que la fusión hacía falta.
- *Comentarios vivos (corrección post-revisión)*: el `DROP FUNCTION` + `CREATE` de `get_dashboard_critical_stock_items` y `rpc_set_product_min_stock` borraba sus `COMMENT ON FUNCTION` vivos (el primero es normativo: "nunca reconstruir este predicado desde `v_products_with_stock`"). La migración los re-emite con el texto vivo de prod más una línea sobre `numeric(15,4)`, y el gate lo asserta (bloque E). *Auditoría post-apply*: la reaplicación se reconoce por el md5 **exacto** del cuerpo que esta migración deja (calculado por el generador), no por "contiene la llamada al helper" — ese predicado laxo habría dejado pasar en silencio una redefinición posterior de cualquiera de las seis.

### D5 — Compatibilidad de unidades en `lib/unit-utils.ts`, espejo exacto de D1/D3

- `compatibleUnits(units, baseUnit)`: con base → mismo `type`; sin base → `factor === 1` y `!baseUnitId`. Es la única definición para los tres selectores.
- `toBaseQuantity(displayQty, unit, baseUnit)` pasa a dividir por `baseUnit?.factor ?? 1` y a redondear a 4 decimales (`_round4` ya existe en `cart-utils`; se reexporta o se duplica una línea, no una regla). La validación local de stock del POS y del formulario usan este valor, que ahora coincide con lo que el servidor va a descontar (hoy el POS valida con `× factor` y el servidor descuenta crudo).
- Al cambiar de producto, el selector preselecciona la base del producto y reinicia la cantidad al mínimo de esa unidad (comportamiento que el POS ya tiene al cambiar de unidad).
- `CartItem.unitFactor` se reemplaza por `quantityBase` como única fuente de la cantidad normalizada del carrito; ningún consumidor usa `unitFactor` para escribir.

### D6 — La reversa de la edición devuelve el delta guardado, no una cantidad recalculada

La pata de reversa de `rpc_atomic_update_*` lee el último `stock_movements` de la fila vieja (`reference_id = fila vieja`, `reference_type = 'sale'|'purchase'`, `ORDER BY created_at DESC LIMIT 1`) — la misma consulta que ya hace para `unit_cost_snapshot` — y pasa `−quantity_delta` a `op_stock_movement`. Si no existe movimiento (fila anterior al ledger de C-21), cae a `_uom_normalize_quantity(producto, unidad vieja, cantidad vieja)`.

*Por qué*: es lo que hace el borrado (`rpc_reverse_stock_movement`) y es lo único correcto si el producto cambió de unidad base entre la creación y la edición. Recalcular con la unidad vieja reproduciría el bug de fondo en un caso raro pero real.

### D7 — `min_stock` numérico de punta a punta

- `ALTER TABLE branch_stock ALTER COLUMN min_stock TYPE numeric(15,4) USING min_stock::numeric(15,4)` (reescritura de tabla: ~5.100 filas, milisegundos). `products.min_stock` ya es numérico en prod; la migración lo garantiza para el stack local con el mismo `DO $$ … IF data_type = 'integer'` guardado que usó `20260930000001` para `sales.quantity`.
- `DROP FUNCTION rpc_set_product_min_stock(uuid, int)` + `CREATE ... (uuid, numeric)`, cuerpo idéntico salvo el tipo (`GREATEST(COALESCE(p, 0), 0)` se conserva: el negativo se rechaza en Pydantic con `ge=0` y en SQL queda en 0 como red).
- `check_branch_low_stock` y `get_dashboard_critical_stock` comparan `quantity <= min_stock`: numérico contra numérico, sin cambio de código; el gate lo ejercita con `0.5`.
- Backend: `min_stock: Decimal = Field(default=Decimal("0"), ge=0)` en `ProductIn` y `Decimal | None` en `ProductUpdate`; la fila del importador (`ProductImportRowIn.min_stock`) **sigue `int | None`**, porque `rpc_bulk_upsert_products` castea a `integer` (Non-Goal); `_SET_MIN_STOCK_SQL` con `$2::numeric`; `_propagate_min_stock(product_id, min_stock: Decimal)`.
- Frontend: `Product.minStock: number` ya lo es; el `NumericInput` ya acepta decimales. El `Math.ceil` del importador CSV queda (Non-Goal).

### D8 — Mostrar la unidad con los formateadores que ya existen

`formatStock` y `formatQuantity` (`lib/format-unit.ts`) ya implementan la regla "entero sin decimales, fracción con tres". Sólo hay que llevarles el símbolo:

- `/stock`: la fila ya viene de `useProducts` (con `baseUnitId`); se resuelve el símbolo con `useUnitsOfMeasure` + `resolveUnit` y se reemplazan los dos `{row.stock}` crudos y el `"uds"` fijo.
- Historial de movimientos: las filas traen `product_id`; el panel resuelve `baseUnitId` por el mapa de productos ya cacheado en React Query y el símbolo por el mapa de unidades. Sin consulta nueva.
- Ticket: `ReceiptData.items` gana `unit?: string`; `buildReceiptData` lo rellena desde `item.unitId` con el mapa de unidades; las tres salidas (HTML, texto, texto corto) lo imprimen a continuación de la cantidad con `formatQuantity`.

### D9 — Un gate SQL nuevo, transitivo, más la re-ejecución de los existentes

`supabase/tests/test_ventas_unidades_conversion.sql`, cableado en `KPI_Validation.yml`: fixtures propias (cuenta, sucursal, unidades kg/g/L, tres productos: base kg, base g, sin base) con cleanup bajo `session_replication_role = replica` como el resto de los gates; matriz de comportamiento (los cinco caminos × base kg + línea g; base g + línea kg; sin base + mL rechazado; tipo cruzado rechazado en cada camino con verificación de cero rastro; edición en gramos con las dos patas; reversa por borrado; `min_stock = 0.5` dispara alerta; propagación del mínimo fraccionario) y bloque de introspección (los seis cuerpos vivos contienen `_uom_normalize_quantity(` y ninguno contiene `* v_unit_factor`; ACLs del helper cerradas; firma única de `rpc_set_product_min_stock`). *Estado final (corrección post-revisión, 2026-09-25)*: ocho bloques. (A) definición única; (B) seis cuerpos; (C) rechazos sin rastro, borrado e invariante; (D) umbral fraccionario; (E) introspección, incluidos los `COMMENT ON FUNCTION` re-emitidos; (F) unidades **de sistema** (`is_system`, `account_id NULL`: el camino real del 100 % de las líneas con unidad en prod); (G) unidad de **otra cuenta real**, creada por `handle_new_user` (`P0404`, sin rastro); (H) residuo cero asertado en nueve tablas.

### D10 — `base_unit_id` de punta a punta (hallazgo del apply, 2026-09-24)

Al cablear el selector se encontró que **la unidad base nunca llegaba al frontend por la API de FastAPI**: `v_products_with_stock` no exponía `products.base_unit_id`, `ProductOut`/`ProductCreate`/`ProductUpdate` no la tenían, y el hook `use-products` no la mapeaba en la lectura ni la enviaba en el alta/edición — el formulario de producto ya ofrecía el selector y **el backend descartaba el valor en silencio**. Es lo que explica que en prod casi ningún producto tenga unidad base (medido 2026-09-25: 62 sobre ~5.500, 61 en Unidad y **uno solo en Kilogramo**, todos asignados por caminos anteriores a FastAPI) y que el catálogo muestre "uds" para casi todo. Sin esto D1/D3/D5 no son alcanzables desde la UI, así que entra en alcance:

- la vista gana `p.base_unit_id` como última columna (aditiva, mismo criterio que `category_id`), dentro de la misma recreación que ya hacía la migración;
- `ProductOut.base_unit_id` (default `None` para filas sin la columna), `ProductCreate.base_unit_id` y `ProductUpdate.base_unit_id` con **tri-estado por ausencia** (`base_unit_provided` desde `model_fields_set`, mismo molde que `cost`); el repository la incluye en `_NULLABLE_ON_UPDATE` y en el `INSERT`;
- **guard de tenencia**: el FK a `units_of_measure` no está scopeado por tenant, así que el service verifica que la unidad sea del sistema o de la cuenta (`unit_visible_to_account`) y responde `422 base_unit_not_found` — nunca se asigna un uuid ajeno;
- el hook mapea `base_unit_id → baseUnitId`; el `POST` lo envía siempre (`null` = sin unidad base) y el `PUT` es **tri-estado por ausencia de punta a punta** (auditoría post-apply): el campo se omite cuando el formulario no lo determina (variante, padre `variant_only`, producto no rastreado — el selector no se muestra) y el backend conserva el valor. La primera versión mandaba `undefined` como `null`, y editar sólo el nombre de un padre `variant_only` desasignaba su unidad base. Desasignar queda como operación de API (`null` explícito), sin superficie de UI hoy.

Fuera de alcance sigue el importador CSV (`rpc_bulk_upsert_products` no lee unidad) y el backfill de los productos sin unidad que se venden en kg (OQ-1).

### D11 — La unidad base no se cambia debajo del stock (corrección post-revisión, 2026-09-25; provisoria, pendiente de sign-off)

D10 habilitó por primera vez que `PUT /products` cambie `base_unit_id`, sin guard. Como `branch_stock.quantity` y `stock_movements.quantity_delta` están en la unidad base vigente, cambiarla reinterpreta en silencio todo el stock y el historial ("12 u" pasa a leerse "12 kg"). Decisión provisoria **D-C** (opción (a) de la decisión 6 del PO, que todavía no respondió):

- se permite **asignar** la unidad a un producto que no tenía, y mandar la misma que ya tiene;
- **cambiarla o quitarla** se rechaza con `409` RFC 7807 `base_unit_locked` (campo `base_unit_id`, mensaje accionable: dejar la unidad, o crear otro producto con la unidad correcta y pasarle el stock con un ajuste) si el producto o alguna de sus variantes tiene stock ≠ 0 en alguna sucursal o algún `stock_movements`;
- sin stock ni movimientos, el cambio se permite.

Vive en el service (`_guard_base_unit_change`) sobre una lectura del repository (`has_stock_or_movements`, filtrada por `account_id`) **y, desde la segunda revisión, en la tabla**: `trg_product_base_unit_guard` (`BEFORE INSERT OR UPDATE OF base_unit_id, account_id ON products`, `P0409 base_unit_locked`) es el único punto de paso — el guard de FastAPI lo salteaba un `PATCH` por PostgREST (`authenticated` tiene `UPDATE` sobre la columna) y leía sin bloquear (carrera con una compra concurrente, reproducida por la revisión). El trigger evalúa la unidad base **efectiva** (propia o heredada del padre), toma `FOR UPDATE` las variantes que la heredan y replica el guard de tenencia (`P0404 base_unit_not_found`); el chequeo del service queda como camino rápido con el 409 tipado. Asignar la unidad a un producto que no tenía, aunque ya tenga stock, se permite a propósito: es la vía para que los productos que se venden por kilo (OQ-1) declaren su base, y el stock que hasta ahora estaba "en unidades sin nombre" pasa a leerse en esa unidad. Si el PO elige (b) o (c), este guard se reemplaza. Tests: `backend/tests/test_ventas_unidades_conversion_base_unit_lock.py`.

### D12 — El precio de una línea es por unidad DE LA LÍNEA (segunda revisión, 2026-09-25; contrato D-F, provisorio, pendiente de sign-off)

El apply arregló el stock pero no el importe: POS, venta y compra calculaban el subtotal como precio del catálogo (por unidad BASE) × cantidad en la unidad de la LÍNEA — 100 g de un producto a $1.800/kg cobraban $180.000, y "1 Docena" a $100/u cobraba $100 mientras descontaba 12 (en el POS, una regresión nueva: antes stock y precio estaban mal por el mismo factor). La base no definía en qué unidad está `amount`. Contrato elegido (el recomendado por la revisión): **`amount`/`price` es por unidad de la LÍNEA**, así `total = amount × quantity` sigue valiendo para las 1.018 ventas históricas, `rpc_create_sale_operation` lo sigue recalculando igual y el `subtotal` que `_c29_confirm_order_core` toma del cliente es el correcto. El frontend re-expresa el precio (y el costo, en compras) al elegir otra unidad con el mismo factor que `toBaseQuantity` (`convertUnitPrice`, `lib/unit-utils.ts`), de modo que precio(línea) × cantidad(línea) = precio(base) × cantidad(base); el aviso "Cat." compara contra el precio de catálogo re-expresado. **No** se agregó el recálculo del subtotal en el servidor para el POS: rompería el "subtotal editable" (el precio de `sales_order_items` es `numeric(15,2)` y el subtotal se tipea); queda como candidato. Tests: `unit-utils-price-per-line-unit.test.ts`, `sale-form-price-per-line-unit.test.tsx`, `pos-price-per-line-unit.test.tsx`, `purchase-form-price-per-line-unit.test.tsx`, gate (I.1-I.2) y arnés visual (importe de la línea en venta, POS y compra).

### D13 — El reporting cuenta y costea en la unidad BASE (segunda revisión, 2026-09-25)

Todo el reporting multiplicaba la cantidad CRUDA de la línea por un costo POR UNIDAD BASE (`unit_cost_snapshot`/`products.cost`) y sumaba unidades crudas: con este change el POS y los formularios venden en unidades no base, así que cada venta así corrompía el costo, el margen y las unidades del Tablero, de `/estadisticas` y de rentabilidad (100 g a 600/kg: costo 60.000, "100" unidades). La cantidad se normaliza en la definición canónica `reporting_sales_lines_in_window` (la consumen ranking, evolución, desgloses, top clientes y rentabilidad) y en las dos lecturas que no pasan por ella, `rpc_dashboard_kpi_summary` y `rpc_dashboard_channel_margin`, vía `_uom_quantity_for_reporting` — un envoltorio de LECTURA del helper único que, ante una línea histórica que la regla de escritura de hoy rechazaría (la venta en mL del 22-09 sobre un producto sin base), reporta la cantidad tal como se grabó en vez de abortar el reporte. Los tres cuerpos parten del vivo (md5 en el preflight, que pasa a nueve funciones). No se persiste una columna `quantity_base` (seis caminos de escritura más un backfill; el envoltorio da el mismo resultado sin tocar datos). Gate (I.3-I.7): ranking 0,1 kg y COGS 60, margen por canal 66,7 %, costo por venta 60.

### Auditoría post-apply (2026-09-24, PR #584)

Auditoría del diff contra las reglas duras de `CLAUDE.md` y contra D1–D10 (dos agentes: corrección de la migración y del frontend; el resto a mano). Lo corregido en el mismo PR:

1. **Variantes sin unidad base** (D1): herencia `COALESCE(propia, padre)` en el helper y en la vista; gate A.13/A.14/B.6.
2. **Sexto cuerpo con conversión inline** (D4): la rama legacy del kill-switch de `rpc_create_sale_operation`; gate B.7 con el flag apagado para la cuenta.
3. **Guard de tenencia de la unidad de la línea** (D2): `P0404`; gate A.15.
4. **Preflight de reaplicación laxo** (D4): md5 exacto del cuerpo nuevo.
5. **Cleanup del gate** dejaba 24 filas huérfanas por corrida (unidades, formas de pago, categorías, `audit_logs`): bajo `replica` nada cascadea desde `accounts`; se borran explícito.
6. **`PUT /products` desasignaba la unidad base** al editar un padre `variant_only` o un producto no rastreado (D10): tri-estado por ausencia en el hook y el formulario.
7. **"Editar producto" enlazaba `/productos?q=<uuid>`** y el catálogo no buscaba por id: el filtro del catálogo también matchea el id.
8. **Acumulación por escaneo** en venta y compra normalizaba con la base del tipo (2º argumento sin la base del producto): `quantityBase` no tiene lector hoy, pero contradecía D5.
9. `compatibleUnits` tenía una segunda copia del predicado de `isUnitCompatible`; el delta del historial usaba `text-emerald-400`/`text-red-400` en vez de tokens; el arnés visual copiaba la tarjeta móvil de `/stock` en vez de montar la real (`buildMobileCard` exportada); el test del guard de tenencia del backend no fijaba el `account_id`.

Señalado y **no** corregido (fuera de alcance, sin regresión): las líneas cargadas en la edición de venta/compra no traen `minQty`/símbolo (preexistente; **corregido en la segunda revisión** — y la descripción de acá estaba mal: no era que no se pudiera bajar de 1, sino que al tocar la cantidad de una línea de 0,45 kg `Math.max(item.minQty ?? 1, qty)` la **subía en silencio a 1**; ahora el mínimo, el paso y el símbolo se derivan de la unidad de la línea o de la base del producto); el bloque de selector (`productBaseUnit`/`unitOptions`/preselección) está copiado en las tres pantallas — mismo patrón preexistente de `selectedUnit`/`stagedMin`, candidato a hook compartido; `toBaseQuantity` redondea inline en vez de importar `_round4` (D5 lo admitía explícitamente); `ProductImportRowIn.min_stock` sigue `int | None` (el importador es Non-Goal de D7 y `rpc_bulk_upsert_products` castea a `integer`).

### Corrección post-revisión (2026-09-25, PR #584)

La revisión adversarial del PR (2026-09-24, 37 hallazgos confirmados) lo declaró no mergeable; el PO ordenó corregirlo en una sesión local. Lo que cambió respecto del apply, con el detalle en cada decisión:

1. **CI `validate-kpis` en rojo por el propio PR** (bloqueante): tolerancia acotada de los dos reaplicados viejos y reaplicación de la migración nueva al final de la cadena (ver Riesgos). La afirmación "84/84 gates" del apply venía de correr los gates sueltos, no el workflow; se retiró.
2. **Colisión con #585** (bloqueante): renumeración a `20261062000001` y fusión en 3 vías de `rpc_atomic_update_sale_operation` (D4).
3. **`/stock` se caía en prod** (bloqueante): FastAPI serializa `min_stock` (`Decimal`) como string y el hook no lo convertía, así que `formatStock` hacía `.toFixed` sobre un string. `use-products.ts` lo pasa por `Number()` (como stock y precio) y `lib/format-unit.ts` se defiende de un string en la entrada. Los tests nuevos usan el string real de la API, no un número.
4. `COMMENT ON FUNCTION` vivos re-emitidos (D4); gate con unidades de sistema, unidad de otra cuenta real y residuo cero asertado (D9); guard de cambio de unidad base (D11).
5. Frontend: `toBaseQuantity` sin unidad de línea es espejo exacto del helper (redondeo a 4 decimales, sin factor); el selector de unidad base del formulario de producto viaja sólo para productos con control de stock (`stockControlType === "tracked"`) y los inputs de stock y de stock mínimo aceptan decimales (`step="any"`: con 0,5 el navegador bloqueaba el submit por `stepMismatch`, hallazgo de la corrección); el toast de stock insuficiente de la venta y del POS muestra el disponible con el símbolo de la unidad **base** del producto; comentarios del importador corregidos (el entero del mínimo lo impone `rpc_bulk_upsert_products`, no la columna).
6. Verificación visual: el arnés `e2e/harness/unidades-visual.spec.ts` suma el POS y el formulario de compra en 1366 y 375 px × claro y oscuro (task 6.4).

## Risks / Trade-offs

- [La cadena de reaplicación de `KPI_Validation.yml` (paso "Verify G1/G4 migrations are idempotent on reapply") reaplica migraciones viejas sobre la base ya migrada] → encontrado por la revisión (CI run 36042552278 en rojo): reaplicar `20261039000001` choca con el `RETURNS TABLE` nuevo de `get_dashboard_critical_stock_items` (*cannot change return type of existing function*) y, detrás, `20261040000001` con la vista que ganó una columna (*cannot drop columns from view*). Se toleran **sólo** esos dos errores exactos con el patrón acotado que ya usa el workflow (cualquier otro → `exit 1`), y la migración nueva se reaplica al final de la cadena, sin tolerancia: 6/6 funciones por la rama de reaplicación del preflight, gate embebido PASS y schema idéntico al previo.
- [Un gate existente fija literalmente el texto reemplazado (p. ej. la multiplicación inline)] → se corren los cinco gates que introspectan estas funciones antes de abrir el PR; el que falle se actualiza en el mismo PR con la justificación en el comentario del gate, nunca relajando la aserción que protegía.
- [Un cliente viejo (pestaña abierta durante el deploy) manda una unidad ahora incompatible] → recibe `P0400` con token propio traducido en `operation-errors.ts` a "La unidad X no es compatible con el producto Y"; no hay estado parcial porque el rechazo ocurre antes de escribir.
- [Cambio de comportamiento en el POS con Docena/Caja x 6 sobre productos en Unidad] → hoy el POS descuenta 1 por "1 docena"; pasa a descontar 12, que es lo que el formulario ya hacía. 0 líneas del POS usan esas unidades; se documenta en `CHANGES.md` como corrección, no como BREAKING.
- [`ALTER COLUMN TYPE` toma lock exclusivo sobre `branch_stock`] → tabla chica, operación de milisegundos, dentro del deploy habitual (`supabase db push` desde CI); sin ventana especial.
- [Redondeo a 4 decimales en la base del producto] → 0,1 g sobre kg, 0,1 mL sobre L: suficiente para el negocio objetivo; una línea que normalice a `0` (p. ej. 0,00004 kg) se rechaza con `P0400` en el helper para no registrar ventas que no mueven stock.
- [Precisión JS en la validación local (`450 × 0.001`)] → `_round4` en `toBaseQuantity`; la decisión final siempre es del servidor.
- **[D-E — ventana entre el deploy del backend y el `db push`]** El backend nuevo llama `rpc_set_product_min_stock(uuid, numeric)`, que no existe en la base vieja (allí es `(uuid, integer)`). Si Render despliega el backend antes de que el job "Deploy Supabase" termine el `db push` (o si el push falla), **toda alta de producto (`POST /products`) devuelve 500** hasta que la migración llegue a prod. No se mitiga con una sobrecarga `(uuid, integer)`: reabre la ambigüedad de resolución de funciones (`42725`) que el proyecto ya pagó. *Segunda revisión (medido)*: la ventana no afecta "algunas" altas sino **todas** (`ProductCreate.min_stock` vale `Decimal('0')` por defecto y siempre se propaga) y también `PUT /products` con mínimo; el orden inverso —base primero, backend viejo después— es seguro (con la base nueva, la llamada de `main` con `$2::int` resuelve por cast implícito a `numeric`, y `ProductOut.min_stock` ya es `Decimal | None` en `main`). "Mergear en hora tranquila" no controla el orden. **Mitigación concreta, sin overload**: pausar el auto-deploy de Render antes del merge, dejar que el job "Deploy Supabase" haga el `db push`, verificar `pg_get_function_identity_arguments` de `rpc_set_product_min_stock` = `p_product_id uuid, p_min_stock numeric`, y recién entonces disparar el deploy del backend a mano (`POST /deploys`); alternativa equivalente: un PR sólo de base primero. Queda a decisión del PO en el merge.

## Migration Plan

1. Verificar en prod (sólo `SELECT`) y en el stack local los md5 CR-stripped de las seis funciones y la firma vigente de `rpc_set_product_min_stock`; registrarlos en la cabecera de la migración.
2. Migración `20261062000001_ventas_unidades_conversion.sql`, en este orden: preflight md5 → helper → seis `CREATE OR REPLACE` → `ALTER` de `branch_stock.min_stock` (+ guardado de `products.min_stock` para local) → `DROP`/`CREATE` de `rpc_set_product_min_stock` con `GRANT` idéntico al vivo → `REVOKE` del helper → gate embebido de introspección.
3. `supabase db reset` local limpio; gate nuevo + los gates de `KPI_Validation.yml` en el orden del workflow; backend `pytest` con cobertura; frontend `vitest` + `tsc`. **Y el workflow `validate-kpis` completo en CI en verde**, incluido el paso "Verify G1/G4 migrations are idempotent on reapply": correr los gates sueltos no lo reemplaza (corrección post-revisión: ese paso es justo el que esta migración rompía — ver Riesgos).
4. Deploy por el camino normal (merge → `deploy.yml` → `db push --include-all`). Sin toggle: el rechazo de unidades incompatibles y la conversión correcta no se pueden desplegar a medias sin dejar un camino corrompiendo stock.
5. Verificación post-merge en prod: `MAX(version) = 20261062000001`, tipo de `branch_stock.min_stock`, una sola firma de `rpc_set_product_min_stock`, `has_function_privilege` del helper en `false` para `anon`/`authenticated`, los seis cuerpos vivos con la llamada al helper y los `COMMENT ON FUNCTION` de `get_dashboard_critical_stock_items` y `rpc_set_product_min_stock` presentes.
6. Humo real del PO: producto en kg con stock 1, venta de 450 g desde el POS y desde el formulario, edición a 300 g, borrado; `/stock` mostrando `0.550 kg`; mínimo `0.5` con alerta.
7. **Rollback**: la migración es idempotente pero no reversible sola; ante un problema se reaplican los cuerpos anteriores (registrados por md5 en la cabecera y recuperables del historial de migraciones) con una migración correctiva. El `ALTER` de `min_stock` no necesita rollback: numérico es un superconjunto de entero.
8. **Daño histórico**: un solo movimiento afectado (`stock_movements.id = cf4550c0-cf36-4f88-aeba-bdf2cd8bb423`, cuenta `192b9efe-…`, producto `ac5ae409-…`, `-0.0004` donde correspondía `-0.381`). No se corrige por migración: el PO decide un ajuste manual desde `/stock` (`rpc_adjust_branch_stock`, deja rastro `adjustment`) o lo deja, dado que el producto tiene ~7.000 en stock y la diferencia es de 0,38.

## Sign-off del PO (pendiente)

El propose y el apply se hicieron en la misma sesión (2026-09-24), sin sign-off del PO, en un change MEDIA con un tramo ALTA; el alcance se amplió en el apply (D10) sin volver a propose. La revisión del PR #584 (2026-09-24) listó nueve decisiones que sólo el PO puede tomar. Estado al 2026-09-25:

| # | Decisión | Estado |
|---|---|---|
| 1 | Orden de merge entre #585 (Facturar) y #584 | **Resuelta por los hechos**: #585 mergeó primero; este PR se renumeró a `20261062000001` y se fusionó sobre él (D4). |
| 2 | Reescribir en una sola migración, sin interruptor, las seis funciones que escriben stock (POS, venta por formulario, venta legacy, compra, edición de venta y de compra); la vuelta atrás es con una migración correctiva | Implementada por la sesión de la nube. **Pendiente de confirmación del PO.** |
| 3 | Un producto SIN unidad base deja de poder venderse o comprarse por Docena, Caja x 6, g, mL, cm o t (el sistema pide asignarle la unidad base); en el POS "1 Docena" pasa a descontar 12 unidades en vez de 1. Hoy 62 productos tienen unidad base | Implementada por la sesión de la nube. **Pendiente de confirmación del PO.** |
| 4 | Stock mínimo decimal en todas las sucursales (0,5 kg); el importador CSV lo sigue redondeando a entero hasta un change aparte | Implementada por la sesión de la nube. **Pendiente de confirmación del PO.** |
| 5 | Las variantes (163) heredan la unidad del padre para vender y para mostrar el stock | Implementada por la sesión de la nube. **Pendiente de confirmación del PO.** |
| 6 | El formulario de producto guarda y cambia la unidad base; qué hacer con un producto que ya tiene stock o movimientos: (a) bloquear, (b) sólo entre unidades del mismo tipo convirtiendo el stock, (c) libre | **Implementada con la opción conservadora (a)** por decisión D-C (D11), **provisoria** hasta que el PO responda. |
| 7 | Opción "Sin unidad" en el formulario de producto | **No implementada.** Desasignar sigue siendo sólo una operación de API (`null` explícito), sujeta a D11. |
| 8 | Ajuste manual de −0,3806 en `/stock` para el producto `ac5ae409…` de la cuenta `192b9efe…` (movimiento `cf4550c0-cf36-4f88-aeba-bdf2cd8bb423`, venta del 22-09 en mL que descontó 0,0004 en vez de 0,381) | **Sin cambios de datos** hasta que el PO responda (D-D). |
| 10 | (segunda revisión) Contrato de precio: el precio de una línea es por unidad DE LA LÍNEA (D12) — 100 g a $1.800/kg se cobran $180; el reporting cuenta y costea en unidad base (D13) | **Implementado** como decisión provisoria **D-F**; **pendiente de confirmación del PO** (es dinero). |
| 9 | (OQ-1) Cargar "Kilogramo" como unidad base en los productos sin unidad que se venden por kilo (37 en 30 días, 49 en el historial, 46 sin borrar) | **Sin cambios de datos** hasta que el PO responda (D-D). |

## Open Questions

- **OQ-1** — ¿Sembrar `base_unit_id = Kilogramo` en los productos sin unidad que se vienen vendiendo en kg, para que el catálogo deje de decir "uds"? Medido en prod el 2026-09-25 (sin unidad base propia ni heredada, con líneas de venta en Kilogramo): **37 en los últimos 30 días, 49 en todo el historial, 46 de ellos sin borrar** — la cifra de 37 del propose era la ventana de 30 días, no el total. No cambia specs ni tareas de este change (D3 los deja funcionando); es una migración de datos de una cuenta y media que el PO puede pedir como fix ad-hoc después.
