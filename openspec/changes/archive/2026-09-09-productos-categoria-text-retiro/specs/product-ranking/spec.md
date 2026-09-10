## ADDED Requirements

### Requirement: La categoría que informa el ranking se deriva del catálogo

El ranking de productos y el detalle de evolución por producto SHALL informar el nombre de la categoría derivándolo del catálogo (`product_categories`) a partir de la categoría imputada al producto, y NOT SHALL leerlo de una copia desnormalizada guardada en el producto. En consecuencia, el nombre que informan SHALL ser siempre el vigente: renombrar una categoría SHALL reflejarse de inmediato en el ranking, en el detalle y en la exportación del ranking, sin partir el histórico ni reprocesar dato alguno.

La resolución del nombre NOT SHALL excluir del ranking a un producto cuya categoría no pueda resolverse: un producto sin categoría imputada SHALL competir en el ranking igual que los demás, con su categoría vacía.

Esta regla NOT SHALL alterar la forma de salida del ranking ni del detalle: el nombre del campo, su tipo y su posición se conservan, de modo que la pantalla y la exportación no cambien.

#### Scenario: El ranking sigue el renombre de una categoría

- **GIVEN** un ranking donde un producto figura con la categoría "Ropa"
- **WHEN** un `owner` renombra esa categoría a "Indumentaria"
- **THEN** el ranking, el detalle por producto y la exportación del ranking informan "Indumentaria"

#### Scenario: Un producto sin categoría compite igual

- **GIVEN** un producto vendido en el período y sin categoría imputada
- **WHEN** se consulta el ranking
- **THEN** el producto aparece en el ranking con su categoría vacía

#### Scenario: La forma de salida no cambia

- **WHEN** se consulta el ranking o el detalle por producto tras el cambio de origen de la categoría
- **THEN** la salida conserva el mismo campo de categoría, con el mismo tipo, y la exportación del ranking conserva su columna sin cambios
