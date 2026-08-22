## ADDED Requirements

### Requirement: El borrado consulta los mismos locks que la edición
El sistema SHALL evaluar en el borrado de una operación los mismos predicados de lock que ya gobiernan su edición — comprobante fiscal emitido y dinero posteado en los libros — y SHALL resolverlos de forma diferenciada: el lock fiscal bloquea el borrado, y el lock por dinero posteado lo habilita compensando los libros en lugar de impedirlo.

#### Scenario: Operación con comprobante fiscal
- **WHEN** se intenta borrar una operación con comprobante `pending_cae` o `authorized`
- **THEN** el sistema rechaza el borrado con `P0423`
- **AND** aplica exactamente el mismo predicado que bloquea la edición

#### Scenario: Operación con dinero posteado y sin comprobante
- **WHEN** se borra una operación bloqueada para edición por tener dinero posteado, pero sin comprobante fiscal
- **THEN** el borrado procede
- **AND** cada libro con movimientos de esa operación recibe su contra-movimiento

#### Scenario: Borrar y recrear como camino de corrección
- **WHEN** un usuario intenta editar una operación con dinero posteado, recibe el bloqueo, la borra y la vuelve a crear con los datos corregidos
- **THEN** los saldos de todos los libros reflejan únicamente la operación recreada
- **AND** no queda ningún cargo, movimiento ni asiento remanente de la operación borrada

### Requirement: Exposición del estado de borrabilidad en el listado
El sistema SHALL exponer al listado de operaciones, derivado de lectura y nunca desde una columna denormalizada, si una operación es borrable y qué razón la bloquea cuando no lo es.

#### Scenario: Operación facturada en el listado
- **WHEN** el listado incluye una operación con comprobante fiscal emitido
- **THEN** la operación se expone como no borrable
- **AND** la razón informada es el comprobante fiscal

#### Scenario: Operación borrable con compensación pendiente
- **WHEN** el listado incluye una operación con dinero posteado y sin comprobante
- **THEN** la operación se expone como borrable
- **AND** se exponen los libros que su borrado compensaría
