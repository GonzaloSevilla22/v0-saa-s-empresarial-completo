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

- [ ] 1.1 Verificar que `v31-mp-upgrade-webhook-fix` está aplicado y que su verificación E2E (tarea 5.1) pasó. Si no, **detenerse**: este change no puede verificarse.
- [ ] 1.2 Baseline de tests: suite backend (`pytest backend/tests`) y frontend (`pnpm vitest run`). Registrar los conteos. Fallos preexistentes se reportan, no se arreglan acá.
- [ ] 1.3 **[MANUAL PO — resuelve OQ2]** Definir el período de gracia entre `next_payment_date` y `plan_expires_at`. Opciones y recomendación (10 días, igual a la ventana de reintentos de MercadoPago) en `design.md` OQ2. Anotar la decisión acá.
- [ ] 1.4 **[MANUAL PO — resuelve OQ3]** Definir si `inicial` se contrata por suscripción o solo `avanzado` y `pro`. Recomendación: los tres tiers pagos (hoy `inicial` es contratable; excluirlo sería una regresión). Anotar acá.
- [ ] 1.5 **[MANUAL PO — resuelve OQ4]** Definir el comportamiento del cambio de tier con suscripción viva. Recomendación: cancelar y crear una nueva con inicio al fin del período pagado. Anotar acá.
- [ ] 1.6 **[MANUAL PO — resuelve OQ1]** Confirmar que la semántica de `plan_expires_at IS NULL` queda **permisiva** en este change y que el endurecimiento va en uno posterior. Anotar acá.

## 2. Sandbox — validación bloqueante de la API (Fase 0)

- [ ] 2.1 **[MANUAL PO]** Obtener credenciales de test de MercadoPago (`TEST-...`) y confirmar que están disponibles para el entorno de desarrollo. **Nunca credenciales de producción en desarrollo.**
- [ ] 2.2 En sandbox, crear un `preapproval_plan` de prueba (`reason`, `back_url`, `auto_recurring` mensual en ARS) y registrar los campos exactos de la respuesta (`id`, `init_point`, `status`).
- [ ] 2.3 **BLOQUEANTE — valida D2**: crear un `preapproval` con `preapproval_plan_id`, `payer_email`, `external_reference` y `status: "pending"`, **sin** `card_token_id`. Verificar que la respuesta trae un `init_point` utilizable y que conserva el `external_reference`. Documentar el resultado literal acá.
- [ ] 2.4 Si 2.3 falla: **detener la implementación**, documentar el comportamiento real y elevar al PO el fallback de `design.md` D2 (redirigir al `init_point` del plan + reconciliar por `payer_email`), señalando que degrada la garantía de atribución de dinero.
- [ ] 2.5 Completar en sandbox el flujo de autorización del pagador y registrar la notificación `subscription_preapproval` recibida: query params, headers y cuerpo (sin secretos).
- [ ] 2.6 Registrar una notificación `subscription_authorized_payment` de sandbox y los campos de `GET /authorized_payments/{id}` (`status`, `payment.id`, `payment.status`, `retry_attempt`, `next_retry_date`, `debit_date`).
- [ ] 2.7 Confirmar contra las notificaciones reales de 2.5/2.6 que el `data.id` viene como **query param** y que los IDs de `preapproval` son **alfanuméricos** (fundamento de D9).

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
- [ ] 4.2 Crear `public.subscriptions` con `IF NOT EXISTS`: `account_id`, `preapproval_id` único, `preapproval_plan_id`, `plan`, `status`, `next_payment_date`, `amount`, `currency`, `external_reference`, estado de reintento, marcas temporales.
- [ ] 4.3 Índice único **parcial** que garantice como máximo una suscripción viva por cuenta (`WHERE status IN ('pending','authorized')`) — patrón `client_addresses` de v3-catalog-masters.
- [ ] 4.4 RLS: `ENABLE` + policy de `SELECT` por membresía de cuenta. **Sin** policies de `INSERT`/`UPDATE`/`DELETE` para `authenticated` (deliberado: solo escribe el backend). Documentarlo en un `COMMENT` para que no se lea como el olvido que sí ocurrió con `bank_accounts`/`cashboxes`.
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

## 6. Backend — alta, baja y procesamiento de notificaciones (Fase 3)

- [ ] 6.1 **RED** — Tests del repositorio de suscripciones: alta, búsqueda por `preapproval_id`, búsqueda de la suscripción viva de una cuenta, actualización de estado y de fecha de próximo cobro.
- [ ] 6.2 **GREEN** — Repositorio de `subscriptions` siguiendo el patrón de repositorios existente (3 capas, JWT-passthrough; nada de `service_role`).
- [ ] 6.3 **RED** — Tests del alta `POST /payments/subscriptions`: crea el `preapproval` con `preapproval_plan_id`, `payer_email`, `external_reference`; **persiste antes** de devolver la URL de autorización; rechaza sin autenticación; rechaza un tier sin plan registrado; rechaza si ya hay una suscripción viva.
- [ ] 6.4 **GREEN** — Endpoint de alta + schemas Pydantic v2 + service con la lógica.
- [ ] 6.5 **RED** — Tests de la baja: cancela el `preapproval` en MercadoPago, marca la cuenta como cancelando con el `plan_expires_at` **real**, audita el evento; si la cancelación en MercadoPago falla, **no** deja estado local inconsistente; rechaza si no hay suscripción viva.
- [ ] 6.6 **GREEN** — Endpoint de baja + service.
- [ ] 6.7 **RED** — Tests de `subscription_preapproval`: autorización activa la suscripción y guarda `next_payment_date`; cancelación programa la degradación por el camino de `process_cancellations()` (D8); una notificación de una suscripción desconocida no es fatal y queda logueada.
- [ ] 6.8 **GREEN** — Procesamiento del topic `subscription_preapproval` en `backend/services/payments.py`.
- [ ] 6.9 **RED** — Tests de `subscription_authorized_payment`: cobro aprobado extiende `plan_expires_at` a `next_payment_date` + gracia y audita en `billing_events`; redelivery de la misma notificación es no-op; cobro rechazado emite el aviso y **no** cambia plan ni vencimiento; un reintento posterior se procesa como evento propio.
- [ ] 6.10 **GREEN** — Procesamiento del topic `subscription_authorized_payment`, con la idempotencia por `operation_idempotency` del kind nuevo.
- [ ] 6.11 **TRIANGULATE** — Test: un topic no manejado devuelve éxito sin escrituras (para que MercadoPago no reintente indefinidamente).
- [ ] 6.12 **TRIANGULATE** — Test: el motivo registrado en `billing_events` distingue baja voluntaria de cancelación por impago.
- [ ] 6.13 **REFACTOR** — Revisar que `process_payment` (pagos únicos) sigue funcionando sin cambios de comportamiento: durante la transición todavía puede llegar un pago único en vuelo. Correr la suite completa contra el baseline de 1.2.

## 7. Correos y campana (Fase 4)

- [ ] 7.1 **RED** — Test: el correo de cobro fallido incluye en `metadata` un discriminador del cobro concreto, y dos cobros fallidos distintos generan **dos** filas en `email_logs` (D10 — sin discriminador, el `UNIQUE NULLS NOT DISTINCT (user_id, event_type, metadata)` descarta el segundo en silencio).
- [ ] 7.2 **GREEN** — Encolado de los correos de renovación, cobro fallido, vencimiento próximo y baja, con sus `event_type` nuevos.
- [ ] 7.3 Plantillas de los `event_type` nuevos en `supabase/functions/send-email/index.ts`, siguiendo las existentes. Verificar que ninguno cae en el texto genérico de respaldo.
- [ ] 7.4 Confirmar que ninguno de los tipos nuevos entra en la allowlist de fan-out a `all_users` (son avisos por cuenta, nunca masivos).
- [ ] 7.5 Etiqueta legible de `SubscriptionPaymentFailed` en la campana, junto a las de los tipos existentes.
- [ ] 7.6 **TRIANGULATE** — Test: el aviso de vencimiento próximo no se encola para cuentas en `gratis` ni con exención vigente, y no se duplica si el barrido corre dos veces para el mismo vencimiento.

## 8. Frontend (Fase 4)

- [ ] 8.1 **RED** — Test: el CTA de upgrade en `PlanComparison.tsx` llama al endpoint de suscripciones del backend y redirige a la URL de autorización.
- [ ] 8.2 **GREEN** — Migrar `PlanComparison.tsx` al endpoint nuevo.
- [ ] 8.3 **RED** — Test: `CancelSubscriptionModal.tsx` muestra la fecha proveniente del período realmente pagado, no un intervalo calculado en el navegador.
- [ ] 8.4 **GREEN** — Migrar `CancelSubscriptionModal.tsx` al endpoint de baja del backend.
- [ ] 8.5 `/facturacion`: mostrar estado de la suscripción, fecha de próximo cobro y, si hay un cobro en reintento, el aviso correspondiente.
- [ ] 8.6 **TRIANGULATE** — Tests: cuenta sin suscripción, con suscripción autorizada y con cobro en reintento renderizan estados distintos y correctos.
- [ ] 8.7 Retirar `frontend/app/api/billing/preferences/route.ts` y `frontend/app/api/billing/cancel/route.ts` (o dejarlos como redirección al backend), y actualizar `frontend/__tests__/billing.test.ts`.

## 9. Activación en producción (Fase 5)

- [ ] 9.1 **[MANUAL PO]** Crear los `preapproval_plan` de producción para los tiers decididos en 1.4, con los precios de `plan_limits`. Registrar los identificadores en la configuración (no en el código).
- [ ] 9.2 **[MANUAL PO]** Habilitar los topics `subscription_preapproval` y `subscription_authorized_payment` en el panel de webhooks de MercadoPago, apuntando al webhook del backend.
- [ ] 9.3 **[MANUAL PO]** Verificar que llega y verifica firma al menos una notificación de cada topic nuevo en producción.
- [ ] 9.4 **[MANUAL PO — D12, decisión firmada]** Migrar la cuenta `danielsevilla64` (`accounts.id 0f627a85-7d01-4323-8b3f-122bd834a4ab`): fijar `plan_expires_at` en **activación + 30 días** y enviarle el enlace de la suscripción nueva. El mes y medio transcurrido queda de **cortesía**. **Sin cobro retroactivo ni automático.**
- [ ] 9.5 Verificar por consulta de solo lectura que esa cuenta conserva su plan efectivo tras la migración y que su vencimiento quedó donde corresponde.
- [ ] 9.6 **[MANUAL PO]** Confirmar con el PO el primer cobro mensual real cuando ocurra: acreditado, auditado, `plan_expires_at` corrido, correo enviado.

## 10. Documentación y cierre

- [ ] 10.1 Actualizar `CHANGES.md`: estado de `mp-real-subscriptions`, y anotar que **H-19 / `v31-mp-webhook-atomic`** sigue abierto.
- [ ] 10.2 Documentar en la KB (`knowledge-base/05_reglas_de_negocio.md` o donde corresponda) el ciclo de vida de la suscripción y el período de gracia decidido en 1.3.
- [ ] 10.3 Anotar las decisiones de OQ1-OQ4 tal como las resolvió el PO, con fecha.
- [ ] 10.4 `mem_save` con: resultado de la validación de sandbox (2.3), la comparación antes/después de `get_effective_plan` (5.7), las decisiones del PO y el estado de la cuenta migrada.
