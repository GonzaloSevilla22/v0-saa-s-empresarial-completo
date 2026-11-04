## ADDED Requirements

### Requirement: Las líneas de remito usan la definición única de normalización y participan de los guards de unidad
El sistema SHALL calcular con la definición única de normalización de cantidad, después de tomar la fila del producto con bloqueo, el delta de stock de toda línea de remito que se emite o se aplica en una edición. La anulación y la pata de reversa de una edición SHALL usar la cantidad base ya guardada en las líneas del remito (lo que efectivamente se descontó), nunca una reconversión de las líneas.

Las líneas de remito SHALL contarse entre las líneas que traban los cambios de unidad, igual que las de venta, compra, orden y presupuesto, en tres puntos:
- el guard de la unidad base efectiva de un producto: asignar una unidad base sobre historia en otra unidad;
- el guard de unidad en uso: factor, tipo o base de una unidad usada en alguna línea;
- la verificación equivalente del backend antes de asignar la unidad base.

Una unidad de la línea de remito SHALL ser del sistema o de la cuenta, y si no, se rechaza como inexistente (`P0404`).

#### Scenario: Remito en gramos sobre un producto en kilogramos
- **GIVEN** un producto con unidad base Kilogramo
- **WHEN** se emite un remito con una línea de `450` Gramo y después se lo edita a `900` Gramo
- **THEN** la emisión descuenta `0.45` y la edición registra una reversa de `+0.45` y una aplicación de `-0.9`

#### Scenario: Una línea de remito traba la asignación de la unidad base
- **GIVEN** un producto sin unidad base, con stock y una única línea de remito con unidad Unidad, emitida por la operación real del remito
- **WHEN** se le asigna la unidad base Kilogramo, por la API o por PostgREST
- **THEN** la operación falla con `P0409` y el token `base_unit_locked`, y el producto sigue sin unidad base
- **AND** asignarle Unidad se acepta

#### Scenario: Una unidad usada sólo en un remito no cambia de factor
- **GIVEN** una unidad de la cuenta usada únicamente en una línea de remito
- **WHEN** se intenta cambiar su factor
- **THEN** la operación falla con `P0409` y el token `unit_in_use`

#### Scenario: Las funciones del remito no conservan una conversión propia
- **WHEN** se inspeccionan las definiciones vivas de las funciones del remito que escriben stock
- **THEN** cada una invoca la definición única de normalización y ninguna contiene una multiplicación inline por el factor de la unidad
