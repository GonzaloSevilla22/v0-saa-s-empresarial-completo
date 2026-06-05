# billing — Delta Spec (billing-schema-migration)

> Capability: **billing** — modelo de planes comerciales, límites por plan, estado de suscripción y trial. Esta delta crea el esquema de datos; el enforcement (gating) es responsabilidad de `plan-gating-engine` (C-02).

## ADDED Requirements

### Requirement: Cuatro planes comerciales

El sistema SHALL representar exactamente cuatro planes comerciales — `gratis`, `inicial`, `avanzado`, `pro` — en la columna `profiles.billing_plan`, validados por una restricción CHECK.

#### Scenario: Asignar un plan válido
- **WHEN** se asigna `billing_plan = 'avanzado'` a un perfil
- **THEN** la operación es aceptada

#### Scenario: Rechazar un plan inválido
- **WHEN** se intenta asignar `billing_plan = 'enterprise'` a un perfil
- **THEN** la base de datos rechaza la operación por violación de la restricción CHECK

#### Scenario: Default para perfiles nuevos
- **WHEN** se crea un perfil sin especificar `billing_plan`
- **THEN** el perfil recibe `billing_plan = 'gratis'` por defecto

### Requirement: Límites por plan centralizados

El sistema SHALL almacenar los límites de cada plan en la tabla `plan_limits`, con una fila por plan, como única fuente de verdad de los límites (productos, clientes, proveedores, operaciones/mes, historial, exportaciones, consultas IA, consejos IA, usuarios, sucursales y flags de features).

#### Scenario: La tabla contiene los cuatro planes sembrados
- **WHEN** se consulta `SELECT count(*) FROM plan_limits`
- **THEN** el resultado es 4 y cada plan tiene los límites de RN-03 (ej.: `gratis.max_products = 100`, `pro.max_products = 5000`)

#### Scenario: El seed es idempotente
- **WHEN** la migración de seed se ejecuta más de una vez
- **THEN** `plan_limits` conserva exactamente 4 filas (upsert por `ON CONFLICT (plan)`), sin duplicados

#### Scenario: Lectura pública de límites
- **WHEN** un cliente no autenticado (`anon`) lee `plan_limits`
- **THEN** la lectura es permitida por RLS

#### Scenario: Escritura restringida a admin
- **WHEN** un usuario autenticado sin rol admin intenta `UPDATE` sobre `plan_limits`
- **THEN** RLS rechaza la operación

### Requirement: Estado de suscripción y trial de 60 días

El sistema SHALL persistir el estado de suscripción (`billing_status` ∈ `active|trialing|expired|cancelled`) y los timestamps del trial (`trial_started_at`, `trial_expires_at`) en `profiles`. La aplicación de la lógica de vencimiento queda fuera de esta capability (la cubre `grace-period-logic`, C-03).

#### Scenario: Trial inicial de un perfil nuevo
- **WHEN** se crea un perfil nuevo
- **THEN** `billing_status = 'trialing'` y `trial_expires_at = trial_started_at + 60 días`

#### Scenario: Preservar la ventana de gracia de usuarios existentes
- **WHEN** se migra un usuario existente que tiene `created_at`
- **THEN** `trial_started_at = created_at` y `trial_expires_at = created_at + 60 días` (no se reinicia la gracia ya transcurrida)

### Requirement: Contadores de uso de IA separados

El sistema SHALL rastrear el uso de IA en dos contadores independientes en `profiles`: `ai_queries_used` (Consultas IA) y `ai_advice_used` (Consejos IA), junto con `usage_reset_at` para el reset mensual.

#### Scenario: Backfill del contador de consultas desde el legacy
- **WHEN** se migra un usuario con `insights_used = N`
- **THEN** `ai_queries_used = N` y `ai_advice_used = 0`

#### Scenario: Default de los contadores en perfiles nuevos
- **WHEN** se crea un perfil nuevo
- **THEN** `ai_queries_used = 0`, `ai_advice_used = 0` y `usage_reset_at = now()`

### Requirement: Audit trail de eventos de billing

El sistema SHALL registrar todo cambio de plan o estado en la tabla append-only `billing_events`, sin permitir modificación ni borrado por usuarios finales.

#### Scenario: Evento de backfill durante la migración
- **WHEN** la migración backfillea un perfil
- **THEN** se inserta un `billing_events` con `event_type = 'migration_backfill'`, `from_plan` y `to_plan`

#### Scenario: Un usuario no puede escribir eventos de billing
- **WHEN** un usuario autenticado intenta `INSERT` en `billing_events`
- **THEN** RLS rechaza la operación (la escritura queda reservada a sistema/admin)

#### Scenario: Un usuario lee solo sus propios eventos
- **WHEN** un usuario autenticado consulta `billing_events`
- **THEN** solo ve filas donde `user_id = auth.uid()`

### Requirement: Migración aditiva y no destructiva

La migración SHALL ser aditiva: NO redefine el dominio de la columna legacy `profiles.plan` (un ENUM `user_plan`), NO elimina `insights_used`, y todas las columnas/tablas se agregan con `IF NOT EXISTS`.

#### Scenario: La columna legacy `plan` permanece intacta
- **WHEN** se aplica la migración
- **THEN** la columna `profiles.plan` conserva su tipo y valores; `billing_plan` es la nueva fuente de verdad

#### Scenario: No se pierden filas en el backfill
- **WHEN** se completa el backfill
- **THEN** el conteo de filas de `profiles` es igual al baseline previo a la migración y ninguna fila queda con `billing_plan IS NULL`
