## Context

Fuente vinculante: `openspec/explore/2026-11-06-mejora-ia.md` (PR #690, §2, §5, §7.1 y §8 change 1). Este design lo confirma contra el código y contra prod (sólo `SELECT`, 2026-11-06).

**Estado actual, verificado.**

- `POST /api/ai/copilot` (`frontend/app/api/ai/copilot/route.ts`, Route Handler de Next en Vercel): valida 1.000 caracteres, autentica con `supabase.auth.getUser()` del cliente de servidor, arma `buildBusinessSnapshot(supabase, user.id)` (30 días fijos, ~7 consultas), elige bloques con `buildAdaptiveContext` (regex), suma un cálculo de márgenes por regex (`aiCopilotService.analyzePricingInQuestion`), manda los últimos 6 mensajes cortados a 500 caracteres y llama a `gpt-4o-mini` (temp. 0,5, `max_tokens` 600, timeout 12 s, 2 reintentos). **No llama a ninguna cuota.** Guarda en segundo plano con `aiCopilotService.saveConversation` e ignora el error.
- `/copiloto-ia` (`app/(dashboard)/copiloto-ia/page.tsx`): carga **todo** el historial (`select('*')` sin límite, ascendente), llama a la ruta con `fetch`, muestra errores crudos («Error (502): OpenAI error…»), tipa con `any`. Entrada de menú «Copiloto IA» ya existe (`components/app-sidebar.tsx:144`).
- **Guardado roto desde junio (causa probable encontrada en este propose).** `ai_conversations` = `{id, user_id, question, answer, created_at, account_id}`; `account_id` es nullable, **sin default y sin trigger**. Desde `20260606000004_rls_tenant_scoping.sql` la policy `ai_conversations_account_insert` exige `WITH CHECK (account_id IN (SELECT current_account_ids()))`. `saveConversation` inserta `{user_id, question, answer}` → `account_id = NULL` → la RLS rechaza → el `.catch` lo loguea. Prod: 11 filas, la última del **2026-05-11**, 0 con `account_id` nulo (las 11 se backfillearon en C-19). Cuadra con «no hay registros después de mayo». La task 1.1 lo confirma con evidencia antes de arreglarlo (D9).
- **Cuota.** `rpc_reserve_ai_usage(p_counter text)` (`20261090000001`, `SECURITY DEFINER`, `EXECUTE` sólo `authenticated`) sólo acepta `'ocr'` (22023 para cualquier otro); el comentario dice que el parámetro es «el punto de extensión para queries/advice». Las demás Edge Functions de IA usan `checkAiQuota` (fail-open) + `incrementAiUsage` sobre `profiles.ai_queries_used`. Límites de `queries` por plan: gratis 5 · inicial 30 · avanzado 120 · pro 300.
- **RPCs canónicas disponibles** (prod, `SECURITY DEFINER`, `EXECUTE` para `authenticated`, no para `anon`): `rpc_dashboard_kpi_summary(p_from, p_to, p_prev_from, p_prev_to, p_branch_id)`, `get_dashboard_financials(p_date_from, p_date_to, p_branch_id)`, `rpc_sales_evolution(p_account_id, p_start, p_end, p_bucket, p_branch_id, p_canal)`, `rpc_product_ranking(p_account_id, p_start, p_end, p_order_by, p_group_variants, p_branch_id, p_canal, p_limit, p_offset)`, `rpc_sales_breakdown(p_account_id, p_start, p_end, p_dimension, p_branch_id, p_canal)`, `rpc_sales_top_clients(p_account_id, p_start, p_end, p_branch_id, p_limit)`, `get_dashboard_critical_stock_items(p_branch_id, p_limit)`, `rpc_product_sales_evolution(p_account_id, p_product_id, p_start, p_end, p_bucket, p_branch_id, p_canal)`, `rpc_receivables_report(p_account_id)`, `rpc_payables_report(p_account_id)`, `rpc_period_comparison(p_a_start, p_a_end, p_b_start, p_b_end)`, `rpc_product_profitability(p_period_days)`. Las que reciben `p_account_id` verifican la membresía (`P0401`) y aplican el clamp de historial por plan (`reporting_plan_window`). **No hay** lecturas canónicas de caja ni de banco para la IA, ni un listado canónico de productos sin movimiento (sólo `stagnant_stock_count`/`stagnant_stock_value` en el resumen).
- **Molde a copiar**: `ai-estadisticas` (`supabase/functions/ai-estadisticas/index.ts` + `_shared/ai-estadisticas-core.ts` + `_shared/ai-insight-core.ts`): handler fino que cablea dependencias; toda la decisión en un núcleo TS puro sin `Deno.*`, testeado desde vitest (`frontend/__tests__/ai-estadisticas.test.ts`). Cuenta activa con `resolveActiveAccountId` (`_shared/reporting-canon.ts`, que ejecuta `current_account_ids()` con el JWT). Fechas de negocio con `_shared/argentina-time.ts` y `_shared/statistics-params.ts`. Modelo por allow-list: `resolveOcrModel` en `_shared/invoice-ocr-core.ts`.
- `useAiUsage` (`hooks/auth/use-ai-usage.ts`) ya expone `queriesUsed`/`queriesRemaining`/`resetAt`.

**Decisiones del PO (2026-11-06, textuales, no se reabren).** (1) «solo responde» — el Copiloto es de sólo lectura y nunca registra nada. (2) «sí» — se guarda por usuario la valoración «me sirvió / no me sirvió» de cada respuesta, y se reutiliza para los insights en el change 2.

## Goals / Non-Goals

**Goals:**

- Que una pregunta vaga y natural («cuánto vendí hoy», «cómo venimos este mes vs el anterior», «a quién le tengo que cobrar») se conteste con el número correcto, sacado de una RPC canónica, sin que el usuario tenga que saber cómo pedirlo.
- Que el Copiloto pase por la cuota con reserva atómica, tenga ráfaga y techo de costo por pregunta.
- Que cada pregunta quede registrada con lo necesario para medir (modelo, herramientas, latencia, tokens, resultado) y con la valoración del usuario.
- Que el modelo se pueda cambiar por variable sin deploy, y que la elección del modelo por defecto la decidan evals con números verificables.

**Non-Goals:**

- **Escribir datos del negocio** desde el Copiloto (decisión del PO). Ninguna herramienta escribe; las únicas escrituras son el registro de la conversación y la valoración, que no son datos del negocio.
- Los insights del Tablero (`ai-insights`) y el resto de las funciones de IA: change 2 (`ia-insights-tablero`) y change 3 (candidatos). La rama `insight` de `ai_feedback` se habilita en el change 2.
- Migrar las demás Edge Functions de IA de `checkAiQuota`/`incrementAiUsage` a la reserva atómica (candidato del change 3).
- Lecturas de caja, banco o productos sin movimiento: no hay RPC canónica que las exponga, y escribir una agregación nueva para la IA va contra `reporting-invariants`. Se declaran como límite y quedan como candidato (D3).
- Streaming de la respuesta: el bucle de herramientas devuelve la respuesta completa; el indicador de progreso cubre la espera (D11).
- RAG, embeddings, fine-tuning, cambio de proveedor y workers Python (explore §6, DEC-15).

## Decisions

### D1. Edge Function `ai-copilot` con núcleo puro

`supabase/functions/ai-copilot/index.ts` sólo cablea: cliente Supabase con el `Authorization` del request (anon key + JWT del usuario, **nunca** service role), `getUser()`, cuenta activa con `resolveActiveAccountId`, llamada a OpenAI con `fetchWithTimeout`. Toda la decisión vive en tres módulos puros sin `Deno.*` a nivel de módulo, testeables desde vitest por ruta relativa (patrón `ai-estadisticas-core.ts`):

- `_shared/ai-copilot-core.ts`: `runCopilotTurn(deps)` — orden fijo validar → reservar cuota → armar mensajes → bucle de herramientas → respuesta final → registrar; topes; mapeo de errores a respuestas cerradas.
- `_shared/ai-copilot-tools.ts`: catálogo de herramientas (schema JSON estricto para OpenAI), validación de argumentos, traducción a la llamada RPC, recorte de filas y compactación del resultado.
- `_shared/ai-copilot-prompt.ts`: system prompt, ejemplos few-shot, línea de fecha/hora ART, armado de la memoria corta con presupuesto.

*Alternativa descartada*: dejar la ruta de Next y cambiar sólo el contenido — duplica `_shared` en otro runtime y la deja fuera de la cuota (explore §7.1).

### D2. Contrato HTTP

`POST /functions/v1/ai-copilot` con cuerpo:

```json
{ "question": "string (1..1000)",
  "history": [{ "role": "user|assistant", "content": "string (<= 4000)" }],
  "state": { "period": { "start": "YYYY-MM-DD", "end": "YYYY-MM-DD" } | null,
             "product": { "id": "uuid", "name": "string" } | null,
             "client":  { "id": "uuid", "name": "string" } | null } }
```

Respuestas cerradas (el cliente nunca interpreta texto crudo del proveedor):

| HTTP | Cuerpo | Cuándo |
|---|---|---|
| 200 | `{ok:true, kind:"answer"\|"clarification", answer, conversation_id, consulted:[{tool, label}], state}` | respuesta o repregunta |
| 200 | `{ok:true, kind:"fallback", answer, conversation_id\|null}` | timeout total, respuesta vacía, tope de rondas sin respuesta final |
| 400 | `{ok:false, error:"invalid_params", message}` | validación (antes de la cuota) |
| 401 | `{ok:false, error:"unauthorized"}` | sin sesión |
| 403 | `{ok:false, error:"no_active_account"}` | sin cuenta activa |
| 429 | `{ok:false, error:"quota_exceeded", resetAt, used, limit}` o `{ok:false, error:"rate_limited", retryAfterSeconds}` + `Retry-After` | cuota o ráfaga |
| 502 | `{ok:false, error:"ai_unavailable"}` | error del proveedor (el detalle va al log, no al usuario) |
| 503 | `{ok:false, error:"quota_unavailable"}` | la reserva no se pudo resolver (fail-closed) |

`consulted[].label` es texto para la persona, armado por el servidor desde la herramienta y sus argumentos ya validados («ventas del 1 al 6 de noviembre», «stock crítico de todas las sucursales»); nunca lo escribe el modelo.

### D3. Catálogo de herramientas (sólo lectura)

Cada herramienta tiene schema con `additionalProperties:false`, `strict:true` y todos los campos requeridos (los opcionales como `["string","null"]`), y se traduce a **una** RPC canónica. El servidor fija `p_account_id` desde `resolveActiveAccountId` (el modelo **nunca** elige la cuenta) y la RPC vuelve a verificar la membresía.

| Herramienta | Argumentos | RPC | Tope de filas |
|---|---|---|---|
| `resumen_periodo` | `desde`, `hasta`, `sucursal_id\|null` | `rpc_dashboard_kpi_summary` (ventana previa por `previousWindow`) | 1 |
| `evolucion_ventas` | `desde`, `hasta`, `agrupar: day\|week\|month`, `sucursal_id\|null` | `rpc_sales_evolution` | 31 buckets |
| `ranking_productos` | `desde`, `hasta`, `orden: units\|revenue\|margin`, `limite (1..20)`, `sucursal_id\|null` | `rpc_product_ranking` (`p_group_variants=true`) | 20 |
| `desglose_ventas` | `desde`, `hasta`, `dimension: canal\|branch\|weekday\|hour\|category`, `sucursal_id\|null` | `rpc_sales_breakdown` | 24 |
| `mejores_clientes` | `desde`, `hasta`, `limite (1..20)`, `sucursal_id\|null` | `rpc_sales_top_clients` | 20 + fila `unassigned` |
| `stock_critico` | `sucursal_id\|null`, `limite (1..50)` | `get_dashboard_critical_stock_items` | 50 |
| `buscar_producto` | `texto (2..80)` | lectura de `products` con filtro explícito por `account_id`, sin borrados, `ilike` sobre nombre/SKU (RLS como red) | 10 |
| `detalle_producto` | `producto_id`, `desde`, `hasta`, `agrupar` | `rpc_product_sales_evolution` (`P0404` → «no encontré ese producto») | 31 buckets |
| `cuentas_por_cobrar` | `limite (1..20)` | `rpc_receivables_report` (ordenado por saldo; el total se suma **sobre todas** las filas antes de recortar, igual que el endpoint `/reports/receivables/summary`) | 20 + total |
| `cuentas_por_pagar` | `limite (1..20)` | `rpc_payables_report` (mismo criterio) | 20 + total |
| `comparar_periodos` | `a_desde`, `a_hasta`, `b_desde`, `b_hasta` | `rpc_period_comparison` | 1 |
| `rentabilidad_productos` | `dias (7..365)`, `limite (1..20)`, `orden: mejor\|peor` | `rpc_product_profitability` | 20 |

Reglas comunes: fechas `YYYY-MM-DD` de negocio (nunca `AT TIME ZONE`), `desde <= hasta`, rango máximo 366 días; argumento fuera de dominio → el resultado de la herramienta es `{error:"argumento_invalido", detalle}` y el modelo puede corregir en la ronda siguiente (no es un 400 para el usuario). El resultado que vuelve al modelo es JSON compacto con los nombres de columna de la RPC, montos como número (el formato `es-AR` lo pide el prompt) y la marca `window_clamped` cuando el plan recortó el historial, para que lo diga. **Ninguna** herramienta suma buckets ni recalcula lo que la RPC ya devuelve (`reporting-invariants`).

*Sin herramienta (límite declarado, candidato)*: caja y banco del día, listado de productos sin movimiento. «Qué producto no se mueve» se contesta con `stagnant_stock_count`/`stagnant_stock_value` de `resumen_periodo` más los últimos de `rentabilidad_productos` por `last_sale_date`, y el prompt obliga a decir que el listado completo no está disponible.

### D4. Bucle y topes (techo de costo por pregunta)

- `tool_choice: "auto"`, `parallel_tool_calls: true`.
- **Máximo 3 rondas con herramientas** y **8 llamadas a herramienta** por pregunta; alcanzado el tope, una última llamada **sin** `tools` obliga a responder con lo que hay.
- **Tiempo total 45 s** (cada llamada a OpenAI 25 s, cada RPC 8 s); vencido → `fallback` sin reintento del bucle completo.
- **Salida**: 700 tokens por llamada. **Entrada**: presupuesto de memoria corta de 6.000 tokens estimados (D6) + resultados de herramientas recortados por D3.
- Una RPC que falla devuelve `{error:"no_disponible"}` a esa herramienta (registrado en el log con el prefijo `[ai-copilot]`); el turno sigue.

Con ~6.000 tokens de entrada y ~800 de salida por pregunta, `gpt-6.1-terra` cuesta ≈ US$ 0,01 por pregunta (explore §5).

### D5. Prompt de asistente

`buildSystemPrompt({now})` arma, en este orden:

1. **Rol**: asistente de gestión de Aliadata para microemprendedores de Mendoza, Argentina; español rioplatense; montos en pesos argentinos con formato `es-AR` ($ 1.234.567,89 → «$1.234.568»).
2. **Hoy**: «Hoy es viernes 6 de noviembre de 2026, 15:42 (hora de Mendoza)», calculado con `America/Argentina/Mendoza` (`_shared/argentina-time.ts`), con «ayer», «esta semana» (lunes a hoy), «la semana pasada» y «el mes pasado» explicitados como fechas para que el modelo no tenga que calcularlas.
3. **Capacidades y límites**: sólo consulta datos; **no registra, edita ni borra nada** («si te piden anotar algo, explicá que desde acá sólo podés consultar y decí dónde se hace»); no ve caja, banco ni el listado de productos sin movimiento.
4. **Regla de números**: todo número de la respuesta sale de un resultado de herramienta de este turno o de la memoria; si no hay dato, lo dice. Prohibido estimar cifras del negocio.
5. **Período por defecto**: si la pregunta no dice período, usa el mes en curso y lo aclara en una línea («Tomé noviembre hasta hoy»). Si el estado trae un período en foco y la pregunta es de seguimiento («¿y el anterior?»), lo usa.
6. **Repregunta**: si falta el producto o el cliente y no se infiere del estado ni de `buscar_producto` (cero o varios candidatos), hace **una** pregunta corta con hasta 3 opciones; nunca dos repreguntas seguidas sobre lo mismo.
7. **Formato**: primero el número exacto, después a lo sumo 3 líneas; una acción concreta sólo si corresponde; nada de consejos genéricos.
8. **Few-shot**: 6 ejemplos sacados de las preguntas reales anonimizadas de `ai_conversations` («¿cuál es mi producto con menos stock?», «¿cuánto vendí hoy?», «¿qué cliente compró más?», «¿cuál fue mi ganancia neta?», «¿qué producto me conviene reponer?», «dame tres consejos para mejorar mi negocio»), cada uno con la herramienta esperada y la forma de la respuesta, con números ficticios.

La respuesta final se pide con `response_format: json_schema` `{kind: "answer"|"clarification", answer: string, state: {...}}` (strict) para que el estado de foco salga estructurado; si el modelo elegido no soporta `json_schema` (task 0), cae a texto libre y el estado se deriva en el servidor de las últimas herramientas llamadas (D7).

### D6. Memoria corta

- El cliente manda el historial visible de la conversación actual (hasta 20 mensajes). El servidor lo recorta **de lo más viejo a lo más nuevo** hasta un presupuesto de 6.000 tokens estimados (`ceil(caracteres/4)`), sin cortar mensajes por la mitad: un mensaje entra entero o no entra. Cada mensaje del historial tiene un tope duro de 4.000 caracteres (validación, 400).
- Los resultados de herramientas de turnos anteriores **no** se reenvían: cada respuesta del asistente en el historial ya lleva sus números; el `consulted` previo entra como una línea «(consulté: …)» compacta.
- `state` (D2) viaja ida y vuelta; el servidor lo valida (UUIDs, fechas, nombres ≤ 120) y lo incluye en el prompt como «En foco: período …, producto …». Confiar en el estado que manda el cliente es aceptable: sólo orienta una lectura que igual pasa por la membresía de la RPC.

### D7. Estado de foco

Lo devuelve el modelo en el `json_schema` (D5). Fallback determinista en el servidor: el último `desde/hasta` usado en una herramienta es el período; el último `producto_id` resuelto por `buscar_producto`/`detalle_producto`, el producto; el último cliente nombrado por `mejores_clientes`/`cuentas_por_cobrar` en una respuesta de 1 fila, el cliente. Un estado inválido que devuelve el modelo se descarta y se usa el determinista.

### D8. Modelo por variable con allow-list

`resolveCopilotModel(Deno.env.get("COPILOT_AI_MODEL"))` con `COPILOT_ALLOWED_MODELS = ["gpt-6.1-terra", "gpt-6-luna", "gpt-4o-mini", "gpt-5-mini", "gpt-4.1-mini"]` y `COPILOT_DEFAULT_MODEL = "gpt-6.1-terra"`; valor fuera de la lista → default + `console.warn` (copia del patrón de `resolveOcrModel`; se generaliza a un `resolveAllowedModel(list, default, value)` compartido sólo si la Regla de Tres lo pide — hoy son dos).

**Task 0 obligatoria** con la clave de producción: `GET /v1/models` y una llamada de prueba por candidato con `tools` + `response_format: json_schema`, registrando qué parámetro de tope de salida acepta cada uno (`max_completion_tokens` vs `max_tokens`) y si acepta `temperature`. **Fallback sin reabrir el change**: si `gpt-6.1-terra` no existe o no soporta `tools`, el default pasa a `gpt-5-mini`; si tampoco, `gpt-4.1-mini`; los que no existan se sacan de la allow-list. El parámetro de tope de salida se elige por modelo en una tabla del núcleo. Las evals (D12) confirman o cambian el default con datos.

### D9. Registro de conversaciones (arreglo + instrumentación)

- **Diagnóstico primero** (task 1.1): reproducir en el stack local el insert sin `account_id` con un usuario real de la cuenta y verificar el `42501`/`new row violates row-level security policy`; mirar en los logs de Vercel de los últimos días si aparece `[Copilot] Failed to save conversation` (si los logs ya no llegan, se dice) y, con el MCP de lectura, contar preguntas con `ai_queries_used` (no las hay: el Copiloto no cobra). La evidencia queda en el design (§Notas del apply).
- **Arreglo**: la Edge Function inserta **con** `account_id` (el de `resolveActiveAccountId`) y con el JWT del usuario (la policy de `INSERT` existente lo valida); el insert se **espera** antes de responder (no `.catch` silencioso) porque el `conversation_id` es lo que la valoración necesita. Si el insert falla, la respuesta igual llega con `conversation_id: null` (sin botones de valoración) y el error va al log con prefijo; no se cobra de más ni se pierde la respuesta.
- **Columnas aditivas** en `ai_conversations`: `model text`, `tools_used jsonb NOT NULL DEFAULT '[]'` (lista de `{name, ok, rows, ms}`, sin los argumentos de texto libre), `latency_ms integer`, `prompt_tokens integer`, `completion_tokens integer`, `outcome text CHECK (outcome IN ('answer','clarification','fallback','error'))`, `thread_id uuid` (agrupa los turnos de una conversación de la pantalla). Las 11 filas viejas quedan con `NULL`/`'[]'`.
- Sólo se registran turnos que llegaron al modelo (pasaron la reserva). Un 400/401/403/429 no deja fila.
- Lectura del historial: la pantalla lee los últimos 50 turnos del usuario (`user_id = auth.uid()`; la RLS ya acota a la cuenta), descendente y luego invertido; nunca `select('*')` sin límite.

### D10. Cuota, ráfaga y reserva

- `rpc_reserve_ai_usage` gana la rama `'queries'`: mismo `UPDATE` condicional único sobre `ai_queries_used < max_ai_queries_per_month` y una ventana de ráfaga propia (`profiles.ai_queries_window_count`, `ai_queries_window_started_at`) con **5 por 60 s**. La función se reescribe **desde su `pg_get_functiondef` vivo** (regla del proyecto), `CREATE OR REPLACE` con la misma firma, conservando el `COMMENT` actualizado y re-emitiendo `REVOKE`/`GRANT` en el mismo archivo. La rama `'ocr'` no cambia (gate: misma respuesta antes y después). Contador desconocido sigue en `22023`.
- **Una reserva por pregunta**, antes de cualquier lectura de datos y antes del modelo, con el cliente del usuario. Las rondas de herramientas no cobran aparte (el techo de costo lo pone D4). Una reserva concedida no se devuelve aunque el modelo falle (mismo criterio que el OCR, OQ-2 de `v31-ia-ratelimit-budget`).
- Fail-closed: si la reserva no se resuelve → 503 `quota_unavailable` sin llamar a OpenAI.
- Comparte el contador `ai_queries_used` con las otras funciones de IA (que siguen con check + incremento): la reserva y el incremento tocan la misma columna con `UPDATE` atómicos, así que conviven sin carrera nueva.
- El cron `reset-ai-counters` agrega `ai_queries_window_count = 0, ai_queries_window_started_at = NULL` (unschedule + schedule con el mismo nombre, como en `20261090000001`).
- `_shared/ai-quota.ts`: `ReserveCounter = "ocr" | "queries"`; `mapAiReservation` sin cambios.

### D11. Superficie `/copiloto-ia`

Misma ruta y entrada de menú («Copiloto IA», grupo Inteligencia). Se reescribe sobre:

- `hooks/data/use-copilot.ts`: `askCopilot(input)` (fetch a la Edge Function con `getAuthHeaders()`, nunca `supabase.auth.*`; traduce la respuesta a un resultado cerrado como `analyzeStatistics`), `useAskCopilot()` (al éxito invalida `aiUsage` y el historial), `useCopilotHistory()` (D9), `useSetAiFeedback()` (RPC `rpc_set_ai_feedback`, optimista con rollback). Claves nuevas en `lib/query-keys.ts`, con `accountId` en la clave.
- `components/copilot/`: `CopilotChat.tsx`, `CopilotMessage.tsx` (texto + bloque «Miré: …» con los `consulted` + botones «Me sirvió» / «No me sirvió» con `aria-pressed`), `CopilotSuggestions.tsx` (6 preguntas sugeridas, clicables, visibles con el chat vacío y como chips debajo del input en mobile), `CopilotQuotaBadge.tsx` (`useAiUsage`: «Te quedan N consultas este mes»; en 0, input deshabilitado con el aviso de renovación).
- **Estados legibles**: cargando con pasos («Consultando tus datos…» tras 2 s, «Sigo buscando…» tras 15 s); 429 cuota → «Usaste tus N consultas del mes. Se renuevan el 1 de diciembre.»; 429 ráfaga → «Esperá N segundos» con cuenta regresiva; 502/503/fallback → «No pude responder ahora. Probá de nuevo en un rato.»; sin conexión → aviso propio. Nunca texto crudo del proveedor ni `console.log` del cuerpo.
- «Nueva conversación» reinicia `thread_id`, historial enviado y estado de foco (el historial guardado sigue visible arriba, separado).
- Tokens semánticos y componentes base (Card, Button, Input, Badge, ScrollArea); sin colores literales. Desktop y mobile (360 px: sin desborde horizontal, input fijo abajo, burbujas al 90 %); claro y oscuro.
- Arnés `app/dev-harness/copiloto-chat/` (intercepta `window.fetch` hacia `/functions/v1/ai-copilot` y el RPC de valoración con respuestas fijas: respuesta con `consulted`, repregunta, cuota agotada, ráfaga, fallback) y `e2e/harness/copiloto-visual.spec.ts` con capturas en 4 combinaciones.

### D12. Evals

- `supabase/functions/_shared/ai-copilot-evals.json`: ~40 casos `{id, question, history?, expect: {tools_any_of, rpc_check, must_contain_number?, must_ask_clarification?, must_refuse_write?}}`. Composición: las 10 preguntas reales distintas de `ai_conversations`; 20 variantes vagas («cuánto vendí hoy», «ventas de ayer», «qué cliente compró más», «cómo venimos este mes vs el anterior», «qué producto no se mueve», «a quién le tengo que cobrar», «qué me falta comprar», «cómo vengo»…); 5 de seguimiento con estado («¿y el mes pasado?»); 3 de repregunta (producto ambiguo); 2 de escritura pedida («anotame un gasto de $5.000») que deben negarse.
- `scripts/ai/copilot-evals.ts` (Deno, **a mano**, no en CI): por caso llama a la Edge Function desplegada con un JWT de una cuenta de prueba real, ejecuta `rpc_check` con el mismo JWT para obtener el número esperado y verifica que aparezca en la respuesta (normalizando `es-AR`, tolerancia de redondeo a peso entero). Corre por modelo (`COPILOT_AI_MODEL` en el secreto o un override de sólo-eval vía header que la función **ignora** en prod, ver OQ-4) y escribe un resumen (aciertos, repreguntas correctas, negativas correctas, latencia media, tokens) en `openspec/changes/ia-copilot-v2/evals/<fecha>-<modelo>.md`.
- Tests unitarios del núcleo puro (vitest, `frontend/__tests__/ai-copilot-*.test.ts`): ruteo y validación de herramientas, topes de rondas/llamadas/tiempo, armado del prompt con fecha ART (bordes 21:00–24:00), memoria con presupuesto, parseo de `tool_calls` (incluido JSON inválido y herramienta desconocida), mapeo de errores, que el registro lleve `account_id`, y que la reserva ocurra antes que cualquier lectura.

### D13. `ai_feedback` (reutilizable)

```sql
CREATE TABLE public.ai_feedback (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  subject_type text NOT NULL CHECK (subject_type IN ('copilot_answer','insight')),
  subject_id uuid NOT NULL,
  rating text NOT NULL CHECK (rating IN ('useful','not_useful')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, subject_type, subject_id)
);
```

- `subject_id` sin FK dura (polimórfico); la integridad la da la RPC. El `CHECK` ya admite `'insight'` para que el change 2 no tenga que alterar la tabla.
- RLS activa: `SELECT` propio (`user_id = auth.uid() AND account_id IN current_account_ids()`); **sin** policies de escritura y con `REVOKE INSERT, UPDATE, DELETE, TRUNCATE` a `anon`/`authenticated`: se escribe sólo por `rpc_set_ai_feedback(p_subject_type text, p_subject_id uuid, p_rating text)` `SECURITY DEFINER`, `search_path = ''`, `EXECUTE` sólo `authenticated`. La RPC: `P0401` sin sesión; `22023` tipo o valoración fuera de dominio; en este change, `'insight'` → `22023` (la rama la abre el change 2); `'copilot_answer'` exige una fila de `ai_conversations` con ese `id`, del mismo `user_id` y de una cuenta en `current_account_ids()`, si no `P0404`; `p_rating NULL` borra la valoración (toggle); si no, upsert por la clave única. Devuelve `{subject_type, subject_id, rating}`.
- Índice `(account_id, subject_type, created_at)` para el reporte que el change 2 va a necesitar.

*Alternativa descartada*: columna `feedback` en `ai_conversations` — obliga al change 2 a duplicarla en `insights` y deja dos formas de lo mismo.

### D14. Retiro de la ruta vieja

Después de que la pantalla use la Edge Function: grep de `api/ai/copilot`, `buildBusinessSnapshot`, `buildAdaptiveContext`, `AI_SYSTEM_PROMPT`, `aiCopilotService`, `analyzePricingInQuestion` en `frontend/` y `supabase/`; se borran `app/api/ai/copilot/route.ts`, `lib/ai/buildBusinessSnapshot.ts`, `lib/services/aiCopilotService.ts` y sus tests (`__tests__/ai/buildBusinessSnapshot.test.ts`, `__tests__/ai/copilot-server-identity.test.ts`), y se actualizan los que los nombran como ejemplo (`__tests__/lib/server-paths-no-browser-session-store.test.ts`, `__tests__/lib/session-identity-services.test.ts`, los comentarios de `lib/reporting/kpi-summary.ts`, `lib/reporting/product-ranking.ts` y `lib/auth/route-access.ts`). Los tests de middleware que usan `/api/ai/copilot` como ejemplo de ruta de API cambian a otra ruta de `app/api/` existente. `pricingService.suggestPriceRange` se conserva (tiene otros consumidores; verificar en el grep).

### D15. Tandas

- **Tanda A — DB + Edge Function + evals** (migración `20261095000001`, `ai-copilot`, núcleos, tests, gate SQL, script de evals, task 0 y primera corrida de evals). Sin superficie nueva: la pantalla sigue en la ruta vieja hasta la tanda B, así que se puede mergear y desplegar sin cambio visible, y las evals deciden el modelo **antes** de construir la UI sobre él.
- **Tanda B — frontend** (hook, componentes, pantalla, arnés, e2e, retiro de la ruta vieja D14, pasada visual en 4 combinaciones). Depende de A desplegada.

Dos tandas porque el riesgo y la verificación son distintos (A se verifica con SQL, vitest y evals con la clave real; B con capturas), y porque B no puede probarse en real sin A en prod.

## Risks / Trade-offs

- [Latencia de 2-3 rondas] → topes de D4, `parallel_tool_calls`, indicador de progreso por pasos (D11); las evals miden la latencia media por modelo.
- [Nombres y precios de modelos cambiantes] → allow-list por variable (D8) y task 0 con la clave real; cambiar de modelo es cambiar un secreto.
- [El modelo inventa un número] → regla de números en el prompt + `json_schema` + evals numéricas; el `consulted` visible deja ver de dónde salió.
- [Herramientas que devuelven demasiado] → topes de filas (D3) y presupuesto de entrada (D4/D6).
- [Costo] → una reserva por pregunta + techo por pregunta; ≈ US$ 10 cada 1.000 preguntas; el tope mensual de OpenAI que el PO ya fijó es la red final.
- [El estado de foco que manda el cliente se manipula] → sólo orienta lecturas que igual validan membresía; nunca elige cuenta ni escribe.
- [Prompt injection en la pregunta o en nombres de productos/clientes] → las herramientas son de sólo lectura y acotadas a la cuenta por la RPC; lo peor que logra es una respuesta rara sobre sus propios datos. Los nombres que vuelven de las RPCs se pasan como datos JSON, no como instrucciones.
- [Reescribir `rpc_reserve_ai_usage` rompe el OCR] → partir del `pg_get_functiondef` vivo, gate que ejecuta las dos ramas, reaplicación idempotente.
- [Truncado a 1.000 filas de PostgREST] → no aplica: toda herramienta lee una RPC agregada o `buscar_producto` con `limit 10`; nada lee filas crudas de ventas.

## Migration Plan

1. Tanda A: `supabase db push` vía CI al mergear (`20261095000001`); deploy de `ai-copilot` por `deploy.yml`; secreto `COPILOT_AI_MODEL` opcional (sin él, default). La ruta vieja sigue sirviendo a la pantalla.
2. Verificación post-merge en prod (sólo `SELECT`): `MAX(version)`, columnas nuevas, `ai_feedback` con RLS y ACLs, `rpc_reserve_ai_usage` con una sola definición, cron con las columnas nuevas, Edge Function activa.
3. Tanda B: la pantalla pasa a la Edge Function y se retira la ruta vieja en el mismo PR.
4. **Rollback**: tanda B se revierte con el PR (la ruta vieja vuelve); tanda A es aditiva (columnas nulas, tabla nueva, rama nueva de la RPC): revertir la Edge Function no requiere tocar la base.

## Open Questions

**Sign-off del PO por mandato (2026-11-06)**: todas se resuelven por su opción recomendada. Las que **cambiarían el diseño** si el PO opinara distinto: **OQ-1** (una consulta por pregunta), **OQ-2** (ráfaga de 5 por minuto), **OQ-3** (tabla genérica `ai_feedback`).

- **OQ-1. ¿Cuánto cobra una pregunta?** (a) **una consulta por pregunta, sin importar cuántas herramientas use** ← recomendada: es lo que entiende el usuario y el techo de costo lo pone D4; (b) una por ronda — castiga las preguntas buenas. **Resuelta: (a).**
- **OQ-2. Ráfaga.** (a) **5 por 60 s** ← recomendada (explore §7.1; una conversación normal no la toca); (b) 3 por 60 s como el OCR — corta seguimientos rápidos. **Resuelta: (a).**
- **OQ-3. Dónde vive la valoración.** (a) **tabla genérica `ai_feedback` por tipo de sujeto** ← recomendada (el change 2 la reutiliza sin migrarla); (b) columna en `ai_conversations` y otra en `insights`. **Resuelta: (a).**
- **OQ-4. Override de modelo para las evals.** (a) **ninguno en prod: las evals cambian el secreto `COPILOT_AI_MODEL` entre corridas o corren contra el stack local con la clave real** ← recomendada (un header que elige modelo es una puerta de costo); (b) header `x-eval-model` restringido a `platform_admin`. **Resuelta: (a)**; el script lo documenta.
- **OQ-5. ¿Se puede borrar el historial desde la pantalla?** (a) **no en este change** ← recomendada (la policy de `DELETE` existe pero no hay pedido; «Nueva conversación» alcanza); (b) botón «borrar historial». **Resuelta: (a)**, candidato.
- **OQ-6. Preguntas sugeridas fijas o según los datos.** (a) **fijas** (6, sacadas de las reales) ← recomendada; (b) dinámicas según el negocio — otra llamada o lógica nueva. **Resuelta: (a).**
- **OQ-7. Retención del registro.** (a) **sin borrado automático en este change** ← recomendada (11 filas en toda la historia); (b) purga a 12 meses. **Resuelta: (a)**, candidato si crece.

## Notas del apply

(Se completa durante el apply de cada tanda.)

### Notas de implementación de la tanda A (2026-11-06)

**Evidencia del diagnóstico del guardado roto (tasks 1.1 y 1.2, D9).** Confirmado, no sólo probable.
- *Local* (stack con la migración de la tanda A todavía sin aplicar a esa fila de prueba, usuario `@test.local` con su cuenta, rol `authenticated` con los claims del usuario): `INSERT INTO ai_conversations (user_id, question, answer)` → `42501 new row violates row-level security policy for table "ai_conversations"`. El mismo `INSERT` con `account_id` = la cuenta activa → pasa. El gate `test_ia_copilot_v2.sql` (d) deja ambas afirmaciones como permanentes.
- *Prod* (sólo `SELECT`): `ai_conversations` 11 filas, la última del 2026-05-11, 0 con `account_id` nulo. No se pudieron consultar los logs de Vercel de la ruta (no están disponibles desde esta sesión): **no hay evidencia directa del mensaje `[Copilot] Failed to save conversation` en producción**; la conclusión se apoya en la reproducción local de la policy y en que el hueco temporal coincide con el 2026-06-06 (`rls_tenant_scoping`). Veredicto: guardado roto desde junio, sumado a «sin uso» no distinguible con los datos que hay.
- Las preguntas reales distintas de prod son **9**, no 10 (11 filas con dos textos repetidos): el set de evals trae las 9 y compensa con una variante vaga más, hasta 40.

**Punto de partida de `rpc_reserve_ai_usage`.** `md5(replace(prosrc, E'\r', ''))` del cuerpo vivo en prod el 2026-11-06 = `5e8e0795805ddedf2d905f3d03ea69ea` (3.307 caracteres), **idéntico** al cuerpo que declara `20261090000001` (calculado desde el archivo del repo con el mismo criterio). El `design.md` del propose no traía el valor; lo fija esta nota. La migración conserva el cuerpo de `'ocr'` línea por línea dentro de un `IF` y agrega la rama `'queries'` como bloque hermano con su propio `UPDATE` condicional único. No había ningún eslabón de la cadena de reaplicación con preflight por md5 de esta función (grep del workflow: sólo el eslabón de `20261090000001`, sin md5, y el gate del OCR), así que no hubo nada que retirar; el eslabón nuevo de `20261095000001` va **después** de los de `20261093000001` y `20261094000001` y es obligatorio porque el de `20261090000001` reaplica la versión original de la RPC (sin `'queries'`).

**Gates preexistentes tocados.** `test_ia_ocr_cuota_reserva.sql` afirmaba que `rpc_reserve_ai_usage('queries')` daba `22023`: con el contador abierto, ese caso pasa a `'advice'` (que sigue cerrado). Es el único cambio de ese archivo.

**Task 0 (verificación de modelos): preparada, NO corrida.** No hay clave real en esta sesión. `scripts/ai/verify-copilot-models.ts` hace `GET /v1/models` y, por cada modelo de la allow-list que exista, mide el parámetro de tope de salida, `temperature`, `tools` y `json_schema` estricto, e imprime una tabla y un JSON para pegar acá. Hasta que se corra, el código está blindado así: (1) el default queda en `gpt-6.1-terra` (D8); (2) `COPILOT_MODEL_PARAMS` supone que la familia `gpt-5-*`/`gpt-6-*` usa `max_completion_tokens` sin `temperature` y los clásicos `max_tokens` con `temperature = 0,2` — **es una suposición**; (3) `createModelFailover` hace que, si OpenAI responde 404/400 «el modelo no existe», el handler pase solo al siguiente de `COPILOT_FALLBACK_ORDER` (terra → luna → gpt-5-mini → gpt-4.1-mini → gpt-4o-mini), loguee el salto con el prefijo `[ai-copilot]` y recuerde el que funcionó mientras viva el aislado; y si un 400 se queja de un parámetro (`max_tokens`, `temperature`, `response_format`, `reasoning_effort`) corrige y reintenta con el mismo modelo hasta 2 veces y lo recuerda. Ningún otro error (500, timeout, red) salta de modelo. **Riesgo declarado**: en los modelos de razonamiento el tope de 700 tokens de salida incluye el razonamiento; si la task 0 muestra respuestas vacías por ese motivo, se sube `MAX_OUTPUT_TOKENS` o se fija `reasoning_effort` en `COPILOT_MODEL_PARAMS` (una constante, sin reabrir el diseño).

**Decisiones de implementación que el diseño dejaba abiertas.**
- *Estado de foco (D7)*: si el modelo devuelve un estado válido con alguna parte no nula, se usan sus partes y las que falten se completan del foco de las herramientas y del estado previo; si no hay ninguna parte válida, el estado es el determinista completo. Un estado válido de puros `null` se trata como «no lo dio».
- *Cuerpo del request*: además de `question`, `history` y `state`, acepta `thread_id` (uuid, opcional) para agrupar los turnos, y cada mensaje del historial puede traer `consulted: string[]` (rótulos) que entran como la línea `(consulté: …)` de D6. Cualquier otro campo se ignora.
- *Registro de un turno con error del proveedor*: queda una fila con `outcome = 'error'` y `answer = ''` (el turno llegó al modelo y gastó cuota); los rechazos previos (400/401/403/429/503) no dejan fila.
- *`buscar_producto`*: el texto se limpia de comodines de `LIKE` y de separadores de filtros de PostgREST (`% * _ \ , ( ) " ' ; :`) antes del `ilike`; si queda con menos de 2 caracteres es un argumento inválido.
- *`resumen_periodo`*: la ventana va con la convención ya usada por las funciones `ai-*` (`YYYY-MM-DDT00:00:00.000Z` a `T23:59:59.999Z` del día argentino) y la previa sale de `previousWindow` de `reporting-canon`.
- *`rentabilidad_productos`*: la RPC devuelve todos los productos; la herramienta sólo ordena por `gross_margin` (importe de ganancia; `mejor` descendente, `peor` ascendente, desempate por nombre) y recorta — no recalcula nada.
- *Rango máximo*: 366 días **con ambos extremos** (2025-11-06 a 2026-11-06 entra; un día más no).
- *Sin `OPENAI_API_KEY`* la función responde 502 `ai_unavailable` **antes** de reservar cuota (falla de configuración, no del usuario).
- *Un resultado de herramienta* de más de 20.000 caracteres se reemplaza por `{error:"resultado_demasiado_grande"}` (red de seguridad; los topes de filas ya lo evitan).

**Despliegue (task 4.4).** `deploy.yml` corre `supabase functions deploy --no-verify-jwt` para **toda la flota** (línea 63), así que la función nueva se despliega sola al mergear con el directorio `supabase/functions/ai-copilot/` y su `deno.json`; no existe la variante «sin `--no-verify-jwt`» que decía la task: la función se autentica ella misma (`getUser()` → 401) como las demás `ai-*`, según la nota de `config.toml` (D15 de `auth-hardening-jwt-cookies`). **No se tocó `supabase/config.toml`** (instrucción del apply): la entrada `[functions.ai-copilot]` (`verify_jwt = false`, `import_map`, `entrypoint`) sólo afecta a `supabase functions serve` en local y queda como candidato barato. Secreto opcional: `COPILOT_AI_MODEL` (sin él, rige el default y el salto automático).

**Verificación de la función (task 4.3, parcial).** Con el handler REAL corriendo bajo Deno contra el stack local (Auth, RLS y RPCs reales) y OpenAI simulado por un `fetch` de prueba: 401 sin sesión; 400 con pregunta vacía; un turno con 4 llamadas a herramientas en una ronda (3 ejecutadas contra las RPCs reales, 1 con `limite = 500` rechazada como `argumento_invalido`) → 200 con `consulted`, `state` y `conversation_id`; fila de `ai_conversations` con `account_id`, `model`, `tools_used`, latencia, 2.700/70 tokens y `thread_id`; modelo por defecto «inexistente» → salto a `gpt-6-luna` logueado y recordado; error 500 del proveedor → 502 `ai_unavailable` sin filtrar el texto y fila `error`; 5 reservas concedidas y la siguiente → 429 `rate_limited` con `Retry-After`, **sin ninguna llamada a OpenAI**. **Lo que NO se probó**: una llamada real a OpenAI (modelo real, `tools` + `json_schema` reales, latencia real) — queda para el PO con su clave (task 0 y corrida de evals, `docs/pendientes-manuales-po.md` §12).

**Evals (task 5).** `supabase/functions/_shared/ai-copilot-evals.json` (40 casos: 9 reales + 21 vagas + 5 seguimientos con estado + 3 repreguntas + 2 escrituras a negar), verificador puro `_shared/ai-copilot-evals.ts` probado en vitest (23 tests) y `scripts/ai/copilot-evals.ts` (Deno, a mano, `deno check` limpio, **no ejecutado**: necesita la función desplegada y una cuenta de prueba). La línea base con `gpt-4o-mini` y con cada candidato existente (task 5.4) y la elección del default por resultado quedan para el PO.

### Notas de implementación de la tanda B (2026-11-06)

**Contrato calcado, no reinterpretado.** `hooks/data/use-copilot.ts` traduce las formas cerradas de D2: `answer`/`clarification` (texto, `conversation_id`, `consulted`, estado de foco validado campo por campo; un estado inválido cae a vacío y un `consulted` malformado se filtra), `fallback`, 400 (`invalid`, con el mensaje de validación del servidor), 401, 403, 429 por cuota (`resetAt`/`used`/`limit`, `null` si faltan) y por ráfaga (segundos del cuerpo, si no del header `Retry-After`, si no 30), 502/503 (`unavailable`, el cuerpo jamás se muestra), red caída (`offline`) y cualquier otro caso (`error`, sin el cuerpo). Sin sesión no se llama a la función. La llamada es `fetch` con `getAuthHeaders()` (mismo patrón que `analyzeStatistics`), no `supabase.functions.invoke`: el helper compartido ya resuelve el token del store en memoria y una sola forma de armar el Bearer es lo que el candado `auth-headers` barre. El texto de fallback/errores es **del cliente**: ni el `answer` del `fallback` ni nada del proveedor llega a pantalla.

**Decisiones que el diseño dejaba abiertas.**
- *Valoración de la respuesta viva*: `useSetAiFeedback` actualiza de forma optimista el historial cacheado (con rollback), pero la conversación en curso vive en estado local de la pantalla (no en la caché), así que `CopilotChat` guarda la valoración también en el mensaje vivo y la revierte con aviso (`sonner`) si la RPC falla. Así el botón responde aunque el historial todavía no haya releído el turno, y el arnés (sin usuario, con la consulta deshabilitada) lo prueba igual. «Nueva conversación» invalida el historial para que los turnos que acaban de pasar a «anteriores» traigan su valoración.
- *Qué invalida `useAskCopilot`*: sólo `answer`/`clarification` (task 7.2). Un `fallback` también reservó una consulta del cupo (D10: una reserva concedida no se devuelve), así que el contador puede quedar hasta 30 s desactualizado después de un fallback; el 429 posterior lo corrige. No se agregó invalidación para no apartarse de la task.
- *Cupo agotado*: la pantalla bloquea el input con el aviso cuando `useAiUsage` dice 0 **y** el plan ya cargó (`queriesLimit > 0`; sin ese chequeo, mientras `usePlanLimits` carga, `queriesRemaining` es 0 y se bloquearía por error) o cuando el servidor contesta 429 por cuota. La fecha de renovación sale de `resetAt` del 429 y, sin él, de `nextAiResetDate` (la misma regla del cron).
- *Falla de la consulta*: el mensaje del usuario se quita de la conversación y el texto vuelve al campo, con el aviso (`role="alert"`) debajo; la ráfaga deja el input editable y deshabilita sólo el envío con cuenta regresiva de 1 s.
- *Estructura del chat*: lista nativa con `role="log"` y `aria-live="polite"` (desplazable por teclado) en vez de `ScrollArea` de Radix: hay que mover `scrollTop` al llegar un mensaje y el viewport de Radix no es un destino estable para eso. El resto sigue D11 (Card, Button, Input, Badge, tokens semánticos).
- *Historial*: `useCopilotHistory` lee `ai_conversations` (50, descendente, columnas explícitas) y las valoraciones de esos ids en una segunda consulta; si la segunda falla, muestra el historial sin valoraciones. Los turnos guardados no traen los rótulos «Miré: …» (la tabla guarda `tools_used` sin rótulos legibles, D9): sólo la respuesta viva los muestra.

**Retiro de la ruta vieja (D14).** Grep antes y después: los únicos callers eran la pantalla vieja, comentarios de `lib/` y siete tests. `ai-insights` y el export **no** usaban `buildBusinessSnapshot`, así que se borró. Tests que la nombraban como ejemplo: los de middleware y `protected-routes-coverage` pasaron a `/api/billing/cancel`; `auth-headers` ya no necesita nombrar la ruta en su lista de Bearers permitidos; `server-paths-no-browser-session-store` recorre ahora el grafo desde `/api/billing/preferences` (sigue probando dos saltos reales); `critical-stock` dejó de leer el archivo borrado (las tres aserciones de «consumidores canónicos» quedan sobre `ai-insights`, que sí las cumple). **Desvío**: `pricingService` no tiene ningún otro consumidor (el diseño lo daba por conservado), pero se dejó: borrarlo no era parte del alcance firmado y es código inofensivo; queda como candidato junto con las funciones de `lib/reporting/` que sólo consumía el snapshot (`kpi-summary`, `product-ranking` siguen en uso por el Tablero y las Edge Functions).

**Verificación.** Hook 27 casos y pantalla 21 casos en verde; suite del frontend sin fallos; `tsc --noEmit` sin errores nuevos (8 preexistentes en 5 tests ajenos: `LedgerMovementsPanel`, `purchase-operations-list-payment-lock`, `use-critical-stock`, `pos-payment-methods`, `revenue-canon`); arnés `dev-harness/copiloto-chat` con 28 pruebas de navegador (sin desborde horizontal a 375 px, input en el viewport, contraste AA del texto secundario en ambos temas, «Me sirvió» con `aria-pressed`, pasos de espera). **Lo que NO se probó**: el chat contra la función desplegada con un modelo real (latencia, calidad de la respuesta): queda para el humo del PO (`docs/pendientes-manuales-po.md` §12).
