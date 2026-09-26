# Spec Delta — branch-stock

## ADDED Requirements

### Requirement: El umbral de stock mínimo admite fracciones en la unidad base del producto

`branch_stock.min_stock` SHALL tener la misma precisión que `branch_stock.quantity` (`numeric(15,4)`) y expresarse en la unidad base del producto. La propagación del mínimo desde el producto a todas sus sucursales, el trigger de alerta de stock bajo y el cálculo canónico de stock crítico SHALL evaluar el umbral sin truncarlo a entero. El backend SHALL aceptar un mínimo fraccionario no negativo en el alta y la edición del producto y SHALL rechazar un mínimo negativo con error de validación. Para productos llevados por unidad el comportamiento SHALL ser indistinguible del vigente: un mínimo entero sigue siendo entero.

#### Scenario: un mínimo de medio kilo dispara la alerta

- **GIVEN** un producto con unidad base Kilogramo, `branch_stock.quantity = 0.6` y el owner edita "Stock Mínimo" a `0.5`
- **WHEN** una venta reduce la cantidad a `0.45`
- **THEN** `branch_stock.min_stock` es `0.5` en todas las sucursales del producto y se inserta la alerta `low_branch_stock_alert` para esa sucursal

#### Scenario: el mínimo fraccionario no se redondea en ninguna capa

- **WHEN** se guarda un producto con mínimo `0.5` desde el formulario
- **THEN** la respuesta de la API y el listado de stock devuelven `0.5`, no `0` ni `1`

#### Scenario: el mínimo negativo se rechaza

- **WHEN** se intenta guardar un producto con mínimo `-1`
- **THEN** la API responde con error de validación y ninguna fila de `branch_stock` cambia

#### Scenario: el mínimo entero de un producto por unidad no cambia

- **GIVEN** un producto sin unidad base con mínimo `5`
- **WHEN** corre la migración y luego se vuelve a propagar el mínimo
- **THEN** `branch_stock.min_stock` sigue siendo `5` y la alerta se comporta igual que antes
