# Tasks — ia-copilot-v2

> Governance **MEDIO** (IA de sólo lectura; cuota de IA). TDD estricto: cada task de código empieza con el test en rojo (RED), después el mínimo para verde (GREEN), un segundo caso que triangule y refactor con los tests en verde. Dos tandas (design D15): **A** = DB + Edge Function + evals (sin cambio visible); **B** = frontend + retiro de la ruta vieja. Todo commit vía PR; LF siempre.

## Tanda A — DB, Edge Function y evals

### 0. Verificación de modelos con la clave de producción (obligatoria, antes de escribir código del modelo)

- [ ] **[PO]** 0.1 Con la clave de producción (nunca leer `.env*`: el PO la carga como secreto o corre el comando), `GET /v1/models` y registrar en design §Notas del apply cuáles de `gpt-6.1-terra`, `gpt-6-luna`, `gpt-4o-mini`, `gpt-5-mini`, `gpt-4.1-mini` existen. _Corre el PO: `scripts/ai/verify-copilot-models.ts` (ver `docs/pendientes-manuales-po.md` §12)._
- [ ] **[PO]** 0.2 Por cada modelo existente, una llamada mínima con `tools` (una herramienta de juguete) + `response_format: json_schema` strict; registrar si acepta cada una, qué parámetro de tope de salida acepta (`max_completion_tokens` / `max_tokens`) y si acepta `temperature`. _Lo hace el mismo script de 0.1._
- [ ] **[PO]** 0.3 Aplicar el fallback de D8 sin reabrir el change: fijar `COPILOT_DEFAULT_MODEL` y la allow-list final; dejar la tabla de parámetros por modelo para 3.x. _Parcial en código: default `gpt-6.1-terra`, allow-list, salto automático al siguiente modelo y tabla de parámetros con corrección en caliente; el PO fija el resultado con la clave real._

### 1. Diagnóstico del registro de conversaciones (evidencia antes del arreglo)

- [x] 1.1 En el stack local, con un usuario `@test.local` miembro de una cuenta: reproducir el insert de `aiCopilotService.saveConversation` (sin `account_id`) con el cliente del usuario y registrar el error exacto (esperado: violación de la policy `ai_conversations_account_insert`). Repetir con `account_id` = cuenta activa y verificar que pasa. _Reproducido: sin `account_id` → `42501`; con `account_id` → pasa (design §Notas de la tanda A)._
- [x] 1.2 Evidencia de prod (sólo `SELECT`/logs): `count(*)`/`max(created_at)` de `ai_conversations` y, si los logs de Vercel de la ruta están disponibles, búsqueda de `[Copilot] Failed to save conversation`; si no están, decirlo. Escribir la conclusión en design §Notas del apply (guardado roto vs. sin uso). _Prod: 11 filas, última 2026-05-11. Logs de Vercel no disponibles desde la sesión (dicho en el design)._

### 2. Migración `20261095000001_ia_copilot_v2.sql`

- [x] 2.1 Confirmar el número libre (`ls supabase/migrations | tail -3`, prod `MAX(version)`, PRs abiertos); `20261094000001` es de `invitaciones-hardening`.
- [x] 2.2 RED: gate `supabase/tests/test_ia_copilot_v2.sql` (ejecuta de verdad, con `ON_ERROR_STOP`) que falla contra la base actual: columnas nuevas de `ai_conversations` y `profiles`; `ai_feedback` con RLS, sin privilegios de escritura para `anon`/`authenticated` (intento real de `INSERT` como `authenticated` → falla); `rpc_set_ai_feedback` con sus cinco caminos (`P0401`, `22023` tipo/valoración, `22023` para `insight`, `P0404` respuesta ajena / otra cuenta, upsert, borrado con `NULL`); `rpc_reserve_ai_usage('queries')` concede, deniega por cuota (precedencia sobre ráfaga), deniega por ráfaga en la 6ª dentro de 60 s, y dos reservas concurrentes con cupo 1 dejan exactamente una concedida; `rpc_reserve_ai_usage('ocr')` con la misma respuesta y efecto que antes y sin tocar `ai_queries_*`; `'advice'` sigue en `22023`; cron `reset-ai-counters` con las columnas nuevas; ACLs (`anon` sin `EXECUTE` en las dos RPCs).
- [x] 2.3 GREEN: `ai_conversations` + `model`, `tools_used jsonb NOT NULL DEFAULT '[]'`, `latency_ms`, `prompt_tokens`, `completion_tokens`, `outcome` con `CHECK`, `thread_id`; índice `(user_id, created_at DESC)`. Todo `ADD COLUMN IF NOT EXISTS`.
- [x] 2.4 GREEN: `profiles` + `ai_queries_window_count integer NOT NULL DEFAULT 0`, `ai_queries_window_started_at timestamptz` con `COMMENT`.
- [x] 2.5 GREEN: `ai_feedback` (D13) + RLS + policy de `SELECT` propia + `REVOKE` de escritura + índice; `rpc_set_ai_feedback` `SECURITY DEFINER`, `search_path = ''`, `REVOKE ALL … FROM PUBLIC, anon`, `GRANT EXECUTE … TO authenticated`, `COMMENT`.
- [x] 2.6 GREEN: reescribir `rpc_reserve_ai_usage` **partiendo del `pg_get_functiondef` vivo de prod** (comparar líneas sin CR contra `20261090000001`), agregando la rama `'queries'` (5 por 60 s) sin tocar la de `'ocr'`; `CREATE OR REPLACE` misma firma; re-emitir `REVOKE`/`GRANT` y `COMMENT` actualizado.
- [x] 2.7 GREEN: cron `reset-ai-counters` (unschedule + schedule, mismo nombre y horario) con las columnas nuevas.
- [x] 2.8 TRIANGULATE: reaplicar la migración dos veces (idempotencia) y correr el gate en `supabase db reset` local; cablear el gate en `KPI_Validation.yml` y, si corresponde, la migración en la cadena de reaplicación con su preflight.
- [x] 2.9 Correr los gates existentes que tocan la cuota del OCR (`invoice-ocr-budget`) y los de ACLs: sin regresiones.

### 3. Núcleo puro del Copiloto (`supabase/functions/_shared/`)

- [x] 3.1 SAFETY NET: correr `frontend/__tests__/ai-quota.test.ts`, `ai-estadisticas.test.ts`, `invoice-ocr-core.test.ts`, `reporting/edge-reporting-canon.test.ts` y registrar la línea base.
- [x] 3.2 `ai-quota.ts`: RED test de `ReserveCounter = "queries"` (tipado y `reserveAiUsage(client, 'queries')` llama la RPC con `p_counter:'queries'`); GREEN; sin cambiar `mapAiReservation`.
- [x] 3.3 `ai-copilot-tools.ts` — RED `frontend/__tests__/ai-copilot-tools.test.ts`: cada herramienta del catálogo D3 tiene schema strict; validación de fechas (`YYYY-MM-DD`, invertido, > 366 días), enumerados y límites; traducción exacta a la RPC con `p_account_id` inyectado (un argumento `account_id` del modelo se ignora); tope de filas; total de cuentas por cobrar/pagar sumado antes de recortar; `P0404` de `detalle_producto` → resultado legible; RPC con error → `{error:"no_disponible"}`; rótulo `consulted` para la persona. GREEN + TRIANGULATE (≥ 2 casos por herramienta) + REFACTOR.
- [x] 3.4 `ai-copilot-prompt.ts` — RED `ai-copilot-prompt.test.ts`: fecha/día/hora ART con bordes 21:00–24:00 y cambio de mes/año; fechas de ayer, esta semana, semana pasada y mes pasado; reglas (sólo lectura, números de herramientas, período por defecto, una repregunta); few-shot presentes; memoria con presupuesto de 6.000 tokens que descarta mensajes enteros de lo más viejo; línea «En foco» desde un estado validado; estado inválido descartado. GREEN + TRIANGULATE + REFACTOR.
- [x] 3.5 `ai-copilot-core.ts` — RED `ai-copilot-core.test.ts` con dobles inyectados: orden validar → reservar → leer → modelo → registrar (la reserva antes que cualquier lectura); 400 antes de la reserva (pregunta vacía/larga, historial > 20 o mensaje > 4.000); 429/503 de la reserva sin llamar al modelo ni registrar; bucle de herramientas con parseo de `tool_calls` (JSON inválido, herramienta desconocida, llamadas en paralelo); tope de 3 rondas / 8 llamadas con llamada final sin `tools`; timeout total 45 s → `fallback`; error del proveedor → 502 `ai_unavailable` sin filtrar el texto; respuesta `json_schema` → `kind`/`answer`/`state`, y fallback determinista de estado (D7) si el modelo no lo da o es inválido; registro con `account_id`, `model`, `tools_used`, latencia, tokens, `outcome`, `thread_id`; registro fallido → `conversation_id: null`; una sola reserva por pregunta. GREEN + TRIANGULATE + REFACTOR.
- [x] 3.6 `resolveCopilotModel` — RED: allow-list de la task 0.3, default, valor inválido con advertencia, ningún parámetro del request lo cambia; tabla de parámetro de tope de salida por modelo. GREEN.

### 4. Edge Function `supabase/functions/ai-copilot/`

- [x] 4.1 `index.ts` + `deno.json` sobre el molde de `ai-estadisticas`: cliente con anon key + `Authorization` del request, `getUser()`, `resolveActiveAccountId`, `rpc` y lectura de `products` con el JWT del usuario, `fetchWithTimeout` (25 s por llamada), CORS, `Retry-After` en 429. Sin lógica propia fuera del cableado.
- [x] 4.2 `deno check` desde una copia fuera del monorepo con `DENO_NO_PACKAGE_JSON=1`; cero errores nuevos.
- [x] 4.3 Run real en el stack local (`supabase functions serve`) con la clave real cargada como secreto local por el PO o con una clave de prueba: una pregunta con herramienta, una repregunta, cuota agotada (fila de `profiles` ajustada en local), ráfaga; verificar la fila de `ai_conversations` con `account_id`. _Con el handler real bajo Deno contra el stack local y OpenAI simulado; la llamada real a OpenAI queda `[PO]` (§12)._
- [x] 4.4 `deploy.yml`: confirmar que `functions deploy` incluye la función nueva (sin `--no-verify-jwt`); documentar el secreto opcional `COPILOT_AI_MODEL`. _`deploy.yml` despliega toda la flota con `--no-verify-jwt`; la función se autentica ella misma. `config.toml` sin tocar._

### 5. Evals

- [x] 5.1 `supabase/functions/_shared/ai-copilot-evals.json` con ≥ 40 casos (D12): las 10 preguntas reales distintas de `ai_conversations` (anonimizadas), 20 vagas, 5 de seguimiento con estado, 3 de repregunta, 2 de escritura que debe negarse; cada uno con `rpc_check` o la expectativa de repregunta/negativa.
- [x] 5.2 RED/GREEN del verificador puro (normalización de montos `es-AR`, tolerancia de redondeo a peso, detección de repregunta y de negativa) en `frontend/__tests__/ai-copilot-evals.test.ts`.
- [x] 5.3 `scripts/ai/copilot-evals.ts` (Deno, a mano, nunca en CI): llama a la función con el JWT de una cuenta de prueba, ejecuta `rpc_check` con el mismo JWT, escribe `openspec/changes/ia-copilot-v2/evals/<fecha>-<modelo>.md` (aciertos, repreguntas, negativas, latencia media, tokens). Sin override de modelo por request (OQ-4): se cambia el secreto entre corridas. _Script escrito y con `deno check` limpio; no ejecutado (necesita la función desplegada)._
- [ ] **[PO]** 5.4 Correr la línea base con `gpt-4o-mini` y con cada candidato existente (task 0); fijar el default por resultado (criterio: mayor tasa de aciertos numéricos; a igualdad, menor latencia; costo informativo). Registrar la decisión en design §Notas del apply. _Corre el PO: `scripts/ai/copilot-evals.ts` con cada modelo (§12)._

### 6. Cierre de la tanda A

- [x] 6.1 Backend/frontend tests completos en verde (vitest del frontend incluye los núcleos), `tsc` sin errores nuevos, gates SQL del workflow en el orden real. _Vitest de lo tocado (339/339), `tsc` sin errores nuevos, gates SQL de la tanda, ACL y OCR en verde._
- [ ] 6.2 Verificación post-merge en prod (sólo `SELECT`): `MAX(version) = 20261095000001`, columnas, `ai_feedback` con RLS y ACLs, una sola definición de `rpc_reserve_ai_usage` con la rama nueva, cron, función `ai-copilot` activa.
- [x] 6.3 `CHANGES.md` (ficha) y `docs/pendientes-manuales-po.md` (fila del registro con hora ART).

## Tanda B — Frontend y retiro de la ruta vieja

### 7. Hook y datos

- [ ] 7.1 SAFETY NET: tests de `/copiloto-ia`, `use-ai-usage`, `query-keys` y los que nombran la ruta vieja (`__tests__/ai/*`, `__tests__/lib/server-paths-no-browser-session-store.test.ts`, `__tests__/lib/session-identity-services.test.ts`, middleware); registrar línea base.
- [ ] 7.2 RED `frontend/__tests__/hooks/use-copilot.test.tsx`: `askCopilot` arma el request con `getAuthHeaders()` (sin sesión → resultado `error` sin llamar), traduce cada forma cerrada (answer, clarification, fallback, 400, 401, 403, 429 cuota con `resetAt`, 429 ráfaga con `retryAfterSeconds`, 502, 503, red caída) a un resultado cerrado tipado (sin `any`); `useAskCopilot` invalida `aiUsage` y el historial sólo en `answer`/`clarification`; `useCopilotHistory` lee como máximo 50 turnos propios y la valoración de cada uno; `useSetAiFeedback` optimista con rollback. GREEN + TRIANGULATE + REFACTOR. Claves nuevas en `lib/query-keys.ts` con `accountId`.

### 8. Componentes y pantalla

- [ ] 8.1 RED `frontend/__tests__/CopilotoPage.test.tsx`: chat vacío con 6 sugerencias que envían la pregunta; respuesta con bloque «Miré: …»; botones «Me sirvió»/«No me sirvió» con `aria-pressed`, toggle y aviso si falla; contador «Te quedan N consultas»; en 0, envío deshabilitado con fecha de renovación; ráfaga con cuenta regresiva; fallback y errores con texto legible (nunca el del proveedor); «Nueva conversación» reinicia historial enviado, `thread_id` y estado de foco; ningún `supabase.auth.*`.
- [ ] 8.2 GREEN: `components/copilot/CopilotChat.tsx`, `CopilotMessage.tsx`, `CopilotSuggestions.tsx`, `CopilotQuotaBadge.tsx` y `app/(dashboard)/copiloto-ia/page.tsx` reescrita (PascalCase, tokens semánticos, componentes base, sin colores literales, sin `any`). TRIANGULATE + REFACTOR.
- [ ] 8.3 Arnés `app/dev-harness/copiloto-chat/` (intercepta `window.fetch` hacia `/functions/v1/ai-copilot` y el RPC de valoración: respuesta con `consulted`, repregunta, cuota agotada, ráfaga, fallback) y `e2e/harness/copiloto-visual.spec.ts`; capturas en desktop y 360 px, claro y oscuro; sin desborde horizontal; contraste AA (gate `token-contrast-aa`).

### 9. Retiro de la ruta vieja (D14)

- [ ] 9.1 Grep de `api/ai/copilot`, `buildBusinessSnapshot`, `buildAdaptiveContext`, `AI_SYSTEM_PROMPT`, `aiCopilotService`, `analyzePricingInQuestion` en `frontend/` y `supabase/`; listar cada caller.
- [ ] 9.2 Borrar `app/api/ai/copilot/route.ts`, `lib/ai/buildBusinessSnapshot.ts`, `lib/services/aiCopilotService.ts`, `__tests__/ai/buildBusinessSnapshot.test.ts`, `__tests__/ai/copilot-server-identity.test.ts`; ajustar los tests que los usan como ejemplo y los comentarios de `lib/reporting/kpi-summary.ts`, `lib/reporting/product-ranking.ts`, `lib/auth/route-access.ts`; conservar `pricingService` si tiene otros consumidores.
- [ ] 9.3 Suite completa del frontend, `tsc` y e2e de arnés en verde.

### 10. Cierre

- [ ] 10.1 Revisión del diff contra las specs (`ai-copilot`, `ai-feedback`, `ai-canonical-metrics`, `ai-usage-counters`, `plan-gating`) y `openspec validate ia-copilot-v2 --strict`.
- [ ] 10.2 `CHANGES.md` y `docs/pendientes-manuales-po.md`: humo real del PO pendiente (5 preguntas reales en `/copiloto-ia` en mobile y desktop, una valoración, ver el contador bajar de N a N-1).
- [ ] 10.3 Candidatos registrados en `CHANGES.md`: lecturas canónicas de caja/banco y de productos sin movimiento para el Copiloto; migrar las demás funciones de IA a la reserva atómica; borrar historial del Copiloto (OQ-5); retención del registro (OQ-7).
