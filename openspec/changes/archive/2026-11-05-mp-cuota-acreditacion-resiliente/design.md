## Context

**Cómo se acredita hoy un cobro mensual.** MercadoPago manda dos notificaciones por cobro: `payment` (el dinero) y `subscription_authorized_payment` (la cuota). `process_payment` (`backend/services/payments.py`) reconoce la primera como cobro de suscripción con `_subscription_charge_marker` (tres marcadores: `operation_type=recurring_payment`, `point_of_interaction.type=SUBSCRIPTIONS`, `metadata.preapproval_id`) y la ignora a propósito (`ignored="subscription_charge"`, ítem B(1) de #526). La acreditación ocurre sólo en `process_subscription_authorized_payment_notification` → `_apply_authorized_payment_notification` → `_apply_approved_charge` cuando la cuota llega `processed` + `payment.status=approved`, con clave de idempotencia `authorized_payment:{id}:{status}:{payment_status}` en `operation_idempotency` (`subscription_webhook`), reclamada DENTRO de la transacción de los efectos (#641).

**Hechos de producción (medidos el 2026-11-05, sólo lectura; se citan, no se re-miden).**

| Mes | Notificaciones recibidas | Resultado |
|---|---|---|
| Octubre | `authorized_payment:7032577415:scheduled:None` 21:02:37 UTC y `…:processed:approved` 21:02:49 (12 s después) | acreditado (tras el fix #641) |
| Noviembre | `payment` 187789722328 a las 21:13:13 UTC (200, ignorada; reintento 22:44:32, 200, ignorada) y `authorized_payment:7033613241:scheduled:None` (200, sin efecto por diseño). La cuota en `processed/approved` **nunca llegó**: historial de MP de la app ALIADATA (5864120912417849, consultado 05-11 16:30 UTC) = 1 `payment` + 1 `subscription_authorized_payment`, 0 fallidas, 0 pendientes | dinero cobrado ("a liquidar el 22-11: $23.851,64"), `plan_expires_at` quedó en 2026-11-14, sin `billing_event` ni correo |

Reparación del PO (2026-11-05 16:37:50 UTC): `POST /payments/subscriptions/fa624f9b-…/replay-charges` → `billing_events` `subscription_payment_approved` $24.900 `mercadopago_payment_id=187789722328` con `{preapproval_id, authorized_payment_id: 7033613241}`, correo enviado, `plan_expires_at = 2026-12-14 20:54:19+00`, `next_payment_date = 2026-12-04 20:54:19+00`. **El replay ya es la acreditación correcta**; lo que falta es que alguien lo dispare sin depender de la notificación de la cuota.

**Hallazgo de observabilidad (verificado en código).** `backend/main.py` sólo hace `logging.getLogger("app")`; no hay `logging.basicConfig` ni `dictConfig` en `backend/`. Uvicorn configura únicamente sus propios loggers, así que `backend.services.payments` hereda el root en `WARNING` y **toda línea `logger.info` del backend se descarta** (sólo pasan `warning`/`error` por el handler de último recurso). Por eso la línea `"[payments] notificación payment %s de cobro de suscripción ignorada (marker=%s)"` no aparece en Render para 187789722328, y por eso tampoco aparecen las INFO del propio webhook (`[payments/webhook] type=… origin=…`, el requirement "Notification origin is observable" de `payment-webhook` hoy no se cumple en prod). No sabemos cuál de los tres marcadores aplicó a ese pago.

**Qué trae un `payment` de suscripción.** La documentación de MercadoPago (búsqueda por el MCP el 05-11) documenta el topic `subscription_authorized_payment` → `GET /authorized_payments/{id}`, pero no garantiza un campo del pago que lo vincule al preapproval. El único vínculo positivo que el código ya reconoce es `metadata.preapproval_id`; el pago 177298997676 de septiembre no traía ninguno de los tres marcadores (fix `mp-webhook-external-reference-vacio`, 2026-09-11). `subscriptions` no guarda `payer_id`. Conclusión: **del `payment` al preapproval no hay un camino garantizado**; cualquier diseño que dependa sólo de él repite el problema con otra notificación.

## Goals / Non-Goals

**Goals:**
- Que el cobro mensual aprobado se acredite solo aunque MercadoPago no emita la notificación de la cuota `processed`, con una latencia acotada (≤ 1 h) y muy inferior a los 10 días de gracia.
- Una sola definición de "acreditar las cuotas aprobadas de un preapproval" para replay admin, barrido y webhook.
- Cerrar el riesgo de extender el plan sin cobro que el barrido automático amplificaría.
- Que el diagnóstico de una notificación ignorada sea visible en los logs de Render.

**Non-Goals:**
- Cambiar el contrato del replay admin (`POST /payments/subscriptions/{id}/replay-charges`) ni la cola de ambiguas.
- Acreditar automáticamente suscripciones SIN cuenta (`ambiguous`): siguen en la cola manual; el barrido no las toca (no hay plan que extender).
- Volver a acreditar desde `payment` vía `external_reference` (sigue siendo sólo del checkout one-shot).
- Cambios de esquema de tablas o del flujo de checkout.

## Decisions

### D1 — Opción recomendada: C' = barrido programado (B) como red principal + webhook `payment` como acelerador acotado (A restringido a `metadata.preapproval_id`)

| Opción | Cubre noviembre | Depende de | Latencia | Riesgo |
|---|---|---|---|---|
| A pura (acreditar desde `payment`) | sólo si el pago trae un vínculo al preapproval — no garantizado (el de septiembre no traía ninguno) | otra notificación no garantizada + un vínculo no documentado | segundos | repite el problema con otra notificación |
| B pura (reconciliación programada) | sí, sin depender de ninguna notificación | `pg_cron` + `pg_net` (ya en prod: `relay-process-pending-cae`, `cobranzas-overdue-digest-sweep`) | ≤ 1 h | Render frío (~50 s) → el `keep-backend-warm` ya lo mitiga; reintento natural a la hora siguiente |
| **C' (recomendada)** | sí | B; A sólo cuando el dato existe | segundos si el pago trae `metadata.preapproval_id`, ≤ 1 h si no | la suma de ambos, ambos idempotentes |

Alternativas descartadas: resolver el preapproval por `payer.id` (exige consultar a MercadoPago cada suscripción viva por cada pago, o persistir un `payer_id` que hoy no existe); disparar el barrido desde el workflow `keep-backend-warm` (GitHub Actions retrasa los cron arbitrariamente y obligaría a guardar el secreto del relay en GitHub); un job diferido tras la cuota `scheduled` (exige una cola con reintentos que el backend no tiene — el `pg_cron` horario ya es esa cola).

### D2 — Núcleo único: `reconcile_preapproval_charges`

Se extrae de `replay_subscription_charges` (`backend/services/subscriptions.py`) una función de servicio `reconcile_preapproval_charges(subscription, repo, conn) -> {"applied": [...], "already_applied": [...]}` que contiene, sin cambios de semántica salvo D3: las dos consultas a MercadoPago (`_get_preapproval` + `/authorized_payments/search`), el orden por id, el cálculo de `next_cycle`, la aplicación por cuota con `_apply_approved_charge`, la sincronización de `status`/`next_payment_date`/`last_payment_status` y el `clear_pending_charge`. `replay_subscription_charges` queda como envoltorio admin (404 si no existe, 409 si no tiene cuenta) que la llama. Todas las llamadas HTTP ocurren ANTES de abrir transacciones (patrón de #641: ninguna transacción sostenida durante un round-trip de red).

### D3 — El vencimiento sólo lo mueve una cuota acreditada por primera vez

Defecto latente del replay actual: aplica a TODAS las cuotas aprobadas el `plan_expires_at = next_cycle + 10 días` del preapproval vigente. Si MercadoPago adelanta `next_payment_date` al ciclo siguiente antes de procesar la cuota nueva (en noviembre la cuota quedó `scheduled` mientras el cobro ya existía), reaplicar la cuota de octubre extendería el plan un mes **sin cobro**. Hoy sólo lo dispara un humano; con un barrido horario sería sistemático. Regla nueva en el núcleo: para una cuota cuyo `billing_event` ya existía al empezar la corrida se pasa `plan_expires_at=None` (el `COALESCE` de `_apply_approved_charge` conserva el vigente; el resto de sus escrituras sigue completando una aplicación parcial, que es la razón de ser del replay H4). Sólo una cuota `applied` (nueva) mueve el vencimiento. El webhook de la cuota (`_apply_authorized_payment_notification`) no cambia: llega por una cuota concreta y ya calcula el vencimiento con `_fetch_next_cycle`.

### D4 — Selección del barrido: por el período pagado de la cuenta, no por `subscriptions.next_payment_date`

`subscriptions.next_payment_date` lo reescribe la propia reconciliación con el valor del preapproval aunque la cuota no se haya acreditado (D2 sincroniza estado), así que filtrar por él sacaría del barrido una suscripción no acreditada en cuanto MercadoPago adelanta su fecha. El criterio usa `accounts.plan_expires_at`, que SÓLO mueve `_apply_approved_charge` con un cobro nuevo (D3):

```
subscriptions s JOIN accounts a ON a.id = s.account_id
WHERE s.status = 'authorized'
  AND a.plan_expires_at IS NOT NULL
  AND a.plan_expires_at <= now() + GRACE_PERIOD          -- llegó la fecha de cobro del ciclo pagado
  AND a.plan_expires_at >  now() - RECONCILE_LOOKBACK    -- OQ-3: 30 días
```

En noviembre: `plan_expires_at = 2026-11-14 20:54` → la suscripción entra al barrido a partir de 2026-11-04 20:54 y sale sola en cuanto el cobro se acredita (vencimiento → 12-14). Repo: método nuevo `find_subscriptions_due_for_reconciliation(limit)` en `SubscriptionsRepository`, ordenado por `plan_expires_at` y con `LIMIT` (50) para acotar el tiempo de una corrida.

### D5 — Endpoint de máquina y disparo

- `POST /payments/subscriptions/reconcile-cron` en `backend/routers/payments.py`, `Depends(get_service_conn)` (contexto de servicio, ya admitido para webhook/cron), autenticado con `Authorization: Bearer <RELAY_SECRET>` fail-closed (401 si el secreto no está configurado o no coincide, `hmac.compare_digest`). Con `billing_subscriptions_enabled=false` responde 200 `{"ok": true, "skipped": true}` sin consultar nada.
- La verificación del secreto vive hoy inline en `backend/routers/fiscal.py::process_pending_cae_cron`. Se extrae a una dependencia `require_relay_secret` en `backend/core/guards.py` y los DOS endpoints la usan (reutilización antes que repetición; la suite de fiscal es la red de seguridad).
- Errores por suscripción: un 5xx de MercadoPago para una suscripción se registra (`logger.error`) y se sigue con la siguiente; la respuesta resume `{"checked": n, "applied": [...], "errors": n}`. La suscripción fallida reaparece en la corrida siguiente porque su vencimiento no se movió.
- Migración `20261092000001_mp_cuota_reconciliacion_cron.sql`: función `rpc_trigger_subscription_reconcile()` `SECURITY DEFINER`, `SET search_path = public, vault`, molde exacto de `rpc_trigger_cae_relay()` (`20260719000001_c27_cae_relay_trigger.sql`): lee `backend_base_url` y `cae_relay_secret` de `vault.decrypted_secrets` y hace `net.http_post` fire-and-forget; `REVOKE EXECUTE … FROM PUBLIC, anon, authenticated`; `cron.schedule('subscription-reconcile-charges', '7 * * * *', 'SELECT public.rpc_trigger_subscription_reconcile()')` idempotente (unschedule previo si existe). Si los secretos de Vault no existen la función sale con `RAISE WARNING` sin fallar el job.

### D6 — Webhook `payment`: acelerador sólo con vínculo positivo

En `process_payment`, rama `marker` (external_reference inválido + marcador presente): si `metadata.preapproval_id` existe y `repo.find_by_preapproval_id` devuelve una suscripción con cuenta, se llama al núcleo D2 para ese preapproval y se responde `{"ok": true, "reconciled": "subscription_charge"}` (campo nuevo opcional en `WebhookResponse`). En cualquier otro caso (otro marcador, preapproval desconocido, suscripción sin cuenta) se responde exactamente como hoy (`ignored="subscription_charge"`, sin escrituras). El idempotency check de arriba (`billing_events.mercadopago_payment_id`) ya corta los reintentos de un pago ya acreditado. Un error de MercadoPago dentro del núcleo devuelve 502 → MercadoPago reintenta (mismo contrato que el webhook de la cuota). La cola de ambiguas no cambia: una suscripción sin cuenta sigue guardando `pending_*` sólo desde la notificación de la cuota.

### D7 — Concurrencia: lock transaccional por preapproval

Barrido, webhook de la cuota tardía, webhook `payment` y replay pueden aplicar la misma cuota a la vez. `billing_events` ya está protegido por su índice único parcial (`ON CONFLICT DO NOTHING`), pero el correo usa `NOT EXISTS` por `authorized_payment_id`, que bajo dos transacciones concurrentes puede insertar dos filas (su índice único incluye `plan_expires_at` en la metadata, que puede diferir entre caminos). `_apply_approved_charge` toma `pg_advisory_xact_lock(hashtextextended('subscription_charge:' || preapproval_id, 0))` como primera sentencia de su transacción: los caminos se serializan por suscripción y el segundo ve el correo del primero.

### D8 — Logging

`backend/main.py` configura, antes de crear la app, `logging.getLogger("backend").setLevel(INFO)` con un `StreamHandler` a stdout y formato `%(levelname)s %(name)s: %(message)s` (sin tocar los loggers de uvicorn ni el root). La línea del marcador pasa a incluir el preapproval resuelto (o `None`) y el resultado (`reconciled`/`ignored`). No se loguean datos del pagador (mismo criterio que el diagnóstico de `mp-webhook-external-reference-vacio`). Efecto colateral deseado: las INFO del webhook (`type=… origin=…`) vuelven a verse, que es lo que exige "Notification origin is observable".

### D9 — Superficie admin mínima

`list_recent_subscriptions` suma `a.plan_expires_at` y `last_charge_credited_at` (`MAX(billing_events.created_at)` con `event_type='subscription_payment_approved'` y `metadata->>'preapproval_id' = s.preapproval_id`). La tabla "Suscripciones recientes" de `/admin/pagos/ambiguas` (ruta y menú ya existentes, admin de plataforma) muestra "Plan vence" y "Último cobro acreditado" con el formato de fecha del proyecto; en mobile, como filas apiladas igual que las columnas existentes. Tokens semánticos, verificado en claro/oscuro y desktop/mobile.

## Risks / Trade-offs

- [MercadoPago tarda días en pasar la cuota a `processed` (reintentos `recycling`)] → el barrido sigue intentando cada hora dentro de la ventana de 30 días (OQ-3); no acredita nada hasta que la cuota esté `processed/approved` (`_is_approved_charge`, sin cambios).
- [Render en frío cuando dispara el cron] → `pg_net` corta el request pero Render despierta; `keep-backend-warm` pingea cada 10 min; la corrida siguiente reintenta. Latencia peor caso ~2 h, muy por debajo de la gracia de 10 días.
- [Una cuenta con `plan_expires_at` de cortesía y una suscripción `authorized`] → entra al barrido igual; sólo cuesta dos GET a MercadoPago por hora mientras esté en la ventana. Aceptado.
- [`next_payment_date` del preapproval no posterior al débito] → ya se avisa con `warning` en `_fetch_next_cycle`; el núcleo conserva ese comportamiento (vencimiento corto hasta la corrida siguiente, que lo corrige porque la suscripción sigue "vencida" según D4).
- [El replay cambia de comportamiento (D3)] → un admin que replica cuotas ya acreditadas ya no puede "empujar" el vencimiento; es exactamente la protección buscada. Si hiciera falta forzar un vencimiento, es una corrección manual fuera de este change.
- [Duplicar el secreto del relay para dos propósitos] → alcance acotado a endpoints de máquina idempotentes; ver OQ-2.

## Migration Plan

1. Merge del apply → deploy de Render (verificar `GET /deploys`) + `supabase db push` del CI aplica `20261092000001` (re-verificar el número al aplicar: última en main al proponer `20261091000001`).
2. Verificación post-merge (sólo lectura): `cron.job` con `subscription-reconcile-charges` activo; `cron.job_run_details` con corridas `succeeded`; logs de Render con la línea INFO del barrido (`checked=…`) cada hora; respuesta 200 con `checked=0` mientras la suscripción real esté al día.
3. Prueba real: el próximo cobro (2026-12-04) se acredita solo — `billing_events` con el pago de diciembre y `plan_expires_at` ≈ 2027-01-14, sin replay manual.
4. Rollback: `SELECT cron.unschedule('subscription-reconcile-charges')` detiene el barrido sin deploy; revertir el PR restaura el comportamiento anterior. Ninguna escritura del barrido es distinta de las del replay admin.

## Open Questions

**Sign-off explícito del PO para el apply (2026-11-05)**, textual: «apague la pc asi que continua y avanza con todo lo recomendado». Con eso las cinco OQs quedan firmadas por su opción recomendada —OQ-1 (c) C', OQ-2 (a) `RELAY_SECRET`/`cae_relay_secret` con `require_relay_secret` en `backend/core/guards.py`, OQ-3 (a) cada hora al minuto 7 con ventana de 30 días, OQ-4 (b) columnas "Plan vence" y "Último cobro acreditado", OQ-5 (a) fix D3 del replay— y el gate de governance CRÍTICO del apply queda levantado.

Todas resueltas por la opción recomendada. **Sign-off del PO por mandato**: el PO pidió textualmente «propone un change para que esto se solucione»; cada OQ queda resuelta por su recomendada salvo objeción explícita antes del apply (governance CRÍTICO: el apply igual espera el OK del PO).

- **OQ-1 — Estrategia.** (a) A pura · (b) B pura · **(c) C' = B + A acotado a `metadata.preapproval_id` (recomendada)**. → **(c)**, sign-off del PO por mandato.
- **OQ-2 — Secreto del endpoint de cron.** **(a) Reutilizar `RELAY_SECRET` / Vault `cae_relay_secret` (recomendada: cero pasos manuales en prod, mismo modelo de amenaza — endpoint de máquina idempotente)** · (b) secreto nuevo (`SUBSCRIPTION_RECONCILE_SECRET` + entrada de Vault, paso manual del PO). → **(a)**, sign-off del PO por mandato.
- **OQ-3 — Cadencia y ventana.** **(a) cada hora (minuto 7), ventana de 30 días después del vencimiento del plan (recomendada)** · (b) cada 15 min · (c) una vez al día. → **(a)**, sign-off del PO por mandato.
- **OQ-4 — Superficie frontend.** (a) Ninguna (declarar "sin superficie nueva") · **(b) dos columnas en "Suscripciones recientes" de `/admin/pagos/ambiguas`: vencimiento del plan y último cobro acreditado (recomendada: el PO controla cada mes si el cobro entró sin abrir la base)**. → **(b)**, sign-off del PO por mandato.
- **OQ-5 — Defecto latente del replay (D3).** **(a) Corregirlo en este change (recomendada: el barrido lo volvería sistemático)** · (b) dejarlo y filtrar sólo en el barrido. → **(a)**, sign-off del PO por mandato.
