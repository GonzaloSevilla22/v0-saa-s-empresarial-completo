## MODIFIED Requirements

### Requirement: Plan efectivo con soporte de trial

El sistema SHALL calcular el plan efectivo desde la **cuenta activa** del usuario (`accounts`), no desde `profiles`. La determinación SHALL delegarse en la definición normativa única `public.get_effective_plan(account_id)` (capability `billing-trial-lifecycle`): exención de cortesía vigente tiene precedencia sobre el trial, el trial vigente tiene precedencia sobre `billing_plan`, y la ausencia de información resuelve a `gratis`.

Ninguna capa SHALL redefinir la regla por su cuenta: el backend Python consume el plan efectivo **desde el claim del token** y NOT SHALL recomputarlo; el frontend mantiene un espejo verificado por una prueba de paridad contra la función SQL.

#### Scenario: Usuario con trial activo accede a features de plan superior
- **GIVEN** un usuario con `billing_plan = 'gratis'`, `trial_plan = 'pro'`, `trial_expires_at = now() + 15 days`
- **WHEN** el sistema evalúa su acceso a la feature "rentabilidad por producto"
- **THEN** el acceso es concedido (efectivo = 'pro')

#### Scenario: Usuario sin trial usa su plan base
- **GIVEN** un usuario con `billing_plan = 'inicial'`, `trial_plan = null`
- **WHEN** el sistema evalúa su acceso a "reportes comparativos"
- **THEN** el acceso es denegado (efectivo = 'inicial', requiere 'avanzado')

#### Scenario: Trial vencido cae al plan base
- **GIVEN** un usuario con `billing_plan = 'gratis'`, `trial_plan = 'pro'`, `trial_expires_at = now() - 1 day`
- **WHEN** el sistema evalúa su plan efectivo
- **THEN** el plan efectivo es 'gratis'

#### Scenario: Miembros comparten el plan de la cuenta
- **GIVEN** una cuenta con `billing_plan = 'pro'` y 5 miembros
- **WHEN** cualquiera de los 5 miembros evalúa su acceso a una feature 'pro'
- **THEN** el acceso es concedido (el plan vive en la cuenta, no en cada usuario)

#### Scenario: Trial de cuenta aplica a todos los miembros
- **GIVEN** una cuenta con trial PRO vigente
- **WHEN** un miembro evalúa el acceso a "rentabilidad por producto"
- **THEN** el acceso es concedido para ese miembro (plan efectivo de la cuenta = 'pro')

#### Scenario: La cuenta exenta accede como plan máximo
- **GIVEN** una cuenta con `billing_exempt = true`
- **WHEN** se evalúa su acceso a cualquier feature
- **THEN** el acceso es concedido (plan efectivo = 'pro')

#### Scenario: El backend no recomputa el plan
- **GIVEN** un request autenticado cuyo token trae el plan efectivo resuelto
- **WHEN** el backend evalúa un límite de plan
- **THEN** usa el valor del token y no consulta ni recalcula la regla de trial/exención

### Requirement: Límites numéricos de recursos

El sistema SHALL contar los recursos (productos, clientes, proveedores, operaciones/mes, exportaciones/mes) **por cuenta** (`account_id`), no por usuario, al comparar contra los límites del plan.

Los límites SHALL leerse de `plan_limits` en runtime **en todas las capas que los enforcean**, incluido el backend Python. Ninguna capa SHALL enforcear un límite desde constantes hardcodeadas.

El enforcement de los límites de recursos maestros (productos, clientes, proveedores) SHALL aplicarse en la **creación**. Los límites de contadores mensuales (operaciones/mes, exportaciones/mes) quedan fuera del enforcement de creación de este comportamiento.

#### Scenario: Usuario gratis intenta crear el producto 101
- **GIVEN** un usuario con plan efectivo 'gratis' que ya tiene 100 productos
- **WHEN** intenta acceder al formulario de creación de producto
- **THEN** el sistema muestra un banner "Límite alcanzado" en lugar del formulario, con CTA de upgrade

#### Scenario: Usuario avanzado crea productos sin restricción hasta 1.500
- **GIVEN** un usuario con plan efectivo 'avanzado' con 1.499 productos
- **WHEN** crea un producto más
- **THEN** la creación es permitida (límite = 1.500 según `plan_limits`)

#### Scenario: El límite se lee desde `plan_limits` en la DB
- **GIVEN** que el admin actualiza `plan_limits SET max_products = 150 WHERE plan = 'gratis'`
- **WHEN** un usuario gratis con 120 productos intenta crear uno más
- **THEN** el sistema permite la creación (límite actualizado a 150)

#### Scenario: El backend enforcea el límite de `plan_limits`, no una constante propia
- **GIVEN** que `plan_limits.max_products` para 'avanzado' vale 1500
- **WHEN** el backend evalúa la creación de un producto para una cuenta 'avanzado'
- **THEN** el límite aplicado es 1500 y no un valor distinto embebido en el código

#### Scenario: El límite de productos es compartido por la cuenta
- **GIVEN** una cuenta 'inicial' (max_products=500) con 2 miembros que crearon 498 y 1 productos (499 total)
- **WHEN** cualquier miembro crea un producto más
- **THEN** la creación es permitida (499 < 500); el siguiente (#501) es bloqueado para todos los miembros

#### Scenario: El límite de clientes se enforcea en la creación
- **GIVEN** una cuenta con plan efectivo 'gratis' (max_clients = 50) que ya tiene 50 clientes
- **WHEN** intenta crear un cliente más
- **THEN** la creación es rechazada con el mensaje de límite de plan

#### Scenario: El límite de proveedores se enforcea en la creación
- **GIVEN** una cuenta con plan efectivo 'gratis' (max_suppliers = 20) que ya tiene 20 proveedores
- **WHEN** intenta crear un proveedor más
- **THEN** la creación es rechazada con el mensaje de límite de plan

#### Scenario: Registrar una venta no se bloquea por límite de plan
- **GIVEN** una cuenta con plan efectivo 'gratis' que superó `max_operations_per_month`
- **WHEN** registra una venta
- **THEN** la operación es permitida (los contadores mensuales no bloquean la operación del negocio)

#### Scenario: `usePlanLimits()` expone `maxExportsPerMonth` y `exportsUsed`
- **GIVEN** un usuario con plan efectivo 'avanzado' y `exports_used = 7`
- **WHEN** el componente llama a `usePlanLimits()`
- **THEN** retorna `{ ..., maxExportsPerMonth: 15, exportsUsed: 7, exportsRemaining: 8 }`

#### Scenario: `plan_limits` incluye `max_exports_per_month` por plan
- **GIVEN** la tabla `plan_limits` con el seed actualizado
- **WHEN** se consulta `SELECT max_exports_per_month FROM plan_limits WHERE plan = 'inicial'`
- **THEN** retorna `3`

## ADDED Requirements

### Requirement: El enforcement de límites no destruye datos existentes

Cuando el plan efectivo de una cuenta baja y sus recursos existentes superan el límite del plan nuevo, el sistema NOT SHALL borrar, archivar, ocultar ni impedir la lectura o edición de esos recursos. Sólo la creación de recursos nuevos del tipo excedido SHALL bloquearse.

#### Scenario: Bajar de plan no borra nada
- **GIVEN** una cuenta con 2372 productos cuyo plan efectivo pasa de 'pro' a 'gratis'
- **WHEN** se consulta la cantidad de productos vivos de la cuenta
- **THEN** siguen siendo 2372

#### Scenario: El recurso excedido se puede editar y borrar
- **GIVEN** una cuenta en excedente de productos
- **WHEN** edita o borra uno de sus productos
- **THEN** la operación es permitida
