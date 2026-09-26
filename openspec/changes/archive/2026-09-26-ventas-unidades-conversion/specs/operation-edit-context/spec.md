# Spec Delta — operation-edit-context

## MODIFIED Requirements

### Requirement: La cantidad decimal atraviesa la ruta de edición igual que la de creación

La ruta de edición de operaciones SHALL aceptar cantidades fraccionarias con la misma precisión que la ruta de creación y que las columnas que las almacenan (`numeric(15,4)`). Ninguna capa del camino — deserialización del payload, parámetros de la RPC, esquemas Pydantic, formularios — SHALL degradar la cantidad a entero, ni por error ni por redondeo silencioso.

Una operación creada con cantidad decimal SHALL ser editable. Editar su cantidad a otro valor decimal SHALL producir el valor exacto en el header, en la línea y en el delta aplicado al stock.

La edición SHALL normalizar la cantidad por unidad exactamente igual que la creación, en sus **dos** patas: la reversa de la operación vieja SHALL devolver al stock la cantidad normalizada que esa operación descontó (la unidad de la línea vieja convertida a la base del producto), y la aplicación de la operación nueva SHALL descontar la cantidad normalizada de la línea nueva. Esto rige para la edición de ventas y para la edición de compras. Una línea nueva con unidad incompatible con el producto SHALL abortar la edición completa con `P0400`, dejando la operación vieja intacta.

#### Scenario: editar una venta creada con cantidad fraccionaria

- **GIVEN** una venta de 2,5 kg de un producto medible
- **WHEN** se edita la operación a 3,25 kg
- **THEN** la edición se completa sin error
- **AND** el header y la línea quedan con `quantity = 3.25`
- **AND** el stock refleja el delta exacto `+2.5 - 3.25`, sin truncamiento

#### Scenario: la cantidad decimal no se redondea al editar

- **WHEN** se edita una operación con una cantidad de tres decimales
- **THEN** el valor persistido conserva los tres decimales, sin redondeo a entero

#### Scenario: editar una venta hecha en gramos revierte y reaplica en kilos

- **GIVEN** un producto con unidad base Kilogramo, stock `1`, y una venta de `450` con unidad Gramo (stock tras la venta: `0.55`)
- **WHEN** se edita la operación a `300` con unidad Gramo
- **THEN** la pata de reversa registra `quantity_delta = +0.45` y la de aplicación `quantity_delta = -0.3`
- **AND** el stock queda en `0.7`, nunca en `450.55` ni en `-299.45`

#### Scenario: editar una compra en gramos revierte y reaplica en kilos

- **GIVEN** un producto con unidad base Kilogramo y una compra de `2000` con unidad Gramo
- **WHEN** se edita la compra a `1500` con unidad Gramo
- **THEN** la reversa registra `quantity_delta = -2` y la aplicación `quantity_delta = +1.5`, y el stock refleja `-2 + 1.5` respecto del estado previo

#### Scenario: la edición rechaza una unidad incompatible sin tocar la operación vieja

- **GIVEN** una venta vigente de `0.5` con unidad Kilogramo sobre un producto en kilogramos
- **WHEN** se intenta editarla reemplazando la línea por una con unidad Litro
- **THEN** la edición falla con `P0400`, la venta vieja y su movimiento de stock permanecen sin cambios y no se registra ninguna pata de reversa
