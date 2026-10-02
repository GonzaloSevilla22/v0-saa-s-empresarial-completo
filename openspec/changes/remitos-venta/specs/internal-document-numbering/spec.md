## ADDED Requirements

### Requirement: Numeración del remito de venta por cuenta y por sentido
El sistema SHALL numerar los remitos de venta con el tipo de secuencia interna `delivery_note_sale`, que se suma de forma aditiva al conjunto cerrado de tipos. Su prefijo visible es `R` (`R-00000012`), y la numeración es correlativa por cuenta, sin huecos ni repetidos e independiente de la de presupuestos.

El número SHALL asignarlo la función genérica de numeración, enganchada a la tabla de remitos con un disparador condicionado al sentido `sale`. Así, cada sentido de remito numera con su propia secuencia sin copiar la lógica de asignación.

La unicidad del número SHALL ser por cuenta y sentido, porque la misma tabla aloja los dos sentidos. El remito de compra SHALL sumar su propio tipo y su propio disparador condicionado, sin cambiar los del remito de venta.

#### Scenario: Primer remito de una cuenta
- **GIVEN** una cuenta con presupuestos numerados hasta `P-00000007` y sin remitos
- **WHEN** emite su primer remito de venta
- **THEN** el remito recibe el número 1, que se muestra `R-00000001`, y la secuencia de presupuestos no cambia

#### Scenario: Remito fallido no consume número
- **GIVEN** una cuenta cuyo último remito es el 4
- **WHEN** falla la emisión de un remito por stock insuficiente y luego se emite otro con éxito
- **THEN** el remito emitido recibe el número 5

#### Scenario: Disparador genérico condicionado al sentido
- **WHEN** se inspeccionan los disparadores de la tabla de remitos
- **THEN** la numeración de los remitos de venta la asigna la función genérica con el tipo `delivery_note_sale` como argumento, sólo para filas de sentido `sale`

#### Scenario: Formato compartido
- **WHEN** backend y frontend formatean el número 12 de un remito de venta con los casos del archivo compartido
- **THEN** los dos producen `R-00000012`, y la búsqueda acepta `R-12`, `12` y `00000012`
