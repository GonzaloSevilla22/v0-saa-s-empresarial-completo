## Context

### Pedido

El pedido es el hallazgo **H-11** del Roadmap v3.1: *«`invoice-ocr` sin techo de costo + sin rate limiting → DoS/costo OpenAI»*. Tiene prioridad P1, governance MEDIO y esfuerzo M. Lo pide el PO dentro de la corrida autónoma del 2026-11-04 («continuando con los changes 1 por 1 y que siempre vayas con lo recomendado»).

### Estado vivo (código en `main` = `54f7db46` y prod, 2026-11-05, sólo lectura)

- **El handler.** `supabase/functions/invoice-ocr/index.ts` (303 líneas) corre en este orden:
  1. Autentica el JWT del usuario y valida `document_id` con `parseInvoiceOcrRequest`.
  2. Carga la fila de `invoice_documents` filtrada por `user_id`, y `resolveInvoiceDownload` decide entre 404/409 y qué objeto bajar.
  3. Marca la fila `processing`.
  4. Descarga el objeto con service role y lo convierte a base64 con `btoa(String.fromCharCode(...bytes))`.
  5. Si no es `image/*`, responde 422.
  6. Llama a OpenAI: modelo `INVOICE_AI_MODEL ?? 'gpt-4o-mini'`, `detail: 'high'`, `max_tokens: 2000`, `response_format: json_object`, timeout de 55 s.
  7. Persiste el resultado en la fila.

  No consulta ninguna cuota y no limita ni bytes ni frecuencia.
- **El núcleo puro.** `_shared/invoice-ocr-core.ts` se testea con vitest (`frontend/__tests__/invoice-ocr-core.test.ts`). Es el único arnés de Edge Functions del repo: no hay tests Deno.
- **La cuota del resto de la IA.** `_shared/ai-quota.ts` tiene dos piezas:
  - `checkAiQuota`: lee `profiles.ai_*_used` y `plan_limits.max_ai_*_per_month` contra el plan de `rpc_my_effective_plan()`, y es **fail-open** si no puede leer.
  - `incrementAiUsage`: llama a `rpc_increment_ai_usage(p_user_id, p_counter)` **después** del éxito. La RPC es `SECURITY DEFINER`, exige `p_user_id = auth.uid()` y acepta `'queries'` o `'advice'`.

  `ai-estadisticas` es el molde de «incrementar sólo si se persistió».
- **Prod:**
  - **Uso del OCR:** 2 documentos en toda la historia, de mayo de 2026 y de un solo usuario. 0 en los últimos 90 días. El único completado lo leyó `gpt-4o-mini` en 10,4 s.
  - **`plan_limits`:** queries 5/30/120/300 y advice 3/15/60/150.
  - **Cron `reset-ai-counters`:** `0 0 1 * *` (UTC), y sólo resetea `ai_queries_used`/`ai_advice_used`/`usage_reset_at`.
  - **Privilegios sobre `profiles`:** `authenticated` no tiene privilegio de UPDATE, ni de tabla ni de columna.
  - **Policy de `invoice_documents`:** `invoice_documents_update` deja al dueño reescribir sus filas, incluido `status`.
  - **Bucket `invoices`:** 20 MiB, y admite PDF.
- **Frontend.** El OCR se usa sólo desde `/compras`, con el botón «Subir factura IA» (`components/invoice/InvoiceAIButton.tsx` → `invoiceOcrService.processInvoice`). El cliente ya comprime a JPEG de 2048 px de lado mayor y calidad 0,85, pero si la compresión falla sube el original. `useAiUsage()` muestra queries/advice. `StatisticsAiPanel` es el molde de UI de cuota: saldo junto al botón, deshabilitado en 0, y `quota_exceeded` traducido.

### Hallazgos que cambian el diseño

1. **Carrera de chequear y después incrementar.** El chequeo y el incremento son dos pasos separados por la llamada a OpenAI, de 10 s o más. Una ráfaga concurrente pasa entera el chequeo. Para el OCR, la cuota se **reserva** con un `UPDATE` condicional antes de la llamada.
2. **El estado del documento no es un guard.** El dueño puede reescribir `status` por PostgREST. El candado de «en proceso» sirve contra el doble clic, no contra el abuso. El abuso lo frena el contador del usuario, que ningún rol de cliente puede escribir.
3. **El costo de tokens no crece con los bytes.** OpenAI reescala la imagen en `detail: 'high'` a un máximo fijo de tiles. El techo de costo *por llamada* ya lo fijan el reescalado y `max_tokens`. El techo de costo *total* es cantidad de llamadas × costo por llamada, y por eso la palanca es la cuota más la ráfaga. El tope de bytes protege memoria y latencia.
4. **No hace falta Redis.** `v4-backend-07` (`CHANGES.md`) dice que reusará «la primitiva de token bucket de `v31-ia-ratelimit-budget`» sobre Redis. Para una Edge Function en Deno, Redis implicaría Upstash REST: un secreto nuevo, otra dependencia de red en el camino crítico, y además no sería atómico con el contador mensual, que vive en Postgres. La primitiva de este change es **Postgres**. La dependencia de `v4-backend-07` se re-scopea en `CHANGES.md`: el middleware ASGI tendrá su propio bucket en Redis y no hereda nada de acá.

### Restricciones

- **DEC-15:** la IA y el OCR siguen en Edge Functions. El backend Python no se toca.
- **Reutilizar antes que repetir:** se extienden `ai-quota.ts`, `plan_limits`, `profiles` y `useAiUsage` en vez de abrir un mecanismo paralelo.
- **Cuenta activa:** el plan sale de `rpc_my_effective_plan()`, que resuelve con `current_account_ids()`. No se elige cuenta por fuera.
- **Columnas de privilegio:** las columnas nuevas de `profiles` nacen sin privilegio de escritura para `anon`/`authenticated`, igual que las existentes. El gate lo verifica.
- **Tamaño:** una sola tanda de apply, un agente, unas horas.

## Goals / Non-Goals

**Goals:**

- Que ningún usuario pueda pasar de N lecturas de factura por mes, con N según su plan, ni de 3 por minuto, **aun con pedidos concurrentes**.
- Que ninguna llamada procese una imagen de más de 6 MiB ni use un modelo fuera de la allow-list.
- Que el usuario vea en `/compras` cuántas lecturas le quedan y entienda cada rechazo.
- Dejar una primitiva de reserva atómica reutilizable para los contadores `queries`/`advice`, sin migrarlos ahora.

**Non-Goals:**

- **No** se migran las otras 9 funciones de IA a la reserva atómica. La carrera de `checkAiQuota` queda como candidato en `CHANGES.md` (`v3-ia-hygiene-baseline` / H-20).
- **No** hay cuota por cuenta: es por usuario, como los contadores existentes (OQ-5).
- **No** hay telemetría de tokens ni de costo por llamada: eso es H-20, `v31-ia-telemetry-evals`.
- **No** hay rate limiting general del backend: eso es `v4-backend-07`.
- **No** se agrega soporte de PDF. El bucket lo sigue admitiendo y la función lo sigue rechazando con 422. Alinear el bucket es candidato.
- **No** hay superficie de administración: el admin de plataforma no ve el uso de OCR por usuario. Queda declarado y pasa a H-20.
- **No** se devuelve la reserva cuando OpenAI falla (OQ-2).
- **No** hay backfill: el contador nace en 0 para todos.

## Decisions

### D1. Contador y límite propios para el OCR

Columnas nuevas:

- `profiles.ai_ocr_used integer NOT NULL DEFAULT 0`;
- `plan_limits.max_ai_ocr_per_month integer NOT NULL`, sembrado en gratis 5 · inicial 30 · avanzado 120 · pro 300 (OQ-1).

El plan efectivo se resuelve igual que el resto de la IA.

**Alternativa descartada: consumir `queries`.** Una lectura de factura cuesta un orden de magnitud más que una consulta de texto. Además, el usuario que lee facturas se quedaría sin Copiloto y sin Tablero IA, y el reporte de uso no distinguiría una cosa de la otra. La KB (`03_actores_y_roles.md`) ya lista «OCR Facturas» como feature aparte.

**Costo estimado (no verificado contra la factura de OpenAI).** Con `gpt-4o-mini` en `detail: 'high'` sobre una imagen de 2048 px, una llamada cuesta del orden de US$0,005. Pro, con 300 lecturas, da del orden de US$1,5 por usuario y por mes. La telemetría real es de H-20.

### D2. Reserva atómica: `rpc_reserve_ai_usage(p_counter text) RETURNS jsonb`

La RPC es `SECURITY DEFINER`, con `SET search_path = ''`. Hace `REVOKE ALL` de `PUBLIC`/`anon` y `GRANT EXECUTE` a `authenticated`. Pasos:

1. `v_uid := auth.uid()`. Si es `NULL`, lanza `P0401`.
2. `p_counter` tiene que ser `'ocr'`. Cualquier otro valor lanza `22023`: hoy no hay otra rama, y la firma con contador queda como punto de extensión para `queries`/`advice`.
3. Toma `v_plan := public.rpc_my_effective_plan()` y lee `v_limit` de `plan_limits`. Si el límite falta, lanza `P0503` (fail-closed).
4. Ejecuta **un solo** `UPDATE public.profiles … WHERE id = v_uid AND ai_ocr_used < v_limit AND (ventana vencida OR ai_ocr_window_count < 3) RETURNING …`. El `UPDATE` incrementa `ai_ocr_used` y, en la misma sentencia, avanza la ventana (D3).
5. Si hay fila, devuelve `{allowed: true, used, limit, reset_at}`.
6. Si no la hay, relee la fila (sin lock) y responde en este orden de precedencia:
   - `used >= limit` → `{allowed: false, reason: 'quota_exceeded', used, limit, reset_at}`;
   - si no, → `{allowed: false, reason: 'rate_limited', retry_after_seconds}`;
   - si no hay perfil, → `P0503`.

`reset_at` es la **próxima** renovación, `date_trunc('month', now() AT TIME ZONE 'UTC') + interval '1 month'` (el cron corre a las 00:00 UTC del día 1), expresada como instante UTC. Esto difiere a propósito de `checkAiQuota`, que devuelve `usage_reset_at`, es decir el *último* reset. Esa ambigüedad queda como candidato.

La atomicidad la da el `UPDATE` condicional: dos transacciones concurrentes sobre la misma fila se serializan por el lock de fila, y la segunda reevalúa el `WHERE` sobre la versión ya incrementada (READ COMMITTED). **No** hay `SELECT … FOR UPDATE` más `UPDATE` en dos pasos.

**Alternativa descartada: reusar `rpc_increment_ai_usage` antes de la llamada.** Seguiría siendo chequear y después incrementar, porque la RPC no compara contra el límite.

### D3. Ráfaga: ventana fija de 60 s y 3 lecturas, en `profiles`

Columnas: `ai_ocr_window_started_at timestamptz NULL` y `ai_ocr_window_count integer NOT NULL DEFAULT 0`. Dentro del `UPDATE` de D2:

- si `ai_ocr_window_started_at IS NULL OR ai_ocr_window_started_at <= now() - interval '60 seconds'`, la ventana arranca de nuevo (`started_at = now()`, `count = 1`);
- si no, `count = count + 1`, y sólo si `count < 3`.

`retry_after_seconds = ceil(60 - extract(epoch FROM now() - started_at))`, con mínimo 1.

Las constantes van como literales comentados en la RPC; no se pueden configurar por plan (OQ-4).

**Alternativas descartadas:**

- **Token bucket en Upstash:** ver el hallazgo 4.
- **Contar `invoice_documents.created_at` del último minuto:** la fila la inserta el cliente y el estado lo puede reescribir. Además, un reintento sobre la misma fila no crea fila nueva.

### D4. Techo por llamada en el núcleo puro

En `_shared/invoice-ocr-core.ts`, todo sin `Deno.*` y testeable con vitest:

- `MAX_INVOICE_IMAGE_BYTES = 6 * 1024 * 1024` (OQ-6). `checkInvoiceImageBudget(byteLength)` devuelve `{ ok:true }` o `{ ok:false, status:413, error:'La imagen supera 6 MB. Sacá la foto de nuevo o recortala.' }`. Se aplica sobre los bytes **descargados**, no sobre `file_size_bytes`, que lo declara el cliente.
- `resolveOcrModel(envValue)` aplica la allow-list `['gpt-4o-mini', 'gpt-4o']`. Si el valor no está en la lista, o está vacío, devuelve `'gpt-4o-mini'` con un `warning` que el handler loguea.
- `encodeBase64Chunked(bytes)` usa `String.fromCharCode` por bloques de 32 KiB y un solo `btoa`. Es lo mismo que hace hoy, sin el spread de N argumentos.
- `resolveInvoiceDownload` suma el candado de doble clic: con `status === 'processing'` y `updated_at` de hace menos de 90 s, responde **409** «La factura ya se está leyendo». Pasados 90 s, una fila colgada en `processing` se puede reintentar. El `SELECT` del handler suma `updated_at`. El candado no es un guard (hallazgo 2), y el spec lo dice.
- `max_tokens: 2000`, `detail: 'high'` y el timeout de 55 s quedan como constantes nombradas del núcleo (`OCR_MAX_OUTPUT_TOKENS`, `OCR_IMAGE_DETAIL`, `OCR_TIMEOUT_MS`), sin cambiar sus valores. Se conserva `detail: 'high'` porque la legibilidad de una factura lo necesita y el costo ya está acotado (OQ-7).

### D5. Orden del handler: rechazos baratos primero y la reserva justo antes de OpenAI

1. Auth.
2. Parse.
3. Carga de la fila y `resolveInvoiceDownload` (404/409).
4. Descarga.
5. MIME: si no es `image/*`, responde 422 y la fila queda `failed`, como hoy.
6. `checkInvoiceImageBudget`: si falla, responde 413 y la fila queda `failed`, con el mensaje.
7. `OPENAI_API_KEY` presente.
8. **`reserveAiUsage(supabase, 'ocr')`**:
   - denegada → 429, y la fila **no se toca**: sigue `pending` y se puede reintentar cuando haya cupo;
   - no disponible → 503, y la fila tampoco se toca.
9. Marca `processing`. Se mueve desde antes de la descarga hasta acá, para que un 429 no deje la fila «en proceso».
10. OpenAI.
11. Persistencia.

Una reserva concedida **no se devuelve**, aunque OpenAI falle o la respuesta no se pueda parsear (OQ-2). OpenAI factura la llamada igual, y una devolución abriría la puerta a lecturas gratis forzando fallos.

### D6. `reserveAiUsage` en `_shared/ai-quota.ts`

Se agrega `reserveAiUsage(supabase, counter: 'ocr')`. El tipo `AiQuotaClient` suma el overload `rpc('rpc_reserve_ai_usage', { p_counter })`, sin `any`. La función devuelve una unión discriminada:

- `{ kind: 'allowed' }`;
- `{ kind: 'denied', status: 429, body, retryAfterSeconds? }`, donde `body` es `{ ok:false, error:'quota_exceeded', resetAt, used, limit }` o `{ ok:false, error:'rate_limited', retryAfterSeconds }`;
- `{ kind: 'unavailable', status: 503, body: { ok:false, error:'quota_unavailable' } }`.

Si la RPC devuelve error, o devuelve un `jsonb` con otra forma, el resultado es `unavailable`: el OCR es **fail-closed** (OQ-3), a diferencia de `checkAiQuota`, que es fail-open. El mapeo de datos a resultado es una función pura exportada, `mapAiReservation(data, error)`. El handler agrega `Retry-After` cuando `retryAfterSeconds` está presente.

`checkAiQuota` e `incrementAiUsage` no cambian.

### D7. Reset mensual

La migración reprograma `reset-ai-counters` con el mismo nombre y el mismo schedule, con `cron.unschedule` y `cron.schedule` en el orden de `20260606100000_ai_usage_counters.sql`. El comando nuevo es `UPDATE public.profiles SET ai_queries_used = 0, ai_advice_used = 0, ai_ocr_used = 0, ai_ocr_window_count = 0, ai_ocr_window_started_at = NULL, usage_reset_at = now()`. El gate assertea el comando vivo de `cron.job`.

### D8. Superficie frontend en `/compras`

La entrada es el botón «Subir factura IA», que ya existe en `/compras` (menú de Compras). No cambian ni la ruta ni el menú.

- **Datos.** `useAiUsage()` suma `ocrUsed` y `ocrRemaining` (con piso 0) al `select` de `profiles`. `usePlanLimits()` y el fallback de `lib/constants.ts` suman `maxAiOcrPerMonth`.
- **Fecha de renovación.** `lib/ai-usage.ts` (nuevo, capa canónica) aloja `nextAiResetDate(now)`, la misma regla que el servidor (D2), y su formato es-AR.
- **`OcrQuotaNotice`** (componente nuevo, `components/invoice/OcrQuotaNotice.tsx`) va bajo el título del diálogo:
  - con saldo, muestra «Te quedan N lecturas de factura este mes»;
  - en 0, muestra «Usaste las N lecturas de factura de tu plan este mes. Se renuevan el 1 de diciembre.», reemplaza la zona de subida y ofrece «Ver planes» → `/planes`.

  Usa tokens semánticos (`text-muted-foreground`, `bg-muted`, la variante `warning` existente de `Alert`, si la hay) y nada de colores literales.
- **Errores.** `invoiceOcrService` deja de usar `(fnErr as any)`. Lee `context.response` con un guard de tipo (`unknown` → `hasResponse`) y lanza `InvoiceOcrError` (clase con `code: 'quota_exceeded' | 'rate_limited' | 'image_too_large' | 'quota_unavailable' | 'other'`, más `retryAfterSeconds?`/`resetAt?`). `InvoiceAIButton` traduce el código: «Esperá N segundos y volvé a intentar», «La imagen supera 6 MB», «No pudimos verificar tu cupo, intentá en un rato».
- **Refresco.** Después de cada intento que pasó la reserva, o de un 429, se invalida `["aiUsage", user.id]`.
- **Verificación.** Desktop y mobile (375 px), tema claro y oscuro, en el diálogo con saldo, en 0 y con error.

### D9. Documentación

- `CLAUDE.md`, tabla de stack: el OCR usa `gpt-4o-mini` por defecto (`INVOICE_AI_MODEL`, allow-list `gpt-4o-mini`/`gpt-4o`). Se corre `python scripts/ci/check_docs_sync.py --fix` para regenerar `AGENTS.md`.
- `knowledge-base/05_reglas_de_negocio.md`: RN-54 nueva, «Cuota y ráfaga del OCR».
- `knowledge-base/03_actores_y_roles.md`: fila «Lecturas de factura IA/mes» en la tabla de límites.
- `CHANGES.md`:
  - ficha del change;
  - re-scope de la dependencia de `v4-backend-07` (hallazgo 4);
  - candidatos: la carrera de `checkAiQuota` en las otras 9 funciones; el `resetAt` ambiguo; PDF en el bucket.

## Risks / Trade-offs

- **[Una llamada fallida consume cupo]** → con `gratis` = 5, dos fallos de OpenAI le cuestan al usuario el 40 % del mes. Mitigación: los rechazos de entrada (404/409/413/422) no consumen, la ráfaga es corta, y el PO puede subir el límite con un `UPDATE` de `plan_limits`, sin deploy.
- **[Fail-closed ante un error de la RPC]** → si la RPC falla, nadie puede leer facturas. Mitigación: es una sola sentencia sobre `profiles`; si la base no responde, la función tampoco puede escribir `invoice_documents`, así que el modo fail-open no compraría disponibilidad real.
- **[Cuota por usuario, no por cuenta]** → una cuenta pro con 10 usuarios suma 3.000 lecturas por mes. Se acepta por consistencia con queries/advice. Pasarla a cuenta es de H-20 o de `v3-ia-hygiene-baseline`.
- **[Ventana fija]** → permite hasta 6 lecturas en ~2 s en el borde entre dos ventanas. Se acepta: el techo mensual es el que acota el costo.
- **[Reloj]** → todo usa `now()` de la base. El reloj de la Edge Function no interviene.
- **[El candado de 90 s]** → una lectura legítima que tarda más de 90 s (el timeout es de 55 s) no puede quedar en carrera consigo misma, así que no hay falso desbloqueo.

## Migration Plan

1. Migración `20261090000001_ia_ocr_cuota_reserva.sql`, idempotente:
   - `ADD COLUMN IF NOT EXISTS` ×3 en `profiles` y ×1 en `plan_limits`;
   - el valor de cada plan, con `UPDATE` por plan;
   - después, `SET NOT NULL`;
   - `CREATE OR REPLACE FUNCTION rpc_reserve_ai_usage` con `REVOKE`/`GRANT` en el mismo archivo;
   - `COMMENT ON FUNCTION`;
   - reprogramación del cron.
2. **Deploy.** El merge dispara `deploy.yml`: `supabase db push --include-all` y después `functions deploy`. La migración entra antes que la función. La función vieja ignora las columnas nuevas, y la nueva exige la RPC, que ya existe para ese momento.
3. **Verificación post-merge**, en prod y sólo lectura:
   - `max(version) = '20261090000001'`;
   - las 4 columnas, con los valores del seed;
   - las ACL de la RPC (`anon` sin `EXECUTE`);
   - el comando vivo del cron;
   - `authenticated` sin UPDATE sobre las columnas nuevas.
4. **Humo del PO.** Leer una factura real en `/compras` y ver el saldo bajar de N a N-1.

**Rollback:**

- Revertir el PR vuelve a desplegar la función anterior, sin cuota.
- Las columnas y la RPC son aditivas y pueden quedar.
- Para aflojar sin revertir: `UPDATE plan_limits SET max_ai_ocr_per_month = …`, como fix de datos con el OK del PO.

## Open Questions

Cada OQ trae una opción recomendada. Todas quedan resueltas por esa opción (ver «Sign-off del PO»).

- **OQ-1, límites mensuales por plan.**
  - (a) **Recomendada:** gratis 5 · inicial 30 · avanzado 120 · pro 300, el espejo de `queries`. Un solo número por plan, fácil de explicar, y del orden de US$1,5 por usuario pro por mes.
  - (b) Más bajos, por ejemplo 3/15/60/150, el espejo de `advice`.
- **OQ-2, ¿una llamada que falla consume cupo?**
  - (a) **Recomendada:** sí, sin devolución. OpenAI cobra igual, y la devolución abre un bucle de abuso.
  - (b) Devolver si OpenAI respondió con error o timeout.
- **OQ-3, si la reserva no se puede resolver.**
  - (a) **Recomendada:** fail-closed, 503 `quota_unavailable`.
  - (b) Fail-open, como `checkAiQuota`.
- **OQ-4, ráfaga.**
  - (a) **Recomendada:** 3 lecturas cada 60 s por usuario, fijo.
  - (b) 5 por minuto.
  - (c) Configurable por plan en `plan_limits`.
- **OQ-5, alcance de la cuota.**
  - (a) **Recomendada:** por usuario, como los contadores existentes.
  - (b) Por cuenta, lo que exige un contador nuevo en `accounts` y diverge del resto de la IA.
- **OQ-6, tope de imagen.**
  - (a) **Recomendada:** 6 MiB sobre los bytes descargados. El cliente ya comprime a ~1–2 MB; los 6 MiB dejan margen para el original cuando la compresión falla.
  - (b) 10 MiB.
  - (c) Alinear también el bucket a 6 MiB (`storage.buckets.file_size_limit`). Fuera de alcance; queda como candidato.
- **OQ-7, `detail` de la imagen.**
  - (a) **Recomendada:** conservar `'high'`. La legibilidad de los ítems lo necesita, y el costo está acotado por el reescalado.
  - (b) `'auto'`.
- **OQ-8, tope de gasto en OpenAI.**
  - (a) **Recomendada:** el PO configura un tope mensual de gasto en el proyecto de OpenAI, como red de último recurso. Es un paso manual, no bloquea y se anota en `docs/pendientes-manuales-po.md`.
  - (b) No configurarlo.

### Sign-off del PO

**Sign-off del PO 2026-11-04: OQ-1..OQ-8 se resuelven por su opción recomendada (mandato general de la corrida autónoma).** El PO firmó por escrito: «continuando con los changes 1 por 1 y que siempre vayas con lo recomendado». Resolución:

- **OQ-1 (a):** límites 5/30/120/300 en `plan_limits.max_ai_ocr_per_month`.
- **OQ-2 (a):** la reserva concedida no se devuelve.
- **OQ-3 (a):** fail-closed, con 503 `quota_unavailable`.
- **OQ-4 (a):** 3 lecturas por cada 60 s y por usuario, ventana fija.
- **OQ-5 (a):** la cuota es por usuario.
- **OQ-6 (a):** 6 MiB sobre los bytes descargados; el bucket no se toca.
- **OQ-7 (a):** se conserva `detail: 'high'`.
- **OQ-8 (a):** paso manual recomendado en `docs/pendientes-manuales-po.md` (tope de gasto en el proyecto de OpenAI). Aplica como recomendación salvo objeción del PO, y no bloquea el apply.

No se eligió ninguna alternativa distinta de la recomendada, así que no hay decisión, spec ni task que reescribir.
