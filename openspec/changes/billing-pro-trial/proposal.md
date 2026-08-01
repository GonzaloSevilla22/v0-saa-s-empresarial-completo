## Why

El PO decidió (sign-off 2026-07-31) que **todas las cuentas reciban 30 días de plan PRO**, y que al vencer caigan a `gratis` — recién ahí el límite del plan se vuelve real. Hoy nada de eso es implementable, porque el ciclo de vida del trial está **partido entre dos tablas y sólo se mueve la mitad muerta**.

Estado verificado en prod (`gxdhpxvdjjkmxhdkkwyb`, read-only vía MCP, 2026-07-31):

| Dato | Valor |
|---|---|
| `accounts` totales | **34** |
| `accounts.billing_plan` | 24 `avanzado` (beta grandfathered) · 8 `gratis` · 2 `pro` |
| Cuentas con `trial_expires_at` vigente | **5** (las 8 `gratis`, de las cuales 3 ya vencieron) |
| Trial actual de una cuenta nueva | `trial_plan = 'avanzado'` + 30 días — **no `pro`** |
| `expire_trials()` — tabla que actualiza | **`public.profiles`**, no `accounts` |
| `queue_trial_notifications()` — tabla que lee | **`public.profiles`**, no `accounts` |
| `profiles.billing_status = 'expired'` | **3** |
| `accounts.billing_status = 'expired'` | **0** |
| Emails `trial_expiring_soon` enviados | **6** (último 2026-07-26) |
| `get_effective_plan(...)` en la DB | **no existe** |

Las tres consecuencias son medibles hoy:

1. **El trial de las cuentas nunca vence.** C-19 movió el billing de `profiles` a `accounts` (la capability `plan-gating` lo dice: el plan efectivo se calcula desde `accounts`), pero los dos cron de C-03 se quedaron leyendo `profiles`. El barrido diario marca 3 perfiles como `expired` y manda mails de "tu prueba vence" mientras la fuente que el gating consulta —`accounts`— sigue intacta. **El sistema le avisa al usuario de un vencimiento que no ocurre.**
2. **La regla del plan efectivo está escrita tres veces y en ningún lado es normativa.** Existe en prosa en el spec de `plan-gating`, en TypeScript en `frontend/lib/plan-utils.ts::getEffectivePlan`, y `v31-authz-token-hook` está por escribirla una cuarta vez dentro del hook de Auth. No hay una definición única contra la cual verificar que las tres coinciden.
3. **Los límites del backend son constantes hardcodeadas y ya divergen de la DB.** `backend/services/products.py::PLAN_PRODUCT_LIMITS` dice `avanzado: 2000`; `plan_limits.max_products` dice **1500**. El spec de `plan-gating` exige leer los límites de la DB en runtime; el backend Python nunca lo hizo. Mientras el gating fue fail-open (todos tratados como `pro`) la divergencia no se notó.

Y es **prerequisito duro de `v31-authz-token-hook`**: su claim `plan` (D3) debe emitir el plan efectivo. Sin una función canónica en la DB, el hook duplicaría la regla — y una regla duplicada en el camino de emisión de tokens es exactamente el tipo de deriva que este cluster está tratando de cerrar.

## What Changes

- **Trial PRO de 30 días para todas las cuentas elegibles.** El trial pasa de `avanzado` a `pro`: `set_new_user_trial()` siembra `trial_plan = 'pro'` para las cuentas nuevas (30 días desde su registro), y una migración con backfill se lo asigna a las cuentas existentes no exentas (30 días desde la activación de la feature).
- **`get_effective_plan(account_id)` — la definición canónica y única del plan efectivo**, en SQL, en la DB. Orden de precedencia: exención de cortesía → `pro`; trial vigente → `trial_plan`; si no → `billing_plan`; ante cualquier ausencia de información → **`gratis`** (fail-closed, nunca el plan más alto). La consumen el hook de Auth (`v31-authz-token-hook`), el backend y —vía un test de paridad— el equivalente TypeScript del frontend.
- **Vencimiento por evaluación perezosa, sin cron.** El plan efectivo se computa **en cada lectura** comparando `trial_expires_at` contra `now()`. No hay un job que "haga vencer" nada, así que no existe el estado stale de un cron caído o retrasado. `get_effective_plan` **no lee `billing_status`** — deliberadamente: ese campo pasa a ser descriptivo (para la UI de facturación), no autoritativo.
- **Exenciones de cortesía explícitas y auditables.** Columnas nuevas en `accounts` (`billing_exempt`, `billing_exempt_reason`, `billing_exempt_granted_at`, `billing_exempt_granted_by`) con un CHECK que impide una exención sin motivo escrito, más un `billing_events` de tipo `exemption_granted` por cada una. **La exención es un dato, no un agujero**: hoy "nadie tiene límites" es el resultado accidental de un default optimista; después de este change, no tener límites requiere una fila que diga quién lo concedió y por qué.
- **Excedente tolerado post-trial.** Al caer a `gratis`, una cuenta que quedó por encima del límite **conserva todo lo que tiene** — no se borra ni se oculta nada — pero **no puede crear recursos nuevos del tipo excedido** mientras siga por encima. Lectura, edición y borrado siguen disponibles: borrar es justamente el camino de salida.
- **Aviso de excedente por la campana existente.** Nuevo tipo de notificación `PlanLimitExceeded` emitido como evento del outbox y despachado por el Consumer 4 ya existente (`_notification_from_event`) hacia la tabla `notifications` y el `NotificationBell`. **No se inventa infraestructura de avisos**: se agrega un tipo a la que `v3-notifications-realtime` dejó funcionando. Dedup: como máximo un aviso por cuenta y recurso cada 7 días.
- **El backend deja de hardcodear límites.** `PLAN_PRODUCT_LIMITS` se retira; los límites se leen de `plan_limits` (que es lo que el spec de `plan-gating` siempre exigió), y el guard de creación se extiende de productos a **clientes y proveedores** — los tres recursos que la evidencia de prod muestra que pueden quedar en excedente.
- **Los dos cron de C-03 se realinean a `accounts`.** `queue_trial_notifications()` pasa a leer `accounts` (para que los mails de 7d/1d describan un vencimiento real) y `expire_trials()` pasa a actualizar `accounts.billing_status` **como sweep cosmético de reporting, explícitamente no como mecanismo de gating**. Si ese cron se cae, el acceso sigue siendo correcto; sólo la etiqueta de la UI de facturación queda atrasada.

**BREAKING (de comportamiento, no de contrato HTTP)** — y sólo cuando el claim `plan` esté vivo (es decir, tras activar el hook de `v31-authz-token-hook`):

- **24 cuentas beta pierden su `avanzado` grandfathered.** El backfill fija `billing_plan = 'gratis'` para todas las cuentas no exentas, porque el sign-off define el destino post-trial como `gratis` explícitamente y no como "volver al plan contratado". Ninguna de esas 24 pagó nunca: su `avanzado` provino del backfill de beta de C-01 (D5). El valor anterior queda registrado en `billing_events` y el backfill es reversible desde ese registro.
- **3 cuentas quedarían en excedente al vencer los 30 días** (dimensionado exacto en `design.md`): dos por productos y una por clientes. Ninguna pierde datos; las tres quedan bloqueadas para crear más de ese recurso hasta borrar el excedente o subir de plan.
- **`profiles.billing_*` queda declarado legacy muerto** para todo propósito de gating. No se dropea nada en este change.

**Fuera de alcance (decisión explícita, ver `design.md` D7)**: los límites de **operaciones/mes** y **exportaciones/mes** NO se enforcean. Bloquear una venta no es "conservar lo existente sin poder crear más"; es frenar la operación del negocio, y el sign-off habla de "borrar el excedente", algo que sólo tiene sentido sobre datos maestros almacenados.

## Capabilities

### New Capabilities

- `billing-trial-lifecycle`: el ciclo de vida completo del trial comercial — quién lo recibe, con qué plan y por cuánto tiempo, cómo se determina el plan efectivo de una cuenta en cualquier instante (definición canónica en DB, evaluación perezosa, fail-closed), qué es una exención de cortesía y qué garantías de auditoría tiene, y qué le pasa a una cuenta que al vencer el trial queda por encima del límite de su plan (excedente tolerado + aviso).

### Modified Capabilities

- `billing`: la transición `trialing → expired` pasa a operar sobre `accounts` en lugar de `profiles`, y se degrada explícitamente de mecanismo de ciclo de vida a **sweep descriptivo**: el acceso ya no depende de que ese barrido haya corrido.
- `plan-gating`: el plan efectivo deja de ser una regla replicada en prosa y pasa a tener una definición normativa única (`get_effective_plan`); los límites numéricos se leen de `plan_limits` también desde el backend Python; y se agrega la política de **excedente tolerado** (conservar lo existente, impedir la creación de nuevos del tipo excedido) como comportamiento especificado, no como efecto lateral del guard.
- `in-app-notifications`: se incorpora el tipo `PlanLimitExceeded` al catálogo despachado por el Consumer 4, con su audiencia (owners de la cuenta), su severidad y su regla de deduplicación temporal.

## Impact

- **Base de datos**: una migración idempotente con (a) columnas de exención en `accounts` + CHECK; (b) `get_effective_plan(uuid)` nueva (`STABLE SECURITY DEFINER`, `SET search_path`, `EXECUTE` sólo para `supabase_auth_admin` y `service_role`); (c) `set_new_user_trial()` redefinida a `trial_plan = 'pro'`; (d) `expire_trials()` y `queue_trial_notifications()` redefinidas contra `accounts`; (e) el producer de `PlanLimitExceeded` y la extensión de `_notification_from_event`; (f) backfill de trial + backfill de exenciones + `billing_events` de auditoría por cada fila tocada. Todas las redefiniciones son `CREATE OR REPLACE` sobre **la misma firma** — sin riesgo de overload duplicado (42725), verificado explícitamente en las tareas.
- **Código backend**: `backend/services/products.py` (retiro de `PLAN_PRODUCT_LIMITS`, lectura desde `plan_limits`), guards de creación en clientes y proveedores, y un repository/servicio de límites. Sin `service_role`, arquitectura de 3 capas intacta.
- **Frontend**: `frontend/lib/plan-utils.ts::getEffectivePlan` incorpora la exención (test de paridad contra la definición SQL); `frontend/lib/types.ts` + `NotificationBell` incorporan el tipo `PlanLimitExceeded`; el banner de "Límite alcanzado" ya especificado en `plan-gating` se reutiliza — **no se diseña UI nueva**.
- **API**: ningún endpoint cambia de forma. Cambian códigos de respuesta en creación de productos/clientes/proveedores para cuentas en excedente (403 con mensaje accionable).
- **Cluster / secuencia**: **`billing-pro-trial` debe mergearse ANTES que `v31-authz-token-hook`**, porque el claim `plan` del hook consume `get_effective_plan`. Es independiente de `v31-tenancy-pool-rls`.
- **Governance**: **CRÍTICO** — billing de 34 cuentas reales, una de ellas con un pago reconciliado. El backfill y la activación de la feature requieren sign-off explícito del PO por cuenta afectada.
