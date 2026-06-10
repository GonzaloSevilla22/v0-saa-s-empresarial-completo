# multi-tenant — Spec

> Capability: **multi-tenant** — modelo de cuenta/organización compartida por múltiples usuarios, membresía, invitaciones gated por plan, y scoping de datos a nivel cuenta.

## Purpose

Migrar del modelo de usuario individual al modelo de cuenta compartida: cada usuario pertenece a una o más cuentas, puede invitar otros usuarios a su cuenta, y todos los datos de negocio se scopean por `account_id` en lugar de `user_id`. Soporta equipos pequeños (1-5 miembros por plan). C-06 añadió el rol `admin` (exclusivo del plan `pro`) con permisos de escritura pero sin gestión de billing ni ability de cambiar roles de otros admins.

## Requirements

### Requirement: Modelo de cuenta y membresía

El sistema SHALL representar una cuenta (`accounts`) que puede ser compartida por múltiples usuarios a través de una tabla de membresía (`account_members`), donde cada miembro tiene un rol (`owner`, `admin` o `member`). El rol `admin` es exclusivo del plan `pro` y otorga permisos de escritura en operaciones financieras sin acceso a billing ni gestión de otros admins.

#### Scenario: Una cuenta tiene un owner
- **WHEN** se crea una `account`
- **THEN** existe exactamente un `account_members` con `role = 'owner'` para esa cuenta

#### Scenario: Un usuario pertenece a una cuenta
- **GIVEN** un usuario miembro de una cuenta
- **WHEN** se consulta `current_account_ids()` para ese usuario
- **THEN** el resultado incluye el `account_id` de su cuenta

#### Scenario: Los valores de rol permitidos son owner, admin y member
- **GIVEN** cualquier intento de INSERT/UPDATE en `account_members`
- **WHEN** el valor de `role` es cualquier string fuera de `('owner', 'admin', 'member')` — por ejemplo `'superuser'`
- **THEN** la DB rechaza la operación por la constraint `CHECK (role IN ('owner', 'admin', 'member'))`

### Requirement: Backfill no destructivo de usuarios existentes

El sistema SHALL migrar cada usuario existente a su propia cuenta sin pérdida de datos: una cuenta por usuario, el usuario como `owner`, y todas sus filas de negocio reciben el `account_id` de esa cuenta. **Adicionalmente**, los registros de `companies` (organizaciones históricas) se mapean a `accounts` antes de cualquier drop; si el usuario asociado ya tiene una `account`, no se crea cuenta duplicada.

#### Scenario: Cada usuario existente se vuelve owner de su cuenta
- **GIVEN** 26 usuarios en producción antes de la migración
- **WHEN** corre el backfill
- **THEN** se crean 26 `accounts`, cada una con un `account_members` `role='owner'`, y el `accounts.billing_plan` copia el `profiles.billing_plan` del usuario

#### Scenario: Ninguna fila de negocio queda sin cuenta
- **WHEN** el backfill de `account_id` completa
- **THEN** `SELECT count(*) FROM <tabla> WHERE account_id IS NULL` = 0 para cada tabla de negocio scopeada (incluyendo `suppliers`)

#### Scenario: Los conteos de filas se preservan
- **GIVEN** N filas en una tabla de negocio antes de la migración
- **WHEN** la migración completa
- **THEN** la tabla tiene exactamente N filas (backfill aditivo, sin DELETE/INSERT)

#### Scenario: companies con usuarios existentes no generan cuentas duplicadas
- **GIVEN** una fila en `companies` con un usuario que ya tiene `account_id` en `account_members`
- **WHEN** corre el script de migración de `companies`
- **THEN** ese usuario no obtiene una segunda cuenta; se reutiliza la existente y la company queda mapeada a ese `account_id`

### Requirement: suppliers incluido en el scope de tenancy por cuenta

El sistema SHALL extender el modelo de tenancy por cuenta para cubrir la tabla `suppliers`, que en C-05 quedó fuera del alcance del backfill.

#### Scenario: suppliers backfilleado con account_id
- **GIVEN** N filas en `suppliers` con `company_id NOT NULL` y `account_id IS NULL`
- **WHEN** el backfill del paso 1 corre via join `company_id → accounts`
- **THEN** `SELECT COUNT(*) FROM suppliers WHERE account_id IS NULL` = 0

#### Scenario: RLS de suppliers usa current_account_ids()
- **GIVEN** la política RLS de `suppliers` actualizada con `USING (account_id = ANY(current_account_ids()))`
- **WHEN** un usuario autenticado consulta `SELECT * FROM suppliers`
- **THEN** solo ve los suppliers de sus cuentas; la política aplica en SELECT, INSERT, UPDATE y DELETE

### Requirement: Scoping de datos por cuenta vía RLS

El sistema SHALL restringir el acceso a las filas de negocio a los miembros de la cuenta dueña de la fila, reemplazando el scoping previo por `user_id`. **Este requisito ahora incluye `suppliers`** como tabla adicional scopeada por `account_id`. Las columnas `company_id` y `user_id` como mecanismo de tenancy se eliminan de las tablas ERP en el paso 7 del plan de migración.

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

#### Scenario: Un usuario solo puede leer sus propias ventas
- **GIVEN** dos tenants A y B
- **WHEN** el usuario de A consulta `SELECT * FROM sales`
- **THEN** solo ve filas donde `account_id = ANY(current_account_ids())` para su usuario

#### Scenario: Un usuario no puede insertar datos en otra cuenta
- **WHEN** se intenta INSERT en `products` con `account_id` de otro tenant
- **THEN** la RLS rechaza la operación con error de política

#### Scenario: company_id eliminado de sales post-cleanup
- **WHEN** se consulta `information_schema.columns` para la tabla `sales` tras el paso 7
- **THEN** la columna `company_id` no existe en `sales`

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
