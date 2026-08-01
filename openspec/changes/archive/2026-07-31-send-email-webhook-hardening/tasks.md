> **GOVERNANCE: CRÍTICO** — seguridad + envío de correo real desde el dominio de la marca.
> **El apply está BLOQUEADO hasta el sign-off explícito del PO.** Este change es, hasta ese momento,
> solo artefactos OpenSpec. No se toca código de producción.
>
> **Bloqueantes previos al grupo 1:** resolver OQ1–OQ4 (`design.md` §Open Questions) y completar
> el grupo 0 (configuración fuera de banda). Sin el grupo 0 hecho **antes** del merge, el deploy
> corta todo el correo transaccional (fail-closed, D3).
>
> **Strict TDD aplica** a los grupos 2 y 3: RED → GREEN → TRIANGULATE → REFACTOR, con ejecución
> real de la suite en cada gate. Antes de modificar archivos existentes, capturar la red de
> seguridad (suite verde previa) y reportar cualquier fallo preexistente sin arreglarlo.
>
> **ESTADO 2026-07-31:** sign-off del PO obtenido (0.1-0.4 abajo). El apply de código (grupos
> 1-6) queda desbloqueado. El **merge** del PR sigue retenido hasta que el PO complete 0.5-0.8
> (secretos en Vault + Edge Functions) — sin ellos el deploy corta el correo transaccional de
> prod. OQ3 = sí: el grupo 6 (allowlist `all_users`) pasa de condicional a **activo**.

## 0. Sign-off y configuración fuera de banda (PO — bloqueante)

- [x] 0.1 Sign-off explícito del PO obtenido 2026-07-31 para pasar de análisis a implementación (governance CRÍTICO). Autoriza avanzar con los grupos 1-6 de este change; el merge queda retenido hasta que el PO complete el grupo 0 (0.5-0.8, secretos en Vault + Edge Functions).
- [x] 0.2 OQ1 resuelto: **SÍ hubo entrega real.** Llegaron mails espurios de "Nuevo registro" a `danielsevilla@alia-data.com` correlacionados con las ráfagas de CI del 2026-07-31; el dashboard de Resend muestra además envíos `failed` hacia destinos sintéticos generados por los gates de comportamiento (usuarios de prueba de `supabase db reset`). **Severidad escalada** respecto de la hipótesis original ("terminaron todas en 400"): hubo entrega real al admin además de bounces hacia direcciones sintéticas, lo que puede dañar la reputación de envío del dominio. La revisión de reputación en Resend queda como **pendiente del PO, NO bloqueante** para este apply (no requiere cambio de código; se resuelve por separado en el dashboard de Resend).
- [x] 0.3 OQ2 resuelto: rotación del secreto **solo ante sospecha de compromiso** (no hay política de rotación periódica). OQ3 resuelto: **SÍ, allowlist** para `recipient = 'all_users'` — se restringe a `event_type` ∈ {`meeting_notice`, `pool_notice`}; cualquier otro `event_type` con `all_users` se rechaza sin enviar y se registra en log. **El grupo 6 de tasks queda ACTIVO** (implementación obligatoria, no condicional).
- [x] 0.4 OQ4 resuelto: **NO** se mueve el destinatario admin (`danielsevilla@alia-data.com`, hardcodeado en `handle_new_user`) a configuración en este change — confirma la recomendación de D7. Fuera de alcance; si se decide más adelante, es un change aparte.
- [x] 0.5 **Completada por el PO 2026-07-31.** Valor generado con `openssl rand -hex 32` y guardado en su gestor; el valor nunca pasó por el chat, el repo ni ningún artefacto.
- [x] 0.6 **Completada por el PO 2026-07-31 22:53 UTC.** Ambos secretos creados en Vault de prod (verificado por nombres, sin leer valores).
- [x] 0.7 **Completada por el PO 2026-07-31.** Secret `SEND_EMAIL_WEBHOOK_SECRET` configurado en Edge Functions con el mismo valor — verificado conductualmente en 7.3/7.5: el POST del trigger (header de Vault) fue ACEPTADO por la función (ni 401 ni 503) → los dos lados comparten el mismo valor.
- [x] 0.8 **Verificada por el orquestador antes del merge**: `SELECT name FROM vault.secrets WHERE name IN (...)` → exactamente 2 filas (`edge_functions_base_url`, `send_email_webhook_secret`, ambas created_at 22:53:22 UTC).

## 1. Red de seguridad (antes de tocar nada)

- [x] 1.1 Baseline vitest del frontend: **638/638 tests passing** (85 test files), sin fallos preexistentes. Ruido no bloqueante: warnings `HTMLCanvasElement.getContext` de jsdom (recharts), no son fallos.
- [x] 1.2 Estado vigente en prod confirmado (MCP read-only, proyecto `gxdhpxvdjjkmxhdkkwyb`): `email_logs` recientes (últimos 10) todos `status = 'sent'` con `provider_id`/`sent_at` poblados — el flujo real funciona. Logs de `edge-function` (`send-email`) muestran ráfagas masivas de `POST | 400` (decenas por ráfaga, varias ráfagas en las últimas 24h) — confirma en vivo el defecto descrito en el proposal: las ráfagas de CI siguen llegando a prod y solo las frena la validación de forma (400), no un control de origen.
- [x] 1.3 Confirmado en `.github/workflows/deploy.yml`: línea 59-60 `Deploy Database Migrations` (`supabase db push --include-all`) corre **antes** que línea 62-63 `Deploy Edge Functions` (`supabase functions deploy --no-verify-jwt`), mismo job. El orden que hace seguro el Migration Plan (D-mismo-PR) está vigente.

## 2. Módulo compartido de verificación (TDD)

- [x] 2.1 **RED** — Creado `frontend/__tests__/send-email-webhook-auth.test.ts` importando por ruta relativa `../../supabase/functions/_shared/webhook-auth.ts` (inexistente en ese momento) y afirmando que un secreto correcto devuelve `{ ok: true }`. Ejecutado: falló con `Failed to resolve import ... Does the file exist?` (confirmado, no test spuriamente verde).
- [x] 2.2 **GREEN** — Creado `supabase/functions/_shared/webhook-auth.ts` con `verifyWebhookSecret(provided, expected)` y el tipo `WebhookAuthResult`, sin ninguna referencia a `Deno.*` en scope de módulo (D5). Ejecutado: verde (1/1).
- [x] 2.3 **TRIANGULATE** — Agregados: secreto incorrecto → 401; header ausente (`null`) → 401; `expected` ausente (`undefined`) → 503 `misconfigured`; `expected` cadena vacía → 503; provisto vacío contra esperado no vacío → 401. Ejecutado tras cada caso: verde.
- [x] 2.4 **TRIANGULATE** — Cubierto: mismo largo/distinto contenido → 401; más corto → 401; más largo → 401 (la comparación en tiempo constante no cambia el resultado funcional). 9/9 verde.
- [x] 2.5 **REFACTOR** — La comparación en tiempo constante ya vive en un helper interno (`constantTimeEquals`) con comentario explicando por qué no se usa `===`/`!==` (short-circuit en el primer byte distinto filtraría timing). Sin cambios adicionales necesarios — la implementación GREEN ya siguió D3/D5 al pie de la letra dado que el diseño especifica la forma exacta. Suite re-ejecutada tras la revisión: 9/9 verde.

## 3. Edge Function `send-email` (TDD sobre el módulo, cambio mínimo en el handler)

- [x] 3.1 Modificado `supabase/functions/send-email/index.ts`: la primera operación dentro del `try` del handler lee `req.headers.get("x-webhook-secret")` y `Deno.env.get('SEND_EMAIL_WEBHOOK_SECRET')`, invoca `verifyWebhookSecret` (importado del módulo probado en el grupo 2) y traduce el resultado a `Response` (401/503) **antes** de `const rawBody = await req.text()` y antes de cualquier uso de Resend.
- [x] 3.2 Verificado: el `return` del rechazo ocurre antes de `record`/`id` siquiera existir — no hay ningún `UPDATE` posible en esa rama (cierra el vector "UPDATE con id ajeno").
- [x] 3.3 Resto del handler intacto: plantillas, adjuntos y actualizaciones de estado sin cambios funcionales (no-BREAKING) salvo la allowlist del grupo 6 (ver abajo, activo por sign-off).
- [x] 3.4 Log del rechazo: `console.error` con `authResult.reason` y `authResult.status` únicamente — nunca `providedSecret` ni `expectedSecret`.
- [x] 3.5 Suite completa ejecutada: **654/654** verde (638 baseline + 16 nuevos: 9 de `send-email-webhook-auth.test.ts` + 7 de `send-email-fanout-policy.test.ts`, grupo 6). Sin regresiones.

## 4. Migración: trigger endurecido + gates SQL

- [x] 4.1 Migración creada con `supabase migration new send_email_webhook_hardening` → `supabase/migrations/20260731222521_send_email_webhook_hardening.sql`.
- [x] 4.2 `public.send_email_log_webhook()` reescrita con `CREATE OR REPLACE`: `SECURITY DEFINER`, `SET search_path TO 'public', 'vault'`, leyendo `send_email_webhook_secret` y `edge_functions_base_url` de `vault.decrypted_secrets`.
- [x] 4.3 Guard de entorno (D2) implementado: `IF v_webhook_secret IS NULL OR v_base_url IS NULL THEN RAISE NOTICE ...; RETURN NEW; END IF;`. Verificado en local (gate f): el `INSERT` del productor se confirma con `status = 'pending'` intacto — la ausencia de configuración nunca aborta la transacción.
- [x] 4.4 Corte por estado (D6) implementado: `IF NEW.status IS DISTINCT FROM 'pending' THEN RETURN NEW; END IF;`, ANTES de leer Vault (más barato). Verificado (gate g).
- [x] 4.5 `net.http_post` hacia `v_base_url || '/functions/v1/send-email'` con headers `Content-Type: application/json` y `x-webhook-secret: <secreto de Vault>`, mismo body `{type, table, record}` de hoy — contrato de payload sin cambios.
- [x] 4.6 Trigger recreado: `DROP TRIGGER IF EXISTS on_email_log_insert ON public.email_logs;` + `CREATE TRIGGER ... AFTER INSERT ... FOR EACH ROW`.
- [x] 4.7 Confirmado por grep sobre el archivo: los únicos `supabase.co` son (i) un placeholder `<project-ref>.supabase.co` dentro de un comentario `--` instructivo, y (ii)-(iv) la lógica del propio gate (b) que verifica la AUSENCIA de esa cadena. Los únicos `vault.create_secret` son comentarios `--` documentando el setup fuera de banda del PO (mismo patrón que `20260719000001_c27_cae_relay_trigger.sql`) — cero SQL ejecutable crea secretos.
- [x] 4.8 Re-aplicabilidad verificada en local (Docker, `supabase_db_v0-saa-s-empresarial-completo`): (1) `supabase db reset --local` completo (replay de TODA la historia de migraciones) — gates a-g PASSED; (2) el archivo de esta migración re-ejecutado DIRECTAMENTE vía `psql -f` DOS VECES MÁS seguidas sobre la misma base ya migrada (sin reset entre medio) — sin errores, `pg_proc`/`pg_trigger` muestran exactamente 1 función y 1 trigger tras las 3 aplicaciones acumuladas (CREATE OR REPLACE + DROP TRIGGER IF EXISTS confirmado sin efecto acumulativo, lección 42725). Las reaplicaciones directas mostraron (e)/(f)/(g) en `f` porque `accounts` ya no estaba vacía en ese punto (3 cuentas remanentes de migraciones posteriores) — esperado, no es un fallo (mismo comportamiento degrade-sin-abortar que el resto del repo). Reset final limpio re-confirma a-g en `t`.
- [x] 4.9 Encabezado añadido siguiendo la convención de `20260819000001_billing_edge_effective_plan.sql`: contexto, governance CRÍTICO + sign-off, decisiones D1/D2/D4/D6, idempotencia, orden de despliegue, pre-requisito fuera de banda, rollback, verification.

## 5. Gates SQL embebidos en la migración

- [x] 5.1 **Estructural:** gate (a) — `send_email_log_webhook` con exactamente 1 definición (lección 42725), `SECURITY DEFINER` y `search_path` fijado (verificado vía `proconfig`). PASSED.
- [x] 5.2 **Estructural:** gate (b) — `pg_get_functiondef` del cuerpo NOT ILIKE `%supabase.co%`. PASSED.
- [x] 5.3 **Estructural:** gate (c) — el cuerpo referencia `vault.decrypted_secrets` Y `x-webhook-secret`. PASSED.
- [x] 5.4 **Estructural:** gate (d) — trigger `on_email_log_insert`, `AFTER INSERT ... FOR EACH ROW` sobre `public.email_logs`, exactamente 1 (vía `information_schema.triggers`). PASSED.
- [x] 5.5 **Comportamiento (solo `accounts` vacía):** gate (e) — INSERT `pending` sin secretos en Vault; `net.http_request_queue` no creció (conteo antes/después idéntico). PASSED — prueba directa de que las ráfagas de CI se terminan en el trigger, antes de llegar a la función. Anchor con `event_type` propio (`gate_send_email_webhook_hardening_pending`) para no chocar con `UNIQUE NULLS NOT DISTINCT (user_id, event_type, metadata)` de `email_logs` (20250101000008) — **gotcha encontrado y corregido en TDD** (ver desviaciones). Limpieza best-effort al final del bloque.
- [x] 5.6 **Comportamiento:** gate (f) — la fila del anchor de 5.5 persiste con `status = 'pending'` intacto tras el guard. PASSED.
- [x] 5.7 **Comportamiento:** gate (g) — control negativo, INSERT con `status = 'sent'` (anchor con `event_type` distinto, mismo motivo que 5.5): `net.http_request_queue` tampoco creció. PASSED.
- [x] **Verificación adicional (no listada explícitamente en tasks, cubre el escenario normativo "El trigger envía el header de autenticación" de `spec.md`):** con ambos secretos presentes en Vault (creados y borrados manualmente en local, fuera de la migración), un `INSERT pending` SÍ encola una request en `net.http_request_queue` con `url` = `<edge_functions_base_url>/functions/v1/send-email` y `headers->>'x-webhook-secret'` = el valor de Vault. Confirma D1/D4 end-to-end.

## 6. Fan-out `all_users` — ACTIVO (OQ3 = sí, sign-off PO 2026-07-31)

- [x] 6.1 Implementado: nuevo módulo puro `supabase/functions/_shared/email-fanout-policy.ts` con `isAllUsersFanoutAllowed(eventType)` (allowlist `meeting_notice`/`pool_notice`). Wireado en `send-email/index.ts` — dentro de la rama `recipient === "all_users"`, si el `event_type` no está en la allowlist: NO se llama `auth.admin.listUsers()` ni se envía ningún correo, se actualiza `email_logs` a `status: "failed"` con `error_details` describiendo el rechazo (decisión de implementación: da estado terminal a la fila en vez de dejarla `pending` para siempre — no especificado explícitamente en tasks.md, documentado acá), se loguea con `console.error` (incluye `event_type`, nunca datos de usuarios), y se responde HTTP 403.
- [x] 6.2 Cobertura TDD en `frontend/__tests__/send-email-fanout-policy.test.ts` (mismo ciclo RED→GREEN→TRIANGULATE que el grupo 2): RED confirmado (`Failed to resolve import`), GREEN (7/7), triangulación cubre ambos event_type permitidos, dos rechazados explícitos (`welcome`, `new_user_admin_notice`), uno arbitrario, cadena vacía y sensibilidad a mayúsculas/minúsculas.
- [x] 6.3 No aplica (OQ3 = sí).

## 7. Despliegue y verificación en producción

- [x] 7.1 Grupo 0 verificado completo (0.8: 2 filas en Vault, 22:53 UTC) ANTES del merge.
- [x] 7.2 PR #320 squash-mergeado (`296cbb5`, 22:58 UTC). Run `Build and Deploy` 30671581996 verde: `Deploy Supabase` (db push → functions deploy, en ese orden) y `Build Next.js Frontend`, ambos success. Sin db push manual ni MCP apply_migration.
- [x] 7.3 **Camino feliz verificado en infraestructura; entrega real diferida por cuota de Resend.** Fila smoke insertada 23:01:10 UTC (`06590596-…`, event_type `webhook_hardening_smoke`): el trigger disparó con el header de Vault, la función lo ACEPTÓ (ni 401 ni 503 — los secretos de ambos lados coinciden) y llamó a Resend; Resend rechazó con "You have reached your … limit" (cuota diaria del tier free AGOTADA por las ~200 tentativas de las ráfagas de hoy — evidencia adicional del daño del relay) → fila marcada `failed` con error_details, como diseña D3. **La entrega real punta a punta se re-verifica al reset de cuota (chip del día siguiente)**; el camino de envío en sí ya estaba probado hoy mismo a las 12:39 con 4 `low_branch_stock_alert` `sent` (mismo código de envío; este change solo antepone la autenticación).
- [x] 7.4 **Relay CERRADO**: `POST` bien formado (type/table/record con status pending) SIN header → **HTTP 401** (23:01:09 UTC), ningún correo, nada escrito en `email_logs`. Antes de este change, ese mismo payload producía un envío real.
- [x] 7.5 Sin 503 en los logs post-deploy (v529): solo el 401 del test de 7.4 y el 400 de cuota de 7.3. El secret de Edge Functions está configurado y coincide.
- [x] 7.6 **Ráfagas TERMINADAS**: el push del merge (22:58 UTC) fue el primer push del día SIN ráfaga asociada — cero requests a `send-email` en la ventana 22:58→23:01 (vs. ráfagas de ~45×400 en CADA push previo: 20:40, 20:57, 21:04, 21:18, 21:44). El check "Supabase Preview" del PR además PASÓ con el trigger endurecido no-op por ausencia de secretos — el guard funcionando en el entorno efímero de la integración.
- [x] 7.7 `email_logs` sin cambios de volumen ni estados fuera de lo esperado: solo la fila smoke de 7.3 (failed por cuota, esperado) sobre las 4 `sent` reales del día.

## 8. Cierre

- [x] 8.1 CHANGES.md actualizado en el mismo PR del archive (entrada completa con causa raíz, fix, verificaciones y pendientes no bloqueantes).
- [x] 8.2 Engram actualizado por el orquestador: sign-off + escalación OQ1 (`opsx/send-email-webhook-hardening/signoff`), apply (`.../apply`), y archive con las verificaciones de prod (`.../archive`).
- [x] 8.3 `openspec archive send-email-webhook-hardening` ejecutado en este PR: capability nueva `transactional-email-delivery` sincronizada a `openspec/specs/` y change movido a `openspec/changes/archive/2026-07-31-send-email-webhook-hardening/`.
