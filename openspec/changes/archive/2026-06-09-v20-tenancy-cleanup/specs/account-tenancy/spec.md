## ADDED Requirements

### Requirement: Todas las tablas ERP tienen account_id sin NULLs
El sistema SHALL garantizar que ninguna fila en las tablas ERP (`sales`, `purchases`, `products`, `expenses`, `clients`, `stock_movements`, `suppliers`) tenga `account_id IS NULL` tras el backfill.

#### Scenario: Backfill completa sin filas huérfanas
- **WHEN** el script de backfill del paso 1 termina en producción
- **THEN** `SELECT COUNT(*) FROM <tabla> WHERE account_id IS NULL` = 0 para cada tabla ERP listada

#### Scenario: Inserción futura no puede ser sin account_id
- **WHEN** se intenta hacer INSERT en `sales`, `purchases`, `products`, `expenses` o `clients` sin `account_id`
- **THEN** la DB rechaza la operación (NOT NULL constraint o CHECK)

### Requirement: suppliers scoped por account_id con RLS
El sistema SHALL proteger las filas de `suppliers` mediante RLS basada en `account_id`, alineada con el resto de las tablas ERP.

#### Scenario: Usuario solo ve sus propios suppliers
- **GIVEN** dos tenants A y B, cada uno con suppliers propios
- **WHEN** el usuario de tenant A ejecuta `SELECT * FROM suppliers`
- **THEN** solo recibe los `suppliers` donde `account_id = ANY(current_account_ids())`; los suppliers del tenant B no aparecen

#### Scenario: Supplier sin account_id no es creatable post-migración
- **WHEN** se intenta INSERT en `suppliers` sin `account_id`
- **THEN** la DB rechaza la operación (NOT NULL constraint aplicada en paso 6)

### Requirement: account_id obtenido desde el request context en backend Python
El sistema SHALL proveer un dependency `get_account_id` en `core/deps.py` que retorna el `account_id` del tenant activo consultando `account_members` via la conexión JWT-passthrough del request. Ningún repositorio SHALL derivar `account_id` desde JWT claims directamente.

#### Scenario: Dependency retorna account_id del tenant activo
- **WHEN** un endpoint recibe `account_id: UUID = Depends(get_account_id)` con un JWT válido de un usuario miembro de una cuenta
- **THEN** `get_account_id` ejecuta `SELECT account_id FROM account_members WHERE user_id = auth.uid() LIMIT 1` y retorna el UUID de la cuenta

#### Scenario: Usuario sin cuenta activa recibe 403
- **GIVEN** un JWT válido de un usuario sin ninguna fila en `account_members`
- **WHEN** el endpoint invoca `Depends(get_account_id)`
- **THEN** se lanza `HTTPException(status_code=403)` con mensaje "No active account found"

### Requirement: Columnas legacy de tenancy eliminadas de tablas ERP
El sistema SHALL eliminar `company_id` y `user_id` (como mecanismo de tenancy) de las tablas ERP (`sales`, `purchases`, `products`, `expenses`, `clients`) tras validar que no tienen consumidores activos. El campo `user_id` que sea FK a `auth.users` se conserva solo si tiene ese rol semántico distinto.

#### Scenario: tablas ERP no tienen columna company_id post-drop
- **WHEN** se consulta `information_schema.columns` para las tablas ERP listadas
- **THEN** ninguna de ellas tiene una columna llamada `company_id`

#### Scenario: suppliers no tiene company_id post-drop
- **WHEN** se consulta `information_schema.columns` para `suppliers`
- **THEN** la columna `company_id` no existe (reemplazada por `account_id`)

### Requirement: Organizaciones históricas de companies migradas a accounts
El sistema SHALL migrar cada fila de `companies` a una fila en `accounts`, asociando sus usuarios via `account_members`, antes de eliminar la tabla `companies` o sus referencias.

#### Scenario: Cada company tiene un account correspondiente
- **WHEN** el script de migración del paso 1 corre en producción
- **THEN** para cada fila en `companies` existe al menos un `account_id` en `accounts` con los datos equivalentes; no se crean cuentas duplicadas si el usuario ya tenía una

#### Scenario: Usuarios de company_users son miembros del account migrado
- **GIVEN** un usuario listado en `company_users` para una company X
- **WHEN** la migración completa
- **THEN** ese usuario tiene una fila en `account_members` con el `account_id` que corresponde a la company X migrada
