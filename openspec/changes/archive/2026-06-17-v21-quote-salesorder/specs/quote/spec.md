# quote

## ADDED Requirements

### Requirement: Agregado Quote con ciclo de vida
El sistema SHALL proveer un agregado `Quote` (tabla `quotes`) que representa un presupuesto/cotización con un estado de un conjunto cerrado: `draft`, `sent`, `accepted`, `expired`, `rejected`. La tabla SHALL tener `id`, `account_id` (tenancy), `branch_id` (FK→`branches`, nullable), `client_id` (FK→`clients`, nullable), `status` (CHECK sobre el enum), `valid_until` (date, nullable), `total numeric(15,2)`, `created_by` y `created_at`. Las transiciones válidas SHALL ser: `draft → sent`, `sent → accepted | rejected | expired`, `draft → expired`. Un Quote en estado `accepted`, `expired` o `rejected` es terminal y MUST NOT volver a `draft` o `sent`.

#### Scenario: crear un presupuesto en draft
- **WHEN** un usuario con rol writer crea un presupuesto con ítems
- **THEN** se persiste una fila en `quotes` con `status = 'draft'` y su `account_id` igual a la cuenta del usuario

#### Scenario: transición a sent
- **WHEN** se envía (`send()`) un presupuesto en `draft`
- **THEN** su `status` pasa a `sent`

#### Scenario: rechazar una transición inválida
- **WHEN** se intenta `accept()` un presupuesto ya en estado `rejected`
- **THEN** la operación falla con un error de estado inválido y el `status` no cambia

### Requirement: Líneas de presupuesto en quote_items
El sistema SHALL almacenar las líneas del presupuesto en `quote_items` con `quote_id` (FK→`quotes`), `product_id` (FK→`products`, nullable para líneas de servicio), `account_id`, `quantity numeric(15,4)`, `unit_id` (FK→`units_of_measure`, nullable), `price` (unitario) y `subtotal`. La creación/edición de un presupuesto NO SHALL tener ningún efecto sobre `branch_stock` ni sobre la caja.

#### Scenario: el presupuesto no compromete stock
- **WHEN** se crea un presupuesto de 5 unidades de un producto con `branch_stock = 3`
- **THEN** el presupuesto se crea correctamente y `branch_stock` permanece en 3 (el presupuesto no valida ni descuenta stock)

#### Scenario: línea de servicio sin producto
- **WHEN** se agrega una línea con `product_id = NULL` (servicio)
- **THEN** la fila en `quote_items` se acepta con `product_id` nulo

### Requirement: Quote.accept() crea un SalesOrder con los mismos ítems
El sistema SHALL proveer la operación `accept()` que, en una sola transacción atómica vía RPC `SECURITY DEFINER`, transiciona el Quote a `accepted` y crea un `SalesOrder` (con sus `sales_order_items`) cuyas líneas son copia de las de `quote_items` (producto, cantidad, unidad, precio, subtotal), preservando `branch_id`, `client_id` y `total`. El `SalesOrder` resultante SHALL referenciar el Quote de origen (`source_quote_id`). `accept()` NO SHALL descontar stock ni registrar caja: solo materializa la orden (el compromiso de stock ocurre en `SalesOrder.confirm()`).

#### Scenario: accept genera la orden espejo
- **WHEN** se acepta un presupuesto con dos líneas
- **THEN** se crea un `SalesOrder` con dos `sales_order_items` idénticos en producto, cantidad y precio, y `source_quote_id` igual al id del presupuesto

#### Scenario: accept es atómico
- **WHEN** la creación del `SalesOrder` falla durante `accept()`
- **THEN** el Quote permanece en su estado previo (no queda en `accepted` sin orden asociada)

#### Scenario: accept respeta la tenencia
- **WHEN** un usuario intenta aceptar un presupuesto de otra cuenta
- **THEN** la operación es denegada (RLS / guard de cuenta) y no se crea ningún `SalesOrder`

### Requirement: Expiración de presupuesto
El sistema SHALL permitir marcar un presupuesto como `expired` cuando su `valid_until` ya pasó, mediante el comando `expire()`, y SHALL tratar como no aceptable cualquier presupuesto cuyo `valid_until < now()` aunque su `status` materializado siga en `sent` (cómputo defensivo on-read).

#### Scenario: expirar un presupuesto vencido
- **WHEN** se ejecuta `expire()` sobre un presupuesto con `valid_until` en el pasado
- **THEN** su `status` pasa a `expired`

#### Scenario: no se acepta un presupuesto vencido
- **WHEN** se intenta `accept()` un presupuesto con `valid_until` anterior a hoy
- **THEN** la operación falla indicando que el presupuesto está vencido
