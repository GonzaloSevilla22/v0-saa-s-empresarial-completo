# Spec Delta — units-of-measure

## MODIFIED Requirements

### Requirement: El factor de conversión es relativo a la unidad base del mismo tipo

El sistema SHALL interpretar `factor` como el múltiplo de la unidad base del **mismo** `type` (referenciada por `base_unit_id`). La conversión entre unidades SHALL operar únicamente entre unidades que comparten `type`; convertir entre tipos distintos (p. ej. peso ↔ volumen) NO está definido y el sistema SHALL rechazarlo con un error explícito en lugar de producir un resultado silencioso.

La conversión vigente SHALL ser relativa a la **unidad base del producto** cuyo stock se mueve, no a la unidad base del tipo: la cantidad normalizada es `cantidad × factor(unidad de la línea) ÷ factor(unidad base del producto)`, redondeada a la precisión de las columnas de stock (`numeric(15,4)`). Cuando la unidad de la línea es la misma que la base del producto, la cantidad normalizada SHALL ser idéntica a la cantidad de la línea.

#### Scenario: Conversión solo dentro del mismo tipo

- **WHEN** una normalización recibe una unidad de línea cuyo `type` difiere del `type` de la unidad base del producto (p. ej. línea en mililitros sobre un producto llevado en kilogramos)
- **THEN** el sistema rechaza la operación con error de validación (`P0400`, token `unit_type_mismatch`) y no escribe ninguna fila ni mueve stock

#### Scenario: Factor relativo a la base

- **WHEN** una unidad no base declara `base_unit_id` y `factor`
- **THEN** `factor` expresa cuántas unidades base equivalen a una de esta unidad, y ambas comparten `type`

#### Scenario: Conversión relativa a la base del producto, no del tipo

- **GIVEN** un producto cuya unidad base es Gramo (factor `0.001` respecto de Kilogramo)
- **WHEN** una línea vende `0.5` con unidad Kilogramo
- **THEN** la cantidad normalizada es `500` (en gramos, la unidad en que se lleva el stock de ese producto)

#### Scenario: Misma unidad que la base no altera la cantidad

- **GIVEN** un producto cuya unidad base es Kilogramo
- **WHEN** una línea vende `0.45` con unidad Kilogramo
- **THEN** la cantidad normalizada es exactamente `0.45`

## ADDED Requirements

### Requirement: Una sola definición de normalización de cantidad para todo camino que escriba stock

El sistema SHALL exponer una única definición, en la capa de base de datos, de "cantidad de una línea expresada en la unidad en que se lleva el stock del producto". Todo camino que descuente o reponga stock a partir de una línea de operación —alta de venta desde el formulario (en sus dos ramas: la vigente y la legacy del kill-switch `sale_items_rpc_v2`), confirmación de orden desde el POS, edición de venta, alta de compra y edición de compra— SHALL obtener el delta de stock de esa definición y NO SHALL reimplementar la conversión en su propio cuerpo.

La unidad base contra la cual se convierte SHALL ser la **efectiva** del producto: la propia o, para una variante que no declara una, la de su padre. La unidad de la línea SHALL ser del sistema o de la cuenta del producto; una unidad ajena SHALL rechazarse como inexistente (`P0404`), sin revelar si existe en otra cuenta.

La definición SHALL resolver los cuatro casos de entrada de la misma manera en todos los caminos:

- línea sin unidad: la cantidad se normaliza con factor 1;
- producto con unidad base y línea con unidad del mismo tipo: conversión relativa a la base del producto;
- producto con unidad base y línea con unidad de otro tipo: rechazo (`P0400`, `unit_type_mismatch`);
- producto **sin** unidad base y línea con una unidad que no es base de su tipo (factor distinto de 1): rechazo (`P0400`, `unit_requires_base_unit`), porque sin unidad base no existe referencia contra la cual convertir.

La definición NO SHALL ser invocable directamente por los roles de aplicación (`anon`, `authenticated`); sólo la consumen las funciones que ya validaron al usuario.

#### Scenario: Los cinco caminos descuentan lo mismo para la misma línea

- **GIVEN** un producto con unidad base Kilogramo y stock `1` en la sucursal de la operación
- **WHEN** se registra una línea de `450` con unidad Gramo por cualquiera de los caminos (formulario de venta, POS, edición de venta que reemplaza la línea, alta de compra o edición de compra)
- **THEN** el delta aplicado al stock es exactamente `0.45` en valor absoluto en todos ellos (negativo en venta, positivo en compra), y el stock queda en `0.55` tras una venta

#### Scenario: El POS deja de descontar la cantidad cruda

- **GIVEN** un producto con unidad base Kilogramo y stock `1`
- **WHEN** se confirma desde el POS una orden con una línea de `450` con unidad Gramo
- **THEN** la confirmación completa, el stock queda en `0.55` y el movimiento de stock registra `quantity_delta = -0.45`
- **AND** la confirmación NO falla por stock insuficiente ni descuenta `450`

#### Scenario: Producto sin unidad base sólo admite unidades base

- **GIVEN** un producto sin unidad base
- **WHEN** se registra una línea con unidad Mililitro (factor `0.001`)
- **THEN** el sistema rechaza con `P0400` y token `unit_requires_base_unit`, sin escribir la línea ni mover stock
- **AND** la misma línea con unidad Kilogramo o Litro (factor 1) se acepta y descuenta la cantidad tal cual

#### Scenario: Tipo cruzado rechazado en todos los caminos

- **GIVEN** un producto con unidad base Kilogramo
- **WHEN** se intenta registrar una línea con unidad Litro por cualquiera de los cinco caminos
- **THEN** cada camino rechaza con `P0400` y token `unit_type_mismatch` y la transacción no deja ningún rastro parcial

#### Scenario: Una variante hereda la unidad base de su padre

- **GIVEN** un producto padre con unidad base Kilogramo y una variante que no declara unidad base
- **WHEN** se registra una línea de `450` con unidad Gramo sobre la variante
- **THEN** el delta de stock de la variante es `0.45` (la base efectiva es la del padre)
- **AND** una línea con unidad Litro sobre la misma variante se rechaza con `P0400` y token `unit_type_mismatch`
- **AND** `v_products_with_stock.base_unit_id` expone para la variante la unidad base del padre

#### Scenario: Una unidad de otra cuenta se rechaza como inexistente

- **GIVEN** una unidad que no es del sistema ni pertenece a la cuenta del producto
- **WHEN** se intenta normalizar una línea con esa unidad
- **THEN** el sistema rechaza con `P0404` sin escribir la línea ni mover stock

#### Scenario: Las funciones que escriben stock no conservan una conversión propia

- **WHEN** se inspeccionan las definiciones vivas de las funciones que escriben stock desde una operación
- **THEN** cada una invoca la definición única y ninguna contiene una multiplicación inline por el factor de la unidad

### Requirement: El selector de unidad sólo ofrece unidades compatibles con el producto

Toda superficie que permita elegir la unidad de una línea de operación —POS, formulario de venta y formulario de compra— SHALL ofrecer únicamente las unidades que la definición de normalización aceptaría para ese producto: con unidad base, las unidades del mismo `type` (la base incluida y preseleccionada); sin unidad base, sólo las unidades base de cada tipo (factor 1). Las opciones SHALL recalcularse al cambiar de producto, y una unidad previamente elegida que deje de ser compatible SHALL reemplazarse por la base del producto (o por "sin unidad") en lugar de quedar seleccionada de forma invisible.

La regla de compatibilidad SHALL vivir en una única función de la capa canónica del frontend y ser la misma en las tres superficies.

#### Scenario: Producto en kilogramos ofrece sólo unidades de peso

- **GIVEN** un producto con unidad base Kilogramo
- **WHEN** se lo selecciona en el POS, en el formulario de venta o en el de compra
- **THEN** el selector ofrece Kilogramo (preseleccionado), Gramo y Tonelada, y no ofrece Mililitro, Litro, Metro, Centímetro, Unidad ni Docena

#### Scenario: Producto sin unidad base ofrece sólo unidades base

- **GIVEN** un producto sin unidad base
- **WHEN** se lo selecciona en cualquiera de las tres superficies
- **THEN** el selector ofrece "sin unidad" más Unidad, Kilogramo, Litro y Metro, y no ofrece Gramo, Mililitro, Centímetro, Tonelada, Docena ni Caja x 6

#### Scenario: Cambiar de producto invalida la unidad incompatible

- **GIVEN** una línea en preparación con unidad Gramo sobre un producto en kilogramos
- **WHEN** el usuario cambia el producto a uno llevado en litros
- **THEN** la unidad seleccionada pasa a Litro y la cantidad se reinicia al mínimo de esa unidad

### Requirement: Toda cantidad de stock o de línea se muestra con el símbolo de su unidad

El sistema SHALL mostrar cada cantidad de stock y cada cantidad de línea acompañada del símbolo de la unidad en que está expresada, usando el mismo formateador en todas las superficies: el listado de stock y sus filas expandidas, el historial de movimientos de stock, el ticket o comprobante de venta y sus variantes de texto. El símbolo SHALL ser el de la unidad base del producto para cantidades de stock y el de la unidad de la línea para cantidades vendidas o compradas. Un producto sin unidad base SHALL mostrarse con el símbolo genérico de unidades. Las cantidades enteras SHALL mostrarse sin decimales y las fraccionarias con tres decimales, sin truncar.

#### Scenario: El listado de stock muestra kilos como kilos

- **GIVEN** un producto con unidad base Kilogramo y stock `0.55`
- **WHEN** se lo ve en el listado de stock
- **THEN** la cantidad se muestra como `0.550 kg`, tanto en la columna de stock como en la fila expandida con el mínimo (`0.550 / 0.500 kg`), y nunca como `0.55 uds`

#### Scenario: El historial de movimientos lleva la unidad

- **GIVEN** un movimiento de venta de `-0.45` sobre un producto en kilogramos, con antes `1` y después `0.55`
- **WHEN** se lo ve en el historial de movimientos
- **THEN** el delta y el antes/después se muestran como `-0.450 kg` y `1 kg → 0.550 kg`

#### Scenario: El ticket lleva la unidad de la línea

- **GIVEN** una venta con una línea de `450` con unidad Gramo
- **WHEN** se genera el comprobante imprimible, el texto para copiar o el mensaje de WhatsApp
- **THEN** la cantidad aparece como `450 g` en los tres formatos

#### Scenario: Los productos por unidad no cambian de aspecto

- **GIVEN** un producto sin unidad base con stock `12`
- **WHEN** se lo ve en el listado de stock o en un ticket
- **THEN** la cantidad se muestra como `12 uds` (listado) y `12` con el símbolo genérico (ticket), sin decimales

### Requirement: El precio de una línea es por unidad de la línea y se guarda sin redondear

*(D12 / contrato D-F, y D-F′ de la tercera revisión — provisorio, pendiente del sign-off del PO: es dinero.)* El `amount` / `price` de toda línea de venta, compra, orden o presupuesto SHALL expresarse por unidad **de la línea** (la unidad elegida por el usuario), de modo que el importe de la línea sea `precio × cantidad` en la unidad de la línea, igual que en todas las operaciones históricas. El precio del catálogo SHALL entenderse en la unidad base del producto; al elegir otra unidad, el frontend SHALL re-expresarlo con el mismo factor que la normalización de cantidad (`precio(línea) × cantidad(línea) = precio(base) × cantidad(base)`), en el POS, en el formulario de venta y en el de compra.

El precio por unidad de la línea NO SHALL redondearse a un número fijo de decimales en ninguna capa: las columnas de precio de toda línea de documento (`sales.amount`, `sale_items.price`, `sales_order_items.price`, `quote_items.price`, `purchases.amount`, `purchase_items.price`) SHALL ser `numeric` sin escala, y el frontend SHALL limitarse a limpiar el ruido binario del cálculo (15 dígitos significativos). Los importes de dinero que se cobran o se postean (subtotal de la orden, total de la orden, caja, banco, cuenta corriente) SHALL seguir expresados al centavo. Editar una operación sin cambiar sus líneas NO SHALL cambiar su importe.

#### Scenario: 100 g de un producto a $1.800/kg cobran $180

- **GIVEN** un producto con unidad base Kilogramo y precio de catálogo `1800`
- **WHEN** se registra por el formulario de venta una línea de `100` con unidad Gramo
- **THEN** el precio de la línea es `1.8`, el total de la línea es `180` y el stock baja `0.1`

#### Scenario: Una docena se cobra como docena

- **GIVEN** un producto con unidad base Unidad y precio de catálogo `100`
- **WHEN** se vende desde el POS `1` con unidad Docena
- **THEN** el total de la línea es `1200` y el stock baja `12`

#### Scenario: El POS guarda el precio por gramo sin redondear y el total es exacto

- **GIVEN** un producto con unidad base Kilogramo y precio de catálogo `4575`
- **WHEN** se vende desde el POS `100` con unidad Gramo al precio re-expresado `4.575`
- **THEN** `sales.amount`, `sale_items.price` y `sales_order_items.price` valen `4.575` (no `4.58`), `sales.total` es `457.50` y `amount × quantity = total`

#### Scenario: Editar sin cambios no re-precia la venta

- **GIVEN** una venta del POS de `450` con unidad Gramo a `4.575` por gramo, con total `2058.75`
- **WHEN** se edita la operación reenviando la misma línea (precio rehidratado desde `sales.amount`)
- **THEN** el total sigue en `2058.75` (antes quedaba en `2061` por el precio redondeado a `4.58`) y la orden re-sincronizada conserva precio `4.575` y subtotal `2058.75`

#### Scenario: Un precio con más decimales se conserva y el cobro va al centavo

- **GIVEN** un producto con unidad base Kilogramo y precio de catálogo `1234.56`
- **WHEN** se venden desde el POS `450` con unidad Gramo
- **THEN** el precio de la línea es `1.23456` (no `1.2346`), el subtotal del cliente es `555.552` y el total cobrado es `555.55`, con `|amount × quantity − total| < 0.005`

#### Scenario: El formulario de venta, la compra y sus ediciones dan el mismo total

- **GIVEN** un producto con unidad base Kilogramo
- **WHEN** se registra `100` con unidad Gramo a `4.575` por el formulario de venta y, aparte, por el alta de compra, y cada operación se edita sin cambios
- **THEN** los cuatro totales son `457.50`

### Requirement: La unidad base efectiva de un producto no cambia debajo de su stock

*(D11 / decisión D-C, provisoria hasta el sign-off del PO.)* La base de datos SHALL rechazar, para cualquier escritor (API, PostgREST o una función futura), todo cambio que altere la unidad base **efectiva** de un producto (la propia o, para una variante que no declara una, la de su padre) si el producto afectado tiene stock distinto de `0` en alguna sucursal o algún movimiento de stock: `P0409` con token `base_unit_locked`. Esto incluye cambiar o quitar `base_unit_id`, y re-parentar o desenganchar una variante que hereda la unidad. Asignar una unidad base a un producto que no tenía unidad efectiva SHALL permitirse aunque tenga stock. La unidad base SHALL ser del sistema o de la cuenta del producto (`P0404`, `base_unit_not_found`).

La carrera entre un cambio de unidad base y una venta o compra concurrente del mismo producto SHALL resolverse sin escribir stock en la unidad vieja: las funciones que escriben stock SHALL normalizar la cantidad recién después de tomar la fila del producto con bloqueo, y el guard de la unidad base SHALL tomar las variantes que heredan con bloqueo.

#### Scenario: Cambiar la unidad base de un producto con stock se rechaza

- **GIVEN** un producto con unidad base Kilogramo, stock `10` y movimientos
- **WHEN** se intenta cambiar su unidad base a Gramo, o quitarla, por la API o con un `PATCH` de PostgREST como `authenticated`
- **THEN** la operación falla con `P0409` y token `base_unit_locked`, y la unidad base sigue siendo Kilogramo

#### Scenario: Asignar la unidad a un producto que no tenía se permite

- **GIVEN** un producto sin unidad base con stock `10`
- **WHEN** se le asigna Kilogramo
- **THEN** el cambio se acepta y el stock pasa a leerse en kilogramos

#### Scenario: Re-parentar una variante que hereda con stock se rechaza

- **GIVEN** una variante sin unidad base propia, hija de un padre en Kilogramo, con stock `5`
- **WHEN** se la re-parenta a un padre en Unidad, o se la desengancha (`parent_id = NULL`)
- **THEN** la operación falla con `P0409` y token `base_unit_locked`
- **AND** re-parentarla a otro padre en Kilogramo se permite, igual que re-parentar una variante con unidad base propia

#### Scenario: Cambio de unidad base concurrente con una compra

- **GIVEN** un producto con unidad base Kilogramo, sin stock ni movimientos
- **WHEN** una sesión cambia su unidad base a Unidad y, antes de que commitee, otra sesión registra una compra de `2000` con unidad Gramo
- **THEN** la compra espera la fila del producto y termina con `P0400` (`unit_type_mismatch`), sin stock, movimiento ni fila de compra
- **AND** en el orden inverso (compra abierta, cambio después) el cambio de unidad espera y termina con `P0409`
