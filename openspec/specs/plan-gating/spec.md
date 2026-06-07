# plan-gating — Spec (plan-gating-engine)

> Capability: **plan-gating** — enforcement en runtime de límites y features por plan. Determina el plan efectivo del usuario, provee hooks de gating, y aplica restricciones en UI y Edge Functions.

## ADDED Requirements

### Requirement: Plan efectivo con soporte de trial

El sistema SHALL calcular el plan efectivo desde la **cuenta activa** del usuario (`accounts.billing_plan` / `accounts.trial_*`), no desde `profiles`. La lógica de trial se mantiene: si la cuenta está en trial activo, el plan efectivo es el `trial_plan` de la cuenta; de lo contrario, su `billing_plan`.

#### Scenario: Usuario con trial activo accede a features de plan superior
- **GIVEN** un usuario con `billing_plan = 'gratis'`, `trial_plan = 'avanzado'`, `trial_expires_at = now() + 15 days`
- **WHEN** el sistema evalúa su acceso a la feature "rentabilidad por producto"
- **THEN** el acceso es concedido (efectivo = 'avanzado')

#### Scenario: Usuario sin trial usa su plan base
- **GIVEN** un usuario con `billing_plan = 'inicial'`, `trial_plan = null`
- **WHEN** el sistema evalúa su acceso a "reportes comparativos"
- **THEN** el acceso es denegado (efectivo = 'inicial', requiere 'avanzado')

#### Scenario: Trial vencido cae al plan base
- **GIVEN** un usuario con `billing_plan = 'gratis'`, `trial_plan = 'avanzado'`, `trial_expires_at = now() - 1 day`
- **WHEN** el sistema evalúa su plan efectivo
- **THEN** el plan efectivo es 'gratis'

#### Scenario: Miembros comparten el plan de la cuenta
- **GIVEN** una cuenta con `billing_plan = 'pro'` y 5 miembros
- **WHEN** cualquiera de los 5 miembros evalúa su acceso a una feature 'pro'
- **THEN** el acceso es concedido (el plan vive en la cuenta, no en cada usuario)

#### Scenario: Trial de cuenta aplica a todos los miembros
- **GIVEN** una cuenta con `billing_status='trialing'`, `trial_plan='avanzado'`, trial vigente
- **WHEN** un miembro evalúa el acceso a "rentabilidad por producto"
- **THEN** el acceso es concedido para ese miembro (plan efectivo de la cuenta = 'avanzado')

### Requirement: Jerarquía de planes

El sistema SHALL aplicar una jerarquía ordenada `gratis < inicial < avanzado < pro`. Una feature disponible desde el plan X es accesible por todos los planes >= X.

#### Scenario: Plan superior tiene acceso a features de planes inferiores
- **GIVEN** un usuario con `billing_plan = 'pro'`
- **WHEN** accede a cualquier feature disponible desde 'gratis', 'inicial' o 'avanzado'
- **THEN** el acceso es concedido

### Requirement: Límites numéricos de recursos

El sistema SHALL contar los recursos (productos, clientes, operaciones/mes, exportaciones/mes) **por cuenta** (`account_id`), no por usuario, al comparar contra los límites del plan. Se agrega `max_exports_per_month` como dimensión de límite numérico.

#### Scenario: Usuario gratis intenta crear el producto 101
- **GIVEN** un usuario con plan efectivo 'gratis' que ya tiene 100 productos
- **WHEN** intenta acceder al formulario de creación de producto
- **THEN** el sistema muestra un banner "Límite alcanzado" en lugar del formulario, con CTA de upgrade

#### Scenario: Usuario avanzado crea productos sin restricción hasta 1.500
- **GIVEN** un usuario con plan efectivo 'avanzado' con 1.499 productos
- **WHEN** crea un producto más
- **THEN** la creación es permitida (límite = 1.500)

#### Scenario: El límite se lee desde `plan_limits` en la DB
- **GIVEN** que el admin actualiza `plan_limits SET max_products = 150 WHERE plan = 'gratis'`
- **WHEN** un usuario gratis con 120 productos intenta crear uno más
- **THEN** el sistema permite la creación (límite actualizado a 150)

#### Scenario: El límite de productos es compartido por la cuenta
- **GIVEN** una cuenta 'inicial' (max_products=500) con 2 miembros que crearon 498 y 1 productos (499 total)
- **WHEN** cualquier miembro crea un producto más
- **THEN** la creación es permitida (499 < 500); el siguiente (#501) es bloqueado para todos los miembros

#### Scenario: `usePlanLimits()` expone `maxExportsPerMonth` y `exportsUsed`
- **GIVEN** un usuario con plan efectivo 'avanzado' y `exports_used = 7`
- **WHEN** el componente llama a `usePlanLimits()`
- **THEN** retorna `{ ..., maxExportsPerMonth: 15, exportsUsed: 7, exportsRemaining: 8 }`

#### Scenario: `plan_limits` incluye `max_exports_per_month` por plan
- **GIVEN** la tabla `plan_limits` con el seed actualizado
- **WHEN** se consulta `SELECT max_exports_per_month FROM plan_limits WHERE plan = 'inicial'`
- **THEN** retorna `3`

### Requirement: Gating de features exclusivas

El sistema SHALL restringir el acceso a features marcadas como exclusivas de planes superiores.

#### Scenario: Acceso a rentabilidad por producto (avanzado+)
- **GIVEN** un usuario con plan efectivo 'inicial'
- **WHEN** intenta acceder a la sección de rentabilidad por producto
- **THEN** ve el contenido bloqueado con el componente `PlanGate` mostrando el plan mínimo requerido

#### Scenario: Acceso a comunidad para postear (avanzado+)
- **GIVEN** un usuario con plan efectivo 'gratis'
- **WHEN** intenta crear un post en la comunidad
- **THEN** la acción es bloqueada tanto en UI como en DB (RLS)

### Requirement: Límites de IA con verificación server-side

El sistema SHALL rechazar llamadas a las Edge Functions de IA cuando el usuario agotó su cuota mensual, sin llamar a OpenAI.

#### Scenario: Usuario gratis agotó sus 5 consultas IA
- **GIVEN** un usuario con plan efectivo 'gratis' con `ai_queries_used = 5`
- **WHEN** llama a cualquier Edge Function de IA (ai-insights, ai-prediccion, etc.)
- **THEN** la Edge Function retorna HTTP 429 `{ ok: false, error: 'quota_exceeded', resetAt: <usage_reset_at> }` sin llamar a OpenAI

#### Scenario: Usuario pro usa IA sin restricción práctica
- **GIVEN** un usuario con plan efectivo 'pro' con `ai_queries_used = 299`
- **WHEN** llama a una Edge Function de IA
- **THEN** la llamada es procesada normalmente (límite = 300/mes)

#### Scenario: Contador se incrementa tras cada llamada exitosa
- **GIVEN** una llamada IA exitosa para un usuario con `ai_queries_used = 10`
- **WHEN** la Edge Function completa la llamada a OpenAI
- **THEN** `profiles.ai_queries_used` se incrementa a 11

### Requirement: Límite de usuarios por cuenta

El sistema SHALL enforcear `plan_limits.max_users` como la cantidad máxima de miembros activos de una cuenta.

#### Scenario: El límite de usuarios refleja el plan
- **GIVEN** una cuenta con plan 'avanzado'
- **WHEN** se consulta el límite de usuarios
- **THEN** es 5 (de `plan_limits.max_users WHERE plan='avanzado'`)

#### Scenario: Upgrade de plan amplía el cupo de usuarios
- **GIVEN** una cuenta 'inicial' (max=2) llena que sube a 'avanzado' (max=5)
- **WHEN** se recalcula el cupo
- **THEN** la cuenta puede aceptar 3 invitaciones más

### Requirement: Lectura de límites desde DB en runtime

El sistema SHALL obtener los límites del plan desde `plan_limits` (DB) en runtime, no desde constantes hardcodeadas.

#### Scenario: `usePlanLimits()` retorna los límites del plan efectivo
- **GIVEN** un usuario con plan efectivo 'avanzado'
- **WHEN** el componente llama a `usePlanLimits()`
- **THEN** retorna `{ maxProducts: 1500, maxClients: 1000, maxAiQueriesPerMonth: 120, ... }` leídos de `plan_limits`

#### Scenario: Los límites están cacheados por 1 hora
- **GIVEN** `usePlanLimits()` fue llamado hace 30 minutos
- **WHEN** un nuevo componente llama a `usePlanLimits()`
- **THEN** se retorna el resultado cacheado sin llamar a la DB

## MODIFIED Requirements

### billing — RLS de comunidad actualizada

La restricción de INSERT en `posts` y `replies` pasa de verificar `plan = 'pro'` (ENUM legacy) a `billing_plan IN ('avanzado', 'pro')`.

#### Scenario: Usuario avanzado puede postear en comunidad
- **GIVEN** un usuario con `billing_plan = 'avanzado'`
- **WHEN** intenta INSERT en `posts`
- **THEN** la RLS permite la operación

#### Scenario: Usuario gratis no puede postear
- **GIVEN** un usuario con `billing_plan = 'gratis'`
- **WHEN** intenta INSERT en `posts`
- **THEN** la RLS rechaza la operación con error de policy

### Requirement: Cuota IA aplica a todas las Edge Functions de IA (C-04)

El sistema SHALL verificar la cuota IA **antes** de llamar a OpenAI y SHALL incrementar el contador **después** de una llamada exitosa, en **todas** las Edge Functions de IA del proyecto: `ai-insights`, `ai-prediccion`, `ai-resumen`, `ai-simulador` (counter `'queries'`) y `fair-advisor` (counter `'advice'`).

El incremento SHALL realizarse mediante el RPC atómico `rpc_increment_ai_usage` (no read-modify-write desde el cliente).

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

---

### Requirement: Límite de sucursales por plan (C-07)

El sistema SHALL leer `plan_limits.max_branches` y `plan_limits.has_branches_module` para cada plan y rechazar la creación de sucursales que supere el cupo. El módulo SHALL estar disponible solo para `pro`.

#### Scenario: `usePlanLimits()` expone `maxBranches` y `hasBranchesModule`

- **GIVEN** un usuario con plan efectivo 'pro'
- **WHEN** el componente llama a `usePlanLimits()`
- **THEN** el objeto retornado incluye `maxBranches: 3` y `hasBranchesModule: true`

#### Scenario: `usePlanLimits()` retorna `hasBranchesModule: false` para planes sin sucursales

- **GIVEN** un usuario con plan efectivo 'avanzado'
- **WHEN** el componente llama a `usePlanLimits()`
- **THEN** el objeto retornado incluye `hasBranchesModule: false`

#### Scenario: Seed de `plan_limits` incluye `max_branches` y `has_branches_module`

- **GIVEN** la tabla `plan_limits` correctamente seedeada
- **WHEN** se consulta `SELECT max_branches, has_branches_module FROM plan_limits WHERE plan = 'pro'`
- **THEN** retorna `max_branches = 3`, `has_branches_module = true`

#### Scenario: UI oculta módulo de sucursales para planes sin acceso

- **GIVEN** un usuario con plan 'avanzado' (`hasBranchesModule = false`)
- **WHEN** navega al sidebar principal
- **THEN** el item de menú "Sucursales" no está presente en el DOM (no solo oculto con CSS)
