## MODIFIED Requirements

### Requirement: Read-model de distribución por forma de pago

El sistema SHALL exponer `rpc_payment_method_report(p_account_id, p_start, p_end)` que agregue, por forma de pago y para el rango pedido, el total vendido, el total comprado y el **total gastado**, con una fila propia para las operaciones sin imputar ("Sin especificar"). El RPC SHALL ser `SECURITY DEFINER` con `search_path` fijo y SHALL verificar la membresía del caller sobre `p_account_id` (P0401), espejando `rpc_cost_center_report`. SHALL cumplir los invariantes RN-D: importe de línea con `COALESCE(total, amount)`, conteo de operaciones con `COUNT(DISTINCT COALESCE(operation_id, id))`, bordes `date >= p_start AND date < (p_end + 1)`, y todo importe de salida `NUMERIC`. Los gastos SHALL sumarse por `amount` y SHALL contarse una unidad por fila de gasto, con el mismo criterio con que `rpc_cost_center_report` ya los agrega. **Excepción documentada a RN-D1**: el reporte NO SHALL restar notas de crédito, porque una NC no tiene forma de pago atribuible; la excepción SHALL estar visible en la propia pantalla del reporte, igual que la ya documentada para el margen por canal.

#### Scenario: Agregación por forma de pago

- **GIVEN** en el rango: dos ventas en "Efectivo" por $10.000 y $5.000, una en "Transferencia bancaria" por $20.000 y una compra en "Efectivo" por $3.000
- **WHEN** se ejecuta el reporte sobre ese rango
- **THEN** "Efectivo" muestra $15.000 vendidos y $3.000 comprados, y "Transferencia bancaria" $20.000 vendidos

#### Scenario: Los gastos participan de la agregación

- **GIVEN** en el rango: un gasto de $4.000 imputado a "Efectivo" y otro de $6.000 imputado a "Transferencia bancaria"
- **WHEN** se ejecuta el reporte sobre ese rango
- **THEN** "Efectivo" muestra $4.000 gastados y "Transferencia bancaria" $6.000 gastados
- **AND** los importes de gasto no se mezclan con los de compra

#### Scenario: Operaciones sin imputar

- **GIVEN** ventas históricas con `payment_method_id = NULL` dentro del rango
- **WHEN** se ejecuta el reporte
- **THEN** aparecen agrupadas en una fila "Sin especificar" y no se reparten entre las demás formas de pago

#### Scenario: Los gastos históricos sin imputar aparecen agrupados

- **GIVEN** gastos anteriores a este cambio, sin forma de pago, dentro del rango
- **WHEN** se ejecuta el reporte
- **THEN** aparecen agrupados en la fila "Sin especificar"
- **AND** no se reparten entre las demás formas de pago

#### Scenario: Caller de otra cuenta

- **WHEN** un usuario que no es miembro de `p_account_id` ejecuta el reporte
- **THEN** la llamada es rechazada con P0401

#### Scenario: La pantalla del reporte muestra la columna de gastos

- **WHEN** un usuario abre el reporte de formas de pago
- **THEN** la tabla incluye una columna de gastos junto a las de ventas y compras
- **AND** los totales de la pantalla coinciden con los del read-model

### Requirement: Superficies de la forma de pago

El sistema SHALL exponer la forma de pago en: (a) el gestor del catálogo dentro de `/configuracion`, junto al de centros de costo, visible sólo para `owner`/`admin`, **incluyendo la asignación del destino bancario por defecto de cada forma de pago, con el estado sin destino rotulado como "no registra movimiento bancario"**; (b) un selector "Forma de pago" en el alta y edición de ventas, de compras y de **gastos**, que ofrece sólo las formas activas —y que en el contexto de gasto NO SHALL ofrecer las de `kind` `credit`, con un texto de apoyo propio que nombre los efectos del gasto y no los de la venta—, **acompañado de un selector de cuenta bancaria que aparece únicamente cuando el `kind` elegido es bancario y la organización tiene cuentas bancarias cargadas**; (c) un badge con la forma de pago y un filtro por forma de pago en los listados de ventas, de compras y de **gastos**, resueltos por un componente de badge único y compartido por los tres; (d) la pantalla `/reportes/formas-pago`, alcanzable desde una entrada propia del sidebar y sin gate de plan —mismo criterio que el reporte de centros de costo, porque gatearlo dejaría al plan free imputando datos que no puede leer; y (e) la grilla de formas de pago del POS (`/ventas/pos`), con sus estados propios: indicador de sesión de caja cuando el `kind` es `cash`, bloque de cliente y saldo cuando es `credit`, **y un indicador de cuenta bancaria destino cuando el `kind` es bancario, que muestra el destino resuelto y permite cambiarlo en una sola pulsación sin bloquear el cobro**. La superficie del POS NO SHALL exigir elegir cuenta bancaria para cobrar, y NO SHALL mostrar el indicador cuando la organización no tiene cuentas bancarias cargadas, de modo que el mostrador conserve su fricción actual para quien no lleva el banco en el sistema. Toda superficie nueva SHALL usar los tokens semánticos y los componentes base del design system, y SHALL verificarse en desktop y mobile y en tema claro y oscuro.

#### Scenario: Alta de venta con el selector

- **WHEN** un usuario abre el form de venta
- **THEN** ve el selector "Forma de pago" con las formas activas de su cuenta y la opción de dejarlo sin especificar

#### Scenario: Filtrar el listado por forma de pago

- **GIVEN** operaciones imputadas a distintas formas de pago
- **WHEN** el usuario filtra el listado por "Efectivo"
- **THEN** sólo ve las operaciones imputadas a "Efectivo"

#### Scenario: El member no ve el gestor del catálogo

- **GIVEN** un usuario con rol `member`
- **WHEN** abre `/configuracion`
- **THEN** no se le ofrece la gestión del catálogo de formas de pago, aunque sí puede elegir formas de pago al operar

#### Scenario: El POS muestra el estado de caja sólo para efectivo

- **GIVEN** un usuario en el POS
- **WHEN** elige una forma de pago de `kind` distinto de `cash`
- **THEN** el indicador de sesión de caja no se muestra y el cobro no queda condicionado a una sesión abierta

#### Scenario: El POS muestra el destino bancario resuelto sin pedir una pulsación

- **GIVEN** una organización con cuentas bancarias y la forma de pago "Transferencia bancaria" con destino "Galicia CC"
- **WHEN** el usuario elige esa forma de pago en el POS
- **THEN** ve el destino "Galicia CC" indicado junto a la grilla, con la opción de cambiarlo, y puede cobrar sin ninguna pulsación adicional

#### Scenario: El POS no muestra nada bancario si la organización no tiene cuentas

- **GIVEN** una organización sin ninguna cuenta bancaria cargada
- **WHEN** el usuario elige una forma de pago de `kind = 'transfer'` en el POS
- **THEN** no se muestra indicador ni selector de cuenta bancaria y el cobro procede igual que antes de este change

#### Scenario: El gestor del catálogo permite configurar el destino

- **GIVEN** un `owner` en `/configuracion`
- **WHEN** abre el gestor de formas de pago
- **THEN** ve para cada forma su destino bancario (o el rótulo de que no registra movimiento bancario) y puede asignarlo o quitarlo desde ahí

#### Scenario: Alta de gasto con el selector

- **WHEN** un usuario abre el formulario de gasto
- **THEN** ve el selector "Forma de pago" con las formas activas de su cuenta, sin las de cuenta corriente, y la opción de dejarlo sin especificar

#### Scenario: Filtrar el listado de gastos por forma de pago

- **GIVEN** gastos imputados a distintas formas de pago
- **WHEN** el usuario filtra el listado de gastos por "Efectivo"
- **THEN** sólo ve los gastos imputados a "Efectivo"

## ADDED Requirements

### Requirement: Imputación opcional de la forma de pago en gastos

El sistema SHALL permitir imputar opcionalmente una forma de pago del catálogo a un gasto, mediante una columna nullable `payment_method_id` en `public.expenses`, con el mismo contrato que ya rige para ventas y compras: la forma de pago SHALL pertenecer a la cuenta del gasto y estar activa, el `kind` SHALL derivarse en el servidor desde el catálogo, y un gasto sin forma de pago SHALL ser válido.

La desactivación de una forma de pago SHALL preservar la imputación histórica de los gastos que la usan, igual que preserva la de ventas y compras: el gasto conserva su referencia y su nombre histórico sigue siendo legible en el listado y en el reporte.

#### Scenario: Alta de gasto con forma de pago

- **WHEN** se crea un gasto informando una forma de pago activa de la cuenta
- **THEN** el gasto queda persistido con esa forma de pago

#### Scenario: Gasto sin forma de pago

- **WHEN** se crea un gasto sin informar forma de pago
- **THEN** el gasto queda persistido sin imputación y sin efecto en libros

#### Scenario: Forma de pago de otra cuenta en un gasto

- **WHEN** se intenta crear un gasto con una forma de pago de otra cuenta
- **THEN** la operación es rechazada

#### Scenario: Desactivar una forma de pago usada por gastos

- **GIVEN** una forma de pago con gastos ya imputados
- **WHEN** se la desactiva
- **THEN** deja de ofrecerse para gastos nuevos
- **AND** los gastos históricos conservan su imputación y su nombre histórico sigue visible

### Requirement: La forma de pago dispara los efectos del gasto según su kind

El sistema SHALL despachar los efectos en libros de un gasto a partir del `kind` derivado de la forma de pago imputada, con el mismo criterio que ya rige para ventas y compras: `cash` habilita el impacto en la sesión de caja bajo opt-in verificado en servidor; `transfer`, `card`, `check` y `wallet` producen un movimiento bancario; `other` es una etiqueta sin efecto en libros; y `credit` SHALL rechazarse porque un gasto no tiene contraparte con cuenta corriente.

El texto de apoyo del selector SHALL nombrar el efecto de cada elección **en el contexto de gasto**, y SHALL NOT reutilizar el texto de venta, cuyos efectos son distintos.

#### Scenario: El kind del gasto se deriva en el servidor

- **WHEN** se registra un gasto informando una forma de pago
- **THEN** el efecto en libros se determina por el `kind` que el servidor lee del catálogo
- **AND** un `kind` enviado por el cliente no altera el efecto

#### Scenario: Gasto con forma de pago de tipo otro

- **WHEN** se registra un gasto con una forma de pago de `kind` `other`
- **THEN** el gasto queda persistido con su imputación
- **AND** no se registra ningún movimiento de caja ni bancario

#### Scenario: Gasto con forma de pago de cuenta corriente

- **WHEN** se intenta registrar un gasto con una forma de pago de `kind` `credit`
- **THEN** la operación es rechazada
- **AND** el texto de apoyo indica que un egreso a pagar después se registra como compra a proveedor

#### Scenario: El texto de apoyo distingue el contexto

- **WHEN** un usuario elige una forma de pago en el formulario de gasto
- **THEN** el texto de apoyo describe el efecto sobre caja o banco propio del gasto
- **AND** no describe efectos de venta como el cargo a la cuenta corriente de un cliente

### Requirement: La etiqueta de forma de pago tiene una sola definición en la interfaz

El sistema SHALL exponer la forma de pago de una operación en los listados mediante un componente único y compartido, alimentado por una definición canónica de las etiquetas en castellano de cada `kind` y del literal de "sin imputar", en lugar de repetir la marcación en cada listado.

Las etiquetas SHALL usar los tonos semánticos del design system y SHALL NOT usar colores literales, para no reintroducir la deuda de contraste que el gate vigente vigila.

#### Scenario: Los listados comparten la etiqueta

- **WHEN** se muestran las formas de pago en los listados de ventas, compras y gastos
- **THEN** los tres usan el mismo componente y la misma definición de etiquetas
- **AND** una operación sin imputar se muestra con el mismo literal en los tres

#### Scenario: La etiqueta usa tonos semánticos

- **WHEN** se inspecciona la etiqueta de forma de pago en cualquiera de los listados
- **THEN** sus colores provienen de los tokens semánticos del design system
- **AND** es legible en tema claro y en tema oscuro
