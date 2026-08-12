## Context

**El canon existe y está bien.** `rpc_dashboard_kpi_summary` (vigente en `supabase/migrations/20260814000001_v3_reporting_invariants.sql:440-630`) devuelve, en una sola llamada y para dos ventanas (actual y previa):

| Columna | Fórmula canónica |
|---|---|
| `invoiced_revenue` | `Σ COALESCE(s.total, s.amount) − Σ ABS(nc.amount)` |
| `net_profit` | `(revenue − NC) − (gastos + compras)` |
| `collected_revenue` | devengado − cargos cta cte + cobros (RN-D3) |
| `avg_ticket`, `cost_per_sale` | sobre `COUNT(DISTINCT COALESCE(operation_id, id))` |
| `sales_count` | conteo de operaciones unificado |

Es `SECURITY DEFINER`, resuelve la cuenta con `current_account_ids()` a partir de `auth.uid()`, acepta `p_branch_id` opcional y tiene `GRANT EXECUTE TO authenticated`. Está en producción desde 2026-07-07 y ya lo consume el Bloque Resumen del Tablero vía `hooks/data/use-dashboard-kpi-summary.ts`.

**El problema no es el canon, es el consumo.** Los 5 consumidores de IA lo ignoran y recalculan (evidencia por archivo y línea en `proposal.md`). Todos ellos ya tienen en mano un cliente Supabase con el JWT del usuario:

| Consumidor | Runtime | Cliente | Ventana actual |
|---|---|---|---|
| `frontend/lib/ai/buildBusinessSnapshot.ts` (Copiloto) | Next.js server route | `@/lib/supabase/server` + `getUser()` verificado | últimos 30 d vs 30 d previos |
| `supabase/functions/ai-insights` | Deno | anon key + header `Authorization` del caller | últimos 30 d vs 30 d previos |
| `supabase/functions/ai-simulador` | Deno | ídem | mes en curso (desde el día 1) |
| `supabase/functions/ai-prediccion` | Deno | ídem | últimos 30 d |
| `supabase/functions/ai-resumen` | Deno | ídem | daily/weekly/monthly **o** rango explícito `dateFrom`/`dateTo` |

O sea: **la llamada al canon está a una línea de distancia en los cinco**. No hace falta migración, ni una RPC nueva, ni cambiar permisos.

**Restricciones que condicionan el diseño:**

1. **Deno y Next no comparten bundle.** `supabase/functions/_shared/` es el único mecanismo de reuso entre Edge Functions; `frontend/lib/` es el único del frontend. No hay paquete compartido en el monorepo (el `package.json` raíz solo pinea `next` para Vercel).
2. **Las Edge Functions no tienen runner en CI.** El único gate automático que las alcanza es vitest importando módulos de `_shared/` **por ruta relativa** — patrón ya establecido y probado en 4 archivos: `__tests__/ai-quota.test.ts`, `edge-effective-plan.test.ts`, `send-email-fanout-policy.test.ts`, `send-email-webhook-auth.test.ts`. Funciona porque esos módulos no referencian `Deno.*` a nivel de módulo y reciben el cliente por inyección.
3. **`buildBusinessSnapshot` no tiene ni un test hoy.** Es el archivo con el bug más caro (alimenta el Copiloto entero) y la suite de vitest —751 tests— no lo toca.
4. **El mapeo canónico de la fila del RPC ya está escrito, pero encerrado en un hook de cliente** (`use-dashboard-kpi-summary.ts:33-105`: `"use client"`, `useAuth`, `useQuery`). Una ruta de servidor no puede llamarlo.

## Goals / Non-Goals

**Goals:**

- Que los ingresos que la IA reporta sean exactamente los que reporta el Tablero, para la misma cuenta y la misma ventana. No "parecidos": **la misma fila del mismo read-model**.
- Que la ganancia/margen/balance que la IA cita incluya compras y notas de crédito, según `net_profit` canónico.
- Que la regresión no pueda repetirse en silencio: la fórmula de revenue de línea existe **una sola vez por runtime**, con test de paridad entre runtimes, y el requirement de consumo queda escrito en la spec.
- Que cuando el canon no responda, la IA **calle** la cifra en vez de inventarla.
- Cobertura de test real sobre `buildBusinessSnapshot`, que hoy tiene cero.

**Non-Goals:**

- No se toca ninguna RPC, vista, tabla ni permiso. Cero migraciones.
- No se corrige el filtro por sucursal de `nc_agg`/`charges_agg`/`payments_agg` (hallazgo F3a → C-KPI-3): todos los consumidores de IA llaman con `p_branch_id = NULL`, así que ese defecto no los alcanza.
- No se toca la tarjeta ni el predicado de stock crítico (F4 → C-KPI-2), aunque `buildBusinessSnapshot` y `ai-insights` lo tengan duplicado inline: sacarlo acá mezclaría dos changes y dejaría a C-KPI-2 sin su caso testigo.
- No se corrige el margen por producto calculado con costo de catálogo (`(price − cost)/price`): es la excepción deliberada "catálogo vs rentabilidad histórica" ya documentada. Tampoco el margen por canal sin NC (D6 de `reporting-invariants`).
- No se agregan pantallas, rutas ni entradas de menú. **Sin superficie frontend nueva.**
- No se cambia el prompt más allá de la línea de ganancia neta ni el modelo de IA.

## Decisions

### D1 — Consumir `rpc_dashboard_kpi_summary`, no replicar su fórmula

Los 5 consumidores obtienen ingresos, ganancia neta y comparativa contra el período previo **de una sola llamada al RPC**, no de agregar filas en TypeScript.

*Por qué:* es la regla PO "reutilización antes que repetición" aplicada al caso que la originó. Replicar la fórmula en un helper compartido de TS habría requerido, además, traer notas de crédito (`customer_account_movements` con `movement_type='credit_note'`, `amount` **negativo**, se usa `ABS()`) y compras a cada consumidor: **3 queries extra por consumidor, ×5, para reconstruir a mano algo que la DB ya devuelve resuelto y agregado**. Y habría creado una segunda definición de "ganancia neta" destinada a divergir en la próxima iteración — exactamente el patrón que este change viene a matar.

*Efecto colateral buscado:* si mañana cambia la definición canónica de ganancia, cambia en un solo lugar (la migración) y los 5 consumidores la heredan sin tocarlos.

*Alternativas descartadas:*
- **Helper TS que replica la fórmula.** Descartada por lo anterior (3 queries extra ×5 + segunda fuente de verdad).
- **RPC nueva y más liviana para IA** (sin las CTEs `stagnant_*`). Descartada: es una tercera definición de las mismas métricas y una migración, para ahorrar un escaneo de `v_products_with_stock` en un camino que ya gasta 6-15 s en OpenAI. Si el costo llegara a medirse como problema, se optimiza el RPC existente para todos sus consumidores, no se bifurca.
- **Vista materializada.** Descartada: staleness inaceptable para un asistente que responde "¿cómo vengo este mes?".

*Contrapartida asumida:* +1 round trip por consumidor. En `buildBusinessSnapshot` y `ai-insights` queda **neutro**, porque el fetch de "ventas del período anterior" (que existía solo para la comparativa) desaparece.

### D2 — Ventana previa sintética para los consumidores de ventana libre

El RPC exige las cuatro fechas (`p_from`, `p_to`, `p_prev_from`, `p_prev_to`). `ai-simulador` (mes en curso), `ai-prediccion` (30 d) y `ai-resumen` (rango arbitrario) no tienen noción de "período anterior". Se sintetiza la **ventana inmediatamente anterior de igual duración** con un helper único, `previousWindow(from, to)`, en el módulo compartido.

*Por qué:* es la definición que ya usa el Tablero (mes anterior contra mes en curso) y la que hace que la comparativa, si algún día se muestra, signifique lo que el usuario espera. Los consumidores que no la usan simplemente descartan las columnas `prev_*`.

*Riesgo controlado:* el RPC lanza `P400` si `p_from > p_to`. `previousWindow` deriva de un rango ya validado y nunca invierte los bordes; se cubre con test.

### D3 — Un módulo canónico por runtime, atados por un test de paridad

- `frontend/lib/reporting/revenue-canon.ts` — funciones puras: `lineRevenue(row)`, `sumLineRevenue(rows)`, `netMarginPct(netProfit, revenue)`, `previousWindow(from, to)`.
- `supabase/functions/_shared/reporting-canon.ts` — **las mismas funciones puras** + `fetchKpiSummary(client, window)` (acceso al RPC con el cliente **inyectado**, para que sea testeable desde vitest).
- `frontend/__tests__/reporting-canon-parity.test.ts` — importa **ambos** módulos, corre una tabla de casos compartida por los dos y falla si un solo resultado difiere.

*Por qué no un solo archivo:* se evaluaron las tres formas de tenerlo:
1. **El frontend importa `../../supabase/functions/_shared/…` en código de producción.** Técnicamente resolvería (los tests ya lo hacen), pero mete un archivo de `supabase/functions/` dentro del bundle de Next: queda fuera del `include` del `tsconfig.json` del frontend (que además excluye `supabase/functions`), depende de la inferencia de workspace root de Turbopack y del `outputFileTracing` de Vercel, y contradice la regla del proyecto de que el canon del frontend vive en `lib/`. Riesgo de build por 15 líneas de aritmética: no.
2. **Las Edge Functions importan `../../../frontend/lib/…`.** El bundler del Supabase CLI empaqueta desde el directorio de la función; importar fuera de `supabase/functions/` es frágil entre versiones del CLI — y este proyecto ya se comió una diferencia de comportamiento entre CLI 2.105 y 2.111. `_shared/` existe precisamente para esto.
3. **Paquete compartido en el monorepo.** Correcto en abstracto, desproporcionado acá: el repo no tiene workspaces de pnpm configurados; montarlos para 4 funciones puras es un change de infraestructura, no una corrección de KPIs.

*Cómo se honra la regla "no repetir" pese a la duplicación:* el riesgo real que la regla combate no es tipear dos veces, es **divergir en silencio**. El test de paridad convierte la divergencia en CI rojo, y cada archivo lleva en su cabecera el puntero al gemelo y al test. La superficie duplicada queda deliberadamente mínima: aritmética pura, sin I/O, sin tipos de dominio.

### D4 — Sin canon disponible, se omite la cifra; nunca se inventa

Si `fetchKpiSummary` falla (error del RPC, timeout, cuenta sin resolver), el consumidor:

1. registra el fallo por consola con su prefijo habitual,
2. calcula los **ingresos** con `sumLineRevenue` sobre las filas que ya tenía en memoria (queda gross de NC, pero **ya es correcto respecto de la cantidad**, que es el 100% del hallazgo F1),
3. **omite del prompt la ganancia neta, el margen y la comparativa** en vez de emitir un número mal calculado.

Para eso, `BusinessSnapshot.gastos.margen_neto_pct` pasa de `number` a `number | null`, se agrega `ganancia_neta: number | null`, y `snapshotToText`/`buildAdaptiveContext` dejan de emitir esos fragmentos cuando son `null`. En las Edge Functions, la línea correspondiente del `contextBlock` se filtra igual que ya se filtran las secciones vacías.

*Por qué no fallar la request:* el proyecto usa *degrade-don't-fail* en los caminos no críticos (seed de provisioning, outbox). Un Copiloto que responde 500 porque un KPI no se pudo agregar es peor producto que uno que responde sin citar el margen.

*Por qué no dejar la fórmula vieja como fallback:* sería mantener viva, y ejecutándose sin aviso, exactamente la fórmula que este change borra. El system prompt obliga a la IA a citar números; darle uno falso en el camino degradado es el bug, no la mitigación.

### D5 — La ganancia neta en pesos entra al contexto de la IA

Además de `margen_neto_pct`, el snapshot expone `ganancia_neta` (= `net_profit` del RPC) y el prompt la incluye.

*Por qué:* es gratis (viene en la misma fila) y es la cifra que el system prompt exige citar. Hoy la IA solo tiene un porcentaje, y encima mal calculado; con la ganancia en pesos, el consejo se vuelve verificable contra el Tablero por el propio usuario.

### D6 — Las NC no se atribuyen por producto ni por cliente (aproximación explícita)

`invoiced_revenue` (total) resta NC. Los desgloses `top_rentables[].revenue` y `top_cliente_revenue` se agregan localmente con `sumLineRevenue` y **no** restan NC.

*Por qué:* atribuir una nota de crédito a la línea de producto original exige recorrer el documento origen — trabajo de otro change y sin valor incremental para un ranking (el orden relativo de productos casi nunca cambia por una NC). Es la misma clase de excepción ya documentada para el margen por canal (D6 de `reporting-invariants`).

*Consecuencia a controlar:* `top_cliente_revenue` se expresa como porcentaje del total; con el total neto de NC y el numerador gross, el porcentaje podría pasar de 100 en un caso patológico (NC grande, un solo cliente). Se **clampea a 100** y el caso se cubre con test, para que la IA nunca lea "el 118% del total".

### D7 — El mapeo de la fila del RPC se extrae del hook a la capa canónica

Nace `frontend/lib/reporting/kpi-summary.ts` con el tipo de fila, el mapeo snake_case→camelCase y `fetchKpiSummary(supabase, window)`. `hooks/data/use-dashboard-kpi-summary.ts` se reduce a envolverlo en `useQuery`, y `buildBusinessSnapshot` lo llama directo.

*Por qué:* sin esto, el Copiloto tendría que re-escribir el mismo mapeo `num()` de 16 columnas que el hook ya tiene — creando la duplicación que este change combate, en el mismo commit. Es un refactor sin cambio de comportamiento y lo protege el test existente `__tests__/hooks/use-dashboard-kpi-summary.test.ts` (que además verifica los parámetros exactos del `rpc()`).

*Precaución:* el mapeo debe seguir siendo tolerante a columnas ausentes (`invoiced_revenue?`), como hoy — protege la ventana entre deploy de DB y de frontend.

### D8 — Tipos explícitos donde se toca; el resto del `any` no se persigue

Las Edge Functions tocadas hoy usan `(s: any)` en los `reduce`. **Las expresiones que este change reescribe** se tipan con interfaces locales explícitas (`SaleRevenueRow { amount: number | string | null; total: number | string | null }`), acorde a la regla dura del proyecto. Los `any` restantes de esos archivos (parsing de respuestas de OpenAI, filtros de productos) **no** se tocan: ampliar el diff a un archivo entero por prolijidad diluye el review de un change de corrección de números.

### D9 — Sin migraciones, sin redeploy de DB

`v_sales_flat` ya expone `total` (`20260616000004_v20_compat_views.sql`) y el RPC ya está desplegado con los permisos correctos. El deploy es: Vercel (frontend) + `supabase functions deploy` de las 4 funciones.

## Risks / Trade-offs

- **Los números que ve el usuario cambian de golpe al mergear** (ingresos ↑, margen ↓) → No es regresión: es converger con el Tablero, que ya venía bien. Mitigación: las tasks incluyen medir el delta en una cuenta real **antes** del merge y dejarlo escrito en el PR, igual que se hizo con el +17,53% de `v3-reporting-invariants`. Si el delta fuera desproporcionado, es señal de otro defecto y se levanta antes de mergear, no después.
- **+1 llamada RPC en 5 caminos, con las CTEs `stagnant_*` escaneando `v_products_with_stock`** → Se compensa con el fetch de "período anterior" eliminado en 2 de los 5. Los 5 caminos gastan después 6-25 s en OpenAI; el agregado es ruido frente a eso. Si midiera mal, se optimiza el RPC para todos sus consumidores (D1).
- **Las Edge Functions siguen sin gate automático en CI** → Mitigación estructural: toda la aritmética vive en `_shared/reporting-canon.ts`, que **sí** tiene gate vía vitest; en los `index.ts` queda solo cableado. Un bug de fórmula pasa a ser imposible de introducir sin romper un test; un bug de cableado (pasar la ventana equivocada) sigue requiriendo verificación manual, y por eso las tasks la incluyen explícitamente.
- **Los dos módulos gemelos divergen** → El test de paridad los corre sobre la misma tabla de casos y falla ante la primera diferencia. Es la mitigación completa del riesgo, no un paliativo: no existe divergencia posible que pase verde.
- **El camino degradado se vuelve el camino normal sin que nadie lo note** (si el RPC empezara a fallar sistemáticamente, la IA dejaría de hablar de margen y nadie se enteraría) → Cada consumidor loguea el fallo con su prefijo (`[ai-insights]`, `[Copilot]`, …), observable en los logs de Supabase y Vercel. Alertar sobre eso es infraestructura de observabilidad, fuera del alcance de este change.
- **`buildBusinessSnapshot` es un archivo de 415 líneas sin tests que se toca en 6 puntos** → Se escribe primero la suite (TDD estricto, RED antes que GREEN) y se toma línea base de vitest antes de tocar nada. Las partes no relacionadas (stock crítico, sin rotación, margen bajo) quedan cubiertas por tests de regresión aunque no se modifiquen, para que el refactor no las mueva de contrabando.
- **`ai-resumen` acepta un rango arbitrario del caller** (`dateFrom`/`dateTo`) que ahora viaja al RPC → El RPC valida y lanza `P400` ante un rango inválido, y es `SECURITY DEFINER` con la cuenta resuelta por `auth.uid()`: un rango manipulado no puede leer datos de otra cuenta. El `P400` cae en el camino degradado de D4.

## Migration Plan

Sin migración de datos ni de esquema. Orden de deploy y rollback:

1. **Merge a main** → GitHub Actions despliega Vercel (frontend: Copiloto) y aplica migraciones (ninguna en este change).
2. **`supabase functions deploy`** de `ai-insights`, `ai-simulador`, `ai-prediccion`, `ai-resumen`. Entre el paso 1 y el 2 conviven consumidores viejos y nuevos: **no rompe nada** — el RPC está desplegado desde julio y las funciones viejas siguen leyendo las mismas tablas que antes. La única consecuencia de la ventana es que el Copiloto reporta bien antes que el resumen.
3. **Verificación post-deploy** contra una cuenta real con ventas multi-unidad: los ingresos que cita el Copiloto igualan `invoiced_revenue` del Bloque Resumen para la misma ventana.

**Rollback:** revertir el PR y redeployar las 4 funciones desde el commit anterior. No hay estado persistido que revertir — este change no escribe nada (los insights generados en el interín quedan guardados con el texto que se generó, como cualquier insight histórico).

## Open Questions

- **OQ-1 — Ventanas relativas ancladas a UTC, no a la fecha local del tenant.** RN-D5 exige que "últimos N días" se ancle a la fecha local del tenant (`America/Argentina/Mendoza`, helper `reporting_local_today()`), pero los 5 consumidores derivan su ventana de `new Date()` en el servidor (UTC). Entre las 21:00 y las 24:00 de Argentina, la ventana se corre un día. **No se corrige acá**: no es parte de F1/F2, afecta a más consumidores que los de IA y merece su propio change con un helper de ventana compartido. Queda anotado para el orquestador; si el PO lo quiere adentro, es un incremento acotado sobre `previousWindow`.
- **OQ-2 — ¿`ai-prediccion` debe predecir sobre ingresos netos de NC?** Este change usa `invoiced_revenue` (neto), coherente con el canon. Se puede argumentar que una predicción de ventas debería proyectar el bruto y tratar las devoluciones aparte. Se implementa con el canon (consistencia por defecto) y se deja la pregunta abierta al PO; cambiarlo después es una línea.
- **OQ-3 — ¿Conviene exponer también `collected_revenue` (percibido) a la IA?** El RPC ya lo devuelve gratis y es la cifra que más le importa a un microemprendedor ("¿cuánto cobré?"). **Fuera de alcance** de este change para no mezclar corrección con producto, pero es la extensión natural y de costo casi nulo una vez que los 5 consumidores leen la fila canónica.
