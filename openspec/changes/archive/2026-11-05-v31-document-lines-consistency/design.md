## Context

H-15 (Roadmap v3.1, `CHANGES.md`) dice que la línea de documento (`sale_items`/`purchase_items`) no es universal. `c29-write-sale-items`, `v3-snapshot-pattern` y `deudas-menores-agosto` G1 ya cerraron casi todo (ver proposal, «Qué ya está cerrado de hecho»). Este design parte de lo medido en prod el 2026-11-05, sólo lectura (`mcp__supabase__execute_sql`). **El apply re-verifica cada hecho en el grupo 0 antes de escribir SQL.**

### Hechos medidos (2026-11-05)

**Funciones vivas que leen el flag `sale_items_rpc_v2`** (las 4 conservan su firma):

| Función | Uso del flag | md5(`pg_get_functiondef`) |
|---|---|---|
| `rpc_create_sale_operation` (11 args, DEFINER, sin COMMENT) | `IF v_flag_on THEN RETURN v2(...) ELSE <legacy header-only>` | `cf89a1ce6821ed88c4439d5473e53069` |
| `_purchase_operation_core` (13 args, DEFINER, COMMENT) | `IF v_flag_on THEN INSERT purchase_items` (rama de producto) | `defe427a8d4f0545ce7ab29b008e20b1` |
| `rpc_atomic_update_sale_operation` (19 args, DEFINER, COMMENT) | `IF v_flag_on THEN INSERT sale_items` | `8219c37148a22f23b14665e925260624` |
| `rpc_atomic_update_purchase_operation` (20 args, DEFINER, COMMENT) | `IF v_flag_on THEN INSERT purchase_items` | `88b793adc63a340cc2ccbce863178b73` |

**Otros escritores vivos de líneas** (`prosrc ILIKE 'insert into%sale_items|purchase_items'`; ninguno lee el flag):

| Función | Escribe | md5 |
|---|---|---|
| `rpc_create_sale_operation_v2` (11 args, DEFINER, sin COMMENT) | `sale_items` de producto con `name_snapshot = v_product.name`; **servicio: sólo header** | `e552aff0a3a0e856d6b6f74fa59fe38d` |
| `_c29_confirm_order_core` (9 args, DEFINER, COMMENT; lo llaman `rpc_quick_sale`, `rpc_confirm_sales_order`, `rpc_convert_quote_to_sale` y `rpc_convert_delivery_note_to_sale`) | `sale_items` de producto con los 4 snapshots de `sales_order_items`; **servicio: sólo header** | `9d0d68eb75e4f1199b6c988153bd81f2` |
| `rpc_create_purchase_operation_v2` (4 args, sólo `service_role`, sin COMMENT, sin llamadores SQL ni backend; con guards de `multiusuario-operativo`) | `purchase_items` **sin `name_snapshot`** | `1ce48fb319b2cd0dd0e1eaed2ebbf75d` |
| `_sales_order_sync_from_operation` | `sales_order_items` (no líneas de documento); lee `sale_items` | `6518af5b08eb64e4755419cff41c6b5a` |

Las 4 de edición y compra también tienen una rama de servicio que escribe sólo el header. ACLs vivas: `{postgres, service_role}` en `_purchase_operation_core` y `rpc_create_purchase_operation_v2`; `{postgres, authenticated, service_role}` en las demás.

**Datos:**

- `sale_items`: 1273 filas; `purchase_items`: 792. **50 / 29** líneas tienen `name_snapshot` NULL, y **todas** tienen `product_id` NULL:
  - **23 / 18 son filas legacy de variante** (`variant_id NOT NULL`, variante viva en `product_variants`). Conviven en el mismo header con la línea canónica del producto (`snapshot_backfilled = true`). Son las **únicas** ventas o compras con 2 líneas: 23 + 18, de marzo y abril de 2026, en 3 cuentas. La spec las preserva explícitamente.
  - **27 / 11 son líneas canónicas de productos borrados** (el header también tiene `product_id` NULL).
  - De dónde sale el nombre: `stock_movements.product_name` con `reference_id = <id del documento>`. Hay a lo sumo un nombre distinto por documento (verificado). Cubre 23/23 + 23/27 líneas de venta y 18/18 + 8/11 de compra. Además, 5 de las 11 de compra tienen `purchases.description`. El resto queda en la etiqueta.
- **Documentos sin línea**: 2 ventas y 4 compras, todas con `product_id` NULL y de la cuenta `3834e5d7-…`.
  - Ventas: `c6768b9e-…` y `12bb61ed-…`, de la operación `663a7c03-…`, fecha 2026-05-31, $31.920 c/u, ambas con stock movement `sale_update`.
  - Compras: `e4c858c6-…` ($20.000, con stock movement y descripción) y `9c902095-…`, `853731ea-…`, `0d3acd7f-…` ($12.000 c/u, sin stock movement ni descripción).
- Header contra línea: 0 líneas con `subtotal` distinto de `COALESCE(total, amount*quantity)` del header.
- Líneas de servicio reales: 0 en `sales_order_items`, y 0 ventas o compras sin producto creadas desde junio de 2026.
- `account_feature_flags`: 35 filas, todas `sale_items_rpc_v2` y todas `enabled = true`. No hay otros flags.
- Migraciones en prod: `max(version) = 20261090000001` (337 filas). El número libre es **`20261091000001`**.

**Lectores de líneas:**

- Robustos ante la línea de servicio nueva y ante la fila de variante, porque filtran por producto:
  - `reporting_sales_lines_in_window` y `rpc_dashboard_kpi_summary` (`si.product_id = s.product_id`);
  - `rpc_dashboard_channel_margin`;
  - `v_sales_flat` (alimenta `ai-insights`/`ai-precio`);
  - `sales_repository.py` L214 y `purchase_repository.py` L142 (`product_id IS NOT NULL`);
  - `_sales_order_sync_from_operation`, que desempata con `ORDER BY (x.product_id IS NOT DISTINCT FROM s.product_id) DESC` («H2»).
- **No robusto**: `client_repository.py` L146 y L297 (`LEFT JOIN sale_items si ON si.sale_id = s.id`, sin filtro). Las 23 ventas con fila de variante suman dos veces su `COALESCE(si.subtotal, …)`: 21 tienen cliente, son 14 clientes y hay $1.273.900 contados de más en la actividad de clientes.

**Gates que dependen del flag o de la regla «servicio sin fila»:** los 7 archivos que lista el proposal. Además, el FINGERPRINT del paso de reapply de `KPI_Validation.yml` (L52) incluye `count(account_feature_flags WHERE flag_key='sale_items_rpc_v2')`, y ese paso reaplica `20260924000001`, que recrea las funciones con el flag.

## Goals / Non-Goals

**Goals:**

- Que la línea sea universal **por construcción**: un solo camino de escritura, sin flag, y con fila también para el servicio.
- Que los datos históricos cumplan el mismo invariante: 0 documentos sin línea canónica y 0 líneas sin nombre.
- Fijar el invariante con `NOT NULL` y un gate de dinero estricto, para que no se reabra en silencio.
- Corregir el único lector que hoy cuenta dos veces.
- Dejar escrito qué bloquea todavía C-20 Grupo 10.

**Non-Goals:**

- `iva_rate_snapshot`: requiere una tasa de IVA en `products`, que corresponde a un change futuro de IVA/percepciones (V2.5). La mención de H-15 se reclasifica.
- El DROP del header plano de C-20 Grupo 10 (RN-97; aprobación separada del PO).
- `v3-product-composition`.
- Retirar las 41 filas legacy de variante: se conservan, como manda la spec vigente, y sólo reciben nombre.
- Una UI para nombrar líneas de servicio en los formularios de venta y compra (`SaleItemIn.product_id` sigue siendo obligatorio en la API).
- Leer el nombre del servicio desde `sale_items` en `sales_repository`: hoy lo empareja desde `sales_order_items` y sigue funcionando.
- Dropear `rpc_create_purchase_operation_v2`.

## Decisions

**D1. Retiro del flag con `CREATE OR REPLACE` desde el cuerpo vivo.** Ninguna de las 4 firmas cambia, así que no hace falta `DROP FUNCTION` ni hay riesgo `42725`.
- Cada cuerpo se copia de `pg_get_functiondef` **vivo** y su md5 se compara contra la tabla de arriba (checkpoint 0.2).
- Se quitan sólo tres cosas: la variable `v_flag_on`, el `SELECT … INTO v_flag_on` con su `COALESCE`, y el `IF v_flag_on THEN … END IF`, conservando el contenido del bloque.
- En `rpc_create_sale_operation` desaparece la rama `ELSE` legacy entera. La función queda como despachador de una línea a la v2 y conserva su nombre público, porque el backend llama a `rpc_create_sale_operation`.
- Los COMMENT vivos se re-emiten actualizados en el mismo archivo.
- Las ACLs se re-declaran explícitas (`REVOKE ALL … FROM PUBLIC, anon` y los `GRANT` exactos de la tabla). `CREATE OR REPLACE` ya las conserva; esto es un cinturón ante el reapply.

*Alternativa descartada*: dejar el flag fijado en `true` y el `ELSE` muerto. Es código que nadie ejercita y que ya obligó a duplicar guards en `operacion-party-guard`, `multiusuario-operativo` y `ventas-unidades-conversion`.

**D2. Filas del flag: `DELETE` en la migración; la tabla se queda.** Se borran las 35 filas con `flag_key = 'sale_items_rpc_v2'`. `account_feature_flags` queda vacía pero viva, como infraestructura genérica de flags. *Alternativa descartada*: dropear la tabla. Es más superficie y el hallazgo no lo pide.

**D3. La línea de servicio escribe su fila.** Se revierte la regla de `sale-line-items` «el servicio MUST NOT generar fila». El INSERT de la línea se agrega en las 6 ramas de servicio: `rpc_create_sale_operation_v2`, `_c29_confirm_order_core`, `_purchase_operation_core`, las dos RPCs de edición, y `rpc_create_purchase_operation_v2` si tiene rama de servicio.

La línea nueva lleva:
- `product_id = NULL` y `variant_id = NULL`;
- la misma `quantity` y `unit_id` que el header;
- `price = amount` y `subtotal = amount * quantity`, el mismo valor que el header;
- `sku_snapshot`, `unit_cost_snapshot` e `iva_rate_snapshot` en NULL.

El `name_snapshot` sale de esta cascada:
- en `_c29_confirm_order_core`, de `v_item.name_snapshot` de `sales_order_items`;
- en venta, del nombre del ítem si el recordset del payload lo trae (el apply verifica la definición del recordset y, si no lo trae, no agrega el campo);
- en compra, de la `description` del ítem y, si falta, de `p_description`;
- si no queda nada, la etiqueta `'Ítem sin producto'`, una sola constante compartida con el backfill.

*Por qué*: sin fila de servicio la línea nunca puede ser la fuente de verdad, y al dropear el header en C-20 Grupo 10 se perderían el importe y la cantidad del servicio.

*Impacto*: en prod no hay servicios desde junio. Los lectores filtran por producto, así que ningún total cambia. `_sales_order_sync_from_operation` sale ganando, porque ahora encuentra el nombre del servicio.

*Alternativa descartada*: acotar el invariante a «filas con producto». Deja al servicio como excepción permanente y reescribe la regla vieja con otras palabras.

**D4. Línea canónica = `variant_id IS NULL`.** Las 41 filas legacy de variante se conservan. El invariante y los lectores hablan de la **línea canónica**: exactamente una por fila de header, con `variant_id IS NULL`. Ningún escritor vivo escribe `variant_id` (todos usan NULL), y el gate lo asserta.

**D5. Backfill en la misma migración, idempotente y marcado.**

1. **Documentos sin línea canónica** (6 hoy). `INSERT` de la línea desde el header: `product_id` del header (NULL en los 6), `quantity`, `unit_id`, `price = amount`, `subtotal = COALESCE(total, amount*quantity)` y `account_id`. Va con `snapshot_backfilled = true` y `WHERE NOT EXISTS` sobre la línea canónica.
2. **Nombre faltante** (79 hoy, más las 6 líneas nuevas). `UPDATE … SET name_snapshot = COALESCE(products.name, <stock_movements.product_name con reference_id = documento, una fila>, NULLIF(btrim(purchases.description), ''), 'Ítem sin producto'), snapshot_backfilled = true WHERE name_snapshot IS NULL`.

Todo filtra por la propia fila y no depende del `account_id` de sesión: la migración corre como `postgres`. Una segunda corrida no cambia ninguna fila (lo verifica el gate). Antes del `INSERT` y del `UPDATE`, la migración emite con `RAISE NOTICE` los conteos esperados (6 y 79 en prod), para que queden en el log de `db push`.

**D6. `name_snapshot NOT NULL` después del backfill.** Va un `ALTER TABLE … ALTER COLUMN name_snapshot SET NOT NULL` en `sale_items` y en `purchase_items`, en la misma migración y después de D3 y D5. Antes del `ALTER`, la migración aborta con un mensaje claro si queda alguna fila en NULL. El comportamiento es *fail-closed*: un escritor futuro que olvide el nombre rompe en CI en vez de dejar una línea muda en prod.

`rpc_create_purchase_operation_v2` es el único escritor que hoy inserta sin nombre. Pasa a escribir `name_snapshot = v_product.name`, o la cascada de servicio.

*Riesgo*: un camino vivo no inventariado que inserte sin nombre haría fallar ventas reales.
*Mitigación*: el inventario de arriba (`prosrc` cubre todos los INSERT del esquema), el checkpoint 0.3 que lo vuelve a correr, y el gate D7, que **ejecuta** cada escritor.

*Alternativa descartada*: un trigger `CONSTRAINT … DEFERRABLE` que asserte «≥1 línea por header» al commit. Es caro en el hot path, complica la edición (DELETE y reINSERT en la misma transacción), y el invariante ya queda garantizado por construcción (D1 + D3) y vigilado por el gate.

**D7. Gate nuevo `supabase/tests/test_document_lines_consistency.sql`, corrido con `run_gate_strict.py`.** Es un gate de dinero y se cablea en `KPI_Validation.yml` junto al resto de esa familia. Toma de molde `test_sale_items_rpc_v2_activation.sql`: anchors vía `handle_new_user`, claims con `set_config`, fallos acumulados y un solo `RAISE` al final.

Verifica:
- (a) Cada uno de los 6 escritores, ejecutado de verdad (no alcanza con verificar que exista; es regla dura del proyecto), produce **exactamente una** línea canónica con nombre por fila de header, con producto y con servicio.
- (b) El flag ya no tiene efecto: sin fila en `account_feature_flags` y **con** una fila `enabled = false` insertada a mano, el resultado es el mismo.
- (c) Ningún `prosrc` de `public` contiene `sale_items_rpc_v2`.
- (d) Barrido global:
  - 0 headers sin línea canónica, 0 con más de una y 0 líneas con `name_snapshot` NULL;
  - por documento, `Σ subtotal` de la línea canónica = `Σ COALESCE(total, amount*quantity)` del header.
- (e) Los reportes no cambian: `rpc_dashboard_kpi_summary` y `reporting_sales_lines_in_window` devuelven lo mismo antes y después de crear una venta de servicio sobre la cuenta ancla (la invariancia de D3).
- (f) El backfill es idempotente: re-ejecutar su bloque no cambia ninguna fila.
- (g) Las ACLs de las 7 funciones reescritas coinciden con la tabla.

**D8. `client_repository.py` lee sobre la línea canónica.** Los dos `LEFT JOIN sale_items si ON si.sale_id = s.id` pasan a `… AND si.variant_id IS NULL`. Con TDD: primero un test que fija que una venta con fila de variante cuenta una sola vez. *Alternativa descartada*: borrar las filas de variante. Es destructivo y la spec las preserva (D4).

**D9. Los gates y tests existentes se migran; no se borran.**
- Los bloques que prueban el kill-switch (`enabled = false` lleva a legacy) pasan a probar lo contrario: el flag ya no tiene efecto.
- Los que asertan «servicio sin fila» pasan a asertar «servicio con una línea con nombre».
- En `test_operacion_party_guard` (10), el chequeo «0 cuentas con el flag apagado» se reemplaza por «la rama legacy no existe» (`prosrc`).
- En `backend/tests/test_sale_items.py`, los tests del flag (L179-300) se reescriben: el backend siempre llama a `rpc_create_sale_operation` y el despacho ya no existe.
- En el paso de reapply de `KPI_Validation.yml`, el contador del flag sale del FINGERPRINT, y la reaplicación de `20261091000001` se suma al final de la reconvergencia, para que el reapply de `20260924000001` no deje vivas las funciones con flag.

**D10. Rollback en `supabase/migrations_bak/rollback_20261091000001_v31_document_lines_consistency.sql`.** Hace `DROP NOT NULL` en las dos columnas, recrea las 7 funciones con el cuerpo vivo previo (copiado en el checkpoint 0.2) y vuelve a insertar las filas del flag (`enabled = true`) para las cuentas con ventas. **No** revierte el backfill: las líneas agregadas son correctas y quedan marcadas con `snapshot_backfilled`.

**D11. Veredicto sobre C-20 Grupo 10.** Lo deja escrito en `CHANGES.md` la task 5.3. Lo esperado es que no quede nada estructural que lo bloquee. Lo que queda son los **lectores** del header plano (`sales.product_id/amount/quantity/total` y su par en `purchases`): reportes, repositorios, vistas, Edge Functions y `_sales_order_sync_from_operation`. La task los inventaría como candidato `c20-grupo10-lectores`, sin implementarlos.

## Risks / Trade-offs

- **Reescribir 7 funciones del hot path de dinero y stock** → Se parte del cuerpo vivo con el md5 verificado (checkpoint 0.2). El diff de cada función se limita a lo que piden D1 y D3, y el apply lo muestra con `diff` contra el cuerpo vivo. El gate D7 ejecuta cada camino. Los 7 gates migrados siguen cubriendo stock, caja, banco, cuenta corriente y los guards de tenencia.
- **Drift entre el propose y el apply** (otro change reescribe una de estas funciones en el medio) → Si un md5 no coincide, el checkpoint 0.2 detiene el apply y obliga a re-derivar desde el cuerpo vivo nuevo. Nunca se escribe sobre un cuerpo viejo.
- **El `NOT NULL` rompe un escritor no inventariado** → Lo cubren el checkpoint 0.3 (barrido de `prosrc` en todos los esquemas), el gate D7 (a) y la verificación post-merge (5.4) de que las ventas del día siguen entrando.
- **Se pierde el interruptor de apagado por cuenta** → Lo reemplaza el rollback D10. Desde agosto ninguna cuenta tuvo el flag en `false`.
- **Unas 7 líneas quedan con la etiqueta genérica** → El nombre real no existe en ninguna fuente. `snapshot_backfilled = true` marca la aproximación, con el mismo criterio que D5 de `v3-snapshot-pattern`.
- **La actividad de clientes cambia para 14 clientes** → Es la corrección de un doble conteo. Se anota en el registro del PO y el número exacto se vuelve a medir en 5.4.
- **Reapply de `KPI_Validation.yml`** → Lo resuelve D9. Si la reconvergencia no queda verde al primer intento, el apply ajusta el paso del workflow, nunca el gate.

## Migration Plan

1. La migración `20261091000001_v31_document_lines_consistency.sql` corre en una sola transacción, en este orden:
   1. guard de precondiciones: las 7 funciones existen con las firmas esperadas;
   2. `CREATE OR REPLACE` de las 7 funciones (D1 + D3), con sus COMMENT y ACLs;
   3. `DELETE` de las filas del flag (D2);
   4. backfill (D5), con `RAISE NOTICE` de los conteos;
   5. assert de 0 NULL y `SET NOT NULL` (D6).
2. Al mergear, `deploy.yml` corre `supabase db push --include-all`. Nunca se usa el MCP `apply_migration`.
3. Verificación post-merge (orquestador, sólo lectura, task 5.4): `max(version)`; ningún `prosrc` con el flag; 0 filas del flag; 0 headers sin línea canónica; 0 nombres NULL; columnas `NOT NULL`; ACLs; ventas y compras del día con su línea.
4. Rollback: aplicar `supabase/migrations_bak/rollback_20261091000001_…sql` por CLI, con aprobación del PO (D10).

## Open Questions

Todas resueltas por la opción recomendada (ver «Sign-off del PO»):

- **OQ-1** ¿Qué se hace con las filas del flag? (a) borrarlas y conservar la tabla ✅; (b) dejarlas; (c) dropear la tabla.
- **OQ-2** ¿La línea de servicio genera fila? (a) sí, con nombre por cascada y etiqueta de respaldo ✅; (b) no, con un invariante acotado a las filas con producto.
- **OQ-3** ¿Qué pasa con las filas legacy de variante? (a) se conservan con nombre y la línea canónica se define como `variant_id IS NULL` ✅; (b) se borran.
- **OQ-4** ¿Cómo se fija el invariante? (a) `NOT NULL` de `name_snapshot` más gate de dinero estricto ✅; (b) sólo el gate; (c) además, un trigger diferido de «≥1 línea».
- **OQ-5** ¿Qué pasa con `rpc_create_purchase_operation_v2`? (a) se conserva y se le suma `name_snapshot` ✅; (b) se dropea, lo que exige migrar `test_multiusuario_operaciones` (i) y `database.types.ts` (queda como candidato).
- **OQ-6** ¿Qué etiqueta de respaldo? (a) `'Ítem sin producto'` ✅; (b) `'Producto eliminado'`, que es falso para un servicio real; (c) dejar NULL, incompatible con D6.
- **OQ-7** ¿Y el doble conteo de `client_repository`? (a) se corrige en este change ✅; (b) se abre un chip aparte.

## Sign-off del PO

Por mandato permanente del PO del 2026-11-04 («siempre la opción recomendada»), OQ-1 a OQ-7 quedan resueltas por la opción marcada ✅. Governance: **MEDIO con tramo ALTO**, porque reescribe las RPCs del hot path de venta y compra (dinero y stock). El apply avanza con checkpoints (grupo 0) y, antes de abrir el PR, muestra el diff de cada función contra su cuerpo vivo.
