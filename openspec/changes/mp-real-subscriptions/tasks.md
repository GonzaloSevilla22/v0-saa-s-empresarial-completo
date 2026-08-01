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

- [ ] 4.1 Antes de escribir nada: leer con MCP (solo lectura) `pg_get_constraintdef` del CHECK de `operation_idempotency.operation_kind` en **producción** y anotar acá la unión vigente completa (**lección C3** — CI corre con base vacía y no atrapa un kind faltante).
- [ ] 4.2 Crear `public.subscriptions` con `IF NOT EXISTS`: `account_id` (**nullable**, D2bis), `preapproval_id` único, `preapproval_plan_id`, `plan`, `status`, `next_payment_date`, `amount`, `currency`, `external_reference`, estado de reintento, marcas temporales.
- [ ] 4.2bis **[D2bis, nuevo]** Crear `public.subscription_intents` con `IF NOT EXISTS`: `account_id` (NOT NULL), `payer_email` normalizado, `plan`, `preapproval_plan_id`, `status` (`pending`/`matched`/`ambiguous`/`expired`/`cancelled`), `expires_at` (default `now() + interval '24 hours'`), `matched_subscription_id` FK a `subscriptions`, `matched_at`, marcas temporales. Índice sobre `(payer_email, preapproval_plan_id, status) WHERE status = 'pending'` para la búsqueda de reconciliación.
- [ ] 4.3 Índice único **parcial** que garantice como máximo una suscripción viva por cuenta (`WHERE status IN ('pending','authorized') AND account_id IS NOT NULL`) — patrón `client_addresses` de v3-catalog-masters.
- [ ] 4.4 RLS en ambas tablas: `ENABLE` + policy de `SELECT` por membresía de cuenta (en `subscription_intents`, `account_id` siempre NOT NULL así que la policy es directa; en `subscriptions`, una fila con `account_id IS NULL` —ambigua— no es visible a ningún `authenticated`, solo al backend). **Sin** policies de `INSERT`/`UPDATE`/`DELETE` para `authenticated` (deliberado: solo escribe el backend). Documentarlo en un `COMMENT` para que no se lea como el olvido que sí ocurrió con `bank_accounts`/`cashboxes`.
- [ ] 4.5 Recrear el CHECK de `operation_idempotency.operation_kind` con la unión de 4.1 **más** el kind nuevo de notificaciones de suscripción.
- [ ] 4.6 Agregar `SubscriptionPaymentFailed` a la lista en-scope de `_notification_from_event` con `CREATE OR REPLACE` sobre la **misma firma** (`public.events`): target `ADMIN`, severidad `warning`, sin `branch_id`. **No tocar** `rpc_process_outbox_dispatch`.
- [ ] 4.7 Productor del aviso de vencimiento próximo de plan pago (barrido programado), con dedup por cuenta y vencimiento.
- [ ] 4.8 Tras **cada** función definida o redefinida en esta migración: `REVOKE ALL ... FROM PUBLIC, anon, authenticated` explícito. El `REVOKE FROM PUBLIC` solo NO alcanza (PR #337).
- [ ] 4.9 Usar `to_regprocedure()` para toda referencia a funciones que puedan no existir en la base donde corre la migración.
- [ ] 4.10 Cabecera de la migración con: propósito, referencia a `design.md`, nota de idempotencia y **rollback textual listo para pegar**.
- [ ] 4.11 Gates SQL estructurales: la tabla y el índice parcial existen; RLS activa; el CHECK contiene la unión completa; cada función redefinida tiene **exactamente una** definición (42725); `anon` y `authenticated` sin `EXECUTE`.
- [ ] 4.12 Gates SQL de comportamiento (solo con `accounts` vacía — CI): el índice parcial rechaza una segunda suscripción viva y permite una tras cancelar; un evento `SubscriptionPaymentFailed` produce exactamente una `notifications` para los owners.

## 5. Migración de `get_effective_plan` (Fase 2) — el paso delicado

- [ ] 5.1 Capturar y guardar el plan efectivo **actual** de **todas** las cuentas de producción (consulta de solo lectura por MCP). Es la línea base de la verificación de 5.7.
- [ ] 5.2 **RED** — Gate SQL en la migración nueva: una cuenta con `billing_plan` pago, sin exención ni trial, y `plan_expires_at` en el pasado devuelve `'gratis'`. Debe fallar contra la definición actual.
- [ ] 5.3 **GREEN** — Redefinir `public.get_effective_plan(p_account_id uuid)` con `CREATE OR REPLACE` sobre la **misma firma** (un solo parámetro — agregar uno crearía un overload 42725), incorporando el término de vencimiento en el paso (3) de la precedencia. Reafirmar `REVOKE` de `PUBLIC`/`anon`/`authenticated` y `GRANT` a `supabase_auth_admin`/`service_role` **en el mismo archivo**.
- [ ] 5.4 **TRIANGULATE** — Gates: `plan_expires_at` **futuro** conserva el plan; `plan_expires_at` **nulo** conserva el plan (D6, semántica permisiva); exención gana sobre plan pago vencido; trial vigente gana sobre plan pago vencido.
- [ ] 5.5 **TRIANGULATE** — Gate: la función queda con **exactamente una** definición y sigue siendo `STABLE SECURITY DEFINER` con `search_path` fijo.
- [ ] 5.6 **TRIANGULATE** — Gate: `authenticated` y `anon` sin `EXECUTE`; `supabase_auth_admin` con `EXECUTE` (lo necesita el hook de emisión de tokens — romper esto rompe el login).
- [ ] 5.7 **CRITERIO DE ACEPTACIÓN, no opcional**: tras aplicar, recapturar el plan efectivo de todas las cuentas y **compararlo contra 5.1**. Cualquier diferencia no prevista → **revertir con el rollback textual de la cabecera** y reportar antes de continuar.
- [ ] 5.8 Actualizar el espejo del plan efectivo en el frontend para que contemple el vencimiento, y un test de paridad sobre los tres casos (nulo / futuro / pasado).

## 6. Backend — alta, baja y procesamiento de notificaciones (Fase 3) — D2bis

- [ ] 6.0 Guard `BILLING_SUBSCRIPTIONS_ENABLED` (config nueva en `backend/core/config.py`, default `False`, mismo patrón que `tenancy_tx_scope_enabled`): con la palanca apagada, los endpoints nuevos responden `503`/no se registran, y `process_payment` (pago único) sigue siendo el único camino. Test: apagada → 503; encendida → sigue de largo.
- [ ] 6.1 **RED** — Tests del repositorio de suscripciones e intenciones: alta de intención, búsqueda de intenciones `pending` por `(payer_email, preapproval_plan_id)`, alta/búsqueda de `subscriptions` por `preapproval_id`, búsqueda de la suscripción viva de una cuenta, actualización de estado y de fecha de próximo cobro, marcar intención `matched`/`ambiguous`/`expired`.
- [ ] 6.2 **GREEN** — Repositorios de `subscriptions` y `subscription_intents` siguiendo el patrón de repositorios existente (3 capas, JWT-passthrough; nada de `service_role`).
- [ ] 6.3 **RED** — Tests del alta `POST /payments/subscriptions` (D2bis): crea una fila en `subscription_intents` con el `payer_email` de la cuenta autenticada, normalizado; devuelve el `init_point` del `preapproval_plan` del tier pedido (**no** crea ningún `preapproval`); rechaza sin autenticación; rechaza un tier sin plan registrado; rechaza si ya hay una suscripción viva.
- [ ] 6.4 **GREEN** — Endpoint de alta + schemas Pydantic v2 + service con la lógica de D2bis.
- [ ] 6.5 **RED** — Tests de la baja: cancela el `preapproval` en MercadoPago, marca la cuenta como cancelando con el `plan_expires_at` **real**, audita el evento; si la cancelación en MercadoPago falla, **no** deja estado local inconsistente; rechaza si no hay suscripción viva.
- [ ] 6.6 **GREEN** — Endpoint de baja + service.
- [ ] 6.7 **RED** — Tests de `subscription_preapproval` con reconciliación D2bis: `GET /preapproval/{id}` + búsqueda en `subscription_intents` por email normalizado + plan + `pending` + `expires_at > now()`; **exactamente una coincidencia** → activa la suscripción, marca la intención `matched`; **cero coincidencias** → crea `subscriptions` con `account_id NULL` y `status='ambiguous'` (motivo `no_match`), emite aviso a `ADMIN`; **más de una coincidencia** → igual, `status='ambiguous'` (motivo `multiple_match`), sin adivinar; cancelación de un `preapproval` ya vinculado a una cuenta programa la degradación por el camino de `process_cancellations()` (D8); una notificación de un `preapproval` totalmente desconocido no es fatal y queda logueada.
- [ ] 6.8 **GREEN** — Procesamiento del topic `subscription_preapproval` en `backend/services/payments.py`, con la reconciliación de 6.7.
- [ ] 6.8bis **RED→GREEN** — RPC/consulta de la cola de ambiguos (`subscriptions WHERE account_id IS NULL` + intenciones candidatas) y RPC de resolución manual (`SECURITY DEFINER`, rol admin) que asigna `account_id` y audita en `billing_events`. Sin UI en este change (fuera de alcance) — alcanza con la RPC + consulta para soporte manual.
- [ ] 6.9 **RED** — Tests de `subscription_authorized_payment`: cobro aprobado extiende `plan_expires_at` a `next_payment_date` + gracia (10 días, 1.3) y audita en `billing_events`; redelivery de la misma notificación es no-op; cobro rechazado emite el aviso y **no** cambia plan ni vencimiento; un reintento posterior se procesa como evento propio; un cobro sobre una suscripción `ambiguous` (`account_id NULL`) se acredita en `billing_events` sin cuenta asignada y queda visible en la cola de ambiguos — **nunca se pierde**.
- [ ] 6.10 **GREEN** — Procesamiento del topic `subscription_authorized_payment`, con la idempotencia por `operation_idempotency` del kind nuevo.
- [ ] 6.11 **TRIANGULATE** — Test: un topic no manejado devuelve éxito sin escrituras (para que MercadoPago no reintente indefinidamente).
- [ ] 6.12 **TRIANGULATE** — Test: el motivo registrado en `billing_events` distingue baja voluntaria de cancelación por impago de resolución manual de ambiguos.
- [ ] 6.13 **REFACTOR** — Revisar que `process_payment` (pagos únicos) sigue funcionando sin cambios de comportamiento: durante la transición todavía puede llegar un pago único en vuelo. Correr la suite completa contra el baseline de 1.2.
- [ ] 6.14 **TRIANGULATE** — Barrido que marca `expired` las `subscription_intents` con `expires_at < now()` y `status='pending'` sin match — no borra, queda para auditoría.

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
