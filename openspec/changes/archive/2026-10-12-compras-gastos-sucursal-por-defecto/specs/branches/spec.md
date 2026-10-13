## MODIFIED Requirements

### Requirement: Asociación opcional de operaciones a una sucursal

El sistema SHALL admitir `branch_id` nulo en compras y gastos, y en los movimientos de stock de compras, **sólo** en las filas registradas antes de `compras-gastos-sucursal-por-defecto` que nadie editó desde entonces. Una fila con `branch_id` nulo pertenece a la cuenta pero no a una sucursal específica.

Toda compra y todo gasto que se creen o se editen desde ese cambio quedan registrados en una sucursal: la elegida o, si no se eligió ninguna, la principal de la cuenta. Las reglas viven en sus capabilities: `purchase-operation` («La compra persiste su sucursal»), `expense-operation` («El gasto persiste su sucursal») y `operation-edit-context` (la edición).

La venta tampoco admite esta asociación opcional: toda venta queda registrada en una sucursal (requirement «Toda venta queda registrada en una sucursal»).

#### Scenario: Compra creada sin sucursal elegida

- **GIVEN** un formulario de compra en el que el usuario no cambió el selector de sucursal, o una cuenta sin módulo de sucursales
- **WHEN** el usuario registra la compra
- **THEN** las filas en `purchases` tienen `branch_id` igual a la sucursal principal de la cuenta, nunca `NULL`

#### Scenario: Compra histórica sin sucursal

- **GIVEN** una compra registrada sin sucursal antes de este cambio
- **WHEN** se la lista o se la lee
- **THEN** su `branch_id` sigue siendo `NULL` hasta que alguien la edite

#### Scenario: Venta creada con sucursal asignada

- **GIVEN** un formulario de venta con una sucursal seleccionada
- **WHEN** el usuario registra la venta
- **THEN** la fila en `sales` tiene `branch_id` igual al id de la sucursal seleccionada

#### Scenario: Venta creada sin sucursal elegida

- **GIVEN** una venta registrada sin elegir sucursal
- **WHEN** se persiste la venta
- **THEN** la fila en `sales` tiene `branch_id` igual a la sucursal principal de la cuenta, nunca `NULL`

#### Scenario: Venta de una cuenta sin módulo de sucursales

- **GIVEN** un usuario cuyo plan no incluye el módulo de sucursales, de modo que el formulario no muestra el selector
- **WHEN** registra una venta
- **THEN** la fila en `sales` tiene `branch_id` igual a la sucursal principal de la cuenta (`c26_default_branch`): su única sucursal si tiene una sola ("Casa Central" si es la que creó el alta de la cuenta), o la más antigua operativa si conserva varias de un plan anterior

### Requirement: Operaciones solo contra sucursales operativas
El sistema SHALL rechazar ventas, compras, gastos, ajustes y transferencias que referencien explícitamente una sucursal con `status = 'closed'`, con error `P0422 branch_closed` en el alta (`branch_invalid` en la edición de venta, compra y gasto).

#### Scenario: Venta en sucursal cerrada falla
- **GIVEN** una sucursal con `status = 'closed'`
- **WHEN** se registra una venta con `p_branch_id` de esa sucursal
- **THEN** la RPC retorna `P0422 branch_closed` y no inserta ninguna fila

#### Scenario: Compra en sucursal cerrada falla
- **GIVEN** una sucursal con `status = 'closed'`
- **WHEN** se registra una compra con `p_branch_id` de esa sucursal
- **THEN** la RPC retorna `P0422 branch_closed`, no inserta ninguna fila y no suma stock en esa sucursal

#### Scenario: Transferencia hacia o desde sucursal cerrada falla
- **GIVEN** una transferencia cuyo origen o destino tiene `status = 'closed'`
- **WHEN** se llama a `rpc_transfer_stock`
- **THEN** la RPC retorna `P0422 branch_closed` y no modifica ningún ledger

#### Scenario: UI muestra estado y acciones de lifecycle
- **GIVEN** el owner navega a `/sucursales/:id`
- **WHEN** la página carga
- **THEN** ve el badge de estado (`Activa`/`Cerrada`), el botón Abrir/Cerrar con confirmación, y el listado de transferencias de la sucursal

### Requirement: El selector de sucursal de la venta ofrece la principal en lugar de "Sin sucursal"

Toda superficie que registre una venta con un selector de sucursal (hoy, el formulario de venta) SHALL mostrar ese selector con el rótulo «Sucursal» asociado al control y sin la opción «Sin sucursal (general)». De entrada SHALL mostrar seleccionada la sucursal que el servidor va a usar si el usuario no elige otra: la del documento de origen, cuando la venta nace de uno que ya tiene sucursal (por ejemplo, la conversión de un presupuesto), o si no la sucursal principal de la cuenta, resuelta con la definición compartida del cliente. La principal SHALL identificarse como «(principal)» en la lista. Mientras las sucursales cargan, el selector NO SHALL mostrar el texto «Sin sucursal».

Si el usuario no cambia la selección, la venta se registra en la sucursal mostrada. Si elige otra sucursal, se registra en esa.

Los formularios de compra y de gasto, y el importador de gastos, siguen la misma regla desde `compras-gastos-sucursal-por-defecto` (requirement «El selector de sucursal de compra, gasto e importador de gastos ofrece la principal en lugar de "Sin sucursal"»). El presupuesto conserva su opción sin sucursal: no mueve stock ni registra una venta. El selector SHALL leerse y operarse en escritorio y en móvil, con tema claro y oscuro.

#### Scenario: El alta abre con la principal seleccionada
- **GIVEN** una cuenta con módulo de sucursales y las sucursales A (principal) y B
- **WHEN** el usuario abre "Nueva venta"
- **THEN** el selector rotulado "Sucursal" muestra A marcada "(principal)" y la lista no ofrece "Sin sucursal (general)"

#### Scenario: Sin tocar el selector, la venta queda en la principal
- **WHEN** el usuario registra la venta sin cambiar el selector
- **THEN** la venta queda registrada en A

#### Scenario: Elegir otra sucursal la registra en esa
- **WHEN** el usuario elige B y registra la venta
- **THEN** la venta queda registrada en B

#### Scenario: Una venta que nace de un documento con sucursal muestra la de ese documento
- **GIVEN** una superficie que registra una venta a partir de un documento de la sucursal B, en una cuenta cuya principal es A
- **WHEN** el usuario la abre
- **THEN** el selector muestra B, y si la venta se registra sin cambiar el selector queda en B

#### Scenario: El presupuesto conserva su opción
- **WHEN** el usuario abre el formulario de presupuesto
- **THEN** su selector de sucursal sigue ofreciendo «Sin sucursal (general)»

#### Scenario: Cuenta sin módulo de sucursales
- **GIVEN** una cuenta cuyo plan no incluye el módulo de sucursales
- **WHEN** el usuario registra una venta
- **THEN** el formulario no muestra ni el selector ni su rótulo, y la venta queda en la sucursal principal de la cuenta

#### Scenario: La edición muestra la sucursal de la venta
- **GIVEN** una venta registrada en B
- **WHEN** el usuario la edita
- **THEN** el selector muestra B y no ofrece "Sin sucursal (general)"

#### Scenario: Escritorio y móvil, tema claro y oscuro
- **WHEN** el formulario de venta se abre en escritorio y en un ancho de 375 px, con tema claro y con tema oscuro
- **THEN** el rótulo, la sucursal seleccionada y la marca "(principal)" se leen con contraste AA y el selector se opera sin desborde horizontal

## ADDED Requirements

### Requirement: El selector de sucursal de compra, gasto e importador de gastos ofrece la principal en lugar de "Sin sucursal"

Los formularios de alta y edición de compra y de gasto SHALL mostrar el selector de sucursal con el rótulo «Sucursal» asociado al control y sin la opción «Sin sucursal (general)». El importador de gastos SHALL mostrar su selector de sucursal por defecto con el rótulo «Sucursal por defecto» y sin la opción «Sin sucursal por defecto».

De entrada, cada selector SHALL mostrar seleccionada la sucursal que el servidor va a usar si el usuario no elige otra: en el alta y en el importador, la sucursal principal de la cuenta, resuelta con la definición compartida del cliente (la misma que usan la venta, el opt-in de caja y el aviso de cambio de sucursal por defecto); en la edición, la sucursal vigente del documento, o la principal si el documento no tiene sucursal. La principal SHALL identificarse como «(principal)» en la lista. Mientras las sucursales cargan, el selector NO SHALL mostrar el texto «Sin sucursal».

Si el usuario no cambia la selección, la compra, el gasto o las filas del lote sin sucursal propia se registran en la sucursal mostrada. Si elige otra, se registran en esa.

Las tres superficies SHALL reutilizar el componente de selector compartido y la definición compartida de la principal; NO SHALL crearse un selector ni una resolución de la principal nuevos. En las cuentas sin módulo de sucursales los selectores y sus rótulos no se muestran, igual que hoy, y el servidor registra la principal.

El selector SHALL leerse y operarse en escritorio y en móvil, con tema claro y oscuro, usando los tokens semánticos del design system.

#### Scenario: El alta de compra abre con la principal seleccionada

- **GIVEN** una cuenta con módulo de sucursales y las sucursales A (principal) y B
- **WHEN** el usuario abre "Nueva compra"
- **THEN** el selector rotulado "Sucursal" muestra A marcada "(principal)" y la lista no ofrece "Sin sucursal (general)"

#### Scenario: Sin tocar el selector, la compra queda en la principal

- **WHEN** el usuario registra la compra sin cambiar el selector
- **THEN** la compra queda registrada en A y su stock entra en A

#### Scenario: Elegir otra sucursal registra la compra en esa

- **WHEN** el usuario elige B y registra la compra
- **THEN** la compra queda registrada en B y su stock entra en B

#### Scenario: El opt-in de caja de una compra sin sucursal elegida funciona

- **GIVEN** una sesión de caja abierta en la principal A y una forma de pago de tipo efectivo
- **WHEN** el usuario registra hoy una compra en efectivo sin cambiar el selector, con el descuento de caja marcado
- **THEN** la compra se registra en A con su movimiento de caja en la sesión de A, sin error

#### Scenario: El alta de gasto abre con la principal seleccionada

- **GIVEN** una cuenta con módulo de sucursales y las sucursales A (principal) y B
- **WHEN** el usuario abre "Nuevo gasto"
- **THEN** el selector rotulado "Sucursal" muestra A marcada "(principal)" y la lista no ofrece "Sin sucursal (general)"

#### Scenario: La edición de un documento sin sucursal muestra la principal

- **GIVEN** una compra o un gasto históricos sin sucursal
- **WHEN** el usuario los edita sin tocar el selector
- **THEN** el selector muestra la principal y, al guardar, el documento queda en la principal

#### Scenario: La edición muestra la sucursal vigente

- **GIVEN** una compra o un gasto registrados en B
- **WHEN** el usuario los edita
- **THEN** el selector muestra B y no ofrece la opción sin sucursal

#### Scenario: El importador de gastos muestra la principal como sucursal por defecto

- **GIVEN** una cuenta con módulo de sucursales y las sucursales A (principal) y B
- **WHEN** el usuario abre el importador de gastos
- **THEN** el selector rotulado "Sucursal por defecto" muestra A marcada "(principal)" y la lista no ofrece "Sin sucursal por defecto"
- **AND** las filas del archivo sin sucursal propia se registran en A

#### Scenario: Cuenta sin módulo de sucursales

- **GIVEN** una cuenta cuyo plan no incluye el módulo de sucursales
- **WHEN** el usuario registra una compra o un gasto, o importa gastos
- **THEN** ninguna de las tres superficies muestra el selector ni su rótulo, y los documentos quedan en la sucursal principal de la cuenta

#### Scenario: Escritorio y móvil, tema claro y oscuro

- **WHEN** el formulario de compra, el de gasto y el importador de gastos se abren en escritorio y en un ancho de 375 px, con tema claro y con tema oscuro
- **THEN** el rótulo, la sucursal seleccionada y la marca "(principal)" se leen con contraste AA y el selector se opera sin desborde horizontal
