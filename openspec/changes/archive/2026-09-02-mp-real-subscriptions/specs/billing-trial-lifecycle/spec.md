## MODIFIED Requirements

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

## ADDED Requirements

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
