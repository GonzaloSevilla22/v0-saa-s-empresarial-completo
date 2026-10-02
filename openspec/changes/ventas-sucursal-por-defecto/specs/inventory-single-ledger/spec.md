## ADDED Requirements

### Requirement: Única excepción auditada al carácter append-only: la sucursal nula de los movimientos de venta asignados

El ledger de stock SHALL seguir siendo append-only (RN-21) para toda escritura de la aplicación y de los usuarios: las políticas de `UPDATE` y `DELETE` siguen cerradas y las correcciones se expresan con movimientos nuevos.

Como única excepción, firmada por el PO (OQ-5 de `ventas-sucursal-por-defecto`), la migración de datos de ese change SHALL poder completar `branch_id` en los movimientos que cumplan **todas** estas condiciones: `type = 'sale'`, `reference_type = 'sale'`, `branch_id IS NULL`, y `reference_id` igual a una venta viva a la que esa misma migración asignó sucursal. El valor escrito SHALL ser la sucursal asignada a esa venta.

La excepción NO SHALL modificar ninguna otra columna del movimiento (cantidad, cantidades antes y después, costo congelado, tipo, referencias, grupo de operación, metadatos), NO SHALL eliminar movimientos, NO SHALL tocar movimientos que ya registran una sucursal ni los de ventas ya borradas, y NO SHALL alcanzar a otras migraciones o caminos de escritura. Cada movimiento modificado SHALL quedar listado por id en el registro de auditoría de esa migración, de modo que el cambio sea reversible fila por fila.

La excepción completa un dato que faltaba con el valor que el sistema ya usaba para esa venta (la sucursal de la que descontó el stock); no corrige un hecho registrado.

#### Scenario: Sólo se completa la sucursal nula
- **GIVEN** un movimiento `'sale'` con `branch_id` nulo de una venta viva a la que la migración asignó la sucursal A
- **WHEN** se aplica la migración de datos
- **THEN** el movimiento queda con `branch_id = A` y su cantidad, su costo congelado, su tipo y sus referencias no cambian

#### Scenario: Un movimiento que ya registra una sucursal no se modifica
- **GIVEN** un movimiento `'sale'` con `branch_id = X` de una venta con `branch_id` nulo
- **WHEN** se aplica la migración de datos
- **THEN** el movimiento conserva `branch_id = X`

#### Scenario: Los movimientos de una venta borrada no se tocan
- **GIVEN** un movimiento `'sale'` con `branch_id` nulo cuya venta ya fue borrada, y su contramovimiento también nulo
- **WHEN** se aplica la migración de datos
- **THEN** los dos movimientos conservan `branch_id` nulo

#### Scenario: Cada movimiento modificado queda en la auditoría
- **WHEN** la migración de datos completa la sucursal de movimientos de una cuenta
- **THEN** la fila de auditoría de esa cuenta lista los ids de esos movimientos
