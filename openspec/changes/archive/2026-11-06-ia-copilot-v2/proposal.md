## Why

El PO lo dijo así: *«los insights del tablero y el copilot son los más flojos, más que nada el copiloto: tenés que ser muy específico para que entienda lo que querés; tenemos que mejorar el modelo y el prompt»*. El explore `openspec/explore/2026-11-06-mejora-ia.md` (PR #690) encontró que la causa es de diseño, no sólo del modelo: el Copiloto pega una foto fija de 30 días elegida por un regex, no sabe qué día es, no puede pedir más datos, no repregunta, **no pasa por la cuota de IA** y **no guarda ninguna conversación desde el 2026-05-11** (11 filas en toda la historia). Este propose encontró la causa probable del guardado roto: desde `20260606000004_rls_tenant_scoping` la policy de `INSERT` de `ai_conversations` exige `account_id IN current_account_ids()`, y el guardado inserta sin `account_id` (columna sin default ni trigger), así que la RLS lo rechaza y el error se tira al log. Es el change 1 del plan del explore.

## What Changes

- **Edge Function nueva `ai-copilot`** (DEC-15) que reemplaza a la ruta de Next `POST /api/ai/copilot`. Usa **herramientas de sólo lectura** (function calling) sobre las RPCs canónicas que ya existen: resumen del período, evolución, ranking de productos, desglose (canal, sucursal, día de la semana, horario, categoría), mejores clientes, stock crítico con detalle, búsqueda y detalle de un producto, cuentas por cobrar y por pagar, comparación de períodos y rentabilidad por producto. Todas corren con el JWT del usuario (nunca service role), con un schema estricto por herramienta, un tope de rondas por pregunta y un tope de filas por herramienta. **El Copiloto nunca escribe datos del negocio** (decisión del PO: «solo responde»).
- **Prompt de asistente** nuevo: rol, negocio argentino en ARS (`es-AR`), Mendoza, **fecha y hora de hoy en ART inyectadas**, mes en curso como período por defecto (dicho en la respuesta), formato breve con el número exacto primero, **una sola repregunta corta** cuando falta el producto o el cliente y no se infiere, y **ningún número que no venga de una herramienta**. Ejemplos few-shot sacados de las 11 preguntas reales anonimizadas.
- **Memoria corta**: el historial de la conversación entra sin cortar a 500 caracteres, con un presupuesto de tokens explícito, más un estado `{período, producto, cliente}` en foco que viaja de turno a turno.
- **Modelo por variable con allow-list** (`COPILOT_AI_MODEL`, patrón de `INVOICE_AI_MODEL`): por defecto `gpt-6.1-terra`; `gpt-6-luna`, `gpt-4o-mini`, `gpt-5-mini` y `gpt-4.1-mini` en la lista. La task 0 verifica con la clave de producción qué modelos existen y aceptan `tools` y `json_schema`; si el recomendado no sirve, el design ya define el reemplazo.
- **Cuota y ráfaga**: reserva atómica `rpc_reserve_ai_usage('queries')` **antes** de llamar al modelo (como el OCR), una consulta por pregunta sin importar cuántas herramientas use, ráfaga de 5 por minuto, y techo de costo por pregunta (rondas, tokens de salida, tiempo total).
- **Registro de conversaciones arreglado e instrumentado**: se guarda con `account_id`, modelo, herramientas usadas, latencia, tokens y estado del resultado; diagnóstico con evidencia como primera tarea.
- **Valoración «me sirvió / no me sirvió»** por respuesta y por usuario (decisión del PO: «sí»), en una tabla genérica `ai_feedback` pensada para que `ia-insights-tablero` (change 2) la reutilice para los insights sin migrarla.
- **Evals mínimas**: ~40 casos (las 10 preguntas reales distintas + variantes vagas) con verificación **numérica contra las RPCs**, corridas a mano con la clave real (no en CI), y tests unitarios del núcleo puro (ruteo, armado del prompt, parseo de llamadas a herramientas, topes).
- **`/copiloto-ia` renovado**: preguntas sugeridas, indicador de qué consultó la IA («Miré tus ventas del 1 al 6 de noviembre»), botones «me sirvió / no me sirvió», contador de consultas restantes (`useAiUsage`) y mensajes legibles de carga, cuota, ráfaga y error; desktop y mobile, claro y oscuro.
- **BREAKING (interno)**: se retiran `frontend/app/api/ai/copilot/route.ts`, `frontend/lib/ai/buildBusinessSnapshot.ts` y `frontend/lib/services/aiCopilotService.ts` con sus tests, después de un grep de callers. No hay consumidores externos.

## Capabilities

### New Capabilities

- `ai-copilot`: el asistente conversacional de sólo lectura — Edge Function, herramientas y sus topes, prompt, memoria corta, modelo por allow-list, cuota y ráfaga por reserva, registro de conversaciones, evals y la pantalla `/copiloto-ia`.
- `ai-feedback`: la valoración «me sirvió / no me sirvió» por usuario sobre una respuesta de IA, en un almacén genérico por tipo de sujeto, escrito sólo por RPC.

### Modified Capabilities

- `ai-canonical-metrics`: el Copiloto deja de ser `frontend/lib/ai/buildBusinessSnapshot.ts` y pasa a ser la Edge Function `ai-copilot`; sus cifras salen de las herramientas sobre los read-models canónicos, y el requirement de «sin canon, la cifra se omite» deja de nombrar `BusinessSnapshot`.
- `ai-usage-counters`: el reset mensual limpia también la ventana de ráfaga de las consultas; `rpc_reserve_ai_usage` acepta el contador `queries`.
- `plan-gating`: la cuota de IA suma a `ai-copilot`, que reserva el cupo de `queries` de forma atómica en lugar del par verificar / incrementar.

## Impact

- **DB** (migración `20261095000001_ia_copilot_v2.sql`; `20261094000001` está reservada por `invitaciones-hardening`; prod `MAX(version) = 20261093000001`): columnas aditivas en `ai_conversations` y `profiles`, tabla nueva `ai_feedback` con RLS y escritura sólo por `rpc_set_ai_feedback`, rama `queries` en `rpc_reserve_ai_usage` (reescrita desde la definición viva), cron `reset-ai-counters` con las columnas nuevas.
- **Edge Functions**: `supabase/functions/ai-copilot/` nueva; `_shared/ai-copilot-core.ts`, `_shared/ai-copilot-tools.ts`, `_shared/ai-copilot-prompt.ts` nuevos; `_shared/ai-quota.ts` extiende `ReserveCounter`. Secretos: `OPENAI_API_KEY` (ya existe), `COPILOT_AI_MODEL` (opcional).
- **Frontend**: `app/(dashboard)/copiloto-ia/page.tsx` reescrita sobre un hook nuevo (`hooks/data/use-copilot.ts`), componentes en `components/copilot/`, arnés `app/dev-harness/copiloto-*` y spec `e2e/harness/copiloto-visual.spec.ts`. Se retiran la ruta Next, el snapshot y el servicio viejo.
- **Costo**: ≈ US$ 0,01 por pregunta con `gpt-6.1-terra` (≈ US$ 10 cada 1.000); cada corrida de evals, centavos.
- **Governance MEDIO**: IA de sólo lectura y cuota de IA; no toca dinero, auth ni facturación.
