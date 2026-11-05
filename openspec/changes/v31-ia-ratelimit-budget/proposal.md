## Why

Hallazgo **H-11** del Roadmap v3.1 (`CHANGES.md`, mapa hallazgo → change, P1, governance MEDIO): la Edge Function `invoice-ocr` llama a OpenAI con visión **sin cuota, sin límite de ráfaga y sin techo de costo**. Es la única de las funciones de IA que no pasa por `_shared/ai-quota.ts`. Cualquier usuario autenticado, de cualquier plan (incluido `gratis`), puede disparar lecturas de factura en bucle. Cada lectura es la llamada más cara del producto: una imagen en `detail: 'high'` más hasta 2.000 tokens de salida. Hoy el único freno es el chequeo de tipo MIME.

El uso real es casi nulo, así que no hay datos que migrar ni hábitos que romper. Cerrarlo ahora es barato. Cerrarlo después de que el OCR se use a volumen, o de que alguien lo descubra, no lo es.

### Mediciones de prod (2026-11-05, sólo lectura, sin datos personales)

| Medida | Valor |
|---|---|
| `invoice_documents` totales | **2** (ambos de mayo de 2026, un solo usuario) |
| Documentos en los últimos 90 días | **0** |
| Máximo por usuario en un día | 2 |
| Estados | 1 `completed`, 1 abierto (`pending`/`processing`), 0 `failed` |
| `processing_ms` del único completado | 10.425 ms |
| Modelo registrado en `ai_model` | `gpt-4o-mini` (el default del código; `CLAUDE.md` dice `gpt-4o`: **la tabla de stack está desactualizada**, se corrige en este change) |
| Bucket `invoices` | `file_size_limit` = 20 MiB; admite `application/pdf` aunque la función lo rechaza con 422 |
| `plan_limits` (consultas / consejos IA por mes) | gratis 5/3 · inicial 30/15 · avanzado 120/60 · pro 300/150 |
| Cron `reset-ai-counters` | `0 0 1 * *`, `UPDATE public.profiles SET ai_queries_used = 0, ai_advice_used = 0, usage_reset_at = now()` |
| Escritura de `authenticated` sobre `profiles` | **ninguna** (sin privilegio de tabla ni de columna): los contadores sólo se mueven vía RPC `SECURITY DEFINER` |
| `invoice_documents` | policy de UPDATE para el dueño: el usuario puede reescribir `status` de sus filas desde PostgREST |
| Última migración aplicada | `20261089000001` |

### Hallazgos que cambian el diseño

1. **El patrón existente tiene una carrera.** `checkAiQuota` lee el contador y `incrementAiUsage` lo incrementa *después* de la llamada a OpenAI. N pedidos concurrentes leen todos el mismo `used < limit` y pasan todos. Para una consulta de texto de un centavo es tolerable. Para la llamada más cara del producto no lo es: la cuota tiene que **reservarse atómicamente antes** de llamar a OpenAI.
2. **El candado por documento no sirve de guard.** El dueño puede devolver su fila a `pending` por PostgREST y volver a procesarla. El guard real tiene que estar en el contador del usuario, no en el estado del documento.
3. **El costo de tokens por imagen ya está acotado por OpenAI.** Con `detail: 'high'`, OpenAI redimensiona cualquier imagen a un máximo fijo de tiles. Los bytes no suben los tokens. Lo que sí sube el costo es la **cantidad de llamadas**. El tope de bytes protege la memoria y la latencia de la función, no la factura de OpenAI.
4. **La conversión a base64 actual no escala.** Usa `btoa(String.fromCharCode(...uint8Array))`, que expande un argumento por byte. Para imágenes de varios MB eso arriesga un `RangeError`. No verificado contra prod (hay un solo documento completado); se reemplaza igual por codificación por bloques.

## What Changes

- **Cuota mensual propia para la lectura de facturas.** Columnas nuevas: `profiles.ai_ocr_used` como contador y `plan_limits.max_ai_ocr_per_month` como límite, sembrado en gratis 5 · inicial 30 · avanzado 120 · pro 300. El cron `reset-ai-counters` también la pone en cero.
- **Reserva atómica antes de llamar a OpenAI.** RPC nueva: `rpc_reserve_ai_usage(p_counter text)`, `SECURITY DEFINER`, con el usuario tomado de `auth.uid()` y el plan de `rpc_my_effective_plan()`. Hoy acepta sólo `'ocr'`. En un solo `UPDATE … WHERE … RETURNING` hace dos cosas:
  - comprueba la cuota del mes y el límite de ráfaga;
  - si pasan los dos chequeos, consume una unidad.

  La carrera queda cerrada por construcción.
- **Límite de ráfaga por usuario: 3 lecturas cada 60 segundos.** Es una ventana fija en dos columnas de `profiles`. Todo vive en Postgres: no hace falta Redis ni Upstash.
- **Techo de costo por llamada.** Se suman tres cosas a lo que ya había:
  - **Imagen:** un máximo de 6 MiB, medido sobre los bytes descargados (`file_size_bytes` lo declara el cliente) → 413.
  - **Modelo:** una allow-list `{gpt-4o-mini, gpt-4o}` para `INVOICE_AI_MODEL`. Un valor desconocido usa el default y queda logueado.
  - **Codificación:** base64 por bloques.

  Se conservan el `max_tokens: 2000` y el timeout de 55 s.
- **Orden del handler.** Primero los rechazos baratos, que no consumen cuota: 404/409/422/413. Después la reserva: si no hay cuota o hay ráfaga, responde 429 y el documento **no** pasa a `processing` ni a `failed`. Al final, OpenAI. La reserva no se devuelve si OpenAI falla, porque OpenAI cobra igual.
- **Contrato del 429.** Si se acabó la cuota: `{ ok:false, error:'quota_exceeded', resetAt, used, limit }`, la misma forma que el resto de la IA. Si hay ráfaga: `{ ok:false, error:'rate_limited', retryAfterSeconds }` con header `Retry-After`. Si la reserva no se puede resolver: **503 fail-closed**.
- **Superficie frontend** en `/compras`, botón «Subir factura IA», ya existente:
  - el diálogo muestra las lecturas que quedan este mes y la fecha de renovación;
  - con la cuota en cero, el diálogo explica por qué y no deja subir;
  - los errores 429/413/503 se traducen a mensajes claros;
  - `useAiUsage`/`usePlanLimits` exponen el contador nuevo.

  Se retira también el `(fnErr as any)` de `invoiceOcrService.ts`, que viola la regla de no usar `any`.
- `CLAUDE.md`: la fila de IA de la tabla de stack pasa a decir `gpt-4o-mini` por defecto en `invoice-ocr`, configurable por `INVOICE_AI_MODEL`.

Sin **BREAKING** para los usuarios: con 0 documentos en 90 días, nadie se acerca a los límites.

## Capabilities

### New Capabilities
- `invoice-ocr-budget`: cubre cuatro cosas:
  - cuota mensual de lecturas de factura por plan;
  - reserva atómica previa a OpenAI y límite de ráfaga;
  - techo de costo por llamada (imagen, modelo, tokens);
  - contrato de rechazo y su superficie en `/compras`.

### Modified Capabilities
- `ai-usage-counters`: el reset mensual incluye `ai_ocr_used`, y `useAiUsage()` expone el uso y el saldo de lecturas de factura.
- `plan-gating`: el requirement de cuota IA en todas las Edge Functions incorpora `invoice-ocr`, gobernada por la reserva atómica de `invoice-ocr-budget` en lugar del par chequear/incrementar.

## Impact

- **DB.** Migración `20261090000001_ia_ocr_cuota_reserva.sql`, que trae:
  - 3 columnas en `profiles`, 1 en `plan_limits` con su seed;
  - RPC `rpc_reserve_ai_usage` con `REVOKE` de `anon`/`PUBLIC` y `GRANT` a `authenticated`;
  - reprogramación del cron `reset-ai-counters`.

  Gate SQL nuevo, `supabase/tests/test_ia_ocr_cuota_reserva.sql`, cableado en `KPI_Validation.yml`.
- **Edge Functions.** `supabase/functions/invoice-ocr/index.ts`, `_shared/invoice-ocr-core.ts` (núcleo puro: presupuesto de imagen, allow-list de modelo y candado de procesamiento) y `_shared/ai-quota.ts` (`reserveAiUsage`).
- **Frontend.**
  - Servicio y tipos: `lib/services/invoiceOcrService.ts`, `lib/invoice-types.ts`, `lib/constants.ts`.
  - Hooks: `hooks/auth/use-ai-usage.ts`, `hooks/auth/use-plan-limits.ts`.
  - Componentes: `components/invoice/InvoiceAIButton.tsx` y el componente de cuota que se le sume.
  - Tipos de base: `lib/database.types.ts`.
- **Tests.** `frontend/__tests__/invoice-ocr-core.test.ts`, `frontend/__tests__/ai-quota.test.ts`, test nuevo del botón/servicio y el gate SQL.
- **Sin cambios** en el backend Python (DEC-15: la IA y el OCR siguen en Edge Functions). Sin Redis. Sin dependencias nuevas: el base64 por bloques es un helper puro de unas líneas en `invoice-ocr-core.ts`, sin `jsr:@std/encoding`.
- **Fuera del código.** Se recomienda al PO fijar un tope mensual de gasto en el proyecto de OpenAI, como red de último recurso. Queda anotado en `docs/pendientes-manuales-po.md`; no bloquea.
