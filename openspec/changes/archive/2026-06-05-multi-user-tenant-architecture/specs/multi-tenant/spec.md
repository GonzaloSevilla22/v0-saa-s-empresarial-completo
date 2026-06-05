# multi-tenant — Spec (multi-user-tenant-architecture)

> Capability: **multi-tenant** — modelo de cuenta/organización compartida por múltiples usuarios, membresía, invitaciones gated por plan, y scoping de datos a nivel cuenta.

## ADDED Requirements

### Requirement: Modelo de cuenta y membresía

El sistema SHALL representar una cuenta (`accounts`) que puede ser compartida por múltiples usuarios a través de una tabla de membresía (`account_members`), donde cada miembro tiene un rol mínimo (`owner` o `member`).

#### Scenario: Una cuenta tiene un owner
- **WHEN** se crea una `account`
- **THEN** existe exactamente un `account_members` con `role = 'owner'` para esa cuenta

#### Scenario: Un usuario pertenece a una cuenta
- **GIVEN** un usuario miembro de una cuenta
- **WHEN** se consulta `current_account_ids()` para ese usuario
- **THEN** el resultado incluye el `account_id` de su cuenta

### Requirement: Backfill no destructivo de usuarios existentes

El sistema SHALL migrar cada usuario existente a su propia cuenta sin pérdida de datos: una cuenta por usuario, el usuario como `owner`, y todas sus filas de negocio reciben el `account_id` de esa cuenta.

#### Scenario: Cada usuario existente se vuelve owner de su cuenta
- **GIVEN** 26 usuarios en producción antes de la migración
- **WHEN** corre el backfill
- **THEN** se crean 26 `accounts`, cada una con un `account_members` `role='owner'`, y el `accounts.billing_plan` copia el `profiles.billing_plan` del usuario

#### Scenario: Ninguna fila de negocio queda sin cuenta
- **WHEN** el backfill de `account_id` completa
- **THEN** `SELECT count(*) FROM <tabla> WHERE account_id IS NULL` = 0 para cada tabla de negocio scopeada

#### Scenario: Los conteos de filas se preservan
- **GIVEN** N filas en una tabla de negocio antes de la migración
- **WHEN** la migración completa
- **THEN** la tabla tiene exactamente N filas (backfill aditivo, sin DELETE/INSERT)

### Requirement: Scoping de datos por cuenta vía RLS

El sistema SHALL restringir el acceso a las filas de negocio a los miembros de la cuenta dueña de la fila, reemplazando el scoping previo por `user_id`.

#### Scenario: Un miembro accede a los datos de su cuenta
- **GIVEN** un usuario miembro de la cuenta A
- **WHEN** consulta `products` (u otra tabla scopeada)
- **THEN** ve todas las filas con `account_id` de la cuenta A, sin importar qué miembro las creó

#### Scenario: Aislamiento entre cuentas
- **GIVEN** un usuario de la cuenta A y datos de la cuenta B
- **WHEN** el usuario A consulta cualquier tabla de negocio
- **THEN** NO ve ninguna fila con `account_id` de la cuenta B

#### Scenario: El owner conserva acceso a sus datos tras la migración
- **GIVEN** un usuario que era dueño de sus datos antes de la migración
- **WHEN** la RLS migra de `user_id` a `account_id`
- **THEN** el usuario sigue viendo exactamente los mismos datos (los de su cuenta backfilleada)

### Requirement: `user_id` conservado como autoría

El sistema SHALL conservar la columna `user_id` en las tablas de negocio como referencia de "creado por" (autoría/auditoría), sin usarla ya como eje de scoping.

#### Scenario: Una fila registra quién la creó
- **WHEN** un miembro de una cuenta crea una venta
- **THEN** la fila tiene `account_id` de la cuenta y `user_id` del miembro que la creó

### Requirement: Invitaciones gated por límite de plan

El sistema SHALL permitir invitar miembros a una cuenta hasta el límite `plan_limits.max_users` del plan efectivo de la cuenta, rechazando invitaciones que excedan el cupo.

#### Scenario: Cuenta con cupo acepta una invitación
- **GIVEN** una cuenta con plan 'avanzado' (max_users=5) y 3 miembros activos
- **WHEN** un invitado acepta una invitación vía `rpc_accept_invitation(token)`
- **THEN** se inserta un `account_members` y la cuenta queda con 4 miembros

#### Scenario: Cuenta sin cupo rechaza la invitación
- **GIVEN** una cuenta con plan 'gratis' (max_users=1) y 1 miembro (el owner)
- **WHEN** se intenta aceptar una invitación
- **THEN** la RPC rechaza la operación con error de cupo y NO inserta el miembro

#### Scenario: El enforcement es server-side
- **WHEN** un cliente intenta insertar directamente en `account_members` saltando la RPC
- **THEN** la RLS lo impide (escritura de miembros solo vía RPC `SECURITY DEFINER` o por el owner dentro del cupo)

### Requirement: RPCs de operaciones sellan la cuenta

El sistema SHALL hacer que las RPCs de creación de operaciones (ventas, compras, movimientos de stock) sellen el `account_id` de la cuenta activa del caller y validen su pertenencia.

#### Scenario: Una venta nueva queda asociada a la cuenta
- **GIVEN** un miembro de la cuenta A creando una venta vía `rpc_create_operation_aggregate`
- **WHEN** la RPC inserta las filas
- **THEN** las filas de `sales` y `stock_movements` tienen `account_id` de la cuenta A

#### Scenario: La RPC rechaza una cuenta ajena
- **WHEN** un caller pasa un `account_id` al que no pertenece
- **THEN** la RPC rechaza la operación
