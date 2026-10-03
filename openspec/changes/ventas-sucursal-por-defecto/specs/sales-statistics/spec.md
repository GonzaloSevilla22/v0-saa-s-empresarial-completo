## MODIFIED Requirements

### Requirement: Desglose por canal y por sucursal con tramo explícito para lo no imputado

El sistema SHALL exponer la facturación, las unidades y las operaciones del período desglosadas **por canal de venta** y **por sucursal**.

Las ventas sin canal o sin sucursal SHALL aparecer como un tramo propio y visible ("Sin canal" / "Sin sucursal"), NUNCA omitidas del resultado: omitirlas haría que el desglose informe menos facturación que el total del período. La suma de los tramos SHALL ser igual al total del período. Las ventas sin canal siguen siendo una parte grande de las operaciones en producción; las ventas sin sucursal, en cambio, quedan reducidas al residuo que no pudo asignar `ventas-sucursal-por-defecto` (toda venta nueva o editada queda en una sucursal), y el tramo "Sin sucursal" se conserva para ese residuo.

#### Scenario: Las ventas sin canal aparecen en su propio tramo

- **GIVEN** un período con ventas con canal y ventas sin canal
- **WHEN** se consulta el desglose por canal
- **THEN** existe un tramo explícito para las ventas sin canal con su importe
- **AND** la suma de todos los tramos es igual a la facturación total del período

#### Scenario: Las ventas sin sucursal aparecen en su propio tramo

- **GIVEN** un período con ventas sin sucursal asignada
- **WHEN** se consulta el desglose por sucursal
- **THEN** existe un tramo explícito para las ventas sin sucursal con su importe

#### Scenario: El desglose no resta notas de crédito y lo declara

- **GIVEN** un período con una nota de crédito
- **WHEN** se consulta el desglose por canal o por sucursal
- **THEN** la nota de crédito no se resta de ningún tramo
- **AND** la superficie que lo muestra declara esa exclusión al usuario
