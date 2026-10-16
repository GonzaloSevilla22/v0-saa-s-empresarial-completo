## ADDED Requirements

### Requirement: Numeración del remito de compra por cuenta y por sentido
El sistema SHALL numerar los remitos de compra con el tipo de secuencia interna `delivery_note_purchase`, correlativo por cuenta desde 1, asignado por el disparador genérico de numeración sólo para las filas con sentido compra, con las mismas garantías que los demás tipos (sin huecos, sin repetidos, un alta revertida no consume número). SHALL mostrarse con el prefijo `RC` y 8 dígitos (`RC-00000012`) en la única definición de formato de cada lenguaje, ningún remito de compra SHALL mostrarse con el prefijo `R` de los remitos de venta, y la búsqueda del listado de remitos de compra SHALL aceptar `RC-12`, `12` o `00000012`.

#### Scenario: Secuencias independientes por sentido
- **GIVEN** una cuenta con 3 remitos de venta y ningún remito de compra
- **WHEN** emite su primer remito de compra
- **THEN** recibe el número `1`, se muestra como `RC-00000001` y el próximo remito de venta sigue con el `4`

#### Scenario: Alta revertida no consume número
- **WHEN** la emisión de un remito de compra falla por un producto dado de baja
- **THEN** el próximo remito de compra de la cuenta recibe el número que habría recibido el fallido
