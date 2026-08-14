## ADDED Requirements

### Requirement: Historial de compras del cliente
El sistema SHALL exponer el historial de compras de un cliente como una lista paginada donde cada elemento representa una operación de venta, con su fecha, la cantidad de ítems y el monto total de la operación.

Las operaciones SHALL ordenarse por fecha descendente. El historial SHALL cubrir únicamente las ventas del cliente dentro de la organización del usuario autenticado.

#### Scenario: Cliente con varias compras
- **WHEN** se solicita el historial de un cliente con 5 operaciones de venta
- **THEN** se devuelven 5 elementos, uno por operación, ordenados de la más reciente a la más antigua

#### Scenario: Operación con varios productos
- **WHEN** una operación de venta contiene 3 líneas de producto
- **THEN** aparece como un único elemento del historial con cantidad de ítems 3 y el monto total de la operación

#### Scenario: Cliente sin compras
- **WHEN** se solicita el historial de un cliente que nunca compró
- **THEN** se devuelve una lista vacía con total 0, sin error

#### Scenario: Cliente de otra organización
- **WHEN** un usuario solicita el historial de un cliente que no pertenece a su organización
- **THEN** el sistema responde con un error de recurso no encontrado y no revela ningún dato del cliente

### Requirement: Monto canónico de la operación
El sistema SHALL calcular el monto de cada línea de venta como `COALESCE(sale_items.subtotal, sales.total, sales.amount)` y el monto de una operación como la suma de los montos de sus líneas, conforme al canon de `reporting-invariants`.

El sistema NO SHALL sumar `sales.amount` como monto de línea cuando exista `sales.total` o `sale_items.subtotal`, dado que `amount` es el precio unitario y subvalúa toda línea con cantidad mayor a 1.

#### Scenario: Línea con cantidad mayor a uno
- **WHEN** una línea de venta tiene precio unitario 100 y cantidad 3, con subtotal registrado 300
- **THEN** el monto de esa línea es 300, no 100

#### Scenario: Línea legacy sin subtotal en sale_items
- **WHEN** una línea de venta no tiene fila correspondiente en `sale_items`
- **THEN** el monto se toma de `sales.total`, y sólo si éste es nulo se cae a `sales.amount`

### Requirement: Resumen acumulado del cliente
El sistema SHALL exponer, junto al historial, un resumen con la cantidad total de compras del cliente, el total comprado acumulado, la fecha de la última compra y los días transcurridos desde ella.

El resumen SHALL calcularse sobre la totalidad de las operaciones del cliente y NO SHALL depender de la página del historial que se esté visualizando. El resumen SHALL reutilizar la misma definición de agregados que alimenta el listado de clientes con actividad, sin declarar una segunda fórmula.

#### Scenario: Resumen independiente de la paginación
- **WHEN** un cliente tiene 30 compras y se visualiza la segunda página del historial
- **THEN** el resumen informa 30 compras y el total acumulado de las 30, no el de la página visible

#### Scenario: Días desde la última compra
- **WHEN** la última compra de un cliente ocurrió hace 73 días calendario argentinos
- **THEN** el resumen informa 73 días transcurridos

### Requirement: El total comprado es bruto y no descuenta notas de crédito
El total comprado SHALL representar la suma bruta de las ventas al cliente, sin descontar notas de crédito ni movimientos de cuenta corriente.

La interfaz SHALL rotular el valor de forma que su alcance sea inequívoco e indicar que no descuenta notas de crédito, y SHALL ofrecer acceso a la cuenta corriente del cliente, donde viven el saldo y sus ajustes.

#### Scenario: Cliente con nota de crédito emitida
- **WHEN** un cliente tiene ventas por 100.000 y una nota de crédito por 20.000 registrada en su cuenta corriente
- **THEN** el total comprado informa 100.000 y la nota de crédito no lo altera

#### Scenario: Acceso a la posición financiera
- **WHEN** el usuario visualiza el resumen de compras de un cliente
- **THEN** dispone de acceso directo a la cuenta corriente de ese cliente desde la misma pantalla

### Requirement: Superficie de detalle del cliente con pestañas
La aplicación SHALL exponer una pantalla de detalle por cliente en la ruta `/clientes/[id]`, alcanzable desde la lista de clientes, que presente una cabecera con la identificación del cliente y navegación por pestañas entre `Historial de compras` y `Cuenta corriente`.

La pestaña de cuenta corriente SHALL corresponder a la ruta ya existente `/clientes/[id]/cuenta`, que a partir de este cambio deja de ser inalcanzable desde la interfaz. Cada pestaña SHALL ser enlazable de forma independiente y SHALL preservar el funcionamiento del botón de retroceso del navegador.

#### Scenario: Navegación desde la lista
- **WHEN** el usuario hace click sobre la fila de un cliente en la lista
- **THEN** navega al detalle de ese cliente mostrando su historial de compras

#### Scenario: Acciones de la fila no navegan
- **WHEN** el usuario acciona los controles de editar o eliminar dentro de la fila de un cliente
- **THEN** se ejecuta esa acción y no se produce la navegación al detalle

#### Scenario: Acceso a la cuenta corriente
- **WHEN** el usuario está en el detalle de un cliente y selecciona la pestaña de cuenta corriente
- **THEN** accede a la pantalla de saldo y movimientos del cliente conservando la cabecera del detalle

#### Scenario: Navegación por teclado
- **WHEN** el usuario recorre la lista de clientes con el teclado
- **THEN** el elemento que abre el detalle es alcanzable, tiene foco visible y se activa con la tecla de confirmación

### Requirement: Historial paginado con el envelope estándar
El historial de compras SHALL paginarse con el envelope estándar `{items, total, page, pages}` definido en `api-standards`, con `page` en base 0.

Los errores SHALL devolverse en formato RFC 7807, conforme al canon de la plataforma.

#### Scenario: Página fuera de rango
- **WHEN** se solicita una página posterior a la última página disponible
- **THEN** se devuelve una lista de elementos vacía conservando los valores correctos de `total` y `pages`

#### Scenario: Cliente inexistente
- **WHEN** se solicita el historial de un identificador de cliente que no existe
- **THEN** se devuelve un error RFC 7807 con estado 404
