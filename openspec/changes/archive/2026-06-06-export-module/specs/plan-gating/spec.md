## MODIFIED Requirements

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
