## ADDED Requirements

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

## MODIFIED Requirements

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

### Requirement: Scoping de datos por cuenta vía RLS
El sistema SHALL restringir el acceso a las filas de negocio a los miembros de la cuenta dueña de la fila, reemplazando el scoping previo por `user_id`. **Este requisito ahora incluye `suppliers`** como tabla adicional scopeada por `account_id`. Las columnas `company_id` y `user_id` como mecanismo de tenancy se eliminan de las tablas ERP en el paso 7 del plan de migración.

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
