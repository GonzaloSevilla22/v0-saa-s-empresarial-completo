## MODIFIED Requirements

### Requirement: Asociación opcional de operaciones a una sucursal

El sistema SHALL permitir registrar compras, y los movimientos de stock que ellas generan, con un `branch_id` opcional. Si `branch_id` es NULL, la compra pertenece a la cuenta pero no a una sucursal específica.

La venta NO admite esta asociación opcional: toda venta queda registrada en una sucursal (requirement «Toda venta queda registrada en una sucursal»). El gasto se registra en la sucursal informada o, si no se informa ninguna, en la principal de la cuenta (capability `expense-operation`, requirement «El gasto persiste su sucursal»).

#### Scenario: Compra creada sin sucursal asignada

- **GIVEN** un formulario de compra sin sucursal seleccionada
- **WHEN** el usuario registra la compra
- **THEN** la fila en `purchases` tiene `branch_id = NULL`

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
- **THEN** la fila en `sales` tiene `branch_id` igual a la única sucursal de su cuenta ("Casa Central" si es la que creó el alta de la cuenta)

### Requirement: El usuario es avisado cuando cambia su sucursal por defecto

El sistema SHALL avisar al usuario, mediante una notificación no bloqueante, cuando la sucursal por defecto de su cuenta cambió respecto de la última vez que la vio en esa pestaña.

`c26_default_branch(p_account_id)` resuelve la sucursal por defecto (la "sucursal principal") como la sucursal más antigua por `created_at ASC` que está activa (`is_active`) **y operativa** (`status = 'active'`). Si ninguna cumple las dos condiciones, cae a la más antigua de la cuenta.

El cliente SHALL resolverla con la misma regla, desde una única definición compartida (`frontend/lib/default-branch.ts`) que consumen este aviso, el selector de sucursal de la venta y el opt-in de caja. Así nunca presenta como principal una sucursal cerrada que el servidor saltea.

Desactivar o cerrar la sucursal que hoy ocupa ese lugar hace que el sistema empiece a resolver otra por defecto de forma silenciosa. Sin este aviso, el usuario no tiene manera de enterarse de que las operaciones sin sucursal explícita empezaron a caer en un lugar distinto. Este requirement no reemplaza al guard de `branch-decommission-guard` (que impide desactivar una sucursal con contenido operativo): cubre el caso, legítimo, en que la sucursal por defecto cambia sin ningún contenido bloqueante de por medio.

El aviso SHALL persistirse por pestaña (no por dispositivo ni de forma permanente): lo que importa es el cambio ocurrido dentro de la sesión activa, no reabrir en cada pestaña nueva un cambio que ya pasó.

#### Scenario: Primera carga de la pestaña, sin aviso previo
- **GIVEN** un usuario que abre la aplicación en una pestaña nueva
- **WHEN** el sistema resuelve la sucursal por defecto de su cuenta por primera vez en esa pestaña
- **THEN** no se muestra ningún aviso, y la sucursal resuelta queda registrada para comparaciones futuras en esa pestaña

#### Scenario: La sucursal por defecto no cambió
- **GIVEN** un usuario cuya pestaña ya registró la sucursal por defecto actual de su cuenta
- **WHEN** el sistema vuelve a resolverla y es la misma
- **THEN** no se muestra ningún aviso

#### Scenario: La sucursal por defecto cambió
- **GIVEN** un usuario cuya pestaña registró una sucursal por defecto, y esa sucursal dejó de serlo (por ejemplo, se desactivó)
- **WHEN** el sistema resuelve la nueva sucursal por defecto
- **THEN** se muestra un aviso no bloqueante que nombra la nueva sucursal por defecto, y la pestaña actualiza su registro a la nueva sucursal

#### Scenario: Una sucursal cerrada no es la sucursal por defecto
- **GIVEN** una cuenta cuya sucursal más antigua está activa pero cerrada (`status = 'closed'`) y una segunda sucursal activa y operativa
- **WHEN** el cliente resuelve la sucursal por defecto
- **THEN** resuelve la segunda, la misma que `c26_default_branch`, y es la que nombran el aviso, el selector de la venta y el opt-in de caja

## ADDED Requirements

### Requirement: Toda venta queda registrada en una sucursal

El sistema SHALL registrar toda venta nueva o editada en una sucursal: la que el usuario eligió o, si no eligió ninguna, la sucursal principal de la cuenta (`c26_default_branch`). La sucursal escrita en la fila de `sales` y en su movimiento de stock SHALL ser la misma contra la que se validó y descontó el stock y se resolvieron la caja y el movimiento bancario de esa venta.

Si la cuenta no tiene ninguna sucursal, el alta y la edición SHALL rechazarse con `P0422 no_branch_found` sin persistir nada, igual que el POS y "Facturar venta manual".

Aplica a los dos caminos de alta del formulario y la API (`rpc_create_sale_operation_v2` y la rama legacy de `rpc_create_sale_operation`) y a la edición (`rpc_atomic_update_sale_operation`). El POS, la confirmación de órdenes y los presupuestos aceptados ya registran la sucursal resuelta y no cambian.

Este requirement cumple RN-93 y DEC-19 para la venta: «toda venta, compra, gasto y movimiento de caja lleva `branch_id`».

#### Scenario: Venta sin sucursal elegida queda en la principal
- **GIVEN** una cuenta con la sucursal principal A y otra sucursal B, y una venta de dos líneas (una con producto, una de servicio) registrada sin elegir sucursal
- **WHEN** se registra la venta
- **THEN** todas las filas de `sales` de la operación tienen `branch_id = A`, el movimiento de stock de la línea con producto tiene `branch_id = A`, el stock baja en A y B no se toca

#### Scenario: Venta por la API sin el campo de sucursal
- **WHEN** se llama a `POST /sales` sin `branch_id` (o con `branch_id: null`)
- **THEN** la venta queda registrada en la sucursal principal de la cuenta

#### Scenario: Una sucursal cerrada no recibe las ventas sin sucursal elegida
- **GIVEN** una cuenta cuya sucursal más antigua A está cerrada y una sucursal B activa y operativa
- **WHEN** se registra una venta sin elegir sucursal
- **THEN** la venta, su movimiento y el descuento de stock quedan en B

#### Scenario: La venta, su stock, su caja y su banco quedan en la misma sucursal
- **GIVEN** una venta sin sucursal elegida, pagada con una forma de pago bancaria
- **WHEN** se registra
- **THEN** la fila de `sales`, su movimiento de stock y su movimiento bancario llevan la misma sucursal, la principal

#### Scenario: El camino legacy del alta se comporta igual
- **GIVEN** una cuenta con el flag `sale_items_rpc_v2` apagado
- **WHEN** se registra una venta sin elegir sucursal
- **THEN** la venta y su movimiento de stock quedan en la sucursal principal, igual que por el camino vigente

#### Scenario: Cuenta sin ninguna sucursal
- **GIVEN** una cuenta sin ninguna sucursal
- **WHEN** se intenta registrar una venta sin sucursal
- **THEN** la operación se rechaza con `P0422 no_branch_found` y no se persiste ninguna fila de venta, de idempotencia ni de stock

#### Scenario: Editar una venta informando "sin sucursal" la registra en la principal
- **GIVEN** una venta registrada en la sucursal B
- **WHEN** se edita informando la sucursal como `NULL`
- **THEN** la operación resultante queda en la sucursal principal, el stock vuelve a B y se descuenta de la principal

#### Scenario: Editar una venta histórica sin sucursal la registra en la principal
- **GIVEN** una venta con `branch_id` nulo que la asignación de históricos no pudo resolver en su momento
- **WHEN** se edita sin informar sucursal
- **THEN** la operación resultante queda en la sucursal principal

### Requirement: Las ventas históricas sin sucursal se asignan a la sucursal principal

El sistema SHALL asignar una sucursal, una única vez y de forma idempotente, a toda venta histórica con `branch_id` nulo de una cuenta que tenga al menos una sucursal, con este orden de precedencia:

1. la sucursal de su orden de venta, si la operación fue facturada desde "Facturar venta manual";
2. si no, la única sucursal que ya tengan las demás filas de su misma operación;
3. si no, la sucursal principal vigente de la cuenta al aplicar la asignación.

Los movimientos de stock de tipo venta de esas mismas ventas SHALL tomar la misma sucursal.

La asignación NO SHALL tocar los movimientos de caja, de banco ni de cuenta corriente, los asientos, los eventos, las órdenes, las líneas ni el stock. Tampoco SHALL disparar notificaciones, eventos ni registros de analítica. SHALL dejar una fila de auditoría por cuenta afectada con las ventas y los movimientos asignados, e informar como residuo, sin abortar, las filas que no pueda resolver (por ejemplo, sin cuenta).

#### Scenario: Cuenta con una sola sucursal
- **GIVEN** una venta histórica con `branch_id` nulo de una cuenta con una única sucursal
- **WHEN** se aplica la asignación
- **THEN** la venta queda en esa sucursal

#### Scenario: Cuenta con varias sucursales
- **GIVEN** una venta histórica con `branch_id` nulo de una cuenta con las sucursales A (principal) y B
- **WHEN** se aplica la asignación
- **THEN** la venta queda en A

#### Scenario: Venta facturada desde "Facturar venta manual"
- **GIVEN** una venta histórica con `branch_id` nulo cuya operación tiene una orden de venta registrada en la sucursal B, aunque la principal sea A
- **WHEN** se aplica la asignación
- **THEN** la venta queda en B, la misma sucursal que su orden y su factura

#### Scenario: Operación con filas de distinta sucursal
- **GIVEN** una operación con una fila en la sucursal B y otra con `branch_id` nulo
- **WHEN** se aplica la asignación
- **THEN** la fila nula queda en B y "Facturar venta manual" sobre esa operación ya no se rechaza por "distinta sucursal"

#### Scenario: El movimiento de stock sigue a la venta
- **GIVEN** una venta histórica con `branch_id` nulo y su movimiento de stock también nulo
- **WHEN** se aplica la asignación y después se borra esa venta
- **THEN** el movimiento queda en la sucursal asignada a la venta y el borrado repone el stock en esa sucursal

#### Scenario: Una venta sin cuenta queda como residuo informado
- **GIVEN** una fila de `sales` con `branch_id` y `account_id` nulos
- **WHEN** se aplica la asignación
- **THEN** la fila conserva `branch_id` nulo, se informa como residuo y la asignación termina sin error

#### Scenario: Reaplicar no cambia nada
- **GIVEN** la asignación ya aplicada
- **WHEN** se ejecuta otra vez
- **THEN** ninguna fila cambia y no se escribe ninguna fila de auditoría nueva

#### Scenario: Sin efectos laterales
- **WHEN** se aplica la asignación
- **THEN** no se crean eventos, notificaciones ni registros de analítica, y los movimientos de caja, de banco y de cuenta corriente y los asientos quedan intactos

#### Scenario: Rastro de lo asignado por el sistema
- **WHEN** la asignación modifica ventas de una cuenta
- **THEN** queda una fila de auditoría de esa cuenta que lista las ventas y los movimientos asignados y cuántos se resolvieron por cada regla

### Requirement: El selector de sucursal de la venta ofrece la principal en lugar de "Sin sucursal"

El formulario de venta SHALL mostrar el selector de sucursal con el rótulo «Sucursal», sin la opción «Sin sucursal (general)» y con la sucursal principal de la cuenta (resuelta con la definición compartida del cliente) seleccionada de entrada e identificada como «(principal)».

Si el usuario no cambia la selección, la venta se registra en la principal. Si elige otra sucursal, se registra en esa.

Los formularios de compra y de gasto, y el importador de gastos, que comparten el componente, SHALL conservar su opción «Sin sucursal (general)» sin cambios. El selector SHALL leerse y operarse en escritorio y en móvil, con tema claro y oscuro.

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

#### Scenario: Compra y gasto conservan su opción
- **WHEN** el usuario abre el formulario de compra o el de gasto
- **THEN** su selector de sucursal sigue ofreciendo "Sin sucursal (general)" como antes de este cambio

#### Scenario: Cuenta sin módulo de sucursales
- **GIVEN** una cuenta cuyo plan no incluye el módulo de sucursales
- **WHEN** el usuario registra una venta
- **THEN** el formulario no muestra el selector y la venta queda en la única sucursal de la cuenta

#### Scenario: La edición muestra la sucursal de la venta
- **GIVEN** una venta registrada en B
- **WHEN** el usuario la edita
- **THEN** el selector muestra B y no ofrece "Sin sucursal (general)"

#### Scenario: Escritorio y móvil, tema claro y oscuro
- **WHEN** el formulario de venta se abre en escritorio y en un ancho de 375 px, con tema claro y con tema oscuro
- **THEN** el rótulo, la sucursal seleccionada y la marca "(principal)" se leen con contraste AA y el selector se opera sin desborde horizontal
