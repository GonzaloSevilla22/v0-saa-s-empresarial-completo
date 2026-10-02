## ADDED Requirements

### Requirement: Única excepción auditada al carácter append-only: la sucursal nula de los movimientos de venta de origen demostrable

El ledger de stock SHALL seguir siendo append-only (RN-21) para toda escritura de la aplicación y de los usuarios: las políticas de `UPDATE` y `DELETE` siguen cerradas y las correcciones se expresan con movimientos nuevos.

Como única excepción, firmada por el PO (OQ-5 de `ventas-sucursal-por-defecto`), la migración de datos de ese change SHALL poder completar `branch_id` en los movimientos que cumplan **todas** estas condiciones:

- `type = 'sale'`, `reference_type = 'sale'` y `branch_id IS NULL`;
- `reference_id` igual a una venta viva a la que esa misma migración asignó sucursal;
- **origen demostrable**: cuando se registró el movimiento (`stock_movements.created_at`), la sucursal asignada a la venta ya existía y era la única sucursal de la cuenta (ninguna otra sucursal de la cuenta tiene `created_at` menor o igual al del movimiento).

El valor escrito SHALL ser la sucursal asignada a esa venta.

La condición de origen demostrable existe porque el stock de una venta sin sucursal salió de la sucursal principal **del momento de la venta**, mientras que la migración asigna, en general, la principal vigente al aplicarla, o la sucursal de la operación, de la factura o de la orden. Cuando esas sucursales difieren, completar el movimiento registraría una salida de stock desde una sucursal de la que no salió, y el borrado posterior de la venta repondría el stock en el lugar equivocado. Eso rompe el «Invariante de reconstrucción y de no-orfandad del ledger de operaciones» por `(product_id, branch_id)`. Si la sucursal asignada era la única de la cuenta cuando se registró el movimiento, la resolución de la principal no pudo devolver otra, así que es la sucursal de la que salió el stock. Los movimientos que no cumplen esa condición SHALL conservar `branch_id` nulo, y la migración SHALL contarlos.

La excepción NO SHALL modificar ninguna otra columna del movimiento (cantidad, cantidades antes y después, costo congelado, tipo, referencias, grupo de operación, metadatos). Tampoco SHALL eliminar movimientos, ni tocar movimientos que ya registran una sucursal o los de ventas ya borradas, ni alcanzar a otras migraciones o caminos de escritura. Cada movimiento modificado SHALL quedar listado por id en el registro de auditoría de esa migración, de modo que el cambio sea reversible fila por fila.

La excepción completa un dato que faltaba sólo cuando se puede demostrar su valor; no corrige ni reinterpreta un hecho registrado.

#### Scenario: Se completa la sucursal nula de un movimiento de origen demostrable
- **GIVEN** un movimiento `'sale'` con `branch_id` nulo de una venta viva a la que la migración asignó la sucursal A, en una cuenta cuya única sucursal cuando se registró el movimiento era A
- **WHEN** se aplica la migración de datos
- **THEN** el movimiento queda con `branch_id = A` y su cantidad, su costo congelado, su tipo y sus referencias no cambian

#### Scenario: Un movimiento de origen incierto conserva la sucursal nula
- **GIVEN** un movimiento `'sale'` con `branch_id` nulo de una venta viva a la que la migración asignó la sucursal A, en una cuenta que, cuando se registró el movimiento, ya tenía otra sucursal además de A
- **WHEN** se aplica la migración de datos
- **THEN** el movimiento conserva `branch_id` nulo y la migración lo cuenta como de origen incierto

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
