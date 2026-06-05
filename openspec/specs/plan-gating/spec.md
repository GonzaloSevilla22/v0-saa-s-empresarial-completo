# plan-gating — Spec (plan-gating-engine)

> Capability: **plan-gating** — enforcement en runtime de límites y features por plan. Determina el plan efectivo del usuario, provee hooks de gating, y aplica restricciones en UI y Edge Functions.

## ADDED Requirements

### Requirement: Plan efectivo con soporte de trial

El sistema SHALL calcular el plan efectivo del usuario considerando un trial activo: si `billing_status = 'trialing'`, `trial_plan` no es nulo, y `trial_expires_at > now()`, el plan efectivo es `trial_plan`; de lo contrario, es `billing_plan`.

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

### Requirement: Jerarquía de planes

El sistema SHALL aplicar una jerarquía ordenada `gratis < inicial < avanzado < pro`. Una feature disponible desde el plan X es accesible por todos los planes >= X.

#### Scenario: Plan superior tiene acceso a features de planes inferiores
- **GIVEN** un usuario con `billing_plan = 'pro'`
- **WHEN** accede a cualquier feature disponible desde 'gratis', 'inicial' o 'avanzado'
- **THEN** el acceso es concedido

### Requirement: Límites numéricos de recursos

El sistema SHALL bloquear la creación de recursos cuando el usuario alcanzó el límite de su plan efectivo.

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
