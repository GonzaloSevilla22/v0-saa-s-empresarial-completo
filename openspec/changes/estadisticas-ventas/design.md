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
