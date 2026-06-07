# plan-gating — Delta Spec (multi-user-tenant-architecture)

> Modifica la capability `plan-gating` (C-02): el plan efectivo y los límites de recursos pasan a resolverse a nivel cuenta, no a nivel usuario individual.

## MODIFIED Requirements

### Requirement: Plan efectivo con soporte de trial

El sistema SHALL calcular el plan efectivo desde la **cuenta activa** del usuario (`accounts.billing_plan` / `accounts.trial_*`), no desde `profiles`. La lógica de trial se mantiene: si la cuenta está en trial activo, el plan efectivo es el `trial_plan` de la cuenta; de lo contrario, su `billing_plan`.

#### Scenario: Miembros comparten el plan de la cuenta
- **GIVEN** una cuenta con `billing_plan = 'pro'` y 5 miembros
- **WHEN** cualquiera de los 5 miembros evalúa su acceso a una feature 'pro'
- **THEN** el acceso es concedido (el plan vive en la cuenta, no en cada usuario)

#### Scenario: Trial de cuenta aplica a todos los miembros
- **GIVEN** una cuenta con `billing_status='trialing'`, `trial_plan='avanzado'`, trial vigente
- **WHEN** un miembro evalúa el acceso a "rentabilidad por producto"
- **THEN** el acceso es concedido para ese miembro (plan efectivo de la cuenta = 'avanzado')

### Requirement: Límites numéricos de recursos

El sistema SHALL contar los recursos (productos, clientes, operaciones/mes) **por cuenta** (`account_id`), no por usuario, al comparar contra los límites del plan.

#### Scenario: El límite de productos es compartido por la cuenta
- **GIVEN** una cuenta 'inicial' (max_products=500) con 2 miembros que crearon 498 y 1 productos (499 total)
- **WHEN** cualquier miembro crea un producto más
- **THEN** la creación es permitida (499 < 500); el siguiente (#501) es bloqueado para todos los miembros

## ADDED Requirements

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
