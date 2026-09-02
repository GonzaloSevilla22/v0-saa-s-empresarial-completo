# reporting-invariants — Delta

## MODIFIED Requirements

### Requirement: Reporte por sucursal con revenue y operaciones consistentes

El RPC `rpc_branch_report(p_account_id, p_start, p_end)` SHALL calcular por sucursal: `total_sales` = Σ `COALESCE(total, amount)` de ventas del rango, `total_expenses` = Σ gastos del rango, y `operation_count` = `COUNT(DISTINCT COALESCE(operation_id, id))` (las ventas legacy sin `operation_id` cuentan una operación cada una). El rango SHALL incluir el día final completo (RN-D5). La verificación de membership del caller sobre `p_account_id` se conserva sin cambios.

El RPC SHALL ejecutar sin error: toda referencia de columna que colisione con un parámetro OUT del `RETURNS TABLE` (como `branch_id`) SHALL estar calificada con su alias de tabla, de modo que la función nunca falle con `42702 column reference is ambiguous`.

La página `/reportes/sucursal` SHALL resolver la cuenta del usuario por el camino canónico de la app (`account_members`), NO desde `user_metadata` (donde ningún camino del sistema escribe `account_id`), y SHALL mostrar una rama de error visible cuando la carga del reporte falla — nunca presentar un fallo como "sin datos".

#### Scenario: El RPC ejecuta y devuelve filas

- **GIVEN** una cuenta con ventas y gastos repartidos en dos sucursales activas dentro del rango
- **WHEN** se ejecuta `rpc_branch_report` con la cuenta y el rango correctos
- **THEN** responde sin error con una fila por sucursal y totales no nulos

#### Scenario: La página resuelve el tenant como el resto de la app

- **GIVEN** un usuario autenticado miembro de una cuenta con datos en el período
- **WHEN** abre `/reportes/sucursal`
- **THEN** el reporte se carga con los datos de su cuenta, sin depender de ningún campo de `user_metadata`

#### Scenario: Un fallo del RPC es visible

- **WHEN** la llamada al RPC falla por cualquier motivo
- **THEN** la página muestra un estado de error visible y distinguible del estado "sin datos para el período"

#### Scenario: Venta legacy sin operation_id cuenta como una operación

- **GIVEN** una sucursal con 3 ventas modernas de una misma operación y 2 ventas legacy con `operation_id = NULL`
- **WHEN** se ejecuta `rpc_branch_report` sobre el rango que las contiene
- **THEN** `operation_count = 3` (1 operación moderna + 2 legacy)

#### Scenario: El revenue por sucursal suma totales de línea

- **GIVEN** una sucursal con una única venta de 2 unidades a $1.000 (`total = 2000`)
- **WHEN** se ejecuta `rpc_branch_report`
- **THEN** `total_sales = 2000`
