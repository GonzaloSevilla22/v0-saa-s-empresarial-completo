## MODIFIED Requirements

### Requirement: Margen por producto sólo donde hay costo, con su cobertura declarada

El ranking SHALL informar el margen del producto en el período cuando el costo sea derivable, usando la cascada canónica de costo: el costo congelado en la línea de venta, con fallback al costo del catálogo únicamente cuando la línea no tiene snapshot.

Un grupo sin **ningún** costo resoluble SHALL informar el margen como ausente y la superficie SHALL mostrarlo como tal — NUNCA como cero, y nunca con un valor derivado de un costo inventado. Este estado es alcanzable: el costo del catálogo es un dato **opcional** (capability `product-cost`), de modo que la cascada puede no resolver en ninguno de sus dos peldaños.

Un grupo con cobertura **parcial** de costo SHALL informar además qué proporción de sus líneas tiene costo, y la superficie SHALL mostrarlo: un grupo con cobertura baja exhibe un margen aparentemente alto y sería indistinguible de uno medido sobre todas sus líneas.

La cobertura de costo SHALL medir la proporción de líneas con **costo resoluble** por la cascada canónica, NO la proporción de líneas con snapshot presente. Las dos preguntas difieren en las dos direcciones y ambas mienten: una línea sin snapshot pero con costo de catálogo real tiene su margen perfectamente medido y contaría como no cubierta, mientras que una línea con snapshot cero contaría como cubierta aportando un margen del 100 % artificial.

Cuando el ranking se ordena por margen, los grupos con margen ausente SHALL quedar al final del orden y NOT SHALL encabezarlo: un producto sin costo documentado no es el más rentable del catálogo.

#### Scenario: Producto sin costo muestra margen ausente

- **GIVEN** un producto cuyas líneas de venta no tienen costo congelado ni costo de catálogo
- **WHEN** se consulta el ranking
- **THEN** su margen se informa como ausente y la superficie lo muestra como tal, no como cero

#### Scenario: El margen usa el costo congelado, no el actual

- **GIVEN** un producto vendido con costo congelado en la línea, cuyo costo de catálogo cambió después
- **WHEN** se consulta el ranking del período que contiene esa venta
- **THEN** el margen se calcula con el costo congelado

#### Scenario: Cobertura parcial declarada

- **GIVEN** un grupo donde sólo parte de sus líneas tienen costo
- **WHEN** se consulta el ranking
- **THEN** la fila informa su proporción de cobertura de costo y la superficie la muestra junto al margen

#### Scenario: Una línea sin snapshot pero con costo de catálogo cuenta como cubierta

- **GIVEN** un producto con una única línea de venta sin snapshot de costo, cuyo producto sí tiene costo en el catálogo
- **WHEN** se consulta el ranking
- **THEN** la cobertura de costo de ese grupo es del 100 %, porque su costo es resoluble
- **AND** su margen se informa con el costo del catálogo

#### Scenario: El producto sin costo no encabeza el ranking por margen

- **GIVEN** un ranking ordenado por margen con productos medidos y un producto sin costo alguno
- **WHEN** se consulta el ranking
- **THEN** el producto sin costo aparece al final del orden, no en la primera posición
