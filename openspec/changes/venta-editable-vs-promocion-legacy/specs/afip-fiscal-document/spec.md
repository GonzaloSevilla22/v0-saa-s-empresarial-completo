## ADDED Requirements

### Requirement: La emisión rechaza una orden que no coincide con su venta

`rpc_emit_sale_invoice` SHALL verificar, con la orden tomada `FOR UPDATE` y ANTES de numerar o crear el comprobante, que la orden refleja su venta: que tenga `sale_operation_id`, que la operación tenga filas de la cuenta, que `round(Σ sales.total, 2)` sea igual a `round(sales_orders.total, 2)` y que todas las filas tengan el `client_id` de la orden. Si algo no coincide SHALL fallar **cerrado** con `P0409 sales_order_out_of_sync` sin crear ningún comprobante. La lectura de `sales` SHALL hacerse sin lock (tomarla después de `sales_orders` invertiría el orden global de locks `sales → sales_orders → fiscal_documents`); con la orden tomada, ninguna edición ni borrado de esa operación puede commitear. La allow-list de re-emisión (`rejected`, `voided`) SHALL quedar intacta.

#### Scenario: una orden con otro importe no se factura

- **GIVEN** una orden confirmada cuyo total difiere de Σ `sales.total` de su operación
- **WHEN** se emite el comprobante
- **THEN** la RPC falla con `P0409 sales_order_out_of_sync` y no se crea ningún `fiscal_documents`

#### Scenario: una orden con otro receptor o sin venta vinculada no se factura

- **GIVEN** una orden confirmada cuyo `client_id` difiere del de su venta, o con `sale_operation_id NULL`
- **WHEN** se emite el comprobante
- **THEN** la RPC falla con `P0409 sales_order_out_of_sync` sin crear comprobante

#### Scenario: una orden sana se emite y la salida del usuario funciona

- **GIVEN** una orden desincronizada que fue rechazada con `sales_order_out_of_sync`
- **WHEN** el usuario vuelve a tocar "Facturar" (la promoción en replay la re-sincroniza) y emite
- **THEN** el comprobante sale por Σ `sales.total` a 2 decimales
