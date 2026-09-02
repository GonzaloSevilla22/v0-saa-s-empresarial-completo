# billing-trial-lifecycle Specification

## Purpose
TBD - created by archiving change billing-pro-trial. Update Purpose after archive.
## Requirements
### Requirement: Plan efectivo con definición normativa única en la base de datos

El sistema SHALL exponer `public.get_effective_plan(p_account_id uuid) RETURNS text` como **la** definición normativa del plan efectivo de una cuenta. Cualquier otro cómputo del plan efectivo (frontend, hook de Auth) SHALL producir el mismo resultado que esta función para las mismas entradas.

La precedencia SHALL ser, en este orden: (1) exención de cortesía vigente → `pro`; (2) trial vigente (`trial_expires_at > now()` y `trial_plan` no nulo) → `trial_plan`; (3) `billing_plan`, **siempre que su período pagado no esté vencido**; (4) cualquier caso sin información suficiente → `gratis`.

Un `billing_plan` pago SHALL considerarse vencido cuando `plan_expires_at` no es nulo y quedó en el pasado. Un `plan_expires_at` **nulo** SHALL interpretarse como ausencia de vencimiento programado y NOT SHALL degradar la cuenta: es el caso de las cuentas provisionadas fuera del circuito de suscripción, para las cuales el mecanismo previsto es la exención de cortesía auditable, no un plan pago sin fecha.

La evaluación del vencimiento SHALL ser perezosa, comparando `plan_expires_at` contra el instante de la consulta, con el mismo criterio que ya rige para el trial: ningún proceso programado es prerequisito del resultado.

La firma de la función SHALL permanecer congelada en un único parámetro `uuid`. La redefinición SHALL hacerse con `CREATE OR REPLACE` sobre esa misma firma —agregar un parámetro crearía un segundo overload— y la migración SHALL reafirmar en el mismo archivo el `REVOKE` de `PUBLIC`, `anon` y `authenticated` y el `GRANT` a `supabase_auth_admin` y `service_role`.

La función SHALL declararse `STABLE SECURITY DEFINER` con `SET search_path` fijo, y su `EXECUTE` SHALL estar revocado de `PUBLIC`, `anon` y `authenticated`, concedido únicamente a `supabase_auth_admin` y `service_role`.

#### Scenario: Cuenta con trial PRO vigente
- **GIVEN** una cuenta con `billing_plan='gratis'`, `trial_plan='pro'`, `trial_expires_at = now() + 10 days`, sin exención
- **WHEN** se invoca `get_effective_plan(account_id)`
- **THEN** devuelve `'pro'`

#### Scenario: Trial vencido cae al plan base
- **GIVEN** una cuenta con `billing_plan='gratis'`, `trial_plan='pro'`, `trial_expires_at = now() - 1 second`
- **WHEN** se invoca `get_effective_plan(account_id)`
- **THEN** devuelve `'gratis'`

#### Scenario: Cuenta sin trial usa su plan contratado
- **GIVEN** una cuenta con `billing_plan='pro'`, `trial_plan IS NULL`, `trial_expires_at IS NULL`
- **WHEN** se invoca `get_effective_plan(account_id)`
- **THEN** devuelve `'pro'`

#### Scenario: Plan pago vencido cae a gratis
- **GIVEN** una cuenta con `billing_plan='pro'`, sin exención, sin trial vigente y `plan_expires_at = now() - 1 day`
- **WHEN** se invoca `get_effective_plan(account_id)`
- **THEN** devuelve `'gratis'`

#### Scenario: Plan pago vigente se conserva
- **GIVEN** una cuenta con `billing_plan='pro'` y `plan_expires_at = now() + 5 days`
- **WHEN** se invoca `get_effective_plan(account_id)`
- **THEN** devuelve `'pro'`

#### Scenario: Plan pago sin fecha de vencimiento no degrada
- **GIVEN** una cuenta con `billing_plan='avanzado'` y `plan_expires_at IS NULL`
- **WHEN** se invoca `get_effective_plan(account_id)`
- **THEN** devuelve `'avanzado'`

#### Scenario: La exención gana sobre un plan pago vencido
- **GIVEN** una cuenta con exención de cortesía vigente, `billing_plan='inicial'` y `plan_expires_at` en el pasado
- **WHEN** se invoca `get_effective_plan(account_id)`
- **THEN** devuelve `'pro'`

#### Scenario: El trial gana sobre un plan pago vencido
- **GIVEN** una cuenta con `trial_plan='pro'` vigente, `billing_plan='inicial'` y `plan_expires_at` en el pasado
- **WHEN** se invoca `get_effective_plan(account_id)`
- **THEN** devuelve `'pro'`

#### Scenario: El vencimiento se evalúa sin que corra ningún barrido
- **GIVEN** una cuenta con `plan_expires_at` a un segundo en el futuro y ningún proceso programado ejecutado desde entonces
- **WHEN** se invoca `get_effective_plan(account_id)` antes y después de ese instante
- **THEN** la primera invocación devuelve el plan contratado y la segunda devuelve `'gratis'`

#### Scenario: Cuenta inexistente resuelve fail-closed
- **WHEN** se invoca `get_effective_plan()` con un `account_id` que no existe en `accounts`
- **THEN** devuelve `'gratis'` y no lanza excepción

#### Scenario: La ausencia de información nunca concede el plan más alto
- **GIVEN** una cuenta cuyo `billing_plan` no permite determinar un plan válido
- **WHEN** se invoca `get_effective_plan(account_id)`
- **THEN** el resultado es `'gratis'` y NOT SHALL ser `'pro'` ni ningún otro plan superior

#### Scenario: La función conserva una única definición
- **WHEN** se inspecciona el catálogo de funciones tras aplicar la migración
- **THEN** existe exactamente una definición de `public.get_effective_plan`, con un solo parámetro

#### Scenario: `EXECUTE` no está disponible para el rol del navegador
- **WHEN** se inspeccionan los privilegios de `public.get_effective_plan(uuid)`
- **THEN** `authenticated` y `anon` no tienen `EXECUTE`, y `supabase_auth_admin` sí

### Requirement: El vencimiento del trial se evalúa de forma perezosa

El sistema SHALL determinar la vigencia del trial comparando `trial_expires_at` contra el instante de la consulta, **sin** depender de que ningún proceso programado haya actualizado previamente el estado de la cuenta.

`get_effective_plan` NOT SHALL leer `accounts.billing_status` para determinar el plan efectivo.

#### Scenario: El plan efectivo cambia sin que corra ningún job
- **GIVEN** una cuenta con `trial_expires_at` a 1 segundo en el futuro y ningún barrido programado ejecutado desde entonces
- **WHEN** se invoca `get_effective_plan(account_id)` antes y después de ese segundo
- **THEN** la primera invocación devuelve `trial_plan` y la segunda devuelve `billing_plan`

#### Scenario: `billing_status` no altera el plan efectivo
- **GIVEN** dos cuentas con idénticos `billing_plan`, `trial_plan` y `trial_expires_at`, y `billing_status` distintos entre sí
- **WHEN** se invoca `get_effective_plan()` sobre ambas
- **THEN** ambas devuelven el mismo valor

### Requirement: Trial PRO de 30 días para toda cuenta elegible

El sistema SHALL otorgar 30 días de plan `pro` a toda cuenta no exenta. Para cuentas nuevas, el trial SHALL comenzar en el momento de su registro. Para las cuentas existentes al momento de activar la feature, el trial SHALL comenzar en el momento de la activación.

Al vencer el trial, el plan efectivo SHALL ser `gratis`.

#### Scenario: Una cuenta nueva nace con 30 días de PRO
- **WHEN** se registra un usuario nuevo y se provisiona su cuenta
- **THEN** la cuenta queda con `trial_plan='pro'` y `trial_expires_at` a 30 días de su creación, y `get_effective_plan()` devuelve `'pro'`

#### Scenario: Al vencer el trial el plan efectivo es `gratis`
- **GIVEN** una cuenta no exenta cuyo trial PRO venció
- **WHEN** se invoca `get_effective_plan(account_id)`
- **THEN** devuelve `'gratis'`

#### Scenario: El otorgamiento del trial queda auditado
- **WHEN** se otorga el trial PRO a una cuenta existente
- **THEN** se registra una fila en `billing_events` con el `billing_plan` anterior en `from_plan`, suficiente para revertir el cambio sin restaurar un backup

#### Scenario: Re-aplicar el otorgamiento no reinicia el reloj
- **GIVEN** una cuenta que ya recibió su trial PRO
- **WHEN** se vuelve a aplicar la migración de otorgamiento
- **THEN** `trial_expires_at` conserva exactamente el mismo valor que tenía

### Requirement: Exención de cortesía explícita y auditable

El sistema SHALL representar la exención comercial como un dato explícito en `accounts` (`billing_exempt`, `billing_exempt_reason`, `billing_exempt_granted_at`, `billing_exempt_granted_by`), y NOT SHALL derivarla de un valor por defecto, de la ausencia de información ni de una condición implícita.

Una cuenta marcada como exenta SHALL quedar fuera del ciclo de trial y SHALL resolver a plan efectivo `pro`. La base de datos SHALL rechazar una exención sin motivo escrito.

#### Scenario: Una exención sin motivo es rechazada por la base
- **WHEN** se intenta marcar `billing_exempt = true` dejando `billing_exempt_reason` en NULL
- **THEN** la operación falla por violación de CHECK constraint

#### Scenario: La cuenta exenta resuelve a `pro` sin trial
- **GIVEN** una cuenta con `billing_exempt = true` y `trial_expires_at IS NULL`
- **WHEN** se invoca `get_effective_plan(account_id)`
- **THEN** devuelve `'pro'`

#### Scenario: La exención tiene precedencia sobre un trial vencido
- **GIVEN** una cuenta exenta con `billing_plan='gratis'` y un trial vencido
- **WHEN** se invoca `get_effective_plan(account_id)`
- **THEN** devuelve `'pro'`

#### Scenario: La cuenta pagadora conserva su plan
- **GIVEN** la cuenta con un pago registrado en `billing_events`, marcada exenta
- **WHEN** se otorga el trial PRO al resto de las cuentas
- **THEN** su `billing_plan` no cambia y su plan efectivo sigue siendo el plan que pagó

#### Scenario: Un usuario no puede auto-concederse la exención
- **WHEN** un usuario `authenticated` intenta escribir `billing_exempt = true` sobre su propia cuenta
- **THEN** la operación es rechazada (no existe política de escritura que se lo permita)

#### Scenario: Cada exención concedida queda registrada
- **WHEN** se concede una exención de cortesía
- **THEN** existe una fila en `billing_events` que identifica la cuenta, el motivo y el instante del otorgamiento

### Requirement: Excedente tolerado al vencer el trial

Cuando una cuenta cae a un plan cuyo límite es menor que la cantidad de recursos que ya posee, el sistema NOT SHALL borrar, ocultar ni bloquear el acceso a los recursos existentes. El sistema SHALL impedir la **creación** de nuevos recursos del tipo excedido mientras la cuenta siga por encima del límite, y SHALL permitir su lectura, edición y borrado.

#### Scenario: Los recursos existentes por encima del límite siguen accesibles
- **GIVEN** una cuenta con plan efectivo `gratis` (límite 100 productos) que tiene 2372 productos
- **WHEN** el usuario lista y edita sus productos
- **THEN** los 2372 se listan y se pueden editar sin error

#### Scenario: No se puede crear un recurso del tipo excedido
- **GIVEN** la misma cuenta con 2372 productos y límite 100
- **WHEN** intenta crear un producto nuevo
- **THEN** la operación es rechazada con un mensaje que indica el límite del plan y la vía de salida

#### Scenario: Borrar el excedente restablece la capacidad de crear
- **GIVEN** una cuenta con 101 productos y límite 100
- **WHEN** borra 2 productos y luego crea uno
- **THEN** la creación es permitida

#### Scenario: El excedente de un recurso no bloquea otro recurso
- **GIVEN** una cuenta con 513 clientes (límite 50) y 9 productos (límite 100)
- **WHEN** intenta crear un producto
- **THEN** la creación es permitida

### Requirement: Aviso de excedente por la campana de notificaciones

El sistema SHALL avisar a la cuenta que quedó por encima del límite de su plan, usando la infraestructura de notificaciones existente (evento del outbox despachado por el Consumer 4 hacia `notifications`). El aviso SHALL indicar el recurso excedido, la cantidad actual y el límite vigente.

La emisión del aviso NOT SHALL ser condición para que el plan efectivo sea correcto: si el proceso que lo emite no corre, el acceso SHALL seguir siendo el que corresponde al plan efectivo.

#### Scenario: La cuenta en excedente recibe el aviso
- **GIVEN** una cuenta cuyo trial venció y que tiene más productos que su límite
- **WHEN** corre el barrido de detección de excedente
- **THEN** los owners de la cuenta reciben una notificación de tipo `PlanLimitExceeded` con severidad `warning` indicando recurso, cantidad actual y límite

#### Scenario: El aviso no se repite a diario
- **GIVEN** una cuenta que ya recibió el aviso de excedente de productos hace 2 días
- **WHEN** vuelve a correr el barrido
- **THEN** no se emite un segundo aviso para ese mismo recurso

#### Scenario: El barrido caído no altera la autorización
- **GIVEN** que el barrido de excedente no se ejecuta durante varios días
- **WHEN** una cuenta con trial vencido intenta crear un recurso por encima del límite
- **THEN** la creación es rechazada igual, porque el enforcement no depende del aviso

#### Scenario: Una cuenta sin excedente no recibe aviso
- **GIVEN** una cuenta con 99 productos y límite 100
- **WHEN** corre el barrido
- **THEN** no se emite ninguna notificación de excedente para esa cuenta

### Requirement: Paridad entre la definición normativa y su espejo en el frontend

El sistema SHALL verificar automáticamente que el cómputo del plan efectivo en el frontend produce el mismo resultado que `get_effective_plan` para un conjunto compartido de casos que incluya, como mínimo: cuenta exenta, trial vigente, trial vencido, sin trial, cuenta inexistente y `billing_plan` ausente.

#### Scenario: Los dos cómputos coinciden en todos los casos de la tabla
- **WHEN** se ejecuta la verificación de paridad
- **THEN** para cada caso de la tabla compartida, el resultado de la función SQL y el del cómputo del frontend son idénticos

#### Scenario: Una divergencia introducida rompe la verificación
- **GIVEN** que se altera la precedencia en una sola de las dos implementaciones
- **WHEN** se ejecuta la verificación de paridad
- **THEN** la verificación falla identificando el caso divergente

### Requirement: Contrato hacia el gating de roles funcionales

El gating por plan de los roles funcionales SHALL leer el plan efectivo (`get_effective_plan`), no `accounts.billing_plan`. Al caer el plan efectivo por debajo del nivel requerido, el sistema SHALL bloquear la **asignación** de nuevos roles funcionales y NOT SHALL revocar las asignaciones ya existentes.

#### Scenario: Durante el trial PRO los roles funcionales están disponibles
- **GIVEN** una cuenta con `billing_plan='gratis'` y trial PRO vigente
- **WHEN** se evalúa su acceso a la gestión de roles funcionales
- **THEN** el acceso es concedido (plan efectivo `pro`)

#### Scenario: Al vencer el trial las asignaciones existentes sobreviven
- **GIVEN** una cuenta que asignó roles funcionales durante el trial y cuyo trial venció
- **WHEN** se consultan los roles asignados a sus miembros
- **THEN** las asignaciones siguen vigentes, y sólo la creación de asignaciones nuevas queda bloqueada

### Requirement: El espejo del plan efectivo en el frontend contempla el vencimiento

El sistema SHALL reflejar el término de vencimiento del plan pago en todo cómputo del plan efectivo que ocurra fuera de la base de datos, de modo que la paridad con la definición normativa se conserve.

Una divergencia acá no es cosmética: el frontend mostraría funcionalidad de un plan que la base ya no concede, o la ocultaría cuando sí corresponde.

#### Scenario: El frontend degrada un plan pago vencido
- **GIVEN** una cuenta sin exención ni trial vigente, con plan pago y `plan_expires_at` en el pasado
- **WHEN** el frontend computa el plan efectivo
- **THEN** obtiene `'gratis'`, igual que la definición normativa

#### Scenario: Paridad en los casos límite del vencimiento
- **WHEN** se comparan la definición normativa y su espejo en el frontend sobre cuentas con `plan_expires_at` nulo, futuro y pasado
- **THEN** ambos producen el mismo resultado en los tres casos

