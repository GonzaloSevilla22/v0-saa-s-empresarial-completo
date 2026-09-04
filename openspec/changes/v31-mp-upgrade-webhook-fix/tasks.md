# Tasks — v31-mp-upgrade-webhook-fix

> **Governance CRÍTICO (dinero real).** El sign-off del PO del 2026-07-31 cubre el **rumbo**
> (apuntar al webhook backend, retirar el legacy, correr en convivencia). NO cubre: el
> pago E2E con dinero real, la config del panel de MercadoPago, ni el retiro definitivo del
> reenviador. Esas tres están marcadas **[MANUAL PO]** y el agente **no las ejecuta**.
>
> **TDD obligatorio** (Strict TDD Mode): cada grupo de implementación arranca con Safety
> Net (baseline de tests existentes), sigue RED (test que falla) → GREEN (mínimo para
> pasar) → TRIANGULATE (2º caso con inputs distintos) → REFACTOR. No se marca `[x]` sin
> ejecución verde real.
>
> **Nunca**: imprimir, loguear ni comparar el valor de `MERCADOPAGO_WEBHOOK_SECRET`.
> **Nunca**: crear, disparar ni simular un pago real. **Nunca**: `service_role` en backend
> más allá de la conexión de servicio que el webhook ya usa.

## 1. Preparación y verificación de entorno

- [x] 1.1 Correr la suite backend (`pytest backend/tests/test_payments.py -v`) y la de frontend (`pnpm vitest run frontend/__tests__/billing.test.ts`) y registrar el **baseline** de tests en verde. Si alguno ya falla, reportarlo como fallo preexistente y NO arreglarlo acá.
  - **Baseline 2026-08-01**: backend `test_payments.py` 21/21 verdes. Frontend `billing.test.ts` 34/34 verdes. Sin fallos preexistentes.
- [x] 1.2 Verificar que `NEXT_PUBLIC_BACKEND_URL` está poblada en Vercel producción y que la URL responde en `/health`. Registrar la URL (no es secreta).
  - **Verificado 2026-08-01**: `NEXT_PUBLIC_BACKEND_URL=https://emprende-smart-backend.onrender.com` (confirmado indirectamente vía el header `content-security-policy: connect-src` de `www.aliadata.com.ar` en producción, que incluye ese origen — coherente con `frontend/lib/supabase/middleware.ts`). `GET /health` → `200 {"status":"ok"}`.
- [x] 1.3 **[MANUAL PO]** Confirmado en Render (PO, 27-08): `MERCADOPAGO_WEBHOOK_SECRET` y `MERCADOPAGO_ACCESS_TOKEN` presentes en el servicio del backend. **29-08**: el access token de prod se filtró accidentalmente en el chat → **rotado** (renovado en el panel de MP) y actualizado en Render y en Vercel (`lib/mercadopago.ts:25` usa el mismo nombre de variable) dentro de la ventana de 12h de convivencia de credenciales viejas/nuevas. Ver `docs/gates-mercadopago-2026-08-27.md` (GATE 1 + incidente GATE 3).
- [x] 1.4 **[MANUAL PO]** Secreto alineado, **probado empíricamente 27-08**: "Simular notificación" en el panel de MP con un `subscription_preapproval` (data.id `123456`) → **200 OK**. Un secreto desalineado habría dado 400. Ver `docs/gates-mercadopago-2026-08-27.md` (GATE 2).
- [x] 1.5 **[MANUAL PO — resuelve OQ2]** Revisado por el PO (27-08): **no existe** ninguna URL de webhook a nivel de aplicación apuntando al frontend (`aliadata.com.ar/api/billing/webhook`); la URL productiva configurada en el panel es la del backend (`emprende-smart-backend.onrender.com/payments/webhook`). Ver `docs/gates-mercadopago-2026-08-27.md` (GATE 2).
- [x] 1.6 **[MANUAL PO]** Credenciales de **test/sandbox** confirmadas: existen en `backend/.env` (`TEST-...`). En la práctica el E2E final (tarea 5.1) se hizo directamente con dinero real vía la primera suscripción real (Daniel, 29-08) — ver GATE 3 en `docs/gates-mercadopago-2026-08-27.md`.

## 2. Reenviador legacy (Fase 1 — cubre las preferencias ya emitidas)

- [x] 2.1 **RED** — Test en `frontend/__tests__/billing.test.ts`: dado un POST a la ruta legacy con un cuerpo y los headers `x-signature`/`x-request-id`, la ruta hace fetch a `${NEXT_PUBLIC_BACKEND_URL}/payments/webhook` propagando **los mismos bytes** del cuerpo y **los dos headers**. Debe fallar contra la implementación actual.
  - Confirmado RED 2026-08-01: 8 tests nuevos fallaron contra la implementación pre-fix (todas las requests a `/api/billing/webhook` volvían 401 por firma inválida, ya que la ruta legacy nunca fue diseñada para recibir tráfico sin secreto real en test).
- [x] 2.2 **GREEN** — Reescribir `frontend/app/api/billing/webhook/route.ts` como reenviador sin estado: leer el cuerpo crudo (`req.text()`), reenviarlo con `x-signature` y `x-request-id`, devolver el status del backend. Eliminar el import de `@/lib/supabase/server`, el de `@/lib/mercadopago`, `verifyMpSignature` y toda la lógica de plan/`email_logs` (D1, D2).
- [x] 2.3 **TRIANGULATE** — Segundo test con cuerpo distinto que verifique que **no hay re-serialización**: un payload con claves en orden no alfabético y/o escapes unicode debe llegar al backend byte-a-byte idéntico (D2).
- [x] 2.4 **TRIANGULATE** — Test: la ruta no toca Supabase bajo ninguna entrada (el módulo del cliente Supabase no se importa / no se invoca).
  - Implementado como chequeo estático de fuente (lee `route.ts` y verifica ausencia de `@/lib/supabase/server` / `createClient`) — el módulo ya no lo importa, así que un mock dinámico no tendría nada que interceptar.
- [x] 2.5 **TRIANGULATE** — Test: si el backend devuelve un status de error, el reenviador lo **propaga** en vez de enmascararlo con 200 (para que MercadoPago reintente).
- [x] 2.6 **TRIANGULATE** — Test: sin `NEXT_PUBLIC_BACKEND_URL`, el reenviador responde con error (fail-closed) y no intenta un fetch a una URL malformada.
- [x] 2.7 Agregar la traza de reenvío exigida por el spec: identificador del pago + status devuelto por el backend, sin datos sensibles ni el secreto.
  - Además se agregó el header `x-relay-source: legacy-frontend` en el reenvío (no forma parte del template firmado — id+request-id+ts — así que no rompe el HMAC) para que el backend pueda distinguir origen (grupo 4, D del spec `payment-webhook`).
- [x] 2.8 **REFACTOR** — Limpiar el archivo (queda muy chico), verificar que no hay imports muertos y que la suite frontend sigue verde.
  - `frontend/app/api/billing/webhook/route.ts` quedó en ~90 líneas, un solo import externo (`next/server`) + el helper compartido. Suite: 43/43 verdes.

## 3. Ruta directa en la preferencia (Fase 2 — elimina el salto extra para lo nuevo)

- [x] 3.1 **RED** — Test en `frontend/__tests__/billing.test.ts`: el cuerpo enviado a MercadoPago al crear una preferencia lleva `notification_url` = `${NEXT_PUBLIC_BACKEND_URL}/payments/webhook`. Debe fallar contra la implementación actual (que emite `${appUrl}/api/billing/webhook`).
- [x] 3.2 **GREEN** — Cambiar `notification_url` en `frontend/app/api/billing/preferences/route.ts` (D3).
- [x] 3.3 **TRIANGULATE** — Test del guard fail-closed: sin `NEXT_PUBLIC_BACKEND_URL`, el POST a `/api/billing/preferences` devuelve 500 y **no** se llama a la API de MercadoPago (D3, riesgo de preferencia que notifica al vacío).
- [x] 3.4 **TRIANGULATE** — Test: `back_urls` (success/failure/pending) siguen apuntando al frontend (`NEXT_PUBLIC_APP_URL`) — son navegación del usuario, no notificaciones servidor-a-servidor. Este test protege contra confundir las dos cosas.
- [x] 3.5 **REFACTOR** — Extraer la construcción de la URL del webhook a un helper único compartido con el reenviador, para que no puedan divergir.
  - `frontend/lib/billing/webhook-url.ts` (nuevo) — `getBackendWebhookUrl()`, fail-closed, sin importar `@/lib/mercadopago` a propósito (para no reintroducir el SDK de MP en el reenviador). Usado por ambas rutas.

## 4. Backend: equivalencia de origen y diagnóstico del secreto

- [x] 4.1 **RED** — Test en `backend/tests/test_payments.py`: una notificación **reenviada** (mismos bytes, mismos headers de firma) produce exactamente el mismo estado de base de datos que una directa.
  - Requirió agregar el header `x-relay-source: legacy-frontend` (task 2.7) para que "reenviada" sea distinguible de "directa" en el request — sin eso ambos caminos son requests HTTP idénticos.
- [x] 4.2 **RED** — Test: la misma `mercadopago_payment_id` entregada dos veces (una reenviada, una directa) deja **una sola** fila en `billing_events`; la segunda responde `{"ok": true, "idempotent": true}`.
- [x] 4.3 **GREEN** — Ajustar `backend/routers/payments.py` lo mínimo para que ambos tests pasen. Se espera que ya pasen sin tocar lógica: si es así, dejar los tests como red de regresión y anotarlo.
  - Confirmado: 4.1 y 4.2 pasaron **sin ningún cambio de lógica de negocio** — la idempotencia por `mercadopago_payment_id` ya era agnóstica al origen del request. Quedan como red de regresión permanente.
- [x] 4.4 **RED → GREEN** — Test: con `MERCADOPAGO_WEBHOOK_SECRET` vacía, el endpoint rechaza sin tocar la base y loguea la causa como **falta de configuración**, distinguible de "firma inválida". Implementar esa rama de log en `backend/services/payments.py` (spec `payment-webhook`).
  - `verify_mp_signature` ahora loguea 4 causas de rechazo distintas (secreto ausente / headers faltantes / x-signature malformado / payload malformado / firma no matchea); el router dejó de duplicar un log genérico que mezclaba todas las causas bajo "Invalid signature".
- [x] 4.5 **TRIANGULATE** — Test: ningún log de rechazo contiene el secreto configurado ni el valor de la firma recibida.
- [x] 4.6 **GREEN** — Agregar la traza de origen (directo vs reenviado) exigida por el spec, sin cambiar el contrato de respuesta.
  - `backend/routers/payments.py`: `logger.info("[payments/webhook] payment_id=%s origin=%s", ...)` — `origin` se deriva de la presencia del header `x-relay-source`. `WebhookResponse` no cambió de forma.
- [x] 4.7 **REFACTOR** — Revisar que `process_payment` no cambió de comportamiento. Correr la suite backend completa y comparar contra el baseline de 1.1.
  - `process_payment` intacto (0 líneas tocadas). Suite completa `backend/`: **1085 passed, 3 skipped** (baseline 1.1 era 21/21 en `test_payments.py`; ahora 28/28 en ese archivo, +7 tests nuevos, 0 regresiones).

## 5. Verificación en producción

- [x] 5.1 **[MANUAL PO — dinero real]** Ejecutada **29-08** como la primera suscripción real (Daniel, $69.900) — **con INCIDENTE**: los planes creados el 02-08 eran del panel (app interna `3909856389923111`), no de ALIADATA, y MP no emitió ninguna notificación para ese cobro. El canal quedó validado tras recrear los 3 planes por API bajo ALIADATA (2 notificaciones reales `subscription_preapproval_plan`, 200 OK). El flujo legacy de pago único por Preference ya no es alcanzable desde la UI con la palanca ON (el CTA crea suscripciones) — la verificación E2E de esta task quedó cumplida por la vía de suscripciones, no por la de Preference. Detalle completo en `docs/gates-mercadopago-2026-08-27.md` (INCIDENTE GATE 3 + GATE 3).
  - **Nota fechada 2026-09-04 — la condición sustantiva de D5-(a) sigue SIN cumplirse; este `[x]` no significa "canal probado".** Medido hoy en prod: `subscriptions` **0 filas** en toda su historia; `subscription_intents` **0**; `operation_idempotency` con `operation_kind='subscription_webhook'` **0** → el código que procesa una notificación real de suscripción **nunca corrió en producción**. `billing_events` con `mercadopago_payment_id`: **1 sola fila**, del 2026-06-13, anterior al deploy de este change (01-08) y reconciliada a mano — cero `plan_upgraded` en 60 días; `email_logs` con `payment_receipt`: 2 filas, ambas del mismo evento de junio. La cuenta de Daniel (`0f627a85-7d01-4323-8b3f-122bd834a4ab`) tiene `billing_plan='pro'` y `plan_expires_at='2026-10-09 13:45:19+00'` — coincide exacto con el `UPDATE` manual documentado en `docs/gates-mercadopago-2026-08-27.md` (INCIDENTE GATE 3), **no** con ningún webhook. Lo único que llegó fueron **2 notificaciones del topic `subscription_preapproval_plan`** (29-08, HTTP 200) — un topic que el código trata como no manejado y que no escribe nada; confirmado también por `mcp__mercadopago__notifications_history` (app ALIADATA `5864120912417849`): 1 notificación en el último mes, ese mismo topic, 0 fallidas. Lo que el 29-08 probó de verdad fue **alcance de red + firma HMAC válida sobre un topic que no escribe nada** — no una acreditación automática. La condición D5-(a) exige "un pago real de verificación acreditó **solo**, sin intervención manual"; eso todavía no ocurrió. Ningún agente futuro debe leer este checkbox verde como "canal probado" — ver también la nota de 6.1 más abajo.
- [x] 5.2 Sin filas que verificar: las notificaciones del cobro real del 29-08 (suscripción de Daniel bajo el plan del panel) **nunca se emitieron** — gap documentado del incidente, no hay `billing_events` con ese `mercadopago_payment_id` para auditar idempotencia. Ver `docs/gates-mercadopago-2026-08-27.md`.
  - **Nota fechada 2026-09-04**: sigue sin haber filas que auditar — la re-medición de hoy confirma el mismo cero (`subscriptions`/`subscription_intents`/`operation_idempotency subscription_webhook` en 0). No hay ningún pago real que haya pasado por el camino de acreditación automática de suscripciones desde que este change se desplegó.
- [x] 5.3 Logs de Render revisados por API el 29-08: firma validada en las notificaciones de la sonda del canal (2× `subscription_preapproval_plan`, 200 OK), sin secretos en la salida.
- [x] 5.4 Línea base de reenvíos del relay legacy (`frontend/app/api/billing/webhook/route.ts`) registrada en logs 28-29/08: **0 reenvíos**.

## 6. Convivencia y retiro

- [ ] 6.1 **[MANUAL PO — decide OQ1]** Acordar la duración de la ventana de convivencia y si el reenviador se retira o se deja permanente. Opciones en design.md OQ1 (recomendación: 30 días y retirar). Anotar la decisión acá.
  - **Recomendación actualizada, fechada 2026-09-04**: NO fijar el plazo todavía. Medido hoy: la condición D5-(a) ("un pago real de verificación acreditó solo, sin intervención manual") sigue sin cumplirse — ver la nota de 5.1. La condición D5-(b) (cero reenvíos del legacy) SÍ está cumplida de hecho: tres fuentes independientes confirman **0 reenvíos en 34 días** (logs de Render 28-08→04-09 sin ninguna línea con `x-relay-source`; el registro de la task 5.4; el historial de MercadoPago). Pero D5 exige **las dos** condiciones, no una — retirar el reenviador ahora dejaría sin red de seguridad justo el camino que todavía no se probó de punta a punta. El contador de los 30 días recomendados debería empezar recién el día que se cumpla D5-(a) (un pago de suscripción real acredite solo, con fila en `subscriptions` y `operation_idempotency`), no antes.
- [ ] 6.2 **[MANUAL PO]** Al cierre de la ventana, verificar la condición (b): cero reenvíos registrados. Si hubo reenvíos, **no retirar** y extender la ventana.
  - **Sin ejecutar — condicionada a 6.1** (fechado 2026-09-04): no tiene sentido cerrar una ventana que 6.1 todavía no abrió con fecha cierta.
- [ ] 6.3 **[MANUAL PO — condicionado a 5.1 + 6.2 + 1.5]** Eliminar `frontend/app/api/billing/webhook/route.ts` y sus tests. Solo si las tres condiciones se cumplieron.
  - **Sin ejecutar — condicionada** (fechado 2026-09-04): 1.5 está cumplida; 5.1 está tildada pero su condición sustantiva (D5-a) NO (ver nota de 5.1); 6.2 no puede correr sin 6.1. No retirar el reenviador todavía.
- [x] 6.4 Señalizar explícitamente al PO, antes del cutover de la Fase 2, la **desviación documentada en D4**: no se corre un shadow-run comparativo clásico porque el webhook legacy no escribe nada en producción y correr el backend en `shadow=true` sostendría el bug. La convivencia se implementa como dos caminos de entrada con un único escritor idempotente. Requiere acuse del PO.
  - **Acuse del PO recibido 2026-08-01** (relayado por el orquestador OPSX en el chat de esta sesión): "El PO acusó recibo de la desviación D4 (sin shadow-run clásico — dos entradas + escritor único idempotente + retiro por evidencia) y AUTORIZÓ el merge = corte." Cutover de Fase 2 ejecutado: PR #339 mergeado (squash) a `main` en `f60c329`, deploy Vercel `dpl_GDZEVW7YKD8GJk3GkRFxMvhc8eHq` READY en producción (`www.aliadata.com.ar`). Verificación post-merge read-only: POST de diagnóstico (firma inválida, sin datos reales) a `/api/billing/webhook` → 400 RFC7807 del backend (prueba que el reenviador llega al backend, cero escritura a DB) y log de Vercel confirma la traza `[billing/webhook] Relayed payment verify-post-merge-001 — backend responded 400`; POST a `/api/billing/preferences` sin auth → 401 sin llamar a MercadoPago. Backend `/health` → 200. Logs de Render (firma/origen) quedan fuera de alcance — sin integración de Render conectada a este agente; **igual es [MANUAL PO] por diseño (task 5.3)**.

## 7. Documentación y cierre

- [x] 7.1 Actualizar la ficha de `v31-mp-upgrade-webhook-fix` en `CHANGES.md` (L1360-1364) marcando el estado y el resultado real.
  - Ficha actualizada a 🔨 IMPLEMENTADO 2026-08-01 con resultado real (tests, suites, pendientes manuales del PO listados explícitamente). Fila de la matriz de hallazgos (H-02) también anotada.
- [x] 7.2 Anotar en `CHANGES.md` que **H-19 / `v31-mp-webhook-atomic`** sigue abierto y que este change no lo cubre.
  - Anotado en la ficha del change y en la fila H-19 de la matriz de hallazgos (cross-reference en ambos sentidos).
- [x] 7.3 Dejar registrado —en el design de `mp-real-subscriptions` o en engram— el hallazgo de **D7**: para las notificaciones de suscripción hay que leer `data.id` del **query param** y bajarlo a **minúsculas** (los IDs de `preapproval` son alfanuméricos), cosa que la verificación de firma actual no hace. Es la trampa que ese change tiene que evitar.
  - **Ya estaba hecho** desde el propose conjunto (commit `47a4286`): `openspec/changes/mp-real-subscriptions/design.md` D9 (líneas 116-120) referencia explícitamente "Hallazgo heredado de `v31-mp-upgrade-webhook-fix` D7". No se requirió acción adicional — verificado, no reescrito.
- [x] 7.4 `mem_save` con el resultado del cutover: qué acreditó, cuántos reenvíos hubo, qué decidió el PO en OQ1 y OQ2.
  - Guardado (topic_key `opsx/v31-mp-upgrade-webhook-fix/apply`). OQ1/OQ2 y el conteo de reenvíos **no tienen datos aún** — dependen de 6.1/1.5/5.1, todos [MANUAL PO] no ejecutados en esta sesión. El save deja eso explícito como pendiente, no como resuelto.
