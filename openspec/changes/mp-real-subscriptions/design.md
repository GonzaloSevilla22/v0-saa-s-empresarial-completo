# Design — mp-real-subscriptions

## Context

### Estado actual, verificado en el código

| Pieza | Dónde | Qué hace hoy |
|---|---|---|
| Alta de plan | `frontend/app/api/billing/preferences/route.ts` | Crea una `Preference` de Checkout Pro — **pago único** |
| Acreditación | `backend/services/payments.py:165` | `UPDATE accounts SET billing_plan=$1, billing_status='active', plan_expires_at = NULL` |
| Plan efectivo | `get_effective_plan(uuid)`, migr. `20260817000001` | Precedencia exención → trial → `billing_plan` → `gratis`. **No lee `plan_expires_at`** |
| Baja | `frontend/app/api/billing/cancel/route.ts:57` | `plan_expires_at = now() + 30 días` — plazo inventado, sin tocar MercadoPago |
| Degradación | `process_cancellations()`, migr. `20260609000001` | Barrido diario sobre `accounts` con `billing_status='cancelling'` y `plan_expires_at < now()` — **funciona y se reutiliza** |
| Vencimiento de trial | `expire_trials()`, realineada por `billing-pro-trial` | Solo `trialing → expired`; su propio `COMMENT` la declara descriptiva |
| Campana | `_notification_from_event(public.events)` + Consumer 4 | 6 tipos en-scope; `PlanLimitExceeded` es el precedente exacto a copiar |
| Correo | `email_logs` + Edge Function `send-email` | `UNIQUE NULLS NOT DISTINCT (user_id, event_type, metadata)`; `event_type` es texto libre, sin CHECK |

**El resultado neto**: se cobra una vez, `plan_expires_at` queda en `NULL`, y la única función que decide el acceso no mira esa columna. Plan pago eterno por construcción.

### Superficie real de la API de MercadoPago (verificada contra la documentación, no inferida)

- `POST /preapproval_plan` — obligatorios `reason` y `back_url`. `auto_recurring`: `frequency`, `frequency_type`, `repetitions`, `billing_day`, `billing_day_proportional`, `free_trial {frequency, frequency_type}`, `transaction_amount`, `currency_id`. Opcional `payment_methods_allowed {payment_types[], payment_methods[]}`. Devuelve `id`, `init_point`, `status`, `collector_id`, `date_created`, `application_id`.
- `POST /preapproval` — obligatorio `payer_email`. Opcionales `preapproval_plan_id`, `reason`, `external_reference`, `card_token_id`, `back_url`, `status`. `auto_recurring`: `frequency`, `frequency_type`, `start_date`, `end_date`, `transaction_amount`, `currency_id`, `free_trial`. Devuelve `id`, `init_point`, `sandbox_init_point`, `status`, `next_payment_date`, `payer_id`, `payer_email`, `preapproval_plan_id`, `external_reference`, `date_created`, `last_modified`, `payment_method_id`, `card_id`, y `summarized {last_charged_date, last_charged_amount, charged_quantity, pending_charge_quantity, charged_amount, pending_charge_amount, semaphore, quotas}`.
- `PUT /preapproval/{id}` — modifica `status` (`paused`, `cancelled`) y monto.
- `GET /authorized_payments/{id}` — cuota concreta: `id`, `preapproval_id`, `type`, `status`, `transaction_amount`, `currency_id`, `payment {id, status, status_detail}`, `retry_attempt`, `next_retry_date`, `debit_date`, `date_created`, `external_reference`.
- **Estados de `preapproval`**: `pending`, `authorized`, `paused`, `cancelled`.
- **Estados de cuota**: `scheduled`, `processed` (resuelta, con pago aprobado o definitivamente fallido), `recycling` (rechazada, en reintento), `cancelled`.
- **Topics de webhook**: `payment`, `subscription_preapproval`, `subscription_preapproval_plan`, `subscription_authorized_payment`.
- **Cuerpo de notificación**: `{id, live_mode, type, date_created, user_id, api_version, action, data:{id}}`.
- **Firma**: manifiesto `id:<data.id>;request-id:<x-request-id>;ts:<ts>;`, HMAC-SHA256 hex. El `data.id` sale del **query param** de la URL de notificación y **va en minúsculas si es alfanumérico**.
- **Reintentos de cobro que MercadoPago hace por su cuenta**: hasta 4 por cuota dentro de una ventana de 10 días; tras **3 cuotas rechazadas consecutivas** cancela la suscripción automáticamente.

### Governance

CRÍTICO. Es el único camino por el que entra dinero, sobre 34 cuentas reales y un pagador. Sign-off del PO sobre el rumbo el 2026-07-31. Todo lo que toque dinero real está marcado **[MANUAL PO]** en `tasks.md`.

## Goals / Non-Goals

**Goals:**
- Que un plan pago se cobre **todos los meses** sin intervención.
- Que el vencimiento de un plan pago exista como dato y **se respete en el único lugar que decide el acceso**.
- Que un impago avise antes de degradar, y que degrade solo cuando corresponde.
- Que el estado de la suscripción sea reconstruible y auditable sin abrir el panel de MercadoPago.

**Non-Goals:**
- Cobro anual (la columna `price_ars_annual` existe, el alcance firmado es mensual).
- Prorrateo en cambios de plan a mitad de ciclo.
- Reimplementar reintentos de cobro — MercadoPago ya los hace (D7).
- Atomicidad transaccional del webhook → **H-19 / `v31-mp-webhook-atomic`**.
- Facturación fiscal de la suscripción (AFIP) — flujo aparte, ya cubierto por v22.

## Decisions

### D1 — Suscripción **con plan asociado**

**Decisión**: un `preapproval_plan` por tier pago, y cada suscripción de cuenta referencia el `preapproval_plan_id` de su tier.

**Por qué**: la alternativa —suscripción sin plan asociado— exige tokenizar la tarjeta en nuestra propia UI (`card_token_id`), lo que arrastra el formulario de tarjeta, su superficie de cumplimiento y su mantenimiento. Con plan asociado, la captura del medio de pago la hace MercadoPago en su checkout, igual que hoy. Además el precio queda como propiedad del plan, actualizable sin tocar suscripciones existentes.

**Trade-off**: cambiar el precio de un tier requiere gestionar el plan en MercadoPago (y decidir si las suscripciones vigentes migran). Fuera de alcance acá; se documenta.

### D2 — El `preapproval` se crea server-side para poder llevar `external_reference`

**Decisión**: `POST /preapproval` con `preapproval_plan_id`, `payer_email` (del usuario autenticado), `external_reference` y `status: "pending"`; se redirige al usuario al `init_point` de la respuesta.

**Por qué**: `external_reference` es lo que permite atribuir a una cuenta un cobro que va a llegar **dentro de tres meses**. Si en cambio se redirige al `init_point` del **plan**, MercadoPago crea el `preapproval` por su cuenta y no hay dónde inyectar esa referencia: quedaría reconciliar por `payer_email`, que puede no coincidir con el email de la cuenta y no es único entre cuentas. Atribuir dinero por heurística de email es exactamente el tipo de decisión que en un dominio CRÍTICO no se toma.

**Riesgo asumido y cómo se cierra**: la documentación no es explícita sobre si un `preapproval` creado con plan asociado, sin `card_token_id` y en estado `pending`, devuelve un `init_point` utilizable. **Esto se valida en sandbox como tarea bloqueante antes de escribir la implementación** (tasks §2). Si no lo devolviera, el fallback documentado es redirigir al `init_point` del plan y reconciliar por `payer_email` **más** una fila de intención pre-registrada con marca temporal, y en ese caso se sube la decisión al PO porque degrada la garantía de atribución.

### D3 — El alta y la baja se mudan al backend FastAPI

**Decisión**: `POST /payments/subscriptions` (alta) y `DELETE /payments/subscriptions/{id}` o equivalente (baja) en el backend. Las rutas `/api/billing/preferences` y `/api/billing/cancel` se retiran.

**Por qué**: crear una suscripción **obliga a persistir** el `preapproval_id` antes de redirigir al usuario. Escribir desde una route de Next.js con cliente Supabase anónimo es la causa raíz exacta de H-02. `v31-mp-upgrade-webhook-fix` evaluó mover el flujo de preferencias al backend y lo dejó explícitamente disponible para este change: acá el motivo sí existe.

**Nota de tenancy**: los endpoints usan JWT-passthrough como el resto del backend. Solo la ruta de webhook, que no tiene usuario, usa la conexión de servicio — igual que hoy.

### D4 — Tabla `public.subscriptions`, no columnas en `accounts`

**Decisión**: tabla nueva con `account_id`, `preapproval_id` (único), `preapproval_plan_id`, `plan`, `status`, `next_payment_date`, `amount`, `currency`, `external_reference`, estado de reintento, marcas temporales. Como máximo una fila viva por cuenta, garantizado por **índice único parcial** sobre `account_id WHERE status IN ('pending','authorized')`.

**Por qué no columnas en `accounts`**: se pierde el historial. Una cuenta que cancela y vuelve a suscribirse sobrescribiría su suscripción anterior, y con ella la evidencia de qué se le cobró y por qué se le dio de baja. Además una suscripción `pending` (creada pero aún no autorizada) no puede convivir con el plan actual si el estado vive en `accounts`.

**Por qué índice parcial y no un guard en el service**: es el patrón que ya usa este proyecto para "exactamente una primaria" en `client_addresses` (v3-catalog-masters). Una invariante de unicidad la garantiza la base o no la garantiza nadie.

**RLS**: `SELECT` para miembros de la cuenta; sin policies de `INSERT`/`UPDATE`/`DELETE` para `authenticated` — el estado lo escribe únicamente el backend desde las notificaciones. **Atención**: `v3-soft-delete-policy` dejó anotado que `bank_accounts`/`cashboxes` quedaron sin policy de `UPDATE` y eso rompió operaciones desde la UI; acá la ausencia es **deliberada y suficiente**, porque ninguna operación de UI escribe esta tabla.

### D5 — Sin tabla de cuotas: se reutilizan `billing_events` y `operation_idempotency`

**Decisión**: los cobros acreditados se auditan en `billing_events` (con `mercadopago_payment_id`, que ya tiene índice único → idempotencia gratis). El estado de reintento vive **en la fila de la suscripción**. Las notificaciones de suscripción se reclaman en `operation_idempotency` con un `operation_kind` nuevo.

**Por qué**: una tabla `subscription_payments` sería un tercer lugar donde vive la misma verdad. La historia de cobros ya es reconstruible desde `billing_events`, y el único dato que `billing_events` no representa bien —"hay un reintento en curso"— es estado presente, no historia, así que su lugar natural es la suscripción.

**Lección C3, obligatoria**: al recrear el CHECK de `operation_idempotency.operation_kind` hay que **leer primero la unión vigente en producción** (`pg_get_constraintdef`) y enumerarla completa. CI corre sobre una base vacía y no atrapa un `kind` faltante; en producción explota al insertar.

### D6 — `get_effective_plan` gana el término de vencimiento; `NULL` no degrada

**Decisión**: la precedencia pasa a exención → trial vigente → `billing_plan` **si `plan_expires_at IS NULL OR plan_expires_at > now()`** → `gratis`. La firma de un parámetro **no cambia**: `CREATE OR REPLACE` sobre la misma firma no crea overload; se reafirman `REVOKE`/`GRANT` en el mismo archivo y un gate verifica que quede **exactamente una** definición.

**Por qué `NULL` no degrada**, pese a que un fail-closed estricto sería más elegante: hoy hay cuentas con plan pago y `plan_expires_at = NULL` —entre ellas la del único cliente pagador, porque el webhook actual lo setea así explícitamente—. Un fail-closed estricto las degradaría a `gratis` **en el instante en que se aplica la migración**, sin aviso. El mecanismo previsto para "plan pago sin vencimiento" ya existe y es auditable: `billing_exempt` con motivo obligatorio. La ruta correcta es migrar esos casos a la exención y **después** endurecer.

**Consecuencia operativa, no negociable**: antes y después de aplicar la migración hay que **comparar `get_effective_plan` sobre las 34 cuentas** y verificar que el conjunto de resultados no cambió. Si cambia para alguna cuenta que no sea la esperada, se revierte. Un error acá degrada usuarios reales en silencio.

### D7 — El dunning lo hace MercadoPago; nosotros avisamos y esperamos

**Decisión**: no se implementa ninguna política de reintento propia. Ante un cobro rechazado se avisa y no se degrada.

**Por qué**: MercadoPago ya reintenta hasta 4 veces en 10 días y cancela la suscripción tras 3 cuotas rechazadas consecutivas. Un reintento propio compitiendo con el del proveedor es la receta para un doble cobro. El período de gracia (D-siguiente, OQ2) es lo que sostiene el acceso mientras el proveedor insiste.

### D8 — La degradación reutiliza `process_cancellations()`

**Decisión**: cuando MercadoPago cancela la suscripción —por baja del usuario o por impago— la cuenta pasa a `billing_status='cancelling'` con su `plan_expires_at` real, y el barrido diario que ya está en producción hace el downgrade. El motivo se distingue en `billing_events`.

**Por qué**: ese barrido ya existe, ya corre y ya audita. Escribir un segundo camino de degradación sería crear una segunda verdad sobre cuándo una cuenta pierde su plan.

### D9 — Corrección obligatoria de la derivación del `data.id` firmado

**Decisión**: leer `data.id` del **query param**, pasarlo a **minúsculas**, usar el cuerpo solo como respaldo.

**Por qué**: los IDs de `preapproval` son alfanuméricos. Con la derivación actual (cuerpo, sin normalizar) el manifiesto no coincide con el que firmó MercadoPago y **todas** las notificaciones de suscripción se rechazan como falsificadas. Hoy funciona solo porque los IDs de pago son numéricos. Hallazgo heredado de `v31-mp-upgrade-webhook-fix` D7, que lo dejó anotado precisamente para que este change no lo descubra en producción.

**Regresión a proteger**: el cambio no debe alterar la verificación de las notificaciones `payment`. Test de no-regresión obligatorio.

### D10 — Discriminador obligatorio en la metadata de los correos

**Decisión**: todo correo del ciclo de suscripción lleva en `metadata` un dato que lo hace único respecto del hito que lo originó (el identificador de la cuota, o la fecha de vencimiento avisada).

**Por qué**: `email_logs` tiene `UNIQUE NULLS NOT DISTINCT (user_id, event_type, metadata)`. Un `subscription_payment_failed` con metadata idéntica al del mes pasado sería **descartado en silencio** por el `ON CONFLICT DO NOTHING`, y el usuario nunca se enteraría del segundo impago. El endpoint de reenvío de recibos ya convive con esta restricción agregando un `requested_at` (`backend/routers/payments.py:148`) — mismo patrón, misma razón.

### D11 — La campana copia el patrón `PlanLimitExceeded` sin desviarse

**Decisión**: productor emite un evento a `public.events`; `_notification_from_event` suma `SubscriptionPaymentFailed` a su lista en-scope **con la misma firma** (`public.events`), target `ADMIN`, severidad `warning`, sin `branch_id`. Sin tocar `rpc_process_outbox_dispatch`.

**Por qué**: ese camino ya está construido, probado y con gates. Cualquier desviación agrega riesgo sin agregar valor.

### D12 — Migración de la cuenta pagadora, según lo firmado

**Decisión**: para `danielsevilla64` (`accounts.id 0f627a85-7d01-4323-8b3f-122bd834a4ab`), `plan_expires_at` se fija en **activación + 30 días**; el mes y medio ya transcurrido queda de cortesía. El PO le envía el enlace de la suscripción nueva. **No se genera ningún cobro retroactivo ni automático.**

**Por qué**: es la decisión firmada por el PO el 2026-07-31. Acá solo se materializa.

## Risks / Trade-offs

- **[Riesgo — el más grave] El término de vencimiento degrada cuentas por error.** Un `plan_expires_at` mal calculado, o la interpretación estricta del `NULL`, deja usuarios reales sin acceso en silencio. → **Mitigación**: `NULL` no degrada (D6); gates SQL de comportamiento sobre los tres casos (nulo / futuro / pasado); y la **comparación antes/después de `get_effective_plan` sobre todas las cuentas** como criterio de aceptación con reversión si difiere.

- **[Riesgo] `get_effective_plan` está en el camino caliente del hook de emisión de tokens** (`v31-authz-token-hook`). Un error acá no degrada una pantalla: degrada el login. → **Mitigación**: `CREATE OR REPLACE` sobre la misma firma (sin overload, sin ventana en la que la función no exista), `REVOKE`/`GRANT` reafirmados en el mismo archivo, y gate de "exactamente una definición".

- **[Riesgo] `external_reference` no disponible en el flujo con plan asociado** (D2) → atribución de dinero por heurística. → **Mitigación**: validación en sandbox **bloqueante**, antes de implementar; fallback documentado que se eleva al PO.

- **[Riesgo] Fricción de conversión.** Autorizar un débito recurrente pide más compromiso que un pago único: puede bajar la tasa de upgrade. → **Mitigación**: ninguna técnica; es una consecuencia asumida de la decisión de producto del PO. Se mide con `billing_events`.

- **[Riesgo] Doble cobro por reintento propio compitiendo con el del proveedor.** → **Mitigación**: D7 — no se implementa ningún reintento propio.

- **[Riesgo] Notificaciones de suscripción no habilitadas en el panel de MercadoPago** → los topics nuevos nunca llegan y el sistema parece funcionar hasta que vence el primer mes. → **Mitigación**: tarea [MANUAL PO] de habilitación + verificación en sandbox de que llega al menos una notificación de cada topic.

- **[Riesgo] Cold start de Render demora la notificación de un cobro.** → **Mitigación**: MercadoPago reintenta y el procesamiento es idempotente; el período de gracia absorbe la demora.

- **[Trade-off] Sin tabla de cuotas** (D5): la historia de reintentos de una cuota concreta no queda persistida en detalle, solo su estado actual y los cobros acreditados. Aceptado: alcanza para soporte y auditoría, y evita una tercera fuente de verdad.

## Migration Plan

**Fase 0 — Sandbox (bloqueante, sin tocar producción)**
1. Credenciales de test de MercadoPago [MANUAL PO].
2. **Validar D2**: crear un `preapproval` con plan asociado, `status: pending`, sin `card_token_id`, y confirmar que devuelve un `init_point` usable y conserva el `external_reference`. Si falla → fallback a decisión del PO.
3. Confirmar que llegan notificaciones de `subscription_preapproval` y `subscription_authorized_payment`, y que **verifican firma** con la derivación corregida (D9).

**Fase 1 — Base de datos (sin efecto de comportamiento)**
4. Migración `20260829000001`: tabla `subscriptions` + RLS + índice único parcial; `operation_kind` nuevo respetando la lección C3; tipo nuevo en `_notification_from_event`; productor de dunning. `REVOKE` explícito de `anon` **y** `authenticated` tras **cada** definición de función, y `to_regprocedure()` para toda referencia a funciones que puedan no existir.
5. Gates SQL estructurales y de comportamiento en la misma migración, patrón `billing-pro-trial`.

**Fase 2 — `get_effective_plan` (el paso delicado)**
6. Capturar el plan efectivo de las 34 cuentas **antes**.
7. Migración que redefine la función con el término de vencimiento (`CREATE OR REPLACE`, misma firma, `REVOKE`/`GRANT` en el mismo archivo).
8. Capturar **después** y comparar. **Diferencia inesperada → revertir.**

**Fase 3 — Backend**
9. Endpoints de alta y baja, procesamiento de los topics nuevos, corrección de firma (D9). TDD.

**Fase 4 — Frontend y correos**
10. `/planes` y `/facturacion` contra los endpoints nuevos; plantillas de los `event_type` nuevos en `send-email`.

**Fase 5 — Activación [MANUAL PO]**
11. Crear los `preapproval_plan` de producción.
12. Habilitar los topics en el panel de MercadoPago.
13. Migrar la cuenta pagadora según D12.
14. Retirar `/api/billing/preferences` y `/api/billing/cancel`.

**Rollback**
- Fases 1 y 3-4 son aditivas: se revierte el código y la tabla queda inerte.
- **Fase 2 es la única con efecto sobre el acceso**: su rollback es restaurar el cuerpo anterior de la función con `CREATE OR REPLACE` sobre la misma firma. Debe quedar escrito **textualmente** en la cabecera de la migración, listo para pegar.
- Los `preapproval` ya autorizados sobreviven a cualquier rollback de código: siguen cobrando. Un rollback de Fase 5 exige cancelarlos en MercadoPago [MANUAL PO].

## Open Questions

- **OQ1 — ¿Cuándo se endurece la semántica de `plan_expires_at IS NULL`?** Este change adopta la interpretación permisiva (nulo = sin vencimiento, no degrada) para no degradar cuentas al aplicar la migración (D6). *Opciones*: (a) migrar las cuentas pagas sin vencimiento a `billing_exempt` en este mismo change y endurecer acá; (b) endurecer en un change posterior, una vez que ninguna cuenta paga tenga `plan_expires_at` nulo; (c) dejarlo permisivo de forma indefinida. **Recomendación: (b)** — separa el cambio de comportamiento del cambio de infraestructura, que es lo que hace el rollback de Fase 2 verificable. **Decide el PO.**

- **OQ2 — ¿Cuántos días de gracia entre `next_payment_date` y `plan_expires_at`?** *Opciones*: (a) 0 días; (b) 3 días; (c) 10 días. **Recomendación: (c) 10 días**, porque coincide exactamente con la ventana en la que MercadoPago reintenta un cobro rechazado: la cuenta conserva el acceso mientras el proveedor sigue intentando cobrar, y lo pierde recién cuando el proveedor se dio por vencido. Cualquier valor menor degrada a un usuario que todavía va a pagar. **Decide el PO.**

- **OQ3 — ¿Se contrata `inicial` por suscripción, o solo `avanzado` y `pro`?** El brief menciona "avanzado/pro", pero `inicial` tiene precio en `plan_limits` y **hoy es contratable** por el flujo de preferencias. Excluirlo sería una regresión de producto silenciosa. *Opciones*: (a) los tres tiers pagos; (b) solo `avanzado` y `pro`, y `inicial` deja de ofrecerse. **Recomendación: (a)**. **Decide el PO.**

- **OQ4 — ¿Qué pasa si el usuario cambia de tier teniendo una suscripción viva?** Este change no hace prorrateo (Non-Goal). *Opciones*: (a) cancelar la suscripción vigente y crear una nueva, perdiendo lo pagado del período en curso; (b) cancelar y crear una nueva con `start_date` al fin del período pagado; (c) bloquear el cambio de tier hasta que venza el período. **Recomendación: (b)** — respeta lo que el usuario ya pagó sin necesidad de prorratear. **Decide el PO.**
