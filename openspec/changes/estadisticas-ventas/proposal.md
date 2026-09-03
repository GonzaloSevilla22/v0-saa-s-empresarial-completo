## Why

El sistema registra 764 ventas y no tiene **una sola pantalla que responda "qué se vende y cuándo"**. La búsqueda por `más vendido` / `top productos` / `ranking` da negativo completo: no existe pantalla, RPC, endpoint ni export. Lo más cercano es `/rentabilidad`, que ordena por `gross_margin_pct` — responde "qué me deja más margen", que es una pregunta distinta y, para un emprendedor que decide qué reponer, la equivocada: el producto más rentable puede venderse tres veces por mes.

Las dos únicas piezas que hoy calculan "top productos" viven duplicadas en JavaScript y sólo para alimentar prompts de IA (`supabase/functions/ai-insights/index.ts` L118-219 y `frontend/lib/ai/buildBusinessSnapshot.ts` L189-224). Ningún humano las ve. Este change expone el agregado como read-model canónico y de paso deja de justificar una tercera copia.

Pedido textual del PO (2026-09-03): *"módulo de estadísticas de ventas y ranking de productos más vendidos"*, con alcance completo firmado el mismo día.

## What Changes

### Estadísticas de ventas (`/estadisticas`)

- **Evolución de ventas en el tiempo** por día / semana / mes, con rango elegible y **comparación contra el período anterior** de igual longitud.
- **Desglose por canal y por sucursal**, con tramo explícito "Sin canal" / "Sin sucursal" — no es un caso marginal: 341 de 636 líneas de los últimos 90 días no tienen canal (54%) y 412 no tienen sucursal (65%). Esconderlas dejaría afuera la mayoría del dinero.
- **Mejores días de la semana** (lunes a domingo, sobre la fecha de negocio declarada).
- **Franjas horarias** — con una corrección de alcance obligada por los datos, ver "Impact → Hallazgos".
- **Top clientes del período** (importe + cantidad de compras).

### Ranking de productos

- Ranking **por unidades** y **por importe**, como dos vistas separadas: en producción difieren desde el 3º puesto, así que colapsarlas en una sola perdería información real.
- **Variantes agrupadas bajo el producto padre** (`products.parent_id`), con detalle por variante. 2.127 de 5.084 productos son variantes (42%): sin agrupar, el ranking se atomiza y ningún producto real aparece arriba.
- **Por margen** donde haya costo — las líneas sin `unit_cost_snapshot` muestran "—", nunca un cero ni un margen inventado (cobertura medida: 508/636 líneas, 79,9%).
- **Por categoría** (sobre `products.category` TEXT tal como está hoy).

### Extras

- **Exportar el ranking a CSV** — 6º `ExportType` (`product_ranking_csv`).
- **Detalle por producto**: click en una fila del ranking abre la evolución de ventas de ese producto y sus variantes.
- **Botón "Analizar con IA"**: Edge Function nueva `ai-estadisticas`, molde de `ai-rentabilidad` (DEC-15: la IA vive en Edge Functions, no en Python).

### Disponibilidad

- Disponible en **todos los planes**, sin candado de entrada. El **rango consultable** se limita por el historial del plan (`plan_limits.history_days`), y ese límite se aplica **en el servidor** — hoy la única barrera equivalente (`/rentabilidad`) es cooperación del cliente.

## Capabilities

### New Capabilities

- `sales-statistics`: read-models y superficie de estadísticas de ventas — evolución temporal con comparación de período, desglose por canal/sucursal/día de semana/horario, top clientes, límite de historial por plan aplicado en servidor, y la Edge Function de análisis IA del módulo.
- `product-ranking`: ranking de productos más vendidos por unidades, importe, margen y categoría; agrupación de variantes bajo el producto padre; detalle de evolución por producto; exportación del ranking.

### Modified Capabilities

- `reporting-invariants`: invariante nuevo que distingue **fecha de negocio declarada** (`sales.date`) de **instante real** (`created_at`), y prohíbe convertir de zona horaria la primera. Además la enumeración de read-models canónicos del requirement "Enforcement de consumo" incorpora los agregados nuevos.
- `product-profitability`: `last_sale_date` deja de informar el día anterior al real (defecto vivo en producción, ver Hallazgos), y el RPC pasa a derivar su agregación del helper canónico compartido en vez de tener la suya propia.
- `data-export`: la exportación por entidad admite el ranking de productos como sexto tipo.
- `plan-gating`: el límite de historial (`history_days`) se declara enforceable en el servidor, no sólo en la UI.

## Impact

### Hallazgos de la exploración que cambian el alcance firmado

Dos mediciones contra producción contradicen premisas con las que se firmó el alcance. Ambas están verificadas, no inferidas.

1. **`sales.date` no tiene hora, y convertirla de zona la corrompe.** La columna es `timestamptz` pero guarda la **fecha de negocio declarada en el formulario**, fijada a `00:00:00+00`. En los últimos 90 días, **0 de 636** líneas tienen hora real (las 636 caen en la misma hora al convertirlas). Y como `00:00 UTC` es `21:00 del día anterior` en Mendoza, aplicarle `AT TIME ZONE 'America/Argentina/Mendoza'` —tal como pedía el encargo— **corre cada venta un día hacia atrás**: el lunes se informa como domingo. La instrucción correcta para esta columna es la contraria: `::date` pelado. El instante real vive en `created_at`, que sí requiere la conversión y sí tiene distribución horaria plausible (pico 11-13 h, cola 19-23 h, 17 horas distintas).

   Consecuencia de alcance: **"franjas horarias de venta" no es entregable tal como se pidió**. Se entrega como horario de **carga** de la operación, rotulado como tal — para las ventas del POS coincide con la venta; para las cargadas después, no (300 de 636 líneas tienen `created_at` a más de 24 h de su `date`). Queda como OQ-1.

2. **`rpc_product_profitability` informa mal la última venta, hoy, en producción.** Su `last_sale_date` hace `(MAX(s.date) AT TIME ZONE 'America/Argentina/Mendoza')::date` sobre esa misma columna: **218 de 218 productos (100%)** muestran en `/rentabilidad` un día anterior al real. Se introdujo en `qa-integral-modulos` (G8) al corregir un `42804`: el arreglo acertó el tipo y erró la semántica. Es el read-model del que este change deriva, así que se corrige acá (OQ-3).

### Código afectado

- **DB** (migración nueva): 1 helper SQL compartido + 5 RPCs `SECURITY DEFINER` nuevas + reescritura del cuerpo de `rpc_product_profitability` (firma intacta) + índice `(account_id, date DESC)` sobre `sales`, que hoy no existe — las 14 índices vivos cubren `user_id`, `client_id`, `canal` y `branch_id`, ninguno el par que consultan todos los agregados nuevos.
- **Backend**: `routers/statistics.py` (`/reports/statistics/*`) + service + repository, en las 3 capas de siempre.
- **Frontend**: `/estadisticas`, `/estadisticas/productos/[id]`, entrada en el grupo "Inteligencia" del sidebar, `lib/sales-statistics.ts`, y componentes de gráfico reutilizables (3 reportes ya repiten el mismo BarChart; este change suma 4 más — la Regla de Tres está cumplida).
- **Edge Functions**: `ai-estadisticas` nueva; `generate-export` suma el tipo del ranking.
- **Docs**: `CHANGES.md` L351 afirma que `rpc_period_comparison` trae "top productos". Es falso — nunca se implementó — y es parte de por qué esta ausencia pasó desapercibida.

### Dependencia blanda

El change hermano `productos-categorias-sku` (en propose paralelo) convierte las 7 categorías fijas en un catálogo por cuenta. **Sólo la vista "por categoría"** depende de él: nace leyendo `products.category` TEXT y adopta el catálogo cuando aterrice. Ninguna otra vista del módulo se bloquea.

### No incluido (declarado)

- Migrar las dos copias JS de "top productos" (`ai-insights`, `buildBusinessSnapshot`) a consumir el agregado canónico — candidato aparte.
- Migrar los 3 reportes existentes a los componentes de gráfico extraídos.
- Materialización o caché de los agregados: 764 ventas y 2 tenants con volumen real no lo justifican.
