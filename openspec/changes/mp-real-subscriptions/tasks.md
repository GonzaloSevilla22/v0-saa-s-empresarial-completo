# Tasks — mp-real-subscriptions

> **Governance CRÍTICO (dinero real).** El sign-off del PO del 2026-07-31 cubre el **rumbo**
> (suscripciones reales de MercadoPago, H-02 primero, cortesía de 30 días a la cuenta
> pagadora). NO cubre las OQ1-OQ4 de `design.md`, la creación de los planes de producción,
> la habilitación de topics en el panel, ni la migración de la cuenta pagadora.
>
> **PREREQUISITO DURO**: `v31-mp-upgrade-webhook-fix` cerrado y **verificado en producción**
> (su tarea 5.1: un pago real acreditó solo). Sin ese canal sano, ninguna notificación de
> suscripción llega a la base y este change no es verificable.
>
> **TDD obligatorio**: Safety Net (baseline) → RED → GREEN → TRIANGULATE (≥2 casos) →
> REFACTOR, con ejecución real de tests en cada paso.
>
> **Prohibiciones absolutas**: crear, disparar o simular cobros con dinero real; usar
> `service_role` en el backend fuera de la conexión de servicio que el webhook ya usa;
> aplicar migraciones con el MCP `apply_migration` (siempre CI / `npx supabase db push`);
> imprimir o comparar el valor de cualquier secreto.
>
> **Reglas de migración**: numeración desde `20260829000001`; **idempotentes** (la
> integración GitHub de Supabase las aplica al mergear **antes** del `db push` de Actions —
> corren dos veces); `REVOKE` explícito de `anon` **Y** `authenticated` después de **cada**
> definición de función (el `REVOKE FROM PUBLIC` solo NO alcanza — gotcha confirmado en
> PR #337); `to_regprocedure()` en vez de cast literal `::regprocedure` para funciones que
> podrían no existir.

## 1. Prerequisitos y decisiones abiertas

- [x] 1.1 Verificado 2026-08-01: `v31-mp-upgrade-webhook-fix` está aplicado en main (27/38 tasks) pero su verificación E2E (tarea 5.1, pago real) **sigue `[MANUAL PO]`, no ejecutada**. Reinterpretado por sign-off del PO (ver `design.md` Amendment "Activación gated"): el desarrollo de este change **procede** sin esperarla; la palanca `BILLING_SUBSCRIPTIONS_ENABLED` (default `False`) es la que impide que llegue a producción hasta que 5.1 pase.
- [ ] 1.2 Baseline de tests: suite backend (`pytest backend/tests`) y frontend (`pnpm vitest run`). Se registra al inicio de PR1 (bloqueado hasta ese momento por el bug de 1.2bis).
  - **1.2bis (hallazgo, no en el plan original)**: `backend/core/config.py::Settings` no tenía `extra="ignore"` → con `MERCADOPAGO_TEST_ACCESS_TOKEN` presente en `backend/.env` (cargado por el PO para GATE 0), `Settings()` explotaba con `ValidationError: extra_forbidden` al importar, rompiendo la colección de 5 módulos de test. **Fix autorizado por el PO 2026-08-01** — se aplica en PR1 junto con el fix de D9.
- [x] 1.3 **[MANUAL PO — resuelve OQ2]** Gracia: **10 días** entre `next_payment_date` y `plan_expires_at`, igual a la ventana de reintentos de MercadoPago. Confirmado explícitamente 2026-08-01.
- [x] 1.4 **[MANUAL PO — resuelve OQ3]** **Los tres tiers pagos** (`inicial`, `avanzado`, `pro`) se contratan por suscripción — firmado en el sign-off original 2026-07-31.
- [x] 1.5 **[MANUAL PO — resuelve OQ4]** Cambio de tier con suscripción viva: **cancelar la vigente y crear una nueva con `start_date` al fin del período pagado** — firmado 2026-07-31.
- [x] 1.6 **[MANUAL PO — resuelve OQ1]** Semántica de `plan_expires_at IS NULL` **permisiva** en este change (D6); el endurecimiento va en un change posterior — firmado 2026-07-31.

## 2. Sandbox — validación bloqueante de la API (Fase 0) — ✅ EJECUTADA 2026-08-01

- [x] 2.1 **[MANUAL PO]** Credenciales de test cargadas por el PO en `backend/.env` (gitignored). Verificadas vía `GET /users/me` como cuenta sandbox real (email `@testuser.com`, nickname `TESTUSER*`) — nunca la cuenta real del PO. Token no impreso en ningún momento.
- [x] 2.2 `preapproval_plan` de prueba creado dos veces en sandbox (`reason`, `back_url`, `auto_recurring` mensual ARS): HTTP 201, `id` alfanumérico de 32 chars, `status:"active"`, `init_point = https://www.mercadopago.com.ar/subscriptions/checkout?preapproval_plan_id=<id>`. Ambos **cancelados** al terminar (`PUT status:"cancelled"` → 200).
- [x] 2.3 **BLOQUEANTE — valida D2**: **FALLA**. `POST /preapproval` con `preapproval_plan_id` + `payer_email` + `external_reference` + `status:"pending"`, sin `card_token_id` → **HTTP 400 "card_token_id is required"**, reproducible 3/3 (2 plans distintos, con/sin `status` explícito). Ver `design.md` Amendment para la tabla completa de evidencia.
- [x] 2.4 2.3 falló → implementación detenida, comportamiento documentado en `design.md` Amendment + evidencia guardada en engram (`opsx/mp-real-subscriptions/apply`, obs #560). Se evaluó ADEMÁS la variante sin plan (pedida por el orquestador como pivot alternativo a tokenizar tarjeta): `POST /preapproval` sin `preapproval_plan_id`, con `auto_recurring` inline, sin `card_token_id` → **HTTP 500 "Internal server error"**, reproducible 6/6, aislado con 3 controles (falta de `back_url` → 400 limpio; `currency_id` inválida → 400 limpio; `card_token_id` basura → 400 limpio — el 500 es específico de "sin plan + sin card_token"). **Sign-off PO 2026-08-01**: Camino A firmado (D2bis — `init_point` del plan + intención pre-registrada + reconciliación por email/ventana + cola de ambiguos), Camino B (tokenizar con Bricks) descartado. Ticket a MP por el 500 queda opcional.
- [ ] 2.5 **Diferido a Fase 3.** Completar en sandbox el flujo de autorización del pagador (login como test-buyer) y registrar la notificación `subscription_preapproval` real: query params, headers y cuerpo. No se ejecutó en esta ronda (requiere un test-buyer separado y un endpoint público que la reciba); se hace junto con el TDD del procesamiento del topic, y se revalida en vivo antes de encender `BILLING_SUBSCRIPTIONS_ENABLED` en Fase 5.
- [ ] 2.6 **Diferido a Fase 3**, mismo motivo que 2.5. Los campos esperados de `GET /authorized_payments/{id}` están documentados en `design.md` (verificados contra la doc oficial, no en vivo todavía).
- [ ] 2.7 **Diferido a Fase 3.** Se implementa D9 (normalización `data.id` a minúsculas desde el query param) igual con TDD basado en fixtures del formato documentado de notificación; la confirmación contra una notificación real de sandbox queda pendiente de 2.5/2.6.

## 3. Verificación de firma — corrección obligatoria (D9)

- [ ] 3.1 **Safety Net** — Correr `pytest backend/tests/test_payments.py` y registrar el baseline verde antes de tocar `verify_mp_signature`.
- [ ] 3.2 **RED** — Test: una notificación con `data.id` alfanumérico en mayúsculas en el query param verifica firma correctamente cuando el manifiesto se arma con el valor **en minúsculas**. Debe fallar hoy.
- [ ] 3.3 **GREEN** — Modificar la derivación en `backend/services/payments.py` para tomar `data.id` del query param y pasarlo a minúsculas.
- [ ] 3.4 **TRIANGULATE — no regresión** — Test: una notificación `payment` con id numérico sigue verificando exactamente igual que antes. Este test protege el camino que hoy funciona.
- [ ] 3.5 **TRIANGULATE** — Test: sin query param `data.id`, la derivación cae al cuerpo aplicando la misma regla de minúsculas.
- [ ] 3.6 **TRIANGULATE** — Test: una firma que no corresponde al manifiesto se rechaza, tanto para `payment` como para los topics de suscripción.
- [ ] 3.7 **REFACTOR** — Extraer la derivación del identificador a una función pura y testeada aparte de la verificación HMAC.

## 4. Migración de esquema (Fase 1) — `20260829000001`

- [x] 4.1 Leído con MCP (solo lectura) 2026-08-01. Unión vigente completa en producción (`operation_idempotency_operation_kind_check`): `'sale', 'purchase', 'payment_received', 'payment_made', 'supplier_charge', 'bank_movement', 'event_consumer', 'bank_statement_import', 'cash_session_close'` (9 valores). El CHECK nuevo debe recrear esta unión completa **más** el kind de notificaciones de suscripción.
- [x] 4.2 `public.subscriptions` creada con `IF NOT EXISTS` en `20260829000001_mp_real_subscriptions_schema.sql`: `account_id` **nullable** (D2bis), `preapproval_id` único NOT NULL, `preapproval_plan_id`, `plan` (CHECK 3 tiers), `status` (CHECK 5 estados + `ambiguous`), `ambiguous_reason`, `next_payment_date`, `amount`, `currency`, `external_reference`, `retry_state`, `last_payment_status`, marcas temporales.
- [x] 4.2bis **[D2bis, nuevo]** `public.subscription_intents` creada con `IF NOT EXISTS`: `account_id` NOT NULL, `payer_email` (CHECK normalizado `lower(trim(...))`), `plan`, `preapproval_plan_id`, `status`, `expires_at` (default `now() + interval '24 hours'`), `matched_subscription_id` FK, `matched_at`, marcas temporales. Índice `idx_subscription_intents_reconciliation` sobre `(payer_email, preapproval_plan_id) WHERE status='pending'`.
- [x] 4.3 Índice único parcial `idx_subscriptions_one_live_per_account` — `WHERE status IN ('pending','authorized') AND account_id IS NOT NULL`.
- [x] 4.4 RLS `ENABLE` + policy `SELECT` únicamente en ambas tablas (`current_account_ids()`). Sin `INSERT`/`UPDATE`/`DELETE` para `authenticated`, documentado en `COMMENT ON POLICY` explícito citando el precedente de `bank_accounts`/`cashboxes`. Test de contenido `test_no_write_policies_for_authenticated` lo protege.
- [x] 4.5 CHECK de `operation_idempotency.operation_kind` recreado (`DROP CONSTRAINT IF EXISTS` + `ADD CONSTRAINT`) con la unión de 4.1 (9 valores) **más** `'subscription_webhook'` (10 total).
- [x] 4.6 `SubscriptionPaymentFailed` agregada a `_notification_from_event` con `CREATE OR REPLACE` sobre la misma firma (`public.events`): target `ADMIN`, severidad `warning`, sin `branch_id`. `rpc_process_outbox_dispatch` no tocado.
- [ ] 4.7 **Diferido a PR3** (deliberado): el productor del aviso de vencimiento próximo se implementa junto con el resto del dunning backend (sección 7), no en el PR de esquema — evita mezclar DDL puro con un cron/producer que depende de decisiones aún por afinar en el procesamiento de notificaciones (sección 6).
- [x] 4.8 `REVOKE ALL ... FROM PUBLIC, anon, authenticated` explícito tras `_notification_from_event` y `get_effective_plan` — verificado por `test_notification_from_event_revokes_anon_and_authenticated` y `test_get_effective_plan_revoke_and_grant_reaffirmed`.
- [x] 4.9 No aplica: esta migración no referencia ninguna función que pueda no existir (no usa `::regprocedure` en ningún punto) — se evitó el patrón por completo usando `pg_proc`/`pg_get_constraintdef` en los gates.
- [x] 4.10 Cabecera con propósito, referencia a `design.md`, notas de idempotencia y **rollback textual listo para pegar** (incl. el cuerpo anterior completo de `get_effective_plan`). Verificado por `test_rollback_header_documents_get_effective_plan_restoration`.
- [x] 4.11 Gates estructurales (a)-(g) en el `DO $gate$` de la migración: tablas+RLS, índice parcial, CHECK con unión completa, `_notification_from_event` 1 sola definición, solo policy SELECT en ambas tablas.
- [x] 4.12 Gates de comportamiento (m)-(n): índice parcial rechaza 2da suscripción viva y permite una tras cancelar; `SubscriptionPaymentFailed` produce exactamente 1 `notifications`. 20 tests de contenido en `backend/tests/test_mp_real_subscriptions_migration.py` (todos verdes) como red de seguridad estática — el comportamiento real de los 14 gates corre en CI (`validate-kpis`) cuando el archivo se aplica contra una DB real.

## 5. Migración de `get_effective_plan` (Fase 2) — el paso delicado

- [x] 5.1 Capturado 2026-08-01 (MCP, solo lectura): **34/34 cuentas de producción** — TODAS con `plan_expires_at = NULL` hoy. 33 con `effective_plan='pro'` vía trial vigente, 1 vía `billing_exempt=true`, y **la única cuenta paga real** (`0f627a85-7d01-4323-8b3f-122bd834a4ab`, danielsevilla64: `billing_plan='pro'`, `billing_status='active'`, `plan_expires_at=NULL`, sin exención, sin trial) con `effective_plan='pro'` vía el paso 3 directo. Línea base completa registrada en engram (`opsx/mp-real-subscriptions/apply`).
- [x] 5.2 **RED** — Gate (h) en la migración: `billing_plan='pro'` + `plan_expires_at` pasado debe devolver `'gratis'`. Falla contra la definición actual (que no lee `plan_expires_at`) — confirmado por inspección, la definición vieja no tiene ninguna referencia a esa columna.
- [x] 5.3 **GREEN** — `get_effective_plan(p_account_id uuid)` redefinida con `CREATE OR REPLACE` sobre la misma firma, término de vencimiento en el paso (3). `REVOKE`/`GRANT` reafirmados en el mismo archivo.
- [x] 5.4 **TRIANGULATE** — Gates (i)/(j)/(k)/(l): futuro conserva, NULL conserva (D6), exención gana sobre vencido, trial vigente gana sobre vencido.
- [x] 5.5 **TRIANGULATE** — Gate (a): exactamente 1 definición, `STABLE SECURITY DEFINER`, `search_path` fijo.
- [x] 5.6 **TRIANGULATE** — Gate (b): `authenticated`/`anon` sin `EXECUTE`, `supabase_auth_admin` con `EXECUTE`.
- [x] 5.7 **CRITERIO DE ACEPTACIÓN — verificado post-merge 2026-08-01** (PR #344, merge `8f68302`): recapturado el plan efectivo de las 34 cuentas → **34/34 siguen en `'pro'`, idéntico a la captura pre-merge (5.1). Cero diferencias.** Confirmado además: `get_effective_plan`/`_notification_from_event` con exactamente 1 definición cada una; tablas `subscriptions`/`subscription_intents` existen (2); CHECK de `operation_kind` con los 10 valores incluyendo `subscription_webhook`; `GET /health` → 200.
- [ ] 5.8 **Diferido a PR4** (frontend): el espejo del plan efectivo en frontend se actualiza junto con `/facturacion` (sección 8).

## 6. Backend — alta, baja y procesamiento de notificaciones (Fase 3) — D2bis — ✅ PR3 (#345)

- [x] 6.0 Guard `billing_subscriptions_enabled` en `backend/core/config.py` (default `False`, patrón `tenancy_tx_scope_enabled`) + `mp_plan_id_inicial/avanzado/pro`. Endpoints nuevos → `503` vía dependencia `require_subscriptions_enabled`; el topic de suscripción en el webhook compartido, con la palanca apagada, cae al camino "topic no manejado" (6.11) en vez de 503 (no puede romper el procesamiento de `payment`, que comparte el mismo endpoint). Tests: 2/2 verdes (`TestFeatureFlagGating`).
- [x] 6.1/6.2 `SubscriptionsRepository` (`backend/repositories/subscriptions_repository.py`): alta/búsqueda de intenciones, alta/búsqueda/actualización de `subscriptions`, cola de ambiguos. 13 tests, todos verdes.
- [x] 6.3/6.4 `POST /payments/subscriptions`: crea la intención con el email del usuario autenticado (resuelto server-side, nunca del body), devuelve el `init_point` del plan (construido determinísticamente, sin llamar a la API de MP — verificado en sandbox 2026-08-01), persiste ANTES de responder, rechaza tier inválido/sin `preapproval_plan` configurado/suscripción viva existente/email no resoluble.
- [x] 6.5/6.6 `DELETE /payments/subscriptions`: cancela en MP primero (si falla, cero escritura local — verificado por test dedicado), `plan_expires_at` = `next_payment_date` (fin del período ya pagado, sin gracia extra porque es baja voluntaria), audita `billing_events` (`event_type='subscription_cancelled'`).
- [x] 6.7/6.8 `subscription_preapproval`: reconciliación D2bis completa (0/1/>1 candidatas), activa el plan en el match único, cancelación de un preapproval ya vinculado dispara D8 (`billing_status='cancelling'`), preapproval desconocido en MP (404) no es fatal.
- [x] 6.8bis Implementado como **endpoints REST admin-only** (`GET /payments/subscriptions/ambiguous`, `POST /payments/subscriptions/ambiguous/{id}/resolve`) en vez de una RPC SQL — evita una migración extra; usa la conexión de servicio del backend + `require_admin` ya existente. Activa el plan de la cuenta recién asignada y audita `billing_events` (`subscription_ambiguous_resolved`, distinguible de un match automático).
- [x] 6.9/6.10 `subscription_authorized_payment`: cobro aprobado extiende `plan_expires_at` a `next_payment_date + 10 días` (gracia, 1.3) y audita `billing_events` (`subscription_payment_approved`); rechazado NO toca plan/vencimiento, emite `SubscriptionPaymentFailed` al outbox + `email_logs` con discriminador (`authorized_payment_id`, D10 — verificado con test de 2 fallos distintos); idempotencia por `operation_idempotency` kind `subscription_webhook`; cuota `scheduled` es no-op; preapproval desconocido no es fatal.
- [x] 6.11 Topic no manejado (incluye ambos topics de suscripción con la palanca apagada) → `{"ok":true,"skipped":true}`, sin escrituras.
- [x] 6.12 `billing_events.reason` distingue `subscription_cancelled` (baja voluntaria vs. impago vía MP) de `subscription_ambiguous_resolved` (resolución manual) — texto distinto en cada INSERT.
- [x] 6.13 **REFACTOR/no-regresión**: `test_payment_topic_still_works_non_regression` — el topic `payment` sigue exactamente igual. Suite completa: 1157 passed, 3 skipped (baseline post-PR2 1109 → +48 tests nuevos, 0 regresiones).
- [~] 6.14 **Parcial**: `repo.expire_stale_intents()` implementado y disponible, pero **sin scheduling** (ni cron ni endpoint que lo dispare) — diferido a PR4 junto con el resto de los productores programados (4.7).

**Hallazgo del propio TDD de este PR (no estaba en el plan)**: el primer borrador del dispatch del webhook pasaba `notification.data.id` (del **body**) a los servicios de suscripción — un test de regresión (`test_subscription_id_case_preserved_even_when_body_id_differs`) atrapó que además debía usarse el id del **query param con su case ORIGINAL** (no el lowercased usado para el manifiesto de firma, D9): un ID real de MP es case-sensitive, así que reusar la versión en minúsculas para el `GET /preapproval/{id}` real habría devuelto 404 contra la API de MercadoPago. Corregido antes de mergear — ver `backend/routers/payments.py`, comentario "IMPORTANTE (D9, no confundir...)".

## 7. Correos y campana (Fase 4)

- [ ] 7.1 **RED** — Test: el correo de cobro fallido incluye en `metadata` un discriminador del cobro concreto, y dos cobros fallidos distintos generan **dos** filas en `email_logs` (D10 — sin discriminador, el `UNIQUE NULLS NOT DISTINCT (user_id, event_type, metadata)` descarta el segundo en silencio).
- [ ] 7.2 **GREEN** — Encolado de los correos de renovación, cobro fallido, vencimiento próximo y baja, con sus `event_type` nuevos.
- [ ] 7.3 Plantillas de los `event_type` nuevos en `supabase/functions/send-email/index.ts`, siguiendo las existentes. Verificar que ninguno cae en el texto genérico de respaldo.
- [ ] 7.4 Confirmar que ninguno de los tipos nuevos entra en la allowlist de fan-out a `all_users` (son avisos por cuenta, nunca masivos).
- [ ] 7.5 Etiqueta legible de `SubscriptionPaymentFailed` en la campana, junto a las de los tipos existentes.
- [ ] 7.6 **TRIANGULATE** — Test: el aviso de vencimiento próximo no se encola para cuentas en `gratis` ni con exención vigente, y no se duplica si el barrido corre dos veces para el mismo vencimiento.

## 8. Frontend (Fase 4)

- [ ] 8.1 **RED** — Test: con la palanca ON, el CTA de upgrade en `PlanComparison.tsx` llama al endpoint de suscripciones del backend y redirige al `init_point` del plan devuelto (D2bis — no hay `preapproval_id` propio en esta respuesta); con la palanca OFF, sigue creando la `Preference` de pago único de siempre (no-regresión).
- [ ] 8.2 **GREEN** — Migrar `PlanComparison.tsx` al endpoint nuevo, condicionado a la palanca.
- [ ] 8.3 **RED** — Test: `CancelSubscriptionModal.tsx` muestra la fecha proveniente del período realmente pagado, no un intervalo calculado en el navegador.
- [ ] 8.4 **GREEN** — Migrar `CancelSubscriptionModal.tsx` al endpoint de baja del backend.
- [ ] 8.5 `/facturacion`: mostrar estado de la suscripción, fecha de próximo cobro y, si hay un cobro en reintento, el aviso correspondiente.
- [ ] 8.6 **TRIANGULATE** — Tests: cuenta sin suscripción, con suscripción autorizada y con cobro en reintento renderizan estados distintos y correctos.
- [ ] 8.7 Retirar `frontend/app/api/billing/preferences/route.ts` y `frontend/app/api/billing/cancel/route.ts` (o dejarlos como redirección al backend), y actualizar `frontend/__tests__/billing.test.ts`.

## 9. Activación en producción (Fase 5)

- [ ] 9.0 **[MANUAL PO — condicionado a `v31-mp-upgrade-webhook-fix` 5.1]** Verificar el pago E2E real de `v31-mp-upgrade-webhook-fix` tarea 5.1 (canal de webhook sano). Es la primera de las dos condiciones de la palanca — ver `design.md` Amendment "Activación gated".
- [ ] 9.1 **[MANUAL PO]** Crear los `preapproval_plan` de producción para los tres tiers pagos (1.4: `inicial`, `avanzado`, `pro`), con los precios de `plan_limits`. Registrar los identificadores en la configuración (no en el código). **Instrucciones exactas**: `POST https://api.mercadopago.com/preapproval_plan` con el `MERCADOPAGO_ACCESS_TOKEN` de **producción** (nunca el de test), body `{"reason": "<nombre del tier>", "back_url": "https://www.aliadata.com.ar/facturacion", "auto_recurring": {"frequency": 1, "frequency_type": "months", "transaction_amount": <precio de plan_limits para ese tier>, "currency_id": "ARS"}}`; guardar el `id` de la respuesta (formato: string alfanumérico de 32 chars) como variable de entorno en Render (`MP_PLAN_ID_INICIAL`/`MP_PLAN_ID_AVANZADO`/`MP_PLAN_ID_PRO` o equivalente), **nunca en el código ni en una migración**. Repetir 3 veces, una por tier.
- [ ] 9.2 **[MANUAL PO]** Habilitar los topics `subscription_preapproval` y `subscription_authorized_payment` en el panel de webhooks de MercadoPago, apuntando al webhook del backend.
- [ ] 9.3 **[MANUAL PO]** Verificar que llega y verifica firma al menos una notificación de cada topic nuevo en producción.
- [ ] 9.4 **[MANUAL PO — D12, decisión firmada]** Migrar la cuenta `danielsevilla64` (`accounts.id 0f627a85-7d01-4323-8b3f-122bd834a4ab`): fijar `plan_expires_at` en **activación + 30 días** y enviarle el enlace de la suscripción nueva (el `init_point` del `preapproval_plan` de su tier, creado en 9.1). El mes y medio transcurrido queda de **cortesía**. **Sin cobro retroactivo ni automático.**
- [ ] 9.5 Verificar por consulta de solo lectura que esa cuenta conserva su plan efectivo tras la migración y que su vencimiento quedó donde corresponde.
- [ ] 9.6 **[MANUAL PO]** Confirmar con el PO el primer cobro mensual real cuando ocurra: acreditado, auditado, `plan_expires_at` corrido, correo enviado.
- [ ] 9.7 **[MANUAL PO]** Encender `BILLING_SUBSCRIPTIONS_ENABLED=true` en Render, recién con 9.0 y 9.1 cumplidos. Reversión: apagar la palanca, sin rebuild (mismo patrón que `TENANCY_TX_SCOPE_ENABLED`).

## 10. Documentación y cierre

- [ ] 10.1 Actualizar `CHANGES.md`: estado de `mp-real-subscriptions`, y anotar que **H-19 / `v31-mp-webhook-atomic`** sigue abierto.
- [ ] 10.2 Documentar en la KB (`knowledge-base/05_reglas_de_negocio.md` o donde corresponda) el ciclo de vida de la suscripción y el período de gracia decidido en 1.3.
- [ ] 10.3 Anotar las decisiones de OQ1-OQ4 tal como las resolvió el PO, con fecha.
- [ ] 10.4 `mem_save` con: resultado de la validación de sandbox (2.3), la comparación antes/después de `get_effective_plan` (5.7), las decisiones del PO y el estado de la cuenta migrada.
