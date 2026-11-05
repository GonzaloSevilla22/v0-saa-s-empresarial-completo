# Tasks: v31-ia-ratelimit-budget

Una sola tanda de apply, con un solo agente. TDD estricto: cada grupo arranca en RED con su archivo de test nombrado, y el apply se hace en un worktree con rama `opsx/v31-ia-ratelimit-budget-apply`. Todo commit va por PR; nunca a `main`.

## 0. Sign-off y checkpoints previos (sólo lectura)

- [ ] 0.1 **[PO]** Sign-off de OQ-1..OQ-8 por su opción recomendada, según el mandato del 2026-11-04 (`design.md` §Sign-off del PO). Ya registrado; el apply sólo verifica que nada lo contradiga.
- [ ] 0.2 Confirmar que el número de migración `20261090000001` sigue libre, contra `MAX(version)` de prod y contra `ls supabase/migrations | tail` en `main`. Si se ocupó, renumerar al siguiente libre y actualizar `proposal.md`/`design.md` en el mismo PR.
- [ ] 0.3 **Checkpoint de cuerpo vivo.** Tomar de prod `pg_get_functiondef` de `rpc_my_effective_plan()` y `rpc_increment_ai_usage(uuid,text)`, y el `command` de `cron.job` `reset-ai-counters`. La RPC nueva llama a la primera tal como está; el cron se reprograma partiendo del comando vivo. Comparar por líneas sin CR.
- [ ] 0.4 Re-medir las cifras de `proposal.md` con `SELECT` en prod: documentos por mes, `plan_limits`, privilegios de `authenticated` sobre `profiles`. Si algo cambió, actualizar el `design.md`.
- [ ] 0.5 **Safety net**, baseline registrado de cuatro corridas:
  - `pnpm vitest run __tests__/invoice-ocr-core.test.ts __tests__/ai-quota.test.ts`;
  - los tests existentes de `use-ai-usage`/`use-plan-limits`/`InvoiceAIButton`, si los hay;
  - `__tests__/StatisticsAiPanel.test.tsx`;
  - `tsc --noEmit`, sin errores nuevos.

## 1. Base de datos: columnas, reserva atómica y reset

- [ ] 1.1 **RED**: escribir el gate `supabase/tests/test_ia_ocr_cuota_reserva.sql`, con fixtures propios y cleanup asertado. Debe fallar antes de la migración. Bloques:
  - (a) las columnas `profiles.ai_ocr_used`/`ai_ocr_window_count`/`ai_ocr_window_started_at` y `plan_limits.max_ai_ocr_per_month`, con el seed 5/30/120/300;
  - (b) `authenticated` sin privilegio de `UPDATE`/`INSERT` sobre esas columnas;
  - (c) ACL de `rpc_reserve_ai_usage(text)`: `anon` y `PUBLIC` sin `EXECUTE`, `authenticated` con `EXECUTE`;
  - (d) la reserva con cupo concede e incrementa;
  - (e) `used = limit` → `quota_exceeded` sin incremento;
  - (f) la cuarta reserva dentro de 60 s → `rate_limited` con `retry_after_seconds >= 1` y sin incremento;
  - (g) ventana vencida, simulando `started_at = now() - 61 s` → concede y deja `count = 1`;
  - (h) `p_counter = 'queries'` → `22023`; sin `auth.uid()` → `P0401`;
  - (i) el plan lo da `rpc_my_effective_plan()`: una cuenta `pro` con perfil `gratis` usa el límite 300;
  - (j) el comando vivo de `cron.job` `reset-ai-counters` incluye `ai_ocr_used = 0`, `ai_ocr_window_count = 0`, `ai_ocr_window_started_at = NULL`;
  - (k) la RPC se **ejecuta** de verdad (regla del proyecto: un gate que ejecuta, no que sólo verifica que existe);
  - (l) concurrencia: con cupo 1 y dos reservas en transacciones separadas, se concede una sola. Hacerlo con `dblink` si está disponible en el stack local; si no, documentar el razonamiento de READ COMMITTED y cubrir el caso con dos llamadas secuenciales en el borde.
- [ ] 1.2 **GREEN**: escribir la migración `supabase/migrations/20261090000001_ia_ocr_cuota_reserva.sql`, idempotente, en LF:
  - `ADD COLUMN IF NOT EXISTS`, después `UPDATE` del seed por plan, después `SET NOT NULL`;
  - `CREATE OR REPLACE FUNCTION public.rpc_reserve_ai_usage(p_counter text) RETURNS jsonb` según D2/D3, `SECURITY DEFINER`, con `SET search_path = ''`;
  - `REVOKE ALL … FROM PUBLIC, anon` y `GRANT EXECUTE … TO authenticated` en el mismo archivo;
  - `COMMENT ON FUNCTION`;
  - `cron.unschedule` y `cron.schedule('reset-ai-counters', '0 0 1 * *', …)` con el comando de D7, en el orden de `20260606100000_ai_usage_counters.sql`.
- [ ] 1.3 Correr el gate contra `supabase db reset` local, en verde. Reaplicar la migración dos veces y verificar que es idempotente.
- [ ] 1.4 Cablear el gate en `.github/workflows/KPI_Validation.yml`, con un step `psql -v ON_ERROR_STOP=1 … -f supabase/tests/test_ia_ocr_cuota_reserva.sql` y un comentario con el change. Revisar los bloques de reaplicación del workflow: si alguno fija el cuerpo del cron o de `plan_limits`, aplicar su regla.

## 2. Núcleo compartido: presupuesto de imagen, modelo, base64, candado y reserva

- [ ] 2.1 **RED**: extender `frontend/__tests__/invoice-ocr-core.test.ts` con estos casos:
  - `checkInvoiceImageBudget`: 6 MiB exactos pasan, 6 MiB + 1 byte → 413, 0 bytes → 413 o 422 según se defina;
  - `resolveOcrModel`: `undefined`/`''`/`'gpt-4.1'` → `gpt-4o-mini` con `warning`; `'gpt-4o'` → `gpt-4o` sin `warning`;
  - `encodeBase64Chunked`: idéntico a `Buffer.from(bytes).toString('base64')` para 0 B, 1 B, 32 KiB ± 1 y 5 MiB, sin lanzar;
  - `resolveInvoiceDownload`: `processing` con `updated_at` de hace 5 s → 409 «La factura ya se está leyendo»; `processing` de hace 120 s → ok; `failed` → ok; `completed` → 409, como hoy.
- [ ] 2.2 **GREEN**: implementar en `supabase/functions/_shared/invoice-ocr-core.ts`, sin `Deno.*`:
  - las constantes nombradas `MAX_INVOICE_IMAGE_BYTES`, `OCR_ALLOWED_MODELS`, `OCR_DEFAULT_MODEL`, `OCR_MAX_OUTPUT_TOKENS = 2000`, `OCR_IMAGE_DETAIL = 'high'`, `OCR_TIMEOUT_MS = 55_000` y `OCR_PROCESSING_LOCK_MS = 90_000`;
  - las cuatro funciones;
  - `updated_at` en `InvoiceDocumentRow`.

  `resolveInvoiceDownload` recibe `now` inyectable para el test.
- [ ] 2.3 **RED**: extender `frontend/__tests__/ai-quota.test.ts` para `mapAiReservation`/`reserveAiUsage` con un doble de `rpc`:
  - `allowed`;
  - `quota_exceeded` → 429 con `{ok:false,error:'quota_exceeded',resetAt,used,limit}`;
  - `rate_limited` → 429 con `retryAfterSeconds`;
  - error de la RPC → 503 `quota_unavailable`;
  - `jsonb` con forma inesperada → 503.

  Además, verificar que `reserveAiUsage` llama a `rpc('rpc_reserve_ai_usage', { p_counter: 'ocr' })` y que `checkAiQuota`/`incrementAiUsage` siguen pasando sus tests sin cambios.
- [ ] 2.4 **GREEN** y **REFACTOR**: implementar en `supabase/functions/_shared/ai-quota.ts`, con el overload tipado en `AiQuotaClient` (sin `any`). Correr los dos archivos de test en verde después de cada refactor.

## 3. Edge Function `invoice-ocr`

- [ ] 3.1 Reordenar `supabase/functions/invoice-ocr/index.ts` según D5:
  - el `SELECT` suma `updated_at`;
  - la marca `processing` se mueve a después de la reserva;
  - `checkInvoiceImageBudget` va sobre `uint8Array.length`, antes de codificar; si falla, la fila queda `failed` y responde 413;
  - `reserveAiUsage(supabase, 'ocr')`: denegada → 429 con el body y `Retry-After`, sin tocar la fila; no disponible → 503;
  - el modelo sale de `resolveOcrModel(Deno.env.get('INVOICE_AI_MODEL'))` y loguea el `warning`;
  - la codificación usa `encodeBase64Chunked`;
  - el body de OpenAI usa las constantes del núcleo;
  - `ai_model` persiste el modelo efectivamente usado;
  - `jsonResponse` acepta headers extra, para `Retry-After`.
- [ ] 3.2 Verificar con `deno check` desde una copia fuera del monorepo con `DENO_NO_PACKAGE_JSON=1` (gotcha registrado): sin errores nuevos en `invoice-ocr` ni en `_shared`.
- [ ] 3.3 Humo local con el stack de Supabase y `functions serve`, con una clave de OpenAI dummy:
  - un usuario sin cupo (`ai_ocr_used` = límite) recibe 429 y su fila sigue `pending`;
  - la cuarta llamada en menos de 60 s recibe 429 `rate_limited` con `Retry-After`;
  - una imagen de más de 6 MiB recibe 413;
  - con cupo, la reserva incrementa aunque OpenAI falle con la clave dummy (OQ-2).

  Registrar las salidas.

## 4. Frontend: cupo visible y errores tipados en `/compras`

- [ ] 4.1 **RED**: escribir `frontend/__tests__/lib/ai-usage.test.ts` para `nextAiResetDate(now)`, que devuelve el día 1 del mes siguiente a las 00:00 UTC. Casos: mediados de mes, 31 de diciembre → 1 de enero, y el instante exacto del reset. Incluye el formato es-AR.
- [ ] 4.2 **GREEN**: escribir `frontend/lib/ai-usage.ts`.
- [ ] 4.3 **RED**: extender los tests de `useAiUsage`/`usePlanLimits`, o crear `frontend/__tests__/hooks/use-ai-usage-ocr.test.tsx`: `ocrUsed`/`ocrRemaining` con piso 0, y `maxAiOcrPerMonth` desde `plan_limits` y desde el fallback de `lib/constants.ts`.
- [ ] 4.4 **GREEN**: tocar `hooks/auth/use-ai-usage.ts` (`select` con `ai_ocr_used`), `hooks/auth/use-plan-limits.ts`, `lib/constants.ts` (los 4 planes) y `lib/database.types.ts` (las columnas nuevas y la RPC).
- [ ] 4.5 **RED**: escribir `frontend/__tests__/lib/invoice-ocr-service-errors.test.ts`, que mapea la respuesta de `functions.invoke` a `InvoiceOcrError`:
  - 429 `quota_exceeded` → `code` y `resetAt`;
  - 429 `rate_limited` → `retryAfterSeconds`;
  - 413 → `image_too_large`;
  - 503 → `quota_unavailable`;
  - otro → `other` con el mensaje del body.

  El test también fija que no queda `as any`.
- [ ] 4.6 **GREEN**: implementar `InvoiceOcrError` en `lib/invoice-types.ts` y el guard de tipo en `lib/services/invoiceOcrService.ts`, en reemplazo de `(fnErr as any).context`.
- [ ] 4.7 **RED**: escribir `frontend/__tests__/components/OcrQuotaNotice.test.tsx` y extender el test del botón:
  - con saldo 18 muestra «Te quedan 18 lecturas de factura este mes»;
  - con saldo 0 oculta `InvoiceUploadZone` y muestra la fecha de renovación y «Ver planes» → `/planes`;
  - el error `rate_limited` muestra «Esperá 40 segundos y volvé a intentar»;
  - después de un intento se invalida `["aiUsage", userId]`.
- [ ] 4.8 **GREEN**: escribir `frontend/components/invoice/OcrQuotaNotice.tsx` (PascalCase, tokens semánticos, sin colores literales) y su integración en `components/invoice/InvoiceAIButton.tsx`.
- [ ] 4.9 Verificación visual del diálogo en `/compras`, en tres estados (con saldo, en 0 y con error de ráfaga) y en cuatro combinaciones: desktop y mobile a 375 px, tema claro y oscuro. Con el stack local o con un arnés de Playwright si no hay Docker. Nunca con el Browser pane sobre `/auth/login` de prod. Medir contraste AA del aviso.

## 5. Documentación y cierre

- [ ] 5.1 `CLAUDE.md`, tabla de stack, fila IA: `invoice-ocr` usa `gpt-4o-mini` por defecto (`INVOICE_AI_MODEL`, allow-list `gpt-4o-mini`/`gpt-4o`). Después, `python scripts/ci/check_docs_sync.py --fix` para regenerar `AGENTS.md` en el mismo PR.
- [ ] 5.2 KB:
  - `knowledge-base/05_reglas_de_negocio.md`: RN-54 «Cuota y ráfaga del OCR», que cubre cuota por plan, reserva previa sin devolución, 3 cada 60 s y 6 MiB;
  - `knowledge-base/03_actores_y_roles.md`: fila «Lecturas de factura IA/mes» 5/30/120/300.
- [ ] 5.3 `CHANGES.md`: actualizar la ficha (apply) y dar de alta los candidatos:
  - (a) la carrera chequear/incrementar de `checkAiQuota` en las otras 9 funciones → migrarlas a `rpc_reserve_ai_usage`;
  - (b) el `resetAt` de `checkAiQuota` es el último reset, no el próximo;
  - (c) el bucket `invoices` admite PDF y 20 MiB, contra los 6 MiB de la función;
  - (d) la visibilidad de admin del uso de OCR, que pasa a H-20.
- [ ] 5.4 Correr la suite completa: los tests del grupo 2 y del grupo 4, `StatisticsAiPanel`, `tsc --noEmit` sin errores nuevos y el gate SQL. Registrar los números en el PR.
- [ ] 5.5 Post-merge, sólo lectura en prod:
  - `max(version) = '20261090000001'`;
  - las columnas y el seed;
  - las ACL de la RPC;
  - el comando vivo del cron;
  - `authenticated` sin `UPDATE` sobre `profiles`;
  - la Edge Function desplegada (`list_edge_functions`, versión nueva).
- [ ] 5.6 **[PO]** Dos pasos manuales:
  - humo real: leer una factura en `/compras` y ver el saldo bajar de N a N-1;
  - tope de gasto mensual en el proyecto de OpenAI (OQ-8, no bloqueante, `docs/pendientes-manuales-po.md`).
