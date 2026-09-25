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

Las dos conversiones existentes multiplican por `unit.factor` **a secas**, o sea relativo a la base del **tipo** (kg, L, m, u), no a la del producto. Coincide con la base del producto sólo porque hoy ningún producto tiene una unidad base derivada (58 en Unidad, 1 en Kilogramo, 5.150 sin unidad). El catálogo, en cambio, muestra el stock con el símbolo de la unidad base del producto (`formatStock(stock, baseUnit.symbol)`), y el alta de producto guarda el stock inicial crudo: la convención **implícita** de todo lo que se ve es "el stock está en la unidad base del producto". Este change la hace explícita.

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

- Asignar unidad base a los 37 productos sin unidad que se venden por kilo (candidato; hoy se muestran como "uds" y seguirán así hasta que el PO decida).
- Corregir el ranking de productos, que suma `sale_items.quantity` cruda mezclando unidades (candidato aparte, misma familia).
- Importador CSV de productos: sigue leyendo el stock mínimo como entero con aviso (`Math.ceil`); levantarlo es un ajuste barato para después de que la columna sea numérica.
- Unidades por tenant (`account_id`) en los selectores: se filtran por el mismo criterio de tipo, sin lógica adicional.
- Backfill del movimiento dañado del 2026-09-22 (ver Migration Plan).

## Decisions

### D1 — La normalización es relativa a la unidad base del PRODUCTO

`normalizada = round(cantidad × factor(unidad línea) ÷ factor(unidad base producto), 4)`. Sin unidad base, el divisor es 1.

*Por qué no dejar "× factor" (base del tipo)*: es lo que se ve en pantalla lo que define la unidad del stock, y el catálogo ya muestra el stock en la base del producto. Con base del tipo, un producto en gramos con stock 1000 mostraría "1000 g" y una venta de 450 g descontaría 0,45. La fórmula relativa al producto es la única consistente con el alta de producto (stock inicial crudo) y con la vista. Para los datos vigentes las dos fórmulas coinciden (0 productos con base derivada), así que no hay migración de datos.

*Por qué no guardar la cantidad normalizada en la línea*: la línea debe conservar lo que el usuario ingresó (450 g) para el ticket, la edición y la reimpresión; el ledger es el que se expresa en base. Ya es así hoy en el formulario.

*Variantes (auditoría post-apply, 2026-09-24)*: una variante nunca declara `base_unit_id` propia (el formulario manda `undefined` y el backend sólo hereda `category_id` del padre), y un padre con variantes sólo se vende a través de ellas (`P0422`). Sin herencia, el helper trataba a toda variante como "producto sin unidad base" — medido en prod: **163 variantes de padres con unidad base** habrían perdido las unidades derivadas (450 g rechazado con `unit_requires_base_unit`) y aceptado cualquier unidad base de cualquier tipo. La base efectiva de una variante es `COALESCE(propia, la del padre)`, en el helper y en `v_products_with_stock.base_unit_id` (que es lo que el frontend lee: el selector, `/stock` y el ticket la heredan sin código propio).

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
- La migración registra el md5 CR-stripped de cada cuerpo de partida y aborta si el cuerpo vivo del stack difiere del esperado (mismo patrón que `20261060000001`), para no reescribir sobre una base desconocida. *Auditoría post-apply*: la reaplicación se reconoce por el md5 **exacto** del cuerpo que esta migración deja (calculado por el generador), no por "contiene la llamada al helper" — ese predicado laxo habría dejado pasar en silencio una redefinición posterior de cualquiera de las seis.

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
- Backend: `min_stock: Decimal = Field(default=Decimal("0"), ge=0)` en `ProductIn`, `Decimal | None` en `ProductUpdate` y en la fila de import; `_SET_MIN_STOCK_SQL` con `$2::numeric`; `_propagate_min_stock(product_id, min_stock: Decimal)`.
- Frontend: `Product.minStock: number` ya lo es; el `NumericInput` ya acepta decimales. El `Math.ceil` del importador CSV queda (Non-Goal).

### D8 — Mostrar la unidad con los formateadores que ya existen

`formatStock` y `formatQuantity` (`lib/format-unit.ts`) ya implementan la regla "entero sin decimales, fracción con tres". Sólo hay que llevarles el símbolo:

- `/stock`: la fila ya viene de `useProducts` (con `baseUnitId`); se resuelve el símbolo con `useUnitsOfMeasure` + `resolveUnit` y se reemplazan los dos `{row.stock}` crudos y el `"uds"` fijo.
- Historial de movimientos: las filas traen `product_id`; el panel resuelve `baseUnitId` por el mapa de productos ya cacheado en React Query y el símbolo por el mapa de unidades. Sin consulta nueva.
- Ticket: `ReceiptData.items` gana `unit?: string`; `buildReceiptData` lo rellena desde `item.unitId` con el mapa de unidades; las tres salidas (HTML, texto, texto corto) lo imprimen a continuación de la cantidad con `formatQuantity`.

### D9 — Un gate SQL nuevo, transitivo, más la re-ejecución de los cinco existentes

`supabase/tests/test_ventas_unidades_conversion.sql`, cableado en `KPI_Validation.yml`: fixtures propias (cuenta, sucursal, unidades kg/g/L, tres productos: base kg, base g, sin base) con cleanup bajo `session_replication_role = replica` como el resto de los gates; matriz de comportamiento (los cinco caminos × base kg + línea g; base g + línea kg; sin base + mL rechazado; tipo cruzado rechazado en cada camino con verificación de cero rastro; edición en gramos con las dos patas; reversa por borrado; `min_stock = 0.5` dispara alerta; propagación del mínimo fraccionario) y bloque de introspección (los cinco cuerpos vivos contienen `_uom_normalize_quantity(` y ninguno contiene `* v_unit_factor`; ACLs del helper cerradas; firma única de `rpc_set_product_min_stock`).

### D10 — `base_unit_id` de punta a punta (hallazgo del apply, 2026-09-24)

Al cablear el selector se encontró que **la unidad base nunca llegaba al frontend por la API de FastAPI**: `v_products_with_stock` no exponía `products.base_unit_id`, `ProductOut`/`ProductCreate`/`ProductUpdate` no la tenían, y el hook `use-products` no la mapeaba en la lectura ni la enviaba en el alta/edición — el formulario de producto ya ofrecía el selector y **el backend descartaba el valor en silencio**. Es lo que explica que en prod haya un solo producto con unidad base (asignado en la era supabase-js) y que el catálogo muestre "uds" para todo. Sin esto D1/D3/D5 no son alcanzables desde la UI, así que entra en alcance:

- la vista gana `p.base_unit_id` como última columna (aditiva, mismo criterio que `category_id`), dentro de la misma recreación que ya hacía la migración;
- `ProductOut.base_unit_id` (default `None` para filas sin la columna), `ProductCreate.base_unit_id` y `ProductUpdate.base_unit_id` con **tri-estado por ausencia** (`base_unit_provided` desde `model_fields_set`, mismo molde que `cost`); el repository la incluye en `_NULLABLE_ON_UPDATE` y en el `INSERT`;
- **guard de tenencia**: el FK a `units_of_measure` no está scopeado por tenant, así que el service verifica que la unidad sea del sistema o de la cuenta (`unit_visible_to_account`) y responde `422 base_unit_not_found` — nunca se asigna un uuid ajeno;
- el hook mapea `base_unit_id → baseUnitId`; el `POST` lo envía siempre (`null` = sin unidad base) y el `PUT` es **tri-estado por ausencia de punta a punta** (auditoría post-apply): el campo se omite cuando el formulario no lo determina (variante, padre `variant_only`, producto no rastreado — el selector no se muestra) y el backend conserva el valor. La primera versión mandaba `undefined` como `null`, y editar sólo el nombre de un padre `variant_only` desasignaba su unidad base. Desasignar queda como operación de API (`null` explícito), sin superficie de UI hoy.

Fuera de alcance sigue el importador CSV (`rpc_bulk_upsert_products` no lee unidad) y el backfill de los 37 productos sin unidad que se venden en kg (OQ-1).

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

Señalado y **no** corregido (fuera de alcance, sin regresión): las líneas cargadas en la edición de venta/compra no traen `minQty`/símbolo (preexistente; una línea de 0,45 kg no se puede bajar de 1 en la edición); el bloque de selector (`productBaseUnit`/`unitOptions`/preselección) está copiado en las tres pantallas — mismo patrón preexistente de `selectedUnit`/`stagedMin`, candidato a hook compartido; `toBaseQuantity` redondea inline en vez de importar `_round4` (D5 lo admitía explícitamente); `ProductImportRowIn.min_stock` sigue `int | None` (el importador es Non-Goal de D7 y `rpc_bulk_upsert_products` castea a `integer`).

## Risks / Trade-offs

- [Un gate existente fija literalmente el texto reemplazado (p. ej. la multiplicación inline)] → se corren los cinco gates que introspectan estas funciones antes de abrir el PR; el que falle se actualiza en el mismo PR con la justificación en el comentario del gate, nunca relajando la aserción que protegía.
- [Un cliente viejo (pestaña abierta durante el deploy) manda una unidad ahora incompatible] → recibe `P0400` con token propio traducido en `operation-errors.ts` a "La unidad X no es compatible con el producto Y"; no hay estado parcial porque el rechazo ocurre antes de escribir.
- [Cambio de comportamiento en el POS con Docena/Caja x 6 sobre productos en Unidad] → hoy el POS descuenta 1 por "1 docena"; pasa a descontar 12, que es lo que el formulario ya hacía. 0 líneas del POS usan esas unidades; se documenta en `CHANGES.md` como corrección, no como BREAKING.
- [`ALTER COLUMN TYPE` toma lock exclusivo sobre `branch_stock`] → tabla chica, operación de milisegundos, dentro del deploy habitual (`supabase db push` desde CI); sin ventana especial.
- [Redondeo a 4 decimales en la base del producto] → 0,1 g sobre kg, 0,1 mL sobre L: suficiente para el negocio objetivo; una línea que normalice a `0` (p. ej. 0,00004 kg) se rechaza con `P0400` en el helper para no registrar ventas que no mueven stock.
- [Precisión JS en la validación local (`450 × 0.001`)] → `_round4` en `toBaseQuantity`; la decisión final siempre es del servidor.

## Migration Plan

1. Verificar en prod (sólo `SELECT`) y en el stack local los md5 CR-stripped de las cinco funciones y la firma vigente de `rpc_set_product_min_stock`; registrarlos en la cabecera de la migración.
2. Migración `20261062000001_ventas_unidades_conversion.sql`, en este orden: helper → cinco `CREATE OR REPLACE` → `ALTER` de `branch_stock.min_stock` (+ guardado de `products.min_stock` para local) → `DROP`/`CREATE` de `rpc_set_product_min_stock` con `GRANT` idéntico al vivo → `REVOKE` del helper → gate embebido de introspección.
3. `supabase db reset` local limpio; gate nuevo + los 40 gates de `KPI_Validation.yml` en el orden del workflow; backend `pytest` con cobertura; frontend `vitest` + `tsc`.
4. Deploy por el camino normal (merge → `deploy.yml` → `db push --include-all`). Sin toggle: el rechazo de unidades incompatibles y la conversión correcta no se pueden desplegar a medias sin dejar un camino corrompiendo stock.
5. Verificación post-merge en prod: `MAX(version) = 20261062000001`, tipo de `branch_stock.min_stock`, una sola firma de `rpc_set_product_min_stock`, `has_function_privilege` del helper en `false` para `anon`/`authenticated`, los cinco cuerpos vivos con la llamada al helper.
6. Humo real del PO: producto en kg con stock 1, venta de 450 g desde el POS y desde el formulario, edición a 300 g, borrado; `/stock` mostrando `0.550 kg`; mínimo `0.5` con alerta.
7. **Rollback**: la migración es idempotente pero no reversible sola; ante un problema se reaplican los cuerpos anteriores (registrados por md5 en la cabecera y recuperables del historial de migraciones) con una migración correctiva. El `ALTER` de `min_stock` no necesita rollback: numérico es un superconjunto de entero.
8. **Daño histórico**: un solo movimiento afectado (`stock_movements.id = cf4550c0-cf36-4f88-aeba-bdf2cd8bb423`, cuenta `192b9efe-…`, producto `ac5ae409-…`, `-0.0004` donde correspondía `-0.381`). No se corrige por migración: el PO decide un ajuste manual desde `/stock` (`rpc_adjust_branch_stock`, deja rastro `adjustment`) o lo deja, dado que el producto tiene ~7.000 en stock y la diferencia es de 0,38.

## Open Questions

- **OQ-1** — ¿Sembrar `base_unit_id = Kilogramo` en los 37 productos sin unidad que se vienen vendiendo en kg, para que el catálogo deje de decir "uds"? No cambia specs ni tareas de este change (D3 los deja funcionando); es una migración de datos de una cuenta y media que el PO puede pedir como fix ad-hoc después.
