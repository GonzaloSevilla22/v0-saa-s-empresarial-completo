## Context

El sistema no tiene ninguna superficie que responda "qué se vende y cuándo". La motivación y el alcance firmado están en `proposal.md`; este documento resuelve el **cómo**.

### Estado medido de producción (2026-09-03)

Todo lo que sigue está verificado contra la base real, no inferido.

| Hecho | Medición |
|---|---|
| Ventas totales / últimos 90 días | 764 líneas / 636 líneas |
| Tenants con actividad en 90 días | 6 (2 con volumen: 304 y 240) |
| Líneas de servicio (`product_id IS NULL`) en 90 días | 13 |
| Líneas sin canal | 341 / 636 (54%) |
| Líneas sin sucursal | 412 / 636 (65%) |
| Líneas sin cliente | 228 / 636 (36%) |
| Líneas con `unit_cost_snapshot` | 508 / 636 (79,9%) |
| Productos totales / variantes (`parent_id` no nulo) | 5.084 / 2.127 (42%) |
| Categorías distintas en `products.category` | 7 |
| Índice `(account_id, date)` en `sales` | **no existe** (14 índices vivos, ninguno cubre ese par) |

### Las dos restricciones que dominan el diseño

**(1) `sales.date` es una fecha de negocio, no un instante.** Es `timestamptz` pero guarda la fecha declarada en el formulario, fijada a `00:00:00+00`. En 90 días, **0 de 636** líneas tienen hora real. Como `00:00 UTC` es `21:00 del día anterior` en Mendoza, convertirla con `AT TIME ZONE 'America/Argentina/Mendoza'` corre **cada** venta un día hacia atrás. El instante real vive en `created_at`.

**(2) El invariante de consumo prohíbe fórmulas ad-hoc.** `reporting-invariants` → "Enforcement de consumo": ningún consumidor recalcula ingresos fuera del read-model canónico, y todo desglose no cubierto agrega vía un helper canónico compartido, "nunca con una expresión escrita en el punto de uso". Este change agrega ~6 agregados nuevos: sin un choke point compartido, son 6 oportunidades de que el módulo discrepe del Tablero.

### Restricciones de plataforma que afectan el diseño

- `auth["plan"]` del backend Python cae al default **`"pro"`** cuando el claim no viaja (`backend/core/auth.py:107`), y el custom access token hook **no está activo en producción** (`v31-authz-token-hook`, tasks 8.3-8.6 pendientes). Un guard de plan en el backend concedería `pro` a todo el mundo.
- `get_effective_plan(uuid)` es `STABLE SECURITY DEFINER` y está REVOKEado de `authenticated`, pero ya se lo invoca desde dentro de otras funciones `SECURITY DEFINER` (precedente en `20260817000001`).
- Las ventas se anulan por DELETE físico: `sales` no tiene `status` ni `deleted_at`, así que ningún agregado necesita filtrar documentos anulados (quedan fuera por construcción, RN-D1).

## Goals / Non-Goals

**Goals:**

- Responder "qué se vende, cuándo, por dónde y a quién" en una sola pantalla, con números que **coincidan con el Tablero** sobre la misma ventana.
- Un único lugar donde vive la definición de "línea de venta del período": helper compartido, consumido por todos los agregados nuevos **y** por `rpc_product_profitability`.
- Que el límite de historial por plan se cumpla aunque el cliente mienta.
- Entregar valor en tres etapas independientemente desplegables.

**Non-Goals:**

- Materializar o cachear agregados (764 ventas; sería complejidad sin problema).
- Migrar las dos copias JS de "top productos" al agregado canónico (candidato declarado).
- Migrar los 3 reportes existentes a los componentes de gráfico extraídos.
- Pantalla de detalle de producto en `/productos/[id]` (ver D12).
- Estadísticas de compras o gastos: el pedido es de ventas.
- Backfill de canal, sucursal o cliente en las operaciones históricas.

## Decisions

### D1 — Un helper SQL compartido + RPCs por forma de salida (no una RPC parametrizada gigante, no seis copias)

`reporting_sales_lines_in_window(p_account_id, p_start, p_end, p_branch_id, p_canal)` devuelve el conjunto de líneas del período con `line_revenue = COALESCE(total, amount)` ya resuelto, los bordes RN-D5 ya aplicados (`>= p_start AND < p_end + 1 día`) y el filtro de sucursal/canal aplicado uniformemente a todos los términos.

Encima de él, **una RPC por forma de salida**, no por dimensión:

| RPC | Forma | Por qué separada |
|---|---|---|
| `rpc_sales_evolution(p_start, p_end, p_bucket, p_branch_id, p_canal)` | `(bucket_start date, revenue, units, operations)` + fila del período anterior | Serie temporal con comparación |
| `rpc_sales_breakdown(p_start, p_end, p_dimension, p_branch_id, p_canal)` | `(bucket_key text, bucket_label text, revenue, units, operations)` | **Una sola** RPC para canal, sucursal, día de semana y hora: la forma de salida es idéntica |
| `rpc_sales_top_clients(p_start, p_end, p_branch_id, p_limit)` | `(client_id, client_name, revenue, operations)` | Forma propia |
| `rpc_product_ranking(p_start, p_end, p_order_by, p_group_variants, p_branch_id, p_canal, p_limit, p_offset)` | fila de ranking con costo/margen/categoría | Forma propia, paginada |
| `rpc_product_sales_evolution(p_product_id, p_start, p_end, p_bucket)` | serie del producto y sus variantes | Detalle |

**Alternativa descartada — una RPC con `p_dimension`, incluidos productos y clientes**: forzaría todas las columnas a un shape genérico (`text`/`numeric`), perdiendo el tipado de `product_id`/`client_id` y obligando al cliente a castear. **Alternativa descartada — cuatro RPCs para canal/sucursal/día/hora**: cuatro cuerpos casi idénticos que divergen al primer arreglo. La línea se traza donde la **forma de salida** cambia, no donde cambia la dimensión.

### D2 — `rpc_product_profitability` también consume el helper (reutilización real, sin tocar su firma)

La regla del proyecto es "reutilizarla o extenderla; NUNCA duplicarla", y `rpc_product_ranking` se solapa fuerte con `rpc_product_profitability` (ambas agregan ventas por producto con costo desde snapshot).

- **Extender su firma** con `p_start`/`p_end`/`p_branch_id`/`p_order_by` obligaría a `DROP FUNCTION` + `CREATE` y a migrar sus dos consumidores vivos (`/rentabilidad` y la Edge Function `ai-rentabilidad`) — entangla una pantalla que funciona, y la lección registrada del proyecto es que endurecer un contrato sin migrar **todos** los callers rompe cosas por semanas.
- **Duplicar la agregación** sería la tercera copia de una fórmula que ya existe dos veces en JS. Exactamente lo que la regla prohíbe.

Se toma la tercera vía: **la parte común se extrae al helper de D1 y las dos RPCs lo consumen**. `rpc_product_profitability` conserva firma y columnas de salida intactas; sólo cambia su cuerpo. Se de-duplica sin romper contratos. Regla de Tres cumplida (es la 3ª+ instancia, no una abstracción especulativa).

Reescritura partiendo del **`pg_get_functiondef` vivo**, no del archivo de migración — precedente registrado de una RPC cuyo cuerpo vivo había divergido del último archivo.

### D3 — Día de negocio con `::date`; hora real con `created_at AT TIME ZONE` (el hallazgo que invierte la instrucción)

- **Bucketing por día / semana / mes y día de la semana**: `s.date::date`, cast pelado. `s.date` ya **es** el día calendario del tenant.
- **Ventana del período**: sin cambios (`>= p_start` / `< p_end + 1 día`), que ya es correcta porque ambos lados viven en UTC-medianoche.
- **Ventanas relativas**: siguen ancladas a `reporting_local_today()` (RN-D5).
- **Horario**: `created_at AT TIME ZONE 'America/Argentina/Mendoza'` — `created_at` sí es un instante y sí requiere la conversión.

Aplicar la conversión de zona a `s.date` produce un off-by-one universal, no ocasional: verificado en **218 de 218 productos**. El requirement nuevo en `reporting-invariants` existe para que el próximo que toque esto no repita el error: la lección es que "usá siempre la zona local" es una regla correcta sobre *instantes* y destructiva sobre *fechas de negocio*, y la spec no distinguía las dos cosas.

**Fix de `last_sale_date`** (`rpc_product_profitability`): pasa a `MAX(s.date)::date`. Sigue satisfaciendo el `42804` que motivó el cast original (el tipo de retorno es `date`), sin el corrimiento.

### D4 — Semana ISO lunes-domingo, sin ambigüedad

`date_trunc('week', ...)` de Postgres ya arranca el lunes, y `extract(isodow)` numera lunes=1..domingo=7. Se usan los dos, que son consistentes entre sí por construcción. No se introduce configuración de "primer día de la semana": ningún dato del negocio la pide y sería una palanca que nadie mueve.

### D5 — La RPC devuelve la hora cruda (0-23); la franja la arma la UI

`rpc_sales_breakdown(..., 'hour')` devuelve a lo sumo 24 filas con la hora entera. La agrupación en franjas (Madrugada 0-6, Mañana 6-12, Tarde 12-19, Noche 19-24) es **presentación**: la UI puede ofrecer ambas vistas sin una segunda consulta, y cambiar los cortes de franja no requiere tocar la base. 24 filas no justifican agregarlas en el servidor.

### D6 — Líneas de servicio: dentro de la facturación, fuera del ranking, declaradas en ambos

Las líneas con `product_id IS NULL` (13 en 90 días, importe real) son **ingreso genuino**:

- **Evolución, canal, sucursal, día, hora, top clientes: las incluyen.** Excluirlas haría que el módulo informe menos facturación que el Tablero.
- **Ranking de productos: las excluye** — no son productos y no tienen dónde rankear.
- **La asimetría se declara en la UI**, no sólo en la spec: el pie del ranking informa el importe excluido. Sin eso, un usuario que suma la columna del ranking y la compara con el gráfico de evolución encuentra una diferencia sin explicación, que es exactamente el modo de fallo que `reporting-invariants` fue escrito para evitar.

### D7 — Notas de crédito: las resta la evolución (vía el helper único), no el ranking

- **Evolución y totales del período**: restan NC vía `reporting_credit_notes_in_window` — el mismo helper que `rpc_dashboard_kpi_summary` y `get_dashboard_financials`. Es la condición para que diario ≡ mensual ≡ estadísticas. No se replica la regla.
- **Ranking, canal, día, hora, top clientes**: **no** restan NC, porque una NC no tiene producto, ni canal, ni hora atribuible. Es la misma excepción ya documentada para `rpc_dashboard_channel_margin`, y se declara igual: en la spec **y** en la nota al pie de la pantalla.
- Bajo filtro de sucursal, la atribución de NC la resuelve el helper (fail-closed), sin lógica nueva.

### D8 — El límite de historial se aplica en la RPC, no en el backend ni en la UI

`auth["plan"]` cae a `"pro"` sin el claim, y el hook de auth no está activo en producción: un clamp en el backend Python **concedería el plan máximo a todos**. Un clamp sólo en la UI es cooperación del cliente — que es exactamente lo que hace hoy `/rentabilidad` (`periodDays = limits?.historyDays ?? 30` viaja como parámetro y la RPC no lo verifica).

El clamp vive en la RPC: `get_effective_plan(v_account_id)` → `plan_limits.history_days` → `p_start` se recorta a `reporting_local_today() - history_days`. Fail-closed por construcción, porque `get_effective_plan` ya devuelve `'gratis'` ante cuenta inexistente o plan no reconocido.

**Recorta, no rechaza** (el módulo está disponible en todos los planes; un 403 sería un candado de entrada que el PO descartó), y **devuelve la ventana efectivamente aplicada** para que la UI diga "tu plan permite N días" en vez de mostrar un gráfico más corto sin explicar por qué. Un recorte silencioso es indistinguible de "no vendiste nada en enero".

### D9 — Backend FastAPI en 3 capas

Precedente de los últimos 5 changes (`/reports/payment-methods`, `/reports/receivables`, `/reports/payables`) contra el precedente alternativo de `supabase.rpc` directo (rentabilidad, sucursal, centros de costo). Se elige FastAPI porque:

- el ranking se pagina, y el envelope estándar `{items,total,page,pages}` de `api-standards` ya vive ahí;
- los parámetros de dimensión y orden se validan como `Literal` → **422 sin ejecutar consulta** ante un valor fuera de dominio, patrón ya usado en `/reports/receivables`;
- la exportación y el detalle por producto se sirven mejor con el read-model detrás de la API.

`routers/statistics.py` con `report_router` prefijo `/reports/statistics`, service con la validación de rango (`422` si `end < start`), repository sobre las RPCs.

### D10 — Índice `(account_id, date DESC)` sobre `sales`

Los 14 índices vivos cubren `user_id`, `client_id`, `canal`, `branch_id`, `product_id`, `operation_id` — **ninguno el par `(account_id, date)`**, que es el predicado exacto de los seis agregados nuevos. El más cercano, `idx_sales_account_client_date`, es parcial (`WHERE client_id IS NOT NULL`) y por lo tanto no sirve para un barrido de período.

`CREATE INDEX IF NOT EXISTS` sin `CONCURRENTLY`: las migraciones corren dentro de una transacción y `CONCURRENTLY` no lo admite; con 764 filas el bloqueo es instantáneo. Se verifica con `EXPLAIN` en el apply — un índice que el planner no elige es peso muerto, y decirlo en la task es más barato que descubrirlo después.

### D11 — Margen con cobertura parcial: se muestra el margen **y** la cobertura

La cascada de costo es la ya canónica: `unit_cost_snapshot` de la línea, con fallback a `products.cost` sólo si el snapshot es NULL (RN-D2).

- Grupo **sin ningún** costo resoluble → `NULL` → la UI muestra "—". Nunca cero, nunca margen inventado.
- Grupo con cobertura **parcial** → muestra el margen **con marca de cobertura** (ej. "72% de las líneas con costo"). Sin la marca, un grupo con 20% de cobertura aparenta un margen enorme y es indistinguible de uno medido de verdad — que es la forma sofisticada de inventar el dato que el encargo prohíbe.

### D12 — Detalle en `/estadisticas/productos/[id]`, no en `/productos/[id]`

`/productos` es el CRUD del catálogo. Una ruta `/productos/[id]` se lee como "editar producto", se esperaría alcanzable desde el catálogo, y comprometería a este change con una pantalla de catálogo que no está en su alcance. Bajo `/estadisticas` la ruta dice lo que es. El header del detalle enlaza al producto en el catálogo, así que el camino existe sin fingir ser otra cosa.

### D13 — Componentes de gráfico extraídos, usados sólo por lo nuevo

Tres reportes ya repiten el mismo BarChart horizontal y este change suma ~4 gráficos: la Regla de Tres está cumplida y `components/charts/` no existe. Se extraen `ReportBarChart` y `ReportTimeSeriesChart` sobre `REPORT_SERIES_COLORS`, y **los consume sólo la superficie nueva**. Migrar los 3 reportes existentes ensancharía el diff con regresiones posibles en pantallas que hoy funcionan; queda como candidato explícito, no como deuda escondida.

### D14 — Etapas de entrega

| Etapa | Contenido | Valor entregable solo |
|---|---|---|
| **E1** | Helper + ranking (unidades/importe/margen/categoría, variantes agrupadas) + evolución con comparación + `/estadisticas` + índice + fix de `last_sale_date` | Responde la pregunta del PO |
| **E2** | Canal, sucursal, día de semana, horario, top clientes | Completa las dimensiones |
| **E3** | Export CSV del ranking + detalle por producto + `ai-estadisticas` | Extras |

Cada etapa deja el sistema consistente. E1 sola ya cierra el pedido literal.

### D15 — Categorías: dependencia blanda de una sola vista

La vista "por categoría" agrupa por `products.category` TEXT. Cuando `productos-categorias-sku` aterrice con `product_categories` + `products.category_id`, esa vista —y sólo esa— pasa a agrupar por el catálogo. Ninguna otra parte del módulo toca categorías, así que el orden de merge entre los dos changes no importa.

## Risks / Trade-offs

- **El horario mide carga, no venta** → Se rotula explícitamente como horario de carga, con la salvedad visible en la pantalla; 300 de 636 líneas tienen `created_at` a más de 24 h de su `date`, así que la brecha es real y grande. Si el PO no acepta la métrica así rotulada, la vista se retira (OQ-1) — es preferible a un gráfico que responde otra pregunta que la que su título promete.
- **Reescribir el cuerpo de `rpc_product_profitability` toca una pantalla que funciona** → Firma y columnas de salida intactas; los tests existentes de `/rentabilidad` y `ai-rentabilidad` son la red. La reescritura parte del `pg_get_functiondef` vivo y el `last_sale_date` corregido se verifica contra el conteo medido (218/218 hoy corridos → 0 después).
- **Seis agregados nuevos pueden discrepar del Tablero** → Es la razón de ser del helper único (D1) y de restar NC por el helper compartido (D7). Se cubre con un gate que compara la facturación del módulo contra `rpc_dashboard_kpi_summary` sobre la misma ventana.
- **El clamp de plan puede confundir** ("¿por qué mi gráfico empieza en febrero?") → La RPC devuelve la ventana aplicada y la UI la explica (D8).
- **Índice que el planner no usa** → Se mide con `EXPLAIN` antes de darlo por bueno; si no lo elige, se retira en el mismo apply en vez de dejarlo como peso muerto.
- **`ON DELETE SET NULL` en `products.parent_id`** → Una variante cuyo padre se borró queda con `parent_id NULL` y agrupa bajo sí misma. Es el comportamiento correcto (ya no tiene padre), no un caso a corregir, pero se fija con un test para que nadie lo "arregle" después.

## Migration Plan

1. Migración única e idempotente (`CREATE OR REPLACE` para el helper y las RPCs nuevas; `DROP FUNCTION` + `CREATE` **sólo** si alguna firma cambiara, para no dejar overloads vivos — gotcha `42725`), con `REVOKE`/`GRANT` explícitos en el mismo archivo (un `DROP`+`CREATE` resetea ACLs).
2. Índice en la misma migración.
3. Reescritura del cuerpo de `rpc_product_profitability` partiendo del `pg_get_functiondef` vivo.
4. Gate SQL propio en `supabase/tests/` + step en `KPI_Validation.yml` con `psql -v ON_ERROR_STOP=1`. Los gates genéricos (ACLs, ERRCODE de 5 caracteres, referencias a tablas) cubren gratis las RPCs nuevas; el comportamiento propio no.
5. Rollback: las RPCs nuevas se dropean sin efecto colateral (nada más las consume); `rpc_product_profitability` se restaura desde el cuerpo vivo capturado antes de tocarla; el índice se dropea. Ningún cambio de datos, ningún cambio de esquema de tablas — **este change no escribe una sola fila de negocio**.

## Open Questions

Las cinco no están cubiertas por el sign-off del 2026-09-03, porque dependen de mediciones hechas **después** de firmarlo.

- **OQ-1 (bloqueante de una vista) — "franjas horarias de venta" no existe en los datos.** 0 de 636 líneas de 90 días tienen hora en `sales.date`. Opciones: **(a, recomendada)** entregar la vista desde `created_at`, rotulada "horario de carga", con la salvedad visible; **(b)** retirar la vista del alcance hasta que las ventas registren hora real. Lo que **no** es una opción es entregarla rotulada como horario de venta.
- **OQ-2 — 36% de las líneas no tienen cliente.** ¿"Top clientes" muestra una fila "Sin cliente" o la excluye? **Recomendación: excluirla del ranking** (ganaría el primer puesto siempre y no es accionable) **y declarar el importe en el pie**, coherente con el tratamiento de las líneas de servicio (D6).
- **OQ-3 — el off-by-one de `last_sale_date` ¿se corrige acá?** **Recomendación: sí.** Es el read-model del que este change deriva, el arreglo es de una línea y demostrable (218/218 → 0). Sacarlo a un change aparte dejaría a este módulo construyendo sobre un defecto conocido.
- **OQ-4 — margen con cobertura parcial.** ¿Margen + marca de cobertura (D11) o "—" salvo cobertura total? La recomendación es D11: con 79,9% de cobertura global, exigir el 100% vaciaría la columna para casi todos los grupos.
- **OQ-5 — ¿la evolución resta notas de crédito?** **Recomendación: sí** (D7), es la condición para coincidir con el Tablero; el ranking no puede y lo declara.

### Resueltas por sign-off del PO (2026-09-03)

Las cinco OQs se firmaron el mismo día del propose, antes del apply de E1. Las resoluciones no estaban escritas en los artefactos; se registran acá y en `CHANGES.md`:

- **OQ-1 → (a)**: la vista de horarios se entrega desde `created_at`, rotulada **"horario de carga"** (exacto para el POS, aproximado para la carga manual). Es de **E2**; E1 no la implementa.
- **OQ-2 → excluir**: "Top clientes" excluye las ventas sin cliente (36% de las líneas) y **declara su importe aparte**. Es de **E2**.
- **OQ-3 → sí, en E1**: el off-by-one de `rpc_product_profitability.last_sale_date` se corrige en este change (218/218 productos corridos un día en `/rentabilidad`; causa: `AT TIME ZONE` sobre `sales.date`, que guarda la fecha de negocio a 00:00 UTC; introducido por `qa-integral-modulos` G8). Lo correcto es el casteo directo; demostrable 218 → 0 en prod tras el merge.
- **OQ-4 → D11**: margen con **marca de cobertura de costo** (79,9% de las líneas con `unit_cost_snapshot`). Aplica al ranking por margen de E1.
- **OQ-5 → sí**: la evolución **resta notas de crédito** vía `reporting_credit_notes_in_window` (el mismo helper de `rpc_dashboard_kpi_summary` / `get_dashboard_financials`) para coincidir con el Tablero. E1.
- **Regla de zona horaria vigente para todo el change**: `sales.date` es fecha de negocio → `::date` pelado, **nunca** `AT TIME ZONE` (corre un día atrás); `created_at` es instante → sí `AT TIME ZONE 'America/Argentina/Mendoza'`. El delta de `reporting-invariants` la formaliza.

### Notas de implementación de E1 (desvíos declarados, apply 2026-09-03)

- **`p_account_id` como primer parámetro** de `rpc_sales_evolution` y `rpc_product_ranking`, con guard de membresía `P0401` (molde `rpc_receivables_report`): las consume el backend FastAPI, que ya resuelve la cuenta con `get_account_id`. D1 no lo listaba.
- **El clamp de D8 se extrae a un helper propio, `reporting_plan_window(p_account_id, p_start, p_end)`** (`get_effective_plan` → `plan_limits.history_days` → `reporting_local_today()`; fail-closed al mínimo de `plan_limits` o 30). Lo consumen las dos RPCs de E1 y lo consumirán las de E2/E3 — el clamp vive en un solo lugar. No se expone a `authenticated` (toma `p_account_id`).
- **`rpc_sales_evolution` devuelve tres clases de fila** (`period` ∈ `bucket` / `current` / `previous`): los buckets rellenos en cero, los totales de la ventana aplicada (NC calculada una sola vez sobre toda la ventana, idéntica al Tablero) y el período anterior de igual longitud. Ningún consumidor re-agrega buckets. La fila `previous` **no** se recorta por plan: es un agregado de comparación, como `prev_invoiced_revenue`.
- **Bajo filtro de canal la evolución no resta NC** (una NC no tiene canal atribuible): fail-closed, misma excepción que los desgloses. Bajo filtro de sucursal la atribuye el helper.
- **`rpc_product_ranking` pagina dentro de la RPC** (`p_limit`/`p_offset`, `total_count` por fila vía `COUNT(*) OVER ()`, orden por `ROW_NUMBER` sobre el conjunto completo); el repository arma el envelope estándar y, si una página queda fuera de rango, sondea una fila para no perder el total ni la ventana. Devuelve también `sku`, `category`, `parent_id`/`parent_name` (contexto de la variante sin agrupar) y `last_sale_date`. La **vista por categoría es de E2**, aunque la columna ya viaja.
- **Orden por margen = margen absoluto** (`gross_margin`), no `gross_margin_pct` (`/rentabilidad` ya ordena por porcentaje; "más vendidos por margen" es la plata que deja).
- **El helper `reporting_sales_lines_in_window` no fija `search_path`** a propósito: una función SQL con `SET` no se inlinea y el planner de la RPC que la envuelve queda ciego al índice. Medido en el apply (task 2.13, 60k filas sintéticas en una transacción revertida): con `idx_sales_account_date` el planner hace *Bitmap Index Scan* sobre el índice compuesto (836 entradas / 549 bloques); sin él, lee las 20.000 entradas de la cuenta y descarta 19.164 por filtro (985 bloques). Todos los nombres del cuerpo van calificados con `public.`. A escala actual de prod (764 filas) el planner usa cualquier índice con prefijo de cuenta; el compuesto importa cuando la tabla crece.
- **`test_qa_integral_fixes.sql` (2) codificaba la semántica invertida**: su fixture era una venta a las 23:30 ART y exigía el día local convertido de zona. Se reescribió con una fecha de negocio real (medianoche UTC) y exige igualdad exacta; el día anterior delata el `AT TIME ZONE` regresivo.
- **Margen `NULL` es estructuralmente inalcanzable por la cascada canónica**: `products.cost` es `NOT NULL DEFAULT 0`, así que `COALESCE(unit_cost_snapshot, products.cost)` siempre resuelve. El read-model y la UI implementan igual la rama `NULL → "—"` (spec `product-ranking`) por si el catálogo cambia; lo que sí distingue un margen medido de uno aproximado es `cost_coverage_pct` (D11), que es la marca que la UI muestra.
- **`KpiCard` gana `changeLabel`** (default `"vs ayer"`): las tarjetas del módulo comparan contra el período anterior.
- **Categorías**: la columna `category` viaja en el ranking (TEXT espejo de `productos-categorias-sku`, mergeado el mismo día); la vista agrupada por categoría queda para E2 por alcance del coordinador (D14 la ubicaba en E1).

### Notas de implementación de E2 (desvíos declarados, apply 2026-09-04)

- **`p_account_id` como primer parámetro + guard `P0401`** en `rpc_sales_breakdown` y `rpc_sales_top_clients`, igual que en E1 (las consume el backend, que ya resuelve la cuenta). Las dos consumen `reporting_sales_lines_in_window` y `reporting_plan_window`; el gate de introspección lo exige y, más estricto que E1, **el único `AT TIME ZONE` admitido en estas RPCs es sobre `created_at`**.
- **`category` es la 5ª dimensión de `rpc_sales_breakdown`, no una vista del ranking** (la spec `product-ranking` la llamaba "ranking por categoría"): comparte exactamente la forma de salida de las otras cuatro (D1 traza la línea por forma de salida), agrupa por `products.category_id` — la fuente de verdad de `productos-categorias-sku` — y rotula con `product_categories.name` scopeado por cuenta (D15 ya no es dependencia blanda: el catálogo está en prod desde `20261023000001`). Los productos sin categoría van al tramo "Sin categoría"; las **líneas de servicio quedan fuera sólo de esta dimensión** (no son productos) y su importe lo declara la tarjeta con `service_revenue` de la evolución. El ranking de E1 sigue devolviendo `category` por fila, sin cambios.
- **`sort_order` viaja como columna**: por importe descendente en canal / sucursal / categoría — el tramo "Sin …" cae donde su importe lo pone (en prod es el mayor; esconderlo al final sería mentir por acomodo) — e isodow (1..7) / hora (0..23) en las temporales. **Día y hora viajan siempre completos** (7 y 24 filas, en cero las vacías), como los buckets de la evolución.
- **`rpc_sales_top_clients` devuelve dos clases de fila** (`row_kind = client` / `unassigned`, molde de `period` en `rpc_sales_evolution`): la fila `unassigned` viaja aunque no haya ningún cliente identificado, `p_limit` (1..200) acota sólo las filas de cliente y `total_clients` viaja por fila. El service compone `{items, unassigned, total_clients}` y responde **500 si la RPC no devolvió la fila `unassigned`** — nunca un cero silencioso (OQ-2: el importe sin cliente se declara, no se pierde).
- **Tenencia de los rótulos**: cliente, sucursal y categoría se resuelven con `LEFT JOIN` scopeado por `account_id`; una venta de esta cuenta que referencie un id de OTRA cuenta rankea por su importe (la venta es real) con id `NULL` y rótulo "… no disponible" — nunca expone datos ajenos. En prod hay 0 casos: es defensa en profundidad.
- **El filtro de sucursal es el `BranchFilter` compartido (URL `?branch=`, como el Tablero) y viaja a las cuatro consultas del módulo** — los hooks de E1 (`useSalesEvolution`, `useProductRanking`) ganaron `branchId` y sus claves de React Query lo incluyen. Lo aplica el helper canónico en la base, uniforme y fail-closed; la pestaña "Por sucursal" bajo filtro explica que las ventas sin sucursal quedan fuera de todo el módulo mientras el filtro esté activo. Ninguna superficie expone un filtro de canal (`p_canal` existe en la API para el consumidor que lo necesite).
- **Las franjas horarias son presentación (D5)**: cuatro cortes (0–6 / 6–12 / 12–19 / 19–24) en `HOUR_BANDS` de `lib/sales-statistics.ts`; conmutar hora / franja **no re-consulta** (misma clave de React Query, test dedicado que fija que el conjunto de parámetros distintos pedidos al hook no crece). La salvedad "horario de carga de la operación, no es el horario de venta" va **antes** del gráfico (`role=note`), no en letra chica (OQ-1).
- **Tarjeta de categoría sin total de operaciones**: una operación puede abarcar varias categorías, así que la suma de operaciones de los tramos no es el total de operaciones del período; el pie muestra "—" con `title` explicativo. Las unidades sí suman.
- **Hallazgo de la pasada visual real (12.4) — corregido en el mismo PR**: en la orientación vertical de `ReportBarChart` (7 días / 24 horas / 4 franjas en columnas) los rótulos del eje X se **solapaban a 375 px**. Fix: `breakdownChartLabel` (día abreviado por isodow `Lun…Dom`, franja sin rango — `HourBand.shortLabel`, prefijo del rótulo completo) para el eje, `tooltipName` para que el tooltip conserve el rótulo completo, e `interval="preserveStartEnd"` para que Recharts omita los ticks que se solaparían (24 h → 6 ticks a 375 px, 24 a 1280 px). **La tabla que acompaña a cada gráfico conserva siempre el rótulo completo.** Medido en el navegador: 0 rótulos solapados en los 6 gráficos en las 4 combinaciones.
- **Gotcha de datos sintéticos** (no de la RPC): canal, sucursal, cliente e instante de carga son **atributos de cabecera** — iguales en todas las filas de una operación (RN-97 header plano). Un seed que los reparte por fila hace que `COUNT(DISTINCT operation_key)` cuente la misma operación en varios tramos y la suma de operaciones de los tramos supere el KPI (49 y 54 contra 38 reales, atrapado en la pasada visual). Con el seed keyed por `operation_id` la identidad se cumple exacta (38 = 38 en canal, sucursal y hora).
- **Gotcha del stack local**: el GoTrue local firma **ES256** (JWKS en `/auth/v1/.well-known/jwks.json`); el backend cae a HS256 sólo si `SUPABASE_URL` está vacía → todo `GET /reports/statistics/*` responde 401. Para la verificación local hay que fijar `SUPABASE_URL=http://127.0.0.1:54321` además de `DATABASE_URL` y las dos palancas de tenancy en `true` (sin `TENANCY_TX_SCOPE_ENABLED` el guard `P0401` de las RPCs rechaza, porque `auth.uid()` no resuelve).

### Notas de implementación de E3 (desvíos declarados, apply 2026-09-04)

- **`rpc_product_sales_evolution(p_account_id, p_product_id, p_start, p_end, p_bucket, p_branch_id, p_canal)`** (migración `20261026000001`) toma `p_account_id` con guard `P0401` como E1/E2, y suma `p_branch_id`/`p_canal` (D1 sólo listaba `p_product_id, p_start, p_end, p_bucket`) para que el detalle respete el mismo filtro que llevó a él. Devuelve **tres clases de fila** (`row_kind = total / bucket / member`, molde de `period` en la evolución): la cabecera del producto (nombre, SKU, categoría, padre, `is_group`, `variant_count`) y la ventana aplicada viajan en todas las filas para que ningún consumidor cruce filas.
- **Regla de grupo idéntica a la del ranking agrupado**: el grupo es el producto pedido + los productos cuyo `parent_id` es él. Las ventas **directas del padre** son un miembro propio ("producto base, vendido directo"); `variant_count` cuenta sólo las variantes con ventas, nunca al padre. Una variante pedida directamente muestra sólo lo suyo (no tiene hijos) con `parent_id`/`parent_name` de contexto. El gate exige la **identidad con la fila del ranking** (agrupada para el padre, sin agrupar para la variante): dos read-models sobre la misma población no pueden disentir.
- **Tenencia por `P0404`, no por cero silencioso**: producto de otra cuenta e inexistente reciben el mismo código y mensaje (no se revela si el id existe); el backend lo traduce a **404 RFC 7807**. `deleted_at` **no filtra**: un producto dado de baja que vendió en el período rankea (E1 tampoco lo filtra) y su detalle tiene que abrir. Producto sin ventas en el período → fila total en cero con cabecera, buckets en cero, sin miembros, margen `NULL` (nunca 0).
- **El gate de introspección de E3 prohíbe CUALQUIER `AT TIME ZONE`** en el cuerpo (más estricto que E2, que admitía el de `created_at`): el detalle no deriva ninguna hora, así que no tiene excusa para convertir de zona.
- **Export (grupo 8) — una sola fuente de tipos**: la unión `ExportType` y el array `validTypes` que `generate-export/index.ts` duplicaba (task 8.3) se reemplazan por `EXPORT_TYPES` en `_shared/export-ranking.ts`, de la que deriva el tipo; `lib/types.ts` conserva la unión TypeScript del cliente como espejo (6 literales). Las filas del CSV salen de `rpc_product_ranking` **paginada de a 500** (tope de la RPC) hasta 10.000 filas (mismo tope que los otros exports), con los **mismos parámetros que la pantalla** (`start`, `end`, `order_by`, `group_variants`, `branch_id` — `triggerExport` gana un tercer argumento `params`; los tipos legacy siguen mandando `{ export_type }` solo). Un tipo desconocido y unos parámetros fuera de dominio se rechazan con 400 **antes** de leer cuota o plan. La cuenta se resuelve con el mismo criterio determinístico que `get_account_id` (membresía más antigua, por id); la RPC vuelve a verificar la membresía. `rowsToCsv` se movió al módulo compartido sin cambios de comportamiento (ahora testeada). El clamp de historial lo aplica la RPC, no la Edge Function. Desde `/exportaciones` el ranking se exporta con los defaults de la pantalla (últimos 30 días, unidades, agrupado) y el texto lo dice; para otro período/orden se exporta desde `/estadisticas`.
- **La lista de tipos de exportación tenía una TERCERA copia en la base**: `export_logs_type_values` (CHECK de `20260610000000`) enumeraba los 5 tipos legacy. Sin ampliarlo, el archivo se genera y la cuota se cobra, pero el `INSERT` en `export_logs` falla "non-fatal" en la Edge Function y `/exportaciones` nunca lista el ranking. Lo atrapó el **run real** del export contra el stack local (los tests unitarios del módulo no podían verlo); `20261026000001` lo amplía con `DROP IF EXISTS` + `ADD` y el gate de E3 lo fija.
- **"Hoy" en las Edge Functions es el día argentino** (`argentinaToday` de `_shared/argentina-time.ts`), no el día UTC del runtime: `_shared/statistics-params.ts` centraliza el parseo de fechas de negocio (`YYYY-MM-DD` reales, rango no invertido) y de uuids opcionales para el export y para `ai-estadisticas`.
- **`ai-estadisticas` (grupo 10) — núcleo puro inyectable**: la orquestación (cuota → contexto → modelo → persistir → cobrar) vive en `_shared/ai-estadisticas-core.ts` (`runEstadisticasAnalysis(deps)`) y el handler `Deno.serve` sólo cablea Supabase y OpenAI — a diferencia de las hermanas (`ai-precio.test.ts` re-declara la lógica pura en el test porque el handler no es importable), acá los seis escenarios de la spec se prueban contra el módulo REAL. El contexto son las filas de `rpc_sales_evolution` (`current`/`previous`; los buckets se descartan y jamás se suman), `rpc_product_ranking` (top 5 por unidades y por importe), `rpc_sales_breakdown` (`canal`, `weekday`) y `rpc_sales_top_clients` (5 + la fila `unassigned`), leídas con el JWT del usuario. **El contador se incrementa sólo si el insight se generó Y se persistió**: timeout, contenido vacío, error del proveedor o fallo del `INSERT` → sin incremento (la hermana `ai-rentabilidad` incrementa aunque el insight venga vacío; acá no). Un margen `NULL` en el prompt se dice "margen s/d", nunca "0 %". Tipo de insight `estadisticas` (tabla `insights`, columnas vivas `user_id, account_id, type, priority, message` — sin CHECK sobre `type`), con `account_id` poblado (ai-rentabilidad no lo puebla); paridad `ESTADISTICAS_INSIGHT_TYPE === STATISTICS_INSIGHT_TYPE` fijada por test. Registrada en `supabase/config.toml` con la forma de `ai-insights`/`ai-resumen` (las hermanas `ai-rentabilidad`/`ai-precio`/`ai-comparativo` no tienen entrada; el deploy sube todas igual).
- **Frontend**: `hooks/data/use-statistics-ai.ts` separa la llamada (`analyzeStatistics`, testeable sin React) del hook de mutación, que invalida el último insight y `aiUsage` **sólo** en `status = "ok"`. `StatisticsAiPanel` deshabilita el botón con cuota 0 y dice por qué. `KpiCard` gana `caption` (la marca "% con costo" del margen en el detalle); `ProductCatalog` gana `initialSearch` y `/productos?q=<sku|nombre>` precarga el buscador — ese es el "enlace al producto en el catálogo" de D12 (no existía deep-link). `breadcrumb-nav` gana un mapa por prefijo para las rutas dinámicas (`/estadisticas/productos/<uuid>` → "Detalle de producto", no el uuid). `RankingExportBody` es `type` y no `interface` porque una interface no es asignable al `Record<string, …>` de `ExportParams` (tsc lo rechazaba).

### Hallazgo del PO: separador de CSV incompatible con Excel es-AR (2026-09-04, hotfix post-merge)

**Síntoma**: humo real del PO en prod el mismo día del merge — exportó `product_ranking_csv` desde `/estadisticas` y "se ve mal el excel cuando lo abrí" (todas las columnas apiladas en A).

**Causa raíz**: `rowsToCsv` en `_shared/export-ranking.ts` serializaba con **coma** (RFC 4180 "de libro"), pero Excel con configuración regional en español (Argentina) usa **punto y coma** como separador de listas — la coma queda reservada para el decimal. El export local `frontend/lib/excel.ts` (`exportToCSV`) ya usaba `;` desde antes (su propio docstring lo dice: *"compatible with Excel (auto-detects the separator when BOM present)"*); la Edge Function divergió de esa convención cuando E3 escribió el sexto tipo de exportación. El BOM UTF-8 (`generate-export/index.ts` ~L304) estaba bien — los acentos no eran el problema.

**Decisión — separador vs. decimales, alcance distinto**:
- El separador `;` se corrige para **los seis tipos** (comparten `rowsToCsv`): ventas, compras, gastos, inventario, XLSX (no aplica, usa SheetJS) y ranking. Es un cambio seguro — no hay dato que reinterpretar, sólo el carácter que separa columnas — y los cinco CSV comparten la misma función.
- La conversión de decimales de punto a coma se aplica **sólo al ranking** (`unidades`, `importe`, `costo`, `margen`, `margen_pct`, `cobertura_costo_pct` — enteros como `puesto`/`variantes`/`operaciones` y la fecha `ultima_venta` quedan igual). El ranking es un reporte de análisis que nadie re-importa. Los otros cuatro CSV (sobre todo `stock_csv`) alimentan el ciclo exportar→editar→importar; convertir sus decimales ahí arriesgaba que un importador que usa `parseFloat` (en vez del `parseAmount` de `lib/excel.ts`, que sí entiende coma decimal) truncara el valor en silencio al reimportar.
- Se mantiene la coma en la lista de caracteres que fuerzan comillas (junto a `;`, `"` y `\n`) aunque ya no sea el separador: un valor con coma queda entrecomillado por seguridad. Efecto colateral verificado: los campos numéricos del ranking con coma decimal (p. ej. `"42,5"`) salen entrecomillados. **No es un problema** — Excel evalúa el tipo del contenido de una celda CSV (texto vs. número) de la misma forma esté o no entre comillas; las comillas son sólo sintaxis de escape, no fuerzan formato "Texto". Verificado con una muestra real abierta en Excel es-AR antes de mergear (ver PR).

**Auditoría de `frontend/lib/import/*` (pedido explícito, no arreglado en este hotfix)**: el importador de productos (`lib/import/validator.ts` L133/146) usa `parseAmount` de `lib/excel.ts` para `precio`/`costo`, que sí interpreta correctamente `"1234,56"` como decimal-coma. **Hallazgo lateral confirmado, fuera de este alcance**: `frontend/components/stock/stock-import-adjustment-dialog.tsx` L270 usa `parseFloat(rawQuantity)` crudo — un usuario que edita el CSV de stock exportado en Excel y escribe una cantidad con coma decimal ("12,5") la ve truncada a 12 en silencio al reimportar. No es un problema introducido por este hotfix (el CSV de stock no lleva decimal-coma, sólo cambió su separador), pero es el mismo patrón de bug que este hallazgo motivó a buscar. Candidato con chip (`task_e8cc177a`).
