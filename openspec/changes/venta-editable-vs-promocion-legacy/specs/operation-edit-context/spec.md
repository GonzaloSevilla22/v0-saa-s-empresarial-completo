## MODIFIED Requirements

### Requirement: La orden de venta promovida sigue a la operación editada

Cuando la edición de una venta regenere el identificador de operación, toda `sales_orders` promovida desde esa operación que **no** tenga comprobante fiscal vivo SHALL re-apuntarse al identificador nuevo **y recalcularse** dentro de la misma transacción: `total = round(Σ sales.total, 2)` de la operación nueva, `client_id` y sucursal de sus filas, y una línea de `sales_order_items` por fila, con el mismo helper interno que usa la promoción (`_sales_order_sync_from_operation`). NO SHALL quedar ninguna orden apuntando a un identificador de operación inexistente, ni una orden re-apuntada con el total, el cliente o las líneas de la operación anterior — de lo contrario "Volver a facturar" o el "Facturar" de una venta editada emitirían por el importe viejo. Si la operación editada queda sin filas, la edición SHALL fallar con `P0400 operation_empty` en vez de dejar una orden confirmada sobre una operación vacía.

#### Scenario: la orden promovida no queda colgada tras editar

- **GIVEN** una venta promovida a `sales_orders` sin comprobante fiscal
- **WHEN** se edita la operación
- **THEN** la orden apunta al identificador de operación nuevo, y no queda ninguna orden huérfana

#### Scenario: la orden re-apuntada se factura por el importe y el receptor nuevos

- **GIVEN** una venta de 500 × 2 promovida a una orden de $1000 sin comprobante
- **WHEN** se edita a 500 × 5 con otro cliente y después se emite el comprobante
- **THEN** la orden queda con `total = 2500.00`, el cliente nuevo y las líneas de la venta editada, y el comprobante sale por $2500 con el receptor del cliente nuevo

#### Scenario: volver a facturar después de anular emite el importe nuevo

- **GIVEN** una venta con comprobante `pending_cae` que no salió hacia ARCA
- **WHEN** se edita la cantidad (el comprobante queda `voided`) y se vuelve a facturar
- **THEN** el comprobante nuevo sale por el importe editado, también cuando el anterior había quedado `rejected`

## ADDED Requirements

### Requirement: La edición y el borrado toman las filas de la operación antes de resolver su orden

`rpc_atomic_update_sale_operation` y `rpc_delete_sale_operation` SHALL tomar las filas de `sales` de la operación `FOR UPDATE`, en orden ascendente de `id`, ANTES de resolver su `sales_orders` y antes de tocar cualquier libro (stock, caja, banco, cuenta corriente, outbox), siguiendo el orden global `sales → sales_orders → fiscal_documents → resto`. La edición SHALL re-contar las filas bajo el lock y fallar con `P0404` si otra edición o un borrado se llevó alguna mientras esperaba (incluido un doble "Guardar"), antes de revertir stock. El borrado SHALL recalcular bajo el lock el conjunto de filas a borrar y devolver `false` si quedó vacío.

#### Scenario: una edición concurrente no ve una orden a medio crear

- **GIVEN** una promoción que ya tomó las filas de la operación y creó la orden sin commitear
- **WHEN** se edita la venta
- **THEN** la edición espera a la promoción, ve la orden creada y la recalcula; no queda ningún comprobante vivo por el importe anterior

#### Scenario: doble guardado de la misma edición

- **GIVEN** dos ediciones concurrentes de la misma operación
- **WHEN** la primera commitea
- **THEN** la segunda falla con `P0404` antes de revertir stock o escribir en cualquier libro, sin duplicar la operación

#### Scenario: el borrado espera a una promoción en curso

- **GIVEN** una promoción en curso sobre la operación
- **WHEN** se borra la venta
- **THEN** el borrado espera, ve la orden y la cancela en la misma transacción
