## Context

El billing de Aliadata vive en `public.accounts` desde C-19 (`billing_plan`, `billing_status`, `trial_plan`, `trial_started_at`, `trial_expires_at`, `plan_expires_at`). La capability `plan-gating` ya declara que el plan efectivo se calcula **desde la cuenta activa**, no desde `profiles`.

Pero la maquinaria que hace vivir ese ciclo nunca se movió con él.

### Evidencia de prod (`gxdhpxvdjjkmxhdkkwyb`, read-only vía MCP, 2026-07-31)

| Dato | Valor | Consecuencia |
|---|---|---|
| `accounts` totales | 34 | el universo completo del change |
| `accounts.billing_plan` | 24 `avanzado` · 8 `gratis` · 2 `pro` | los 24 `avanzado` son el backfill beta de C-01 (D5), no pagos |
| `accounts` con `billing_status='expired'` | **0** | ningún trial de cuenta venció jamás |
| `profiles` con `billing_status='expired'` | **3** | el cron sí corre — contra la tabla equivocada |
| `expire_trials()` — target | `UPDATE public.profiles` | verificado con `pg_get_functiondef` |
| `queue_trial_notifications()` — source | `FROM public.profiles p` | idem |
| `email_logs` tipo `trial_expiring_soon` | **6**, último 2026-07-26 | se avisó de un vencimiento que no ocurre |
| `trial_plan` de una cuenta nueva | `'avanzado'`, +30 días | sembrado por `set_new_user_trial()` |
| `get_effective_plan(...)` | **no existe** | |
| `plan_limits` | 4 filas, `gratis.max_products = 100`, `max_clients = 50`, `max_suppliers = 20` | fuente de verdad de los límites |
| `backend/services/products.py::PLAN_PRODUCT_LIMITS` | `avanzado: 2000` | **diverge** de `plan_limits` (1500) |
| `billing_events` con `event_type='plan_upgraded'` | **1** | el único rastro de un pago real |

**El hallazgo que ordena el diseño**: el trial de una cuenta **no vence nunca**, y sin embargo el sistema le manda mails diciendo que va a vencer. El ciclo de vida quedó partido en dos — `profiles` se mueve y no lo lee nadie; `accounts` lo lee el gating y no se mueve. Cualquier diseño que agregue un cron nuevo sobre `accounts` repite la misma clase de error: crea otro estado que puede quedar desincronizado. Este change lo cierra al revés — **elimina la necesidad de que algo se mueva**.

### Identificación de las cuentas exentas (verificación pedida por el sign-off)

El sign-off nombra tres exenciones. Contra prod, **colapsan en dos cuentas**, y uno de los identificadores no existe tal cual fue escrito:

| # del sign-off | Identificador | Resultado de la verificación |
|---|---|---|
| (1) la cuenta que PAGA | — | **`0f627a85-7d01-4323-8b3f-122bd834a4ab`** · owner `danielsevilla64@gmail.com` · `pro`/`active`. Único `billing_events` con `event_type='plan_upgraded'`: *"pago aprobado en MercadoPago pero el webhook no impactó… Honrado por el PO 2026-06-13"*. Identificación **inequívoca**. |
| (2) `susanacavagno@gmail.com` | email en `auth.users` | **Ese email NO existe en prod.** La única coincidencia cercana es `susanacavagnola@gmail.com` (una `la` de más), user `9e34ea10-5908-4f20-85ff-e344b6ce1f95`. |
| (3) "sumarropadeportiva" | nombre de negocio | `profiles.business_name = 'Sumar Ropa Deportiva'` → **el mismo user `9e34ea10…`**, cuenta **`3834e5d7-f3a9-4496-8fdd-84edf8a8b252`**, `pro`/`active`. |

Es decir: **(2) y (3) son la misma cuenta**, y el email del sign-off tiene un typo. La coincidencia es fuerte (nombre de negocio + email casi idéntico + único candidato en 34 cuentas), pero **quién queda exento de pagar es una decisión comercial, no una inferencia** → **OQ-1**, con la lista de dos cuentas para que el PO la confirme por UUID antes del backfill.

Dato colateral: **las dos cuentas exentas ya están en `pro`/`active`**, así que la exención no las mueve de plan — sólo las blinda de vencimientos y límites futuros.

### Dimensionamiento del excedente al vencer el trial

Las 32 cuentas no exentas caen a `gratis` (`max_products = 100`, `max_clients = 50`, `max_suppliers = 20`, `max_branches = 1`, `max_users = 1`). Conteos vivos (con `deleted_at IS NULL` donde aplica):

| Cuenta | Recurso | Tiene | Límite `gratis` | Excedente |
|---|---|---|---|---|
| `5503bd07…` · *Big Box, la casa del pescador* | productos | **2372** | 100 | **+2272** |
| `b6005a59…` · `tubecoventas6@gmail.com` | clientes | **513** | 50 | **+463** |
| `f715d4f0…` · `rominaaguero96@gmail.com` | productos | **123** | 100 | **+23** |

**Total: 3 cuentas de 32 quedarían en excedente**, en dos dimensiones (productos y clientes). Ninguna otra cuenta supera ningún límite: la cuarta más cargada es `luzmin.petshop@gmail.com` con **99 productos** — a **uno** del límite, y por eso vale la pena que el aviso exista antes de que choque. Proveedores: 0 en las 34 cuentas. Sucursales: todas en 1 salvo la cuenta pagadora (2, exenta). Miembros: 1 en las 34.

### Restricciones del proyecto que acotan el diseño

- La integración GitHub de Supabase auto-aplica migraciones al mergear, **antes** del `db push` de Actions → migraciones idempotentes obligatorias.
- Lección C3: al recrear un CHECK enumerado hay que partir de la unión vigente en prod (`pg_get_constraintdef` antes). Lección 42725: agregar un parámetro a una función existente crea un segundo overload → `DROP FUNCTION` de la firma vieja primero.
- `notifications` sólo se escribe desde `_notification_from_event` (SECURITY DEFINER, Consumer 4 del outbox). No hay política de INSERT para `authenticated`. Cualquier aviso nuevo entra por ahí o no entra.
- Governance CRÍTICO: billing con dinero real.

## Goals / Non-Goals

**Goals:**
- Que el trial PRO de 30 días exista, venza de verdad, y que el vencimiento **no dependa de que ningún job haya corrido**.
- Que el plan efectivo tenga **una** definición normativa, en la DB, consumible por el hook de Auth sin duplicar la regla.
- Que "no tener límites" pase de ser un default accidental a ser un dato con autor, fecha y motivo.
- Que ninguna cuenta pierda datos al vencer su trial, y que la que quede en excedente **se entere** por un canal que ya existe.
- Que el enforcement de límites lea la fuente de verdad (`plan_limits`) en vez de constantes que ya divergen.

**Non-Goals:**
- **No** se implementa cobro, checkout ni cambio de plan pagado — eso ya vive en C-10/C-17 y no se toca.
- **No** se dropea ninguna columna de `profiles`. Se declaran legacy muertas para gating y nada más.
- **No** se crea un quinto plan "ilimitado" ni se toca el CHECK de 4 tiers (ver D4).
- **No** se enforcean operaciones/mes ni exportaciones/mes (D7).
- **No** se activa el claim `plan` en el JWT — eso es `v31-authz-token-hook` y su propio gate del PO.
- **No** se diseña UI nueva: el banner de "Límite alcanzado" ya está especificado en `plan-gating`.
- **No** se decide por el PO quién queda exento (OQ-1).

## Decisions

### D1 — Evaluación perezosa: el trial vence porque pasó el tiempo, no porque un job lo dijo

`get_effective_plan(p_account_id uuid) RETURNS text` computa, **en cada lectura**:

```
1. exención vigente        → 'pro'
2. trial_expires_at > now() y trial_plan IS NOT NULL → trial_plan
3. billing_plan
4. cualquier otro caso (cuenta inexistente, columnas NULL) → 'gratis'
```

El vencimiento es una comparación de timestamps, no una transición de estado. **No existe el estado "trial vencido pero todavía no procesado"**, que es precisamente el bug que hoy tiene prod: 3 perfiles marcados `expired` y 0 cuentas, con mails ya enviados sobre un vencimiento que la fuente autoritativa nunca registró.

**`get_effective_plan` NO lee `billing_status`.** Es deliberado y es el corazón de la decisión: mientras el plan efectivo dependa de un campo que alguien tiene que actualizar, hay una ventana en la que el acceso es incorrecto. Al no leerlo, el peor fallo posible del cron cosmético (D6) es una etiqueta atrasada en la pantalla de facturación — nunca un permiso mal otorgado ni mal negado.

**Alternativa descartada — un cron que haga el downgrade** (`UPDATE accounts SET billing_plan='gratis' WHERE trial_expires_at < now()`). Es lo que el proyecto ya intentó con `expire_trials()` y es exactamente por lo que estamos acá: el job apunta a la tabla equivocada desde C-19 y **nadie se enteró en dos meses**, porque un cron que no corre no produce ningún error — produce silencio. Un cron correcto seguiría teniendo una ventana de hasta 24 h entre el vencimiento real y el efecto.

**Alternativa descartada — un trigger `BEFORE UPDATE` sobre `accounts`.** Sólo dispara si alguien toca la fila; una cuenta inactiva nunca vencería.

**Coste asumido**: `get_effective_plan` se ejecuta en cada emisión de token y en cada guard de creación. Es un `SELECT` por PK sobre una tabla de 34 filas. Si el volumen creciera un orden de magnitud, el camino de optimización obvio es cachear el resultado en el claim del JWT — que es **exactamente lo que `v31-authz-token-hook` ya hace**: el claim se recalcula una vez por refresh (~1 h), no por request. La lentitud de este diseño ya está resuelta por el change que lo consume.

### D2 — Firma única, `SECURITY DEFINER`, y el efecto colateral que le simplifica la vida al hook

`get_effective_plan(p_account_id uuid) RETURNS text`, `STABLE`, `SECURITY DEFINER`, `SET search_path = public, pg_temp`. `REVOKE ALL FROM PUBLIC/anon/authenticated`; `GRANT EXECUTE` sólo a `supabase_auth_admin` y `service_role`.

Al ser DEFINER, **el hook de Auth no necesita `GRANT SELECT` sobre `accounts`**: le alcanza con `EXECUTE` sobre la función. Eso reduce la superficie que `v31-authz-token-hook` D5 tiene que abrir (pasa de "grant + policy sobre `accounts`" a "grant sobre una función"), y —más importante— concentra la regla en un único objeto en vez de repartirla entre una policy y un `jsonb_build_object`. **`v31-authz-token-hook` debe adoptar esta forma**; queda anotado en su design como resolución de OQ-1.

**La firma queda congelada en un solo parámetro.** Si mañana hiciera falta inyectar un `now()` para tests, la tentación es `get_effective_plan(uuid, timestamptz)` — y eso crea un segundo overload (42725, la lección que el proyecto ya pagó con `rpc_close_cash_session`). Los tests manipulan `trial_expires_at`, no el reloj. Si aun así hiciera falta cambiar la firma, primero `DROP FUNCTION IF EXISTS public.get_effective_plan(uuid)`.

**Alternativa descartada — `EXECUTE` para `authenticated`.** El frontend no la necesita: ya lee la fila de `accounts` y calcula el plan en TypeScript. Conceder EXECUTE a `authenticated` sobre una función DEFINER que acepta un `account_id` arbitrario expondría el plan de cualquier cuenta a cualquier usuario logueado. Es información de bajo valor, pero es gratis no exponerla.

### D3 — Tres implementaciones de la misma regla, una sola normativa, y un test que las cruza

La regla del plan efectivo va a existir en tres lugares por razones legítimas:

| Dónde | Rol | Por qué existe |
|---|---|---|
| `public.get_effective_plan` (SQL) | **normativa** | la consume el hook; es la fuente citada por los specs |
| `frontend/lib/plan-utils.ts::getEffectivePlan` | espejo | el frontend ya tiene la fila de `accounts` y no va a hacer un round-trip por un string |
| `backend/core/auth.py` | **ninguna** — no recomputa | lee el claim `plan` del token; si no está, cae al fallback de transición de `v31-authz-token-hook` D6 |

La deriva se previene con un **test de paridad de tabla compartida**: un conjunto de casos (exenta, trial vigente, trial vencido, sin trial, cuenta inexistente, `billing_plan` NULL) definido una vez, ejecutado contra la función SQL en el gate de la migración y contra la función TS en Vitest, exigiendo el mismo resultado en cada caso. Sin ese test, la tercera implementación de una regla que ya existía dos veces es una promesa de bug, no una mitigación.

**El backend nunca recomputa el plan.** Es la única de las tres que puede permitirse no saber la regla, porque el token ya se la trae resuelta. Que el backend la ignore es una decisión, no un olvido.

### D4 — La exención vive en `accounts`, es explícita, y resuelve a `pro`

Cuatro columnas nuevas en `accounts`:

```
billing_exempt            boolean     NOT NULL DEFAULT false
billing_exempt_reason     text        NULL
billing_exempt_granted_at timestamptz NULL
billing_exempt_granted_by uuid        NULL REFERENCES auth.users(id)
CHECK (billing_exempt = false OR billing_exempt_reason IS NOT NULL)
```

Más una fila en `billing_events` (`event_type = 'exemption_granted'`) por cada exención concedida, con el `billing_plan` previo en `metadata` — el rastro histórico que las columnas por sí solas no pueden dar, porque un `UPDATE` las pisa.

**Por qué columnas y no una tabla `billing_exemptions`.** La función que las lee corre **en el camino de emisión de tokens**. Una tabla aparte agrega un join en el punto más caliente y —crítico— **otro objeto al que `supabase_auth_admin` necesitaría acceso**; el hook está envuelto en `EXCEPTION WHEN OTHERS`, así que un permiso faltante no da error: da claims vacíos, en silencio (es el riesgo insidioso que `v31-authz-token-hook` D5 documenta). Menos objetos en ese camino es menos superficie para fallar mudo. La historia, que es lo que una tabla daría, ya la da `billing_events`.

**El CHECK es la parte que importa.** Hoy "esta cuenta no tiene límites" es el resultado de que `get_current_user` usa `default "pro"` — nadie lo decidió, nadie lo firmó, no hay a quién preguntarle por qué. Después de este change, no tener límites **requiere una fila que diga quién lo concedió y por qué**, y la base rechaza el intento de concederlo sin motivo. Reemplazar un fail-open accidental por otro documentado en un comentario sería no haber aprendido nada.

**Por qué la exención resuelve a `pro` y no a "ilimitado".** El PO pidió "sin límites". Un quinto valor de plan rompería el CHECK de `accounts.billing_plan`, la PK de `plan_limits`, el union `Plan` de TypeScript, `PLAN_HIERARCHY` y las policies que comparan contra la lista de 4 — un radio de impacto enorme por un beneficio hoy nulo: **las dos cuentas exentas caben holgadamente en `pro`** (la más cargada tiene 1396 productos contra un tope de 5000, y 592 clientes contra 3000). Si alguna vez rozara el techo, la válvula de escape es subir el número en `plan_limits` — una fila de datos, sin deploy. Esa válvula **sólo funciona si el backend lee los límites de la DB**, que es justamente lo que D5 arregla.

**Escritura restringida**: no se agrega policy de UPDATE para `authenticated` sobre estas columnas. Se conceden por migración o por un admin de plataforma. Una exención que un usuario pudiera auto-concederse no sería una exención.

### D5 — El backend deja de hardcodear límites, y el guard se extiende a los tres recursos que importan

`backend/services/products.py::PLAN_PRODUCT_LIMITS` se retira. Los límites se leen de `plan_limits` a través de un repository, con caché en proceso de corta duración (los límites cambian con frecuencia cero).

No es una limpieza cosmética: **hoy el diccionario dice `avanzado: 2000` y la DB dice `1500`**. Mientras el gating fue fail-open la divergencia fue invisible; el día que el claim `plan` se encienda, el backend enforcearía un límite que ningún spec, ninguna UI y ningún precio respaldan. Y la válvula de escape de D4 (subir `plan_limits` para una cuenta exenta) no funcionaría en absoluto.

El guard `current_count >= limit` **ya implementa exactamente la política de excedente tolerado**: bloquea crear, no toca lo existente. No hay que escribir lógica nueva de excedente — hay que aplicar el guard a los recursos que pueden excederse. Se extiende de productos a **clientes y proveedores** (los tres recursos maestros con límite numérico y conteo por cuenta). Evidencia: prod tiene una cuenta con 513 clientes contra un tope de 50.

### D6 — Los dos cron de C-03 se realinean a `accounts`, con roles explícitamente distintos

| Job | Después de este change | Si falla |
|---|---|---|
| `queue_trial_notifications()` | lee **`accounts`**; manda los mails de 7d/1d sobre trials que sí van a vencer | no llegan mails de aviso |
| `expire_trials()` | actualiza **`accounts.billing_status`** `trialing → expired` + audita en `billing_events` | la UI de facturación muestra una etiqueta atrasada |

**Ninguno de los dos decide acceso.** `expire_trials()` queda degradado a sweep descriptivo, y eso se escribe en el `COMMENT ON FUNCTION` para que nadie lo vuelva a confundir con el mecanismo de gating. Es la lección de este change convertida en documentación ejecutable: la razón por la que el bug vivió dos meses es que la función *parecía* ser el mecanismo del ciclo de vida.

Se dejan de tocar las columnas de `profiles`: quedan congeladas donde están, sin dropear.

**Alternativa descartada — borrar los dos cron.** Los mails de "tu prueba vence en 7 días" son valor real para el usuario en una feature que es, literalmente, un trial. Y una etiqueta correcta en la pantalla de facturación evita tickets de soporte. Lo que había que romper es la creencia de que el acceso depende de ellos, no los jobs.

### D7 — Qué se enforcea y qué no: la diferencia entre "borrar el excedente" y "frenar el negocio"

El sign-off dice: *"conservan lo existente pero no pueden crear recursos nuevos del tipo excedido"*, y ofrece como salida *"borrar el excedente o subir de plan"*.

Esa salida **sólo tiene sentido sobre datos maestros almacenados**. En consecuencia:

| Recurso | ¿Se enforcea? | Razón |
|---|---|---|
| productos, clientes, proveedores | **Sí** | son stock de datos; "borrá el excedente" es una acción posible y sensata |
| sucursales | **Sí**, con el guard existente | `has_branches_module` ya gatea el módulo; las 34 cuentas tienen 1 salvo la exenta |
| miembros de la cuenta | **Sí**, con el guard existente del flujo de invitación | ninguna cuenta tiene más de 1 hoy |
| **operaciones/mes** | **No** | bloquear una venta no es "conservar lo existente sin crear más": es frenar la facturación del negocio. No se puede "borrar el excedente" de ventas de este mes. |
| **exportaciones/mes** | **No** | contador mensual que se resetea solo; no hay excedente que conservar ni que borrar |

Los dos "No" son una **interpretación del sign-off, no una omisión**: se listan explícitamente para que el PO los objete si su intención era otra. Enforcar operaciones/mes sobre una cuenta `gratis` (tope 100) significaría que un comercio deja de poder registrar ventas el día 100 del mes — un resultado que ningún sign-off de "límite de plan" pretende, y que se descubriría en producción y con un cliente enojado.

### D8 — Backfill: el destino post-trial es `gratis` explícito, no "volver a lo que tenías"

El sign-off define el destino del vencimiento como `gratis`. Las 24 cuentas beta tienen `billing_plan = 'avanzado'`, así que sin tocar ese valor, al vencer el trial `get_effective_plan` devolvería `avanzado` — contradiciendo el sign-off.

El backfill, para cada una de las 32 cuentas no exentas:

```
billing_plan     = 'gratis'          -- destino post-trial explícito
trial_plan       = 'pro'
trial_started_at = now()
trial_expires_at = now() + 30 días   -- cuentas nuevas: el trigger lo hace desde su registro
billing_status   = 'trialing'
```

más un `billing_events` (`event_type = 'trial_pro_granted'`) con `from_plan` = el `billing_plan` anterior. **Ese registro es lo que hace el backfill reversible**: revertir es un `UPDATE … FROM billing_events` sobre el `from_plan` guardado, no una restauración de backup.

Escribir `'gratis'` sobre un `'avanzado'` que nadie pagó no destruye información comercial: lo vuelve honesto. Los 24 valores provienen del backfill de beta de C-01 (D5, `WHERE plan = 'pro'`), no de una transacción. La única cuenta con evidencia de pago (`billing_events.plan_upgraded`) está en la lista de exentas y no se toca.

**Idempotencia**: el backfill se acota con `WHERE billing_exempt = false AND trial_plan IS DISTINCT FROM 'pro'`, de modo que re-aplicar la migración no reinicia el reloj de nadie. Esto importa concretamente: la integración GitHub de Supabase aplica las migraciones al mergear y Actions vuelve a hacer `db push` después. **Un backfill no idempotente extendería el trial 30 días más en la segunda pasada**, y nadie lo notaría hasta el mes siguiente.

**Alternativa descartada — dejar `billing_plan` intacto y que el resolver fuerce `gratis` post-trial.** Requiere que `get_effective_plan` sepa distinguir "avanzado de beta" de "avanzado pagado" — una distinción que no está en los datos y habría que inventar con otra columna. Dos fuentes de verdad para responder una sola pregunta.

### D9 — El aviso de excedente entra por el Consumer 4 existente, y se dispara por barrido, no por request

El aviso es una notificación tipo **`PlanLimitExceeded`**, severidad `warning`, audiencia `ADMIN` (owners de la cuenta), con `payload` = `{resource, current, limit, plan}`.

Camino obligado: `notifications` **no tiene policy de INSERT para `authenticated`** — la única vía de escritura es `_notification_from_event`, el Consumer 4 del relay del outbox. Así que un producer inserta en `events` y el relay despacha. Se extiende la lista de tipos en-scope de `_notification_from_event` (`CREATE OR REPLACE`, **misma firma** `(public.events)` — sin riesgo de overload) y se agrega el mapeo tipo→target/severidad.

**Por qué el producer es un barrido diario y no el propio guard de creación.** El guard sólo se entera cuando el usuario **intenta crear** — es decir, el aviso llegaría junto con el bloqueo, que es tarde. El PO pidió que se les avise que superan el límite, no que se enteren al chocar. Un barrido diario (`pg_cron`, la extensión ya está instalada con 2 jobs) detecta la condición aunque la cuenta esté inactiva.

Esto **no contradice D1**: el barrido no computa ni cambia el plan de nadie; sólo observa una condición que `get_effective_plan` ya determina, y emite un evento. Si el barrido no corre, nadie recibe el aviso y **el acceso sigue siendo exactamente el correcto**. Es la separación que D6 hace explícita: lo autoritativo es perezoso, lo cosmético es programado.

**Dedup**: como máximo un aviso por `(account_id, resource)` cada 7 días, verificado contra `notifications` antes de emitir el evento. Sin eso, un barrido diario le pone una notificación por día a la cuenta de 2372 productos hasta que borre 2272 — convirtiendo un aviso útil en ruido que el usuario aprende a ignorar.

El banner en el módulo afectado **ya está especificado** en `plan-gating` ("el sistema muestra un banner 'Límite alcanzado' en lugar del formulario, con CTA de upgrade"). Se reutiliza. Lo único que el frontend agrega es el tipo nuevo en el union `NotificationType` y su etiqueta en `TYPE_LABELS` del `NotificationBell`.

### D10 — Forward-compat con `v3-rbac-multirole`

`v3-rbac-multirole` gatea los roles funcionales a `avanzado`/`pro` (parte del sign-off del 2026-07-30) leyendo `plan_limits.internal_roles` (`none` / `basic` / `advanced`). Dos consecuencias que conviene fijar ahora:

1. **Ese gating debe consumir `get_effective_plan`**, no `accounts.billing_plan` — si no, una cuenta en trial PRO no vería los roles funcionales que su trial le concede, y el trial dejaría de ser una demostración del producto.
2. **Durante los 30 días de PRO todas las cuentas pueden asignar roles funcionales; al caer a `gratis`, `internal_roles = 'none'`.** Lo que se gatea es la **gestión** de roles (la UI de asignación), **no las asignaciones ya hechas**: revocar permisos de un empleado porque venció el trial del dueño sería un cambio de autorización silencioso disparado por un reloj de billing. Las asignaciones sobreviven; lo que se bloquea es crear nuevas. Es la misma política de excedente tolerado de D7, aplicada a roles.

Ambos puntos se escriben en el spec de `billing-trial-lifecycle` para que `v3-rbac-multirole` no los re-litigue.

## Risks / Trade-offs

- **El backfill se aplica dos veces y extiende el trial 30 días más** → El riesgo más probable y el más silencioso, porque la doble aplicación es el comportamiento *normal* del pipeline (integración GitHub + `db push` de Actions). Mitigado por el predicado `trial_plan IS DISTINCT FROM 'pro'` (D8) y por una tarea que aplica la migración **dos veces seguidas** en local verificando que `trial_expires_at` no se mueve en la segunda.
- **Se exime a la cuenta equivocada** → El sign-off nombra un email que no existe en prod y dos identificadores que resuelven a la misma cuenta. Mitigado elevándolo como **OQ-1** con los dos UUID exactos: el agente no infiere quién no paga. Bloquea el backfill, no el merge.
- **Una cuenta pierde acceso a datos al vencer el trial** → No ocurre por construcción: el guard es `current_count >= limit` **al crear**. Lectura, edición y borrado no se tocan. Se cubre con un test explícito de que los 2372 productos de la cuenta más cargada siguen listándose y editándose con plan efectivo `gratis`.
- **El aviso se convierte en spam** → D9, dedup de 7 días por `(cuenta, recurso)`. Con la cuenta de +2272 productos como caso de prueba: sin dedup recibiría ~30 notificaciones en el primer mes.
- **`get_effective_plan` se vuelve un cuello de botella** → Es un `SELECT` por PK; y su consumidor principal (el hook) la ejecuta una vez por refresh de token (~1 h), no por request. Se anota como cosa a medir si el padrón crece un orden de magnitud.
- **El claim `plan` del hook y el `get_effective_plan` del backend divergen dentro de la ventana de 1 h** → Un trial que vence a mitad de sesión deja el token con el plan viejo hasta el refresh. Ya está aceptado explícitamente en `v31-authz-token-hook` (Risks) con el mismo margen. Se menciona acá para que las dos decisiones se lean juntas.
- **Retirar `PLAN_PRODUCT_LIMITS` cambia el límite de `avanzado` de 2000 a 1500** → Es una corrección hacia la fuente de verdad, pero es un endurecimiento real. Verificado contra prod: **ninguna cuenta `avanzado` tiene más de 13 productos**, así que el impacto hoy es exactamente cero. Se deja escrito porque dentro de seis meses no lo será.
- **La UI muestra `avanzado` y el gating aplica `gratis` (o viceversa)** durante la ventana entre el backfill y el refresh de los caches del frontend → El espejo TS de D3 se actualiza en el mismo PR y el test de paridad lo cubre; `usePlanLimits` cachea 1 h, así que la ventana máxima es esa.
- **Enforcar clientes rompe un flujo que hoy funciona** → 33 de 34 cuentas están muy por debajo del tope; la única afectada (513 clientes) es una de las 3 ya dimensionadas y va a recibir el aviso. Riesgo conocido y acotado, no descubierto en producción.
- **`billing_status` queda como campo decorativo y alguien lo vuelve a usar para autorizar** → Mitigado por el `COMMENT ON FUNCTION` de D6, por el spec, y por un test que afirma que `get_effective_plan` devuelve lo mismo con `billing_status` en cualquiera de sus 5 valores.

## Migration Plan

1. **Preparación (agente)** — migración idempotente + código backend + frontend + tests. Merge a `main` dispara `db push`. Al terminar este paso, `get_effective_plan` existe y es correcta, pero **el trial todavía no se otorgó a nadie**: el backfill va detrás del gate del PO (paso 2). El claim `plan` sigue sin viajar (depende de `v31-authz-token-hook`), así que el enforcement sigue siendo el actual.
2. **Gate OQ-1 (PO)** — confirmar por UUID las dos cuentas exentas (`0f627a85…` pagadora, `3834e5d7…` cortesía) y el typo del email del sign-off. **Bloquea el paso 3.**
3. **Backfill (agente, migración aparte)** — exenciones + trial PRO de 30 días para las 32 restantes + `billing_events` de auditoría. Verificar en prod: 2 cuentas exentas, 32 con `trial_plan='pro'` y `trial_expires_at` a 30 días, 34 filas nuevas en `billing_events`.
4. **Activación real del enforcement** — ocurre cuando el PO activa el hook de `v31-authz-token-hook` (su tarea 8.3). Hasta ese momento el trial existe en los datos y no cambia el comportamiento de nadie.
5. **Día 30 (o antes, para las que ya estén en excedente)** — el barrido de D9 emite los avisos. Verificar que las 3 cuentas dimensionadas reciben exactamente una notificación cada una.
6. **Observación** — que ninguna cuenta reporte pérdida de datos, y que los 403 nuevos correspondan exactamente a las 3 cuentas en excedente y sólo en creación.

**Rollback**: los pasos 1 y 3 son reversibles sin restaurar backups. La exención se revierte con `billing_exempt = false`; el trial y el `billing_plan` previo se restauran desde el `from_plan` de `billing_events` (D8). Las columnas nuevas son aditivas y pueden quedarse. El único paso con efecto visible para el usuario es el 4, y su palanca es el toggle del hook — la misma que `v31-authz-token-hook` ya documenta como rollback de un clic.

## Open Questions

- **OQ-1 (bloquea el backfill, no el merge) — confirmación de las cuentas exentas.** El sign-off nombra tres exenciones que en prod son **dos cuentas**, y uno de los identificadores no existe tal cual: **(a)** `susanacavagno@gmail.com` **no existe** en `auth.users`; la coincidencia más cercana es `susanacavagnola@gmail.com` (`9e34ea10-5908-4f20-85ff-e344b6ce1f95`); **(b)** esa misma cuenta es la que tiene `business_name = 'Sumar Ropa Deportiva'`, o sea que las exenciones (2) y (3) del sign-off **son la misma cuenta**: `3834e5d7-f3a9-4496-8fdd-84edf8a8b252`; **(c)** la cuenta pagadora es `0f627a85-7d01-4323-8b3f-122bd834a4ab` (`danielsevilla64@gmail.com`), identificada por el único `billing_events.plan_upgraded` con el pago de MercadoPago reconciliado por el PO el 2026-06-13. Se pide confirmación **por UUID** de que la lista de exentas es exactamente esas dos, y que no hay una tercera cuenta que el sign-off haya querido nombrar. *Quién no paga es una decisión comercial; el agente no la infiere de un typo.*
- **OQ-2 — ¿el excedente se enforcea también sobre operaciones/mes y exportaciones/mes?** D7 decide que **no**, porque "borrá el excedente o subí de plan" no es una salida posible para ventas ya registradas, y bloquear la carga de ventas de una cuenta `gratis` el día 100 del mes frena la operación del negocio. Se eleva para que el PO lo objete si su intención al decir "u otros recursos limitados" incluía los contadores mensuales.
- **OQ-3 — ¿qué pasa con las 5 cuentas que hoy tienen un trial `avanzado` a mitad de camino?** El backfill les da 30 días de PRO desde la activación, lo que **alarga** su prueba (3 de ellas ya vencidas, 2 con días restantes) y les mejora el plan. Es la lectura literal del sign-off ("TODAS las cuentas reciben 30 días de PRO"), y beneficia al usuario, por lo que se implementa así. Se anota por si el PO prefiere respetar la fecha de vencimiento original de esas 5.
