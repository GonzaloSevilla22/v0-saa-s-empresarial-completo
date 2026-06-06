## ADDED Requirements

### Requirement: Creación de sucursal vía RPC con límite de plan

El sistema SHALL crear sucursales únicamente a través de la RPC `rpc_create_branch(p_account_id UUID, p_name TEXT, p_address TEXT)`, que verifica que el número de sucursales activas de la cuenta no supera `plan_limits.max_branches` del plan efectivo antes de insertar.

#### Scenario: Cuenta PRO crea su primera sucursal

- **GIVEN** una cuenta con `billing_plan = 'pro'` y 0 sucursales activas
- **WHEN** el owner llama a `rpc_create_branch` con un nombre válido
- **THEN** se inserta una fila en `branches` con `is_active = TRUE` y se retorna el objeto creado

#### Scenario: Cuenta PRO intenta crear la cuarta sucursal

- **GIVEN** una cuenta con `billing_plan = 'pro'` y 3 sucursales activas (límite = 3)
- **WHEN** cualquier miembro llama a `rpc_create_branch`
- **THEN** la RPC retorna error `branch_limit_exceeded` y NO inserta ninguna fila

#### Scenario: Cuenta no-PRO no puede crear sucursales

- **GIVEN** una cuenta con `billing_plan = 'avanzado'` (max_branches = 0)
- **WHEN** el owner llama a `rpc_create_branch`
- **THEN** la RPC retorna error `branch_limit_exceeded`

#### Scenario: El nombre de sucursal debe ser único dentro de la cuenta

- **GIVEN** una cuenta con una sucursal llamada "Mendoza Centro"
- **WHEN** se intenta crear otra sucursal con el mismo nombre en la misma cuenta
- **THEN** la RPC retorna error `branch_name_duplicate` (violación de UNIQUE constraint `(account_id, name)`)

---

### Requirement: Listado y edición de sucursales

El sistema SHALL permitir a los miembros listar las sucursales activas de su cuenta, y a `owner` y `admin` editar nombre y dirección.

#### Scenario: Miembro lista las sucursales de su cuenta

- **GIVEN** un usuario miembro de una cuenta con 2 sucursales activas
- **WHEN** consulta `SELECT * FROM branches WHERE account_id = :account_id AND is_active = TRUE`
- **THEN** ve exactamente 2 filas

#### Scenario: Miembro no ve sucursales de otra cuenta

- **GIVEN** dos cuentas A y B, cada una con sucursales propias
- **WHEN** un miembro de la cuenta A consulta `branches`
- **THEN** solo ve las sucursales de la cuenta A (RLS aísla)

#### Scenario: Owner actualiza el nombre de una sucursal

- **GIVEN** una sucursal `id = X` que pertenece a la cuenta del owner
- **WHEN** el owner hace UPDATE `branches SET name = 'Nuevo Nombre' WHERE id = X`
- **THEN** la actualización es permitida por RLS

#### Scenario: Member no puede editar sucursales

- **GIVEN** un usuario con rol `member` en la cuenta
- **WHEN** intenta UPDATE `branches SET name = 'Hack' WHERE id = X`
- **THEN** la RLS rechaza la operación

---

### Requirement: Soft-delete de sucursales

El sistema SHALL marcar las sucursales como inactivas (`is_active = FALSE`) en lugar de borrarlas físicamente, preservando el historial de operaciones asociadas.

#### Scenario: Owner desactiva una sucursal

- **GIVEN** una sucursal con `is_active = TRUE` y operaciones históricas con `branch_id = X`
- **WHEN** el owner llama a la función de desactivación
- **THEN** `branches.is_active` pasa a `FALSE` y las filas de `sales` y demás tablas conservan su `branch_id = X`

#### Scenario: Sucursal inactiva no aparece en el selector

- **GIVEN** una sucursal con `is_active = FALSE`
- **WHEN** el sistema carga el listado de sucursales disponibles para el selector de formularios
- **THEN** la sucursal inactiva no está en el listado

#### Scenario: Sucursal inactiva aparece en reportes históricos

- **GIVEN** ventas registradas con `branch_id = X` cuando la sucursal estaba activa
- **WHEN** se consulta el reporte por sucursal incluyendo sucursales inactivas
- **THEN** las ventas de la sucursal X aparecen en el reporte (no se pierden datos históricos)

---

### Requirement: Asociación opcional de operaciones a una sucursal

El sistema SHALL permitir registrar ventas, compras, gastos y movimientos de stock con un `branch_id` opcional. Si `branch_id` es NULL, la operación pertenece a la cuenta pero no a una sucursal específica.

#### Scenario: Venta creada con sucursal asignada

- **GIVEN** un formulario de venta con una sucursal seleccionada
- **WHEN** el usuario registra la venta
- **THEN** la fila en `sales` tiene `branch_id` igual al id de la sucursal seleccionada

#### Scenario: Venta creada sin sucursal asignada

- **GIVEN** un formulario de venta sin sucursal seleccionada (campo vacío o no visible)
- **WHEN** el usuario registra la venta
- **THEN** la fila en `sales` tiene `branch_id = NULL`

#### Scenario: Operaciones de cuentas no-PRO tienen `branch_id = NULL`

- **GIVEN** un usuario con plan `avanzado` creando una venta
- **WHEN** el formulario no muestra el selector de sucursal (plan insuficiente)
- **THEN** la fila en `sales` tiene `branch_id = NULL`

---

### Requirement: Filtro de dashboard por sucursal

El sistema SHALL filtrar todos los KPIs y datos del dashboard por la sucursal seleccionada en el header, propagado vía URL query param `branch`.

#### Scenario: Dashboard sin filtro de sucursal muestra toda la cuenta

- **GIVEN** un usuario PRO con 2 sucursales
- **WHEN** accede a `/dashboard` sin query param `branch`
- **THEN** los KPIs consolidan datos de todas las sucursales + operaciones sin sucursal (account_id completo)

#### Scenario: Dashboard filtrado por sucursal muestra solo esa sucursal

- **GIVEN** un usuario PRO que selecciona la sucursal "Mendoza Centro" (id = X)
- **WHEN** el header propaga `?branch=X` a la URL
- **THEN** los KPIs y tablas solo muestran operaciones con `branch_id = X`

#### Scenario: URL con branch inválido o de otra cuenta es ignorado

- **GIVEN** un usuario que manipula la URL con un `branch` id de otra cuenta
- **WHEN** el servidor resuelve el filtro
- **THEN** el filtro es ignorado (la RLS aísla la sucursal) y el dashboard muestra toda la cuenta

---

### Requirement: Reporte por sucursal

El sistema SHALL proveer un reporte en `/reportes/sucursal` que desglosa ventas, gastos y cantidad de operaciones por sucursal para el período seleccionado, incluyendo una fila para "Sin sucursal" (operaciones con `branch_id = NULL`).

#### Scenario: Reporte muestra totales por sucursal

- **GIVEN** un período seleccionado con ventas en 2 sucursales y ventas sin sucursal
- **WHEN** el usuario accede a `/reportes/sucursal`
- **THEN** la tabla muestra 3 filas: una por cada sucursal activa + "Sin sucursal", con totales de ventas y gastos

#### Scenario: Cuenta no-PRO no puede acceder al reporte por sucursal

- **GIVEN** un usuario con plan `avanzado`
- **WHEN** intenta navegar a `/reportes/sucursal`
- **THEN** ve el componente `PlanGate` con CTA de upgrade a PRO
