> Governance **CRÍTICO** (webhook de pagos, dinero real): **no empezar el apply sin el sign-off explícito del PO** sobre las OQ-1…OQ-5 del `design.md`. TDD estricto: cada tarea de código arranca con su test en rojo. Un solo agente para el apply. Nunca tocar prod; verificación post-merge sólo de lectura.

## 0. Preparación y red de seguridad

- [ ] 0.1 Rama `opsx/mp-cuota-acreditacion-resiliente-apply` desde `origin/main`; `openspec status --change mp-cuota-acreditacion-resiliente` en verde.
- [ ] 0.2 Re-verificar el número de migración libre (`ls supabase/migrations | tail -1`; al proponer, la última era `20261091000001`, se reservó `20261092000001`). Renumerar si fue tomado.
- [ ] 0.3 Safety net: correr y anotar baseline de `backend/tests/test_subscriptions_service.py`, `test_subscriptions_router.py`, `test_subscriptions_repository.py`, `test_payments.py`, `test_subscriptions_apply_approved_charge_integration.py`, `test_subscriptions_webhook_handlers_integration.py` (marker `integration`, stack local de Postgres), y la suite de `fiscal` que cubre `process-pending-cron`. Cualquier rojo preexistente se reporta, no se arregla.
- [ ] 0.4 Releer `_apply_approved_charge`, `replay_subscription_charges`, `_apply_authorized_payment_notification` y `process_payment` en `main` (el diseño cita su forma al 2026-11-05).

## 1. Núcleo compartido de reconciliación (D2, D3)

- [ ] 1.1 RED (`test_subscriptions_service.py`): `reconcile_preapproval_charges` acredita una cuota `processed/approved` sin `billing_event` previo con `plan_expires_at = next_payment_date del preapproval + 10 días`, y la reporta en `applied`.
- [ ] 1.2 RED: una cuota cuyo `billing_event` ya existía se reporta en `already_applied` y se aplica con `plan_expires_at=None` (D3) — caso real: preapproval con `next_payment_date` del mes siguiente y la cuota del mes en curso todavía `scheduled` → el vencimiento de la cuenta NO cambia.
- [ ] 1.3 RED: un 5xx de `GET /preapproval` o de `/authorized_payments/search` levanta 502 antes de cualquier escritura (ningún `execute`).
- [ ] 1.4 GREEN: extraer `reconcile_preapproval_charges(subscription, repo, conn)` del cuerpo de `replay_subscription_charges` (llamadas HTTP antes de cualquier transacción); `replay_subscription_charges` queda como envoltorio admin (404/409) que la llama. Sin duplicar ninguna escritura: todo efecto de dinero sigue en `_apply_approved_charge`.
- [ ] 1.5 TRIANGULAR: los tests existentes del replay (H4: reaplicación que completa un correo faltante, orden por id, `last_payment_status` sin `scheduled`, `clear_pending_charge`) siguen verdes sin tocarlos, salvo los que asserteaban el vencimiento para cuotas ya acreditadas (ajustarlos a D3 y dejarlo dicho en el PR).
- [ ] 1.6 Integración (`test_subscriptions_apply_approved_charge_integration.py`, Postgres real): `plan_expires_at=None` conserva el vencimiento vigente y completa el correo pendiente.

## 2. Serialización por suscripción (D7)

- [ ] 2.1 RED (integración): dos aplicaciones concurrentes de la misma cuota con distinto `plan_expires_at` dejan UNA fila de `billing_events` y UNA de `email_logs`.
- [ ] 2.2 GREEN: primera sentencia de la transacción de `_apply_approved_charge` = `SELECT pg_advisory_xact_lock(hashtextextended('subscription_charge:' || $1, 0))` con el `preapproval_id`.
- [ ] 2.3 Verificar que `_claim_subscription_webhook_idempotency` sigue exigiendo transacción (#641) y que ningún camino nuevo lo llama fuera de una.

## 3. Barrido programado (D4, D5)

- [ ] 3.1 RED (`test_subscriptions_repository.py`): `find_subscriptions_due_for_reconciliation(limit)` devuelve sólo `status='authorized'` con cuenta y `plan_expires_at` en `(now() - 30 días, now() + 10 días]`, ordenadas por `plan_expires_at`, con `LIMIT`; excluye `ambiguous`, `cancelled`, sin cuenta y `plan_expires_at` nulo. Caso noviembre: vencimiento 2026-11-14 20:54 → seleccionada desde 2026-11-04 20:54.
- [ ] 3.2 GREEN: implementar el método (consulta parametrizada, filtro explícito; `GRACE_PERIOD` y la ventana como constantes del servicio, nunca literales duplicados).
- [ ] 3.3 RED (`test_subscriptions_service.py`): `reconcile_due_subscriptions(repo, conn)` llama al núcleo por cada suscripción; un 502 en una no impide la siguiente; devuelve `{checked, applied, errors}`; con la palanca `billing_subscriptions_enabled` apagada no consulta nada.
- [ ] 3.4 GREEN: implementar `reconcile_due_subscriptions`.
- [ ] 3.5 RED (`backend/tests/test_core_guards.py` o el archivo de guards existente): `require_relay_secret` → 401 sin secreto configurado, sin header, con secreto erróneo; pasa con el correcto (comparación con `hmac.compare_digest`).
- [ ] 3.6 GREEN: extraer `require_relay_secret` a `backend/core/guards.py` y migrar `backend/routers/fiscal.py::process_pending_cae_cron` a la dependencia; la suite de fiscal del 0.3 sigue verde.
- [ ] 3.7 RED (`test_subscriptions_router.py`): `POST /payments/subscriptions/reconcile-cron` 401 sin secreto; 200 `skipped` con la palanca apagada; 200 con el resumen con la palanca encendida; usa `get_service_conn`.
- [ ] 3.8 GREEN: endpoint en `backend/routers/payments.py` (router sólo valida + DI; lógica en el servicio). Schema Pydantic v2 de la respuesta en `backend/schemas/payments.py`.
- [ ] 3.9 Migración `supabase/migrations/20261092000001_mp_cuota_reconciliacion_cron.sql`: `rpc_trigger_subscription_reconcile()` `SECURITY DEFINER`, `SET search_path = public, vault`, molde de `rpc_trigger_cae_relay()` (`20260719000001_c27_cae_relay_trigger.sql`, leer su versión VIVA vía `pg_get_functiondef` en local); `RAISE WARNING` y salida limpia si faltan los secretos de Vault; `REVOKE EXECUTE … FROM PUBLIC, anon, authenticated`; `cron.schedule('subscription-reconcile-charges', '7 * * * *', …)` idempotente.
- [ ] 3.10 Gate SQL `supabase/tests/test_mp_cuota_reconciliacion_cron.sql` que EJECUTE la función (sin secretos de Vault → no falla) y verifique ACLs y el job; cablearlo en `.github/workflows/KPI_Validation.yml`; correrlo contra `supabase db reset` local.

## 4. Webhook `payment` como acelerador (D6)

- [ ] 4.1 RED (`test_payments.py`): `payment` aprobado con `external_reference` vacío y `metadata.preapproval_id` de una suscripción con cuenta → llama al núcleo y responde `{"ok": true, "reconciled": "subscription_charge"}`.
- [ ] 4.2 RED: mismo pago con `operation_type=recurring_payment` sin `metadata.preapproval_id`, con preapproval desconocido o con suscripción sin cuenta → `ignored="subscription_charge"` y ningún `execute` (contrato actual intacto).
- [ ] 4.3 RED: error de MercadoPago dentro del núcleo → 502 sin escrituras.
- [ ] 4.4 RED: pago ya acreditado (fila en `billing_events` con ese `mercadopago_payment_id`) → `idempotent` sin consultar MercadoPago (check existente).
- [ ] 4.5 GREEN: implementar la rama en `process_payment` (`WebhookResponse` gana `reconciled: str | None`); el servicio de pagos recibe el repositorio de suscripciones por parámetro, sin import circular.
- [ ] 4.6 Integración (`test_subscriptions_webhook_handlers_integration.py`): `payment` con `metadata.preapproval_id` acredita; la notificación tardía `processed/approved` de la misma cuota después no duplica nada.

## 5. Observabilidad (D8)

- [ ] 5.1 RED: test que verifique que, tras importar `backend.main`, el logger `backend` emite `INFO` (nivel efectivo) y que la línea del marcador incluye marcador, preapproval y resultado, sin email ni nombre del pagador (`caplog`).
- [ ] 5.2 GREEN: configurar el logger `backend` en `backend/main.py` (handler a stdout, nivel INFO, sin tocar uvicorn ni el root); ajustar la línea del marcador en `process_payment`.

## 6. Superficie admin (D9)

- [ ] 6.1 RED (`test_subscriptions_repository.py` / router): `list_recent_subscriptions` devuelve `plan_expires_at` y `last_charge_credited_at` (máximo `created_at` de `subscription_payment_approved` del preapproval; `None` sin cobros); schema de salida actualizado.
- [ ] 6.2 GREEN: consulta + schema.
- [ ] 6.3 RED (`frontend/__tests__/SuscripcionesAmbiguasPage.test.tsx`, `frontend/__tests__/hooks/use-ambiguous-subscriptions.test.ts`): la tabla "Suscripciones recientes" muestra "Plan vence" y "Último cobro acreditado", y "Sin cobros" cuando es nulo.
- [ ] 6.4 GREEN: tipos en `frontend/hooks/data/use-ambiguous-subscriptions.ts` (sin `any`) y columnas en `frontend/app/(dashboard)/admin/pagos/ambiguas/page.tsx` con tokens semánticos y el formateador de fecha existente.
- [ ] 6.5 Verificación visual: desktop y móvil (375 px), tema claro y oscuro, con el arnés local (sin tocar prod).

## 7. Verificación y cierre del apply

- [ ] 7.1 Backend completo (`pytest`, cobertura ≥ umbral de CI) + tier `integration` + `tsc` + vitest de los archivos tocados.
- [ ] 7.2 Revisión adversarial del diff enfocada en: escrituras de dinero fuera de `_apply_approved_charge`, transacciones abiertas durante llamadas HTTP, caminos que extiendan el vencimiento sin cuota nueva, respuestas 4xx/5xx que dejen a MercadoPago reintentando para siempre.
- [ ] 7.3 Ficha de apply en `CHANGES.md` + fila en `docs/pendientes-manuales-po.md`. PR con conventional commit, sin auto-merge.
- [ ] 7.4 Post-merge (sólo lectura): deploy de Render confirmado; migración viva; `cron.job` activo y `cron.job_run_details` con corridas `succeeded`; línea INFO del barrido en los logs de Render.
- [ ] 7.5 Prueba real con el cobro del 2026-12-04 de la suscripción `fa624f9b-32e5-4b5c-ad0d-fc64e6dc16b1`: `billing_event` del pago de diciembre y `plan_expires_at` ≈ 2027-01-14 SIN replay manual (si llegó por el barrido o por la notificación, anotarlo).
