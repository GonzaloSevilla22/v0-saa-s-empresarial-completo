## ADDED Requirements

### Requirement: La reversión de un cargo lleva la referencia del cargo que revierte y sirve también a la edición
El sistema SHALL usar la contraparte de reversión del helper compartido de cargo tanto para el borrado como para la edición de una venta o una compra, y la reversión SHALL registrarse con **la misma referencia** que la huella de cargo que revierte, de modo que la derivación del aging pueda emparejarla con su propio cargo. Ningún camino de edición SHALL reimplementar la reversión ni el cargo inline: los dos pasos SHALL resolverse por los helpers compartidos existentes.

El helper de reversión SHALL seguir traduciendo el rechazo por saldo negativo del ledger al código `P0425` y emitiendo su evento de reversión de cargo.

#### Scenario: La edición revierte con el helper compartido
- **WHEN** la edición de una venta a crédito cambia su importe
- **THEN** la reversión del cargo anterior se resuelve por el helper compartido de reversión y el cargo nuevo por el helper compartido de cargo, sin lógica de cuenta corriente propia de la RPC de edición

#### Scenario: La reversión de una venta del POS lleva la referencia de su orden
- **GIVEN** una venta del POS a crédito cuyo cargo referencia el identificador de su orden
- **WHEN** se edita su importe o se la borra
- **THEN** la reversión referencia el mismo identificador de orden que el cargo
