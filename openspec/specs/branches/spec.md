# branches — Spec (sucursales-module-pro)

## Purpose

Gestión de sucursales (puntos de venta) por cuenta. Exclusivo plan PRO. Permite asignar operaciones (ventas, compras, gastos, stock) a sucursales específicas, filtrar/reportar por ellas y, desde C-26, operar su ciclo de vida (apertura/cierre operacional).
## Requirements
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

- **GIVEN** una cuenta con `billing_plan = 'avanzado'` (hasBranchesModule = false)
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

---

### Requirement: Visualización del stock por sucursal en la página de sucursales

El sistema SHALL mostrar en `/sucursales` el stock total asignado a cada sucursal (suma de `branch_stock.quantity` de todos los productos de esa sucursal) como indicador de inventario.

#### Scenario: Card de sucursal muestra productos con stock asignado

- **GIVEN** una sucursal A con `branch_stock` para 4 productos (distintas cantidades)
- **WHEN** el owner navega a `/sucursales`
- **THEN** la card de la sucursal A muestra "4 productos con stock asignado" o equivalente

#### Scenario: Sucursal sin stock asignado muestra indicador vacío

- **GIVEN** una sucursal B recién creada sin ninguna fila en `branch_stock`
- **WHEN** el owner navega a `/sucursales`
- **THEN** la card de sucursal B muestra "Sin stock asignado" o "0 productos"

---

### Requirement: Acceso a inventario desde la gestión de sucursales

El sistema SHALL proveer en `/sucursales/:id` un enlace o botón "Ver stock" que navega a `/sucursales/:id/stock`.

#### Scenario: Owner accede al inventario desde la página de sucursal

- **GIVEN** el owner está en `/sucursales/:id` (detalle de una sucursal)
- **WHEN** hace clic en "Ver stock"
- **THEN** navega a `/sucursales/:id/stock` con el inventario de esa sucursal

### Requirement: Lifecycle operacional de sucursal (open/close)
El sistema SHALL mantener en cada sucursal un estado operacional `status` (`'active'` | `'closed'`) independiente del soft-delete (`is_active`), con timestamps `opened_at`/`closed_at`, modificable únicamente por `owner`/`admin` vía `rpc_open_branch(p_branch_id)` y `rpc_close_branch(p_branch_id)`.

#### Scenario: Owner cierra una sucursal sin stock
- **GIVEN** una sucursal con `status = 'active'` y `Σ branch_stock = 0`
- **WHEN** el owner llama a `rpc_close_branch`
- **THEN** `status` pasa a `'closed'`, `closed_at = now()`, y la sucursal sigue visible en historial y reportes (`is_active` no cambia)

#### Scenario: Owner reabre una sucursal cerrada
- **GIVEN** una sucursal con `status = 'closed'`
- **WHEN** el owner llama a `rpc_open_branch`
- **THEN** `status` pasa a `'active'` y `opened_at = now()`

#### Scenario: Member no puede operar el lifecycle
- **GIVEN** un usuario con rol `member` en la cuenta
- **WHEN** llama a `rpc_open_branch` o `rpc_close_branch`
- **THEN** la RPC retorna error `P0401` (solo owner/admin)

### Requirement: Cierre de sucursal bloqueado con stock o si es la última operativa
El sistema SHALL rechazar `rpc_close_branch` si la sucursal tiene stock (`Σ branch_stock > 0`, error `P0409 branch_has_stock`) o si es la última sucursal con `status = 'active'` de la cuenta (error `P0409 last_active_branch`).

#### Scenario: Cierre con stock es rechazado
- **GIVEN** una sucursal con 5 unidades de algún producto en `branch_stock`
- **WHEN** el owner llama a `rpc_close_branch`
- **THEN** la RPC retorna `P0409 branch_has_stock` y el estado no cambia (transferir el stock primero)

#### Scenario: No se puede cerrar la única sucursal operativa
- **GIVEN** una cuenta cuya única sucursal con `status = 'active'` es la default
- **WHEN** el owner intenta cerrarla
- **THEN** la RPC retorna `P0409 last_active_branch`

### Requirement: Operaciones solo contra sucursales operativas
El sistema SHALL rechazar ventas, compras, ajustes y transferencias que referencien explícitamente una sucursal con `status = 'closed'`, con error `P0422 branch_closed`.

#### Scenario: Venta en sucursal cerrada falla
- **GIVEN** una sucursal con `status = 'closed'`
- **WHEN** se registra una venta con `p_branch_id` de esa sucursal
- **THEN** la RPC retorna `P0422 branch_closed` y no inserta ninguna fila

#### Scenario: Transferencia hacia o desde sucursal cerrada falla
- **GIVEN** una transferencia cuyo origen o destino tiene `status = 'closed'`
- **WHEN** se llama a `rpc_transfer_stock`
- **THEN** la RPC retorna `P0422 branch_closed` y no modifica ningún ledger

#### Scenario: UI muestra estado y acciones de lifecycle
- **GIVEN** el owner navega a `/sucursales/:id`
- **WHEN** la página carga
- **THEN** ve el badge de estado (`Activa`/`Cerrada`), el botón Abrir/Cerrar con confirmación, y el listado de transferencias de la sucursal

