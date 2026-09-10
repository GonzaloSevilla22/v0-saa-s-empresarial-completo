## MODIFIED Requirements

### Requirement: Límites numéricos de recursos

El sistema SHALL contar los recursos (productos, clientes, proveedores, operaciones/mes, exportaciones/mes) **por cuenta** (`account_id`), no por usuario, al comparar contra los límites del plan.

Los límites SHALL leerse de `plan_limits` en runtime **en todas las capas que los enforcean**, incluido el backend Python. Ninguna capa SHALL enforcear un límite desde constantes hardcodeadas.

El enforcement de los límites de recursos maestros (productos, clientes, proveedores) SHALL aplicarse en la **creación**. Los límites de contadores mensuales (operaciones/mes, exportaciones/mes) quedan fuera del enforcement de creación de este comportamiento.

El enforcement SHALL alcanzar **todo camino que cree recursos maestros**, incluida la carga masiva por archivo. Un camino de creación que no lo aplique NO SHALL considerarse una excepción sino un hueco: mientras exista, el límite del plan sólo restringe a quien crea de a uno.

Cuando una carga masiva dejaría a la cuenta por encima de su límite, el sistema SHALL rechazar el **lote completo** informando el conteo resultante y el tope, y NO SHALL aplicar una parte del archivo hasta agotar el cupo: aplicar parcialmente por cuota deja al usuario sin saber qué quedó adentro y qué no. Una carga masiva que sólo **actualiza** recursos existentes, sin crear ninguno, NO SHALL bloquearse aunque la cuenta ya esté por encima de su límite.

Cuando el enforcement de un límite de recurso maestro se ejecuta **dentro de la unidad de trabajo de base de datos**, la resolución del plan efectivo SHALL hacerse contra la base por la definición normativa única de plan efectivo, y NO SHALL derivarse de la información de plan que viaja en el token: ese camino cae a un valor por defecto permisivo cuando el claim no viaja, y el límite deja de existir sin que nada falle. Esta cláusula NO altera el enforcement que realiza el backend en la capa de aplicación, que conserva su regla propia.

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

#### Scenario: La carga masiva no puede sobrepasar el límite de productos
- **GIVEN** una cuenta con plan efectivo 'gratis' (max_products = 100) que tiene 90 productos
- **WHEN** importa un archivo que crearía 30 productos nuevos
- **THEN** el lote completo es rechazado informando el conteo resultante y el tope
- **AND** no queda creado ninguno de los 30

#### Scenario: Una carga masiva que sólo actualiza no se bloquea
- **GIVEN** una cuenta cuyo conteo de productos ya supera el límite de su plan
- **WHEN** importa un archivo cuyas filas todas actualizan productos existentes
- **THEN** la importación es permitida

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
