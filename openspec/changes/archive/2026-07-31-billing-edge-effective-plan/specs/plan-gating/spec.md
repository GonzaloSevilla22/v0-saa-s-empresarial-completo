## ADDED Requirements

### Requirement: La capa Edge Function no redefine el plan efectivo

Ninguna Edge Function SHALL implementar su propia lógica de plan efectivo ni derivarla de `public.profiles`. El plan efectivo SHALL obtenerse de la definición normativa de la base de datos (`public.get_effective_plan`), invocada a través de un único módulo compartido en `supabase/functions/_shared/`.

La resolución SHALL derivar la cuenta del usuario autenticado a partir de su propia identidad, de modo que una Edge Function NOT SHALL poder obtener el plan efectivo de una cuenta ajena.

Cuando el plan efectivo no pueda resolverse, la resolución SHALL degradar a `'gratis'` (fail-closed), nunca a un plan superior, y SHALL registrar el error para que la degradación sea observable.

#### Scenario: La cuenta que pagó recibe el plan que pagó
- **GIVEN** una cuenta con `accounts.billing_plan = 'pro'` cuyo registro en `profiles` conserva el valor por defecto `'gratis'`
- **WHEN** cualquier miembro de esa cuenta invoca una Edge Function que aplica gating por plan
- **THEN** el plan efectivo usado para decidir es `'pro'`

#### Scenario: La cuenta exenta es reconocida por las Edge Functions
- **GIVEN** una cuenta con `accounts.billing_exempt = true`
- **WHEN** un miembro invoca una Edge Function que aplica gating por plan
- **THEN** el plan efectivo usado para decidir es `'pro'`

#### Scenario: `billing_status` no altera la decisión de una Edge Function
- **GIVEN** dos cuentas con idéntico `billing_plan`, `trial_plan` y `trial_expires_at`, que difieren solo en `billing_status`
- **WHEN** ambas invocan la misma Edge Function
- **THEN** el plan efectivo resuelto es el mismo para las dos

#### Scenario: El trial vencido cae al plan base sin depender de ningún barrido
- **GIVEN** una cuenta con `trial_plan = 'pro'` y `trial_expires_at` en el pasado, sobre la que el barrido de vencimiento todavía no corrió
- **WHEN** invoca una Edge Function que aplica gating por plan
- **THEN** el plan efectivo resuelto es su `billing_plan`, no `'pro'`

#### Scenario: Un fallo al resolver el plan degrada a gratis
- **GIVEN** que la resolución del plan efectivo falla por un error transitorio
- **WHEN** una Edge Function necesita el plan para decidir
- **THEN** usa `'gratis'` y registra el error, en lugar de conceder un plan superior

#### Scenario: Una Edge Function no puede consultar el plan de otra cuenta
- **GIVEN** un usuario autenticado miembro de una cuenta
- **WHEN** se resuelve el plan efectivo desde una Edge Function
- **THEN** la cuenta evaluada es una de las cuentas del propio usuario, sin admitir un identificador de cuenta provisto por el llamador

#### Scenario: Un usuario miembro de varias cuentas resuelve de forma determinista
- **GIVEN** un usuario que pertenece a más de una cuenta
- **WHEN** se resuelve su plan efectivo desde una Edge Function
- **THEN** la resolución selecciona siempre la misma cuenta según una regla documentada, sin producir error

## MODIFIED Requirements

### Requirement: Cuota IA aplica a todas las Edge Functions de IA (C-04)

El sistema SHALL verificar la cuota IA **antes** de llamar a OpenAI y SHALL incrementar el contador **después** de una llamada exitosa, en **todas** las Edge Functions de IA del proyecto: `ai-insights`, `ai-comparativo`, `ai-precio`, `ai-prediccion`, `ai-rentabilidad`, `ai-resumen`, `ai-simulador` (counter `'queries'`) y `fair-advisor` (counter `'advice'`).

El incremento SHALL realizarse mediante el RPC atómico `rpc_increment_ai_usage` (no read-modify-write desde el cliente).

El límite contra el que se compara el contador SHALL corresponder al **plan efectivo de la cuenta**, resuelto según la definición normativa de la base de datos. La verificación de cuota NOT SHALL derivar el plan de `public.profiles`.

#### Scenario: fair-advisor bloqueado al exceder cuota de advice

- **GIVEN** un usuario `gratis` con `ai_advice_used = 3` (límite = 3)
- **WHEN** llama a `fair-advisor`
- **THEN** la función retorna HTTP 429 con `{ ok: false, error: 'quota_exceeded' }`

#### Scenario: fair-advisor procede cuando hay cuota disponible

- **GIVEN** un usuario `avanzado` con `ai_advice_used = 1` (límite = 10)
- **WHEN** llama a `fair-advisor`
- **THEN** la función procesa la solicitud y retorna resultado de IA, `ai_advice_used` queda en 2

#### Scenario: ai-insights bloqueado al exceder cuota de queries

- **GIVEN** un usuario `gratis` con `ai_queries_used = 5` (límite = 5)
- **WHEN** llama a `ai-insights`
- **THEN** la función retorna HTTP 429 con `{ ok: false, error: 'quota_exceeded' }`

#### Scenario: El límite de la cuenta que pagó corresponde a su plan pagado

- **GIVEN** una cuenta con `accounts.billing_plan = 'pro'` cuyo registro en `profiles` conserva `'gratis'`, y un miembro con `ai_queries_used = 10`
- **WHEN** ese miembro llama a una Edge Function de IA
- **THEN** la llamada es procesada, porque el contador se compara contra el límite de `'pro'` (300) y no contra el de `'gratis'` (5)
