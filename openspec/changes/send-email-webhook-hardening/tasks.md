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

## 0. Sign-off y configuración fuera de banda (PO — bloqueante)

- [ ] 0.1 Obtener sign-off explícito del PO para pasar de análisis a implementación (governance CRÍTICO).
- [ ] 0.2 Registrar la resolución de OQ1 (¿llegaron mails espurios de "Nuevo registro" a `danielsevilla@alia-data.com` el 2026-07-31 ~20:40/20:57/21:04/21:18 UTC?) revisando la casilla y el dashboard de Resend. Si hubo entrega real, escalar severidad y revisar reputación del dominio antes de continuar.
- [ ] 0.3 Registrar la resolución de OQ2 (política de rotación) y OQ3 (¿allowlist para el fan-out `all_users`?). Si OQ3 = sí, activar el grupo 6.
- [ ] 0.4 Registrar la resolución de OQ4 (destinatario admin a configuración). Recomendación: **no** en este change (D7); si el PO decide lo contrario, abrir un change aparte y **no** ampliar el alcance de éste.
- [ ] 0.5 Generar el valor del secreto (`openssl rand -hex 32`) y guardarlo en el gestor de secretos del PO. NO pegarlo en el repo, en el PR, ni en ningún artefacto de este change.
- [ ] 0.6 Crear en Vault del proyecto de prod: `send_email_webhook_secret` (valor del 0.5) y `edge_functions_base_url` (`https://<project-ref>.supabase.co`).
- [ ] 0.7 Configurar el secret de Edge Functions `SEND_EMAIL_WEBHOOK_SECRET` con **el mismo valor** del 0.5 (dashboard o `supabase secrets set`).
- [ ] 0.8 Verificar la configuración: `SELECT name FROM vault.secrets WHERE name IN ('send_email_webhook_secret','edge_functions_base_url');` devuelve exactamente 2 filas.

## 1. Red de seguridad (antes de tocar nada)

- [ ] 1.1 Ejecutar la suite de vitest del frontend y anotar el baseline (`N tests passing`). Reportar fallos preexistentes sin corregirlos.
- [ ] 1.2 Confirmar el estado vigente en prod antes del cambio: `email_logs` recientes con `status = 'sent'` y ausencia de errores en los logs de `send-email`.
- [ ] 1.3 Confirmar que `deploy.yml` sigue ejecutando `db push` (paso "Deploy Database Migrations") **antes** de `functions deploy` (paso "Deploy Edge Functions") en el mismo job — es la propiedad que hace seguro el orden de despliegue (design.md §Migration Plan).

## 2. Módulo compartido de verificación (TDD)

- [ ] 2.1 **RED** — Crear `frontend/__tests__/send-email-webhook-auth.test.ts` importando por ruta relativa el archivo real `../../supabase/functions/_shared/webhook-auth.ts` (todavía inexistente) y afirmando que un secreto correcto devuelve `{ ok: true }`. Ejecutar: debe fallar.
- [ ] 2.2 **GREEN** — Crear `supabase/functions/_shared/webhook-auth.ts` con `verifyWebhookSecret(provided, expected)` y el tipo `WebhookAuthResult`, sin ninguna referencia a `Deno.*` en scope de módulo (D5). Implementar lo mínimo para pasar. Ejecutar: verde.
- [ ] 2.3 **TRIANGULATE** — Agregar casos que quiebren cualquier implementación de conveniencia: secreto incorrecto → `{ ok:false, status:401 }`; header ausente (`null`) → 401; `expected` ausente (`undefined`) → `{ ok:false, status:503, reason:'misconfigured' }`; `expected` cadena vacía → 503 (una configuración vacía NO es un secreto válido); provisto vacío contra esperado no vacío → 401. Ejecutar tras cada caso.
- [ ] 2.4 **TRIANGULATE** — Cubrir explícitamente que valores de igual longitud pero distinto contenido, y de distinta longitud, den ambos 401 (la comparación en tiempo constante no debe cambiar el resultado funcional).
- [ ] 2.5 **REFACTOR** — Extraer la comparación en tiempo constante a un helper interno con nombre claro; documentar en comentario por qué no se usa `===`. Suite verde después de cada paso.

## 3. Edge Function `send-email` (TDD sobre el módulo, cambio mínimo en el handler)

- [ ] 3.1 Modificar `supabase/functions/send-email/index.ts` para que la **primera** operación del handler lea el header `x-webhook-secret` y `Deno.env.get('SEND_EMAIL_WEBHOOK_SECRET')`, invoque `verifyWebhookSecret` y traduzca el resultado a `Response` (401 `unauthorized` / 503 `misconfigured`), **antes** de `req.text()` y antes de cualquier uso de Resend.
- [ ] 3.2 Verificar que el rechazo no escribe en `email_logs`: el `return` ocurre antes de construir cualquier `UPDATE` (cierra el vector "UPDATE con id ajeno" descrito en design.md §Context).
- [ ] 3.3 Dejar intacto el resto del handler: plantillas, adjuntos, fan-out y actualizaciones de estado no cambian (no-BREAKING).
- [ ] 3.4 Registrar en log el rechazo con su causa distinguible (401 vs 503) y sin volcar el secreto ni el valor recibido.
- [ ] 3.5 Ejecutar la suite completa: verde, sin regresiones respecto del baseline de 1.1.

## 4. Migración: trigger endurecido + gates SQL

- [ ] 4.1 Crear el archivo de migración con `supabase migration new send_email_webhook_hardening` (nunca inventar el timestamp a mano).
- [ ] 4.2 Reescribir `public.send_email_log_webhook()` con `CREATE OR REPLACE`: `SECURITY DEFINER`, `SET search_path TO 'public','vault'`, leyendo `send_email_webhook_secret` y `edge_functions_base_url` de `vault.decrypted_secrets`.
- [ ] 4.3 Implementar el guard de entorno (D2): si cualquiera de los dos valores es `NULL` → `RAISE NOTICE` y `RETURN NEW` sin emitir HTTP. Verificar que la ausencia de configuración jamás aborta el `INSERT` del productor.
- [ ] 4.4 Implementar el corte por estado (D6): si `NEW.status IS DISTINCT FROM 'pending'` → `RETURN NEW` sin emitir HTTP.
- [ ] 4.5 Emitir `net.http_post` hacia `<edge_functions_base_url>/functions/v1/send-email` con los headers `Content-Type: application/json` y `x-webhook-secret: <secreto>`, y el mismo body `{type, table, record}` de hoy (contrato de payload sin cambios).
- [ ] 4.6 Recrear el trigger con `DROP TRIGGER IF EXISTS on_email_log_insert ON public.email_logs;` + `CREATE TRIGGER ... AFTER INSERT ... FOR EACH ROW`.
- [ ] 4.7 Confirmar que la migración **no** contiene ninguna URL de proyecto literal, ningún valor de secreto, ni ninguna llamada a `vault.create_secret` (fallaría en la segunda pasada del pipeline y obligaría a poner el valor en el repo).
- [ ] 4.8 Verificar re-aplicabilidad: aplicar la migración **dos veces** seguidas sobre la misma base local y comprobar que el resultado es idéntico (el pipeline la aplica dos veces por diseño: integración GitHub + `db push` de Actions).
- [ ] 4.9 Añadir el encabezado de comentario con contexto, governance CRÍTICO, orden de despliegue e idempotencia, siguiendo la convención de `20260819000001_billing_edge_effective_plan.sql`.

## 5. Gates SQL embebidos en la migración

- [ ] 5.1 **Estructurales (siempre, prod y CI):** `send_email_log_webhook` existe con exactamente **una** definición (lección 42725), es `SECURITY DEFINER` y tiene `search_path` fijado.
- [ ] 5.2 **Estructural:** el cuerpo de la función **no** contiene ninguna URL literal `*.supabase.co` ni la cadena del secreto — verificable con `pg_get_functiondef` (`prosrc NOT LIKE '%supabase.co%'`).
- [ ] 5.3 **Estructural:** el cuerpo referencia `vault.decrypted_secrets` y el header `x-webhook-secret`.
- [ ] 5.4 **Estructural:** el trigger `on_email_log_insert` existe, es `AFTER INSERT ... FOR EACH ROW` sobre `public.email_logs`, y hay exactamente uno.
- [ ] 5.5 **Comportamiento (solo con `public.accounts` vacía = CI):** insertar una fila `pending` en `email_logs` sin secretos en Vault y comprobar que **no** se creó ninguna fila nueva en `net.http_request_queue` / `net._http_response` — es la prueba directa de que las ráfagas se terminaron. Limpieza best-effort del anchor sintético.
- [ ] 5.6 **Comportamiento (solo con `accounts` vacía):** el `INSERT` de 5.5 se confirma igual (la fila queda en `email_logs`), demostrando que el guard no aborta la transacción del productor.
- [ ] 5.7 **Comportamiento (solo con `accounts` vacía):** control negativo del corte por estado — insertar una fila con `status = 'sent'` y comprobar que tampoco genera tráfico.

## 6. Fan-out `all_users` — CONDICIONAL a OQ3 = sí

- [ ] 6.1 Si el PO aprueba OQ3: restringir en `send-email` el fan-out `recipient = 'all_users'` a una allowlist de `event_type` (`meeting_notice`, `pool_notice`); cualquier otro `event_type` con ese destinatario se rechaza sin enviar y se registra en log.
- [ ] 6.2 Si el PO aprueba OQ3: cubrir la allowlist con tests en el módulo compartido siguiendo el mismo ciclo TDD del grupo 2.
- [ ] 6.3 Si OQ3 = no: dejar constancia en el PR de que el riesgo queda **aceptado** y documentado en `design.md` §Risks. No implementar nada.

## 7. Despliegue y verificación en producción

- [ ] 7.1 Confirmar que el grupo 0 está completo **antes** de mergear (sin los secretos, el deploy corta el correo).
- [ ] 7.2 Mergear a main y dejar que el pipeline aplique en orden: `db push` (el trigger empieza a mandar el header) → `functions deploy` (la función empieza a exigirlo). No hacer `db push` manual ni usar el MCP `apply_migration`.
- [ ] 7.3 **Verificar el camino feliz:** insertar una fila real en `email_logs` (o disparar un evento que la produzca) y confirmar que llega a `status = 'sent'` con `provider_id` y `sent_at`, y que el correo se recibe.
- [ ] 7.4 **Verificar el cierre del relay:** hacer un `POST` a la URL pública de `send-email` con un payload bien formado y **sin** el header, y confirmar HTTP **401** y que no llega ningún correo.
- [ ] 7.5 **Verificar que no hay 503** en los logs de la función (indicaría secreto no configurado en el entorno de Edge Functions).
- [ ] 7.6 **Verificar el fin de las ráfagas:** tras el siguiente push/merge del repo, confirmar en los logs de la función que ya no aparecen ráfagas de ~40-45 requests correlacionadas con eventos de CI.
- [ ] 7.7 Confirmar que el volumen de `email_logs` y sus estados en prod se mantienen equivalentes a los previos (no-BREAKING).

## 8. Cierre

- [ ] 8.1 Marcar el estado del change en `CHANGES.md` según la convención del roadmap.
- [ ] 8.2 Guardar en engram el resultado del apply: decisiones finales, resolución de las OQs y cualquier gotcha descubierto.
- [ ] 8.3 Ejecutar `openspec archive send-email-webhook-hardening` para sincronizar la nueva capability `transactional-email-delivery` a `openspec/specs/` y cerrar el change.
