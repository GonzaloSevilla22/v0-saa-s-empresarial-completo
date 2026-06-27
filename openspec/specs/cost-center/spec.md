# cost-center Specification

## Purpose
TBD - created by archiving change cost-center-dimension. Update Purpose after archive.
## Requirements
### Requirement: Catálogo de centros de costo por cuenta

El sistema SHALL persistir un catálogo plano de centros de costo en la tabla `cost_centers` (`id` UUID PK, `account_id` UUID FK `accounts` NOT NULL, `name` TEXT NOT NULL, `code` TEXT NULL, `is_active` BOOLEAN NOT NULL DEFAULT TRUE, `created_at` TIMESTAMPTZ). El catálogo SHALL ser **plano** (sin jerarquías ni columna `parent_id`) y sin distribución porcentual. El sistema SHALL impedir nombres duplicados dentro de una misma cuenta de forma case-insensitive (`UNIQUE(account_id, lower(name))`). La tabla SHALL tener RLS por `account_id`.

#### Scenario: Crear un centro de costo

- **WHEN** un `owner`/`admin` crea un centro de costo con un nombre válido
- **THEN** se persiste una fila en `cost_centers` con `account_id` de su cuenta, `is_active = true` y el nombre dado

#### Scenario: Nombre duplicado en la misma cuenta es rechazado

- **GIVEN** una cuenta que ya tiene un centro de costo "Logística"
- **WHEN** se intenta crear otro "logística" (misma cuenta, distinta capitalización)
- **THEN** la operación es rechazada por el unique case-insensitive

#### Scenario: Aislamiento por cuenta

- **GIVEN** centros de costo de la cuenta A y de la cuenta B
- **WHEN** un usuario de la cuenta A lista los centros de costo
- **THEN** sólo ve los de la cuenta A (RLS por `account_id`)

---

### Requirement: Gestión del catálogo gateada por rol

El sistema SHALL permitir **leer** los centros de costo a cualquier miembro de la cuenta y **crear/editar/desactivar** sólo a `owner`/`admin`. La autorización de escritura SHALL aplicarse tanto a nivel de RLS (policy de `INSERT`/`UPDATE`) como en el service (`require_role`), de modo que un `member` no pueda modificar el catálogo aunque alcance la capa de datos.

#### Scenario: Member puede leer pero no escribir

- **GIVEN** un usuario con rol `member`
- **WHEN** lista los centros de costo de su cuenta
- **THEN** la lectura es permitida
- **AND** **WHEN** intenta crear o editar un centro de costo
- **THEN** la operación es rechazada (403)

#### Scenario: Owner/admin gestiona el catálogo

- **GIVEN** un usuario con rol `owner` o `admin`
- **WHEN** crea, renombra o desactiva un centro de costo de su cuenta
- **THEN** la operación es permitida y persiste

---

### Requirement: La baja es desactivación y preserva la imputación histórica

El sistema SHALL dar de baja un centro de costo mediante **desactivación** (`is_active = false`), NO mediante borrado físico. Un centro de costo desactivado NO SHALL ofrecerse para imputar gastos o compras nuevos, pero los gastos y compras ya imputados a él SHALL conservar la referencia (el nombre histórico no se pierde).

#### Scenario: Desactivar un centro de costo en uso

- **GIVEN** un centro de costo "Marketing" con gastos ya imputados
- **WHEN** un `owner`/`admin` lo desactiva
- **THEN** `is_active` queda en `false` y deja de aparecer en el selector de altas nuevas
- **AND** los gastos históricos imputados a "Marketing" conservan su `cost_center_id`

---

### Requirement: Imputación opcional de gastos a un centro de costo

El sistema SHALL permitir imputar opcionalmente un gasto a un centro de costo mediante una columna nullable `cost_center_id` (FK a `cost_centers`, `ON DELETE SET NULL`) en `public.expenses`. El campo SHALL ser opcional: un gasto sin centro de costo es válido y queda `NULL`. El `cost_center_id` provisto SHALL pertenecer a la misma cuenta que el gasto. La columna `cost_center_id` SHALL ser ortogonal a `expenses.category` (texto libre) y a `branch_id`: ninguna reemplaza a otra.

#### Scenario: Alta de gasto con centro de costo

- **WHEN** se crea un gasto con un `cost_center_id` activo de la cuenta
- **THEN** el gasto se persiste con ese `cost_center_id`

#### Scenario: Alta de gasto sin centro de costo

- **WHEN** se crea un gasto sin especificar centro de costo
- **THEN** el gasto se persiste con `cost_center_id = NULL` (válido)

#### Scenario: Centro de costo de otra cuenta es rechazado

- **WHEN** se intenta crear un gasto con un `cost_center_id` que pertenece a otra cuenta
- **THEN** la operación es rechazada (no se imputa cross-account)

---

### Requirement: Imputación opcional de compras a un centro de costo (por operación)

El sistema SHALL permitir imputar opcionalmente una compra a un centro de costo mediante una columna nullable `cost_center_id` (FK a `cost_centers`, `ON DELETE SET NULL`) en `public.purchases`. En una compra multi-línea (varias filas `purchases` con el mismo `operation_id`), el centro de costo SHALL ser **por operación**: todas las líneas de la operación comparten el mismo `cost_center_id`. El alta de compra (`rpc_create_purchase_operation`) SHALL aceptar un `cost_center_id` opcional, validar que pertenezca a la cuenta (igual que valida `branch_id`) y persistirlo en todas las líneas. La firma de idempotencia de la compra NO SHALL cambiar (no se agrega un `operation_kind` nuevo).

#### Scenario: Alta de compra multi-línea con centro de costo

- **WHEN** se crea una compra de 3 líneas con un `cost_center_id` activo de la cuenta
- **THEN** las 3 filas `purchases` de esa operación se persisten con el mismo `cost_center_id`

#### Scenario: Alta de compra sin centro de costo (regresión)

- **WHEN** se crea una compra sin especificar centro de costo
- **THEN** la compra se persiste con `cost_center_id = NULL` y el comportamiento previo no cambia

#### Scenario: Centro de costo de otra cuenta es rechazado en la compra

- **WHEN** se intenta crear una compra con un `cost_center_id` de otra cuenta
- **THEN** la operación es rechazada (validación de pertenencia, espejo de `branch_id`)

