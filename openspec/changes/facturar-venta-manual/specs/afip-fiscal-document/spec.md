## MODIFIED Requirements

### Requirement: Emisión posterior de comprobante para una SalesOrder confirmada

El sistema SHALL proveer una acción dedicada para emitir el comprobante fiscal de una `sales_order` ya confirmada, mediante el endpoint `POST /sales-orders/{id}/emit-invoice` respaldado por una RPC `SECURITY DEFINER` (p.ej. `rpc_emit_sale_invoice`). La emisión SHALL ser válida para una venta recién confirmada, para una venta histórica, **y para una `sales_order` materializada por promoción de una venta legacy** (capability `sales-order`, "Promoción de una venta legacy a SalesOrder facturable"): es el mismo camino, sin distinción del origen de la orden. El endpoint SHALL operar únicamente sobre órdenes con `status = 'confirmed'` y `fiscal_document_id IS NULL`. El tipo de comprobante SHALL resolverse en el backend (capa service vía `resolve_invoice_type`, espejado en la RPC) y NUNCA aceptarse desde el cliente. La emisión SHALL reutilizar la maquinaria existente: reserva de número + INSERT en `pending_cae` vía `rpc_emit_pending_cae`, sin tocar AFIP en el request (el CAE lo obtiene el relay asíncrono). Al emitir, la RPC SHALL setear `sales_orders.fiscal_document_id` con el comprobante creado, dentro del mismo commit que la inserción del `pending_cae`.

Para una venta legacy facturada vía promoción, el comprobante resultante SHALL quedar **reconciliado** a la `sales_order` (vía `sales_orders.fiscal_document_id`), a diferencia de la emisión directa huérfana (`POST /fiscal/documents/emit`), que crea un `fiscal_documents` sin orden asociada. La promoción seguida de la emisión NO SHALL alterar el contrato del flujo `emit-invoice`: la RPC de emisión se invoca con el `sales_order_id` materializado, sin parámetros nuevos.

#### Scenario: Emite Factura C para venta confirmada de emisor monotributista

- **GIVEN** una `sales_order` con `status = 'confirmed'` y `fiscal_document_id IS NULL`, y un `fiscal_profile` con `iva_condition = 'monotributista'` y un PV activo
- **WHEN** se invoca `POST /sales-orders/{id}/emit-invoice`
- **THEN** se crea un `fiscal_documents` con `comprobante_type = 'factura_c'` en `status = 'pending_cae'` y número reservado, y `sales_orders.fiscal_document_id` referencia ese comprobante, sin que el request llame a AFIP

#### Scenario: El tipo lo resuelve el backend, no el cliente

- **WHEN** se invoca `POST /sales-orders/{id}/emit-invoice` (el payload no incluye ni puede forzar `comprobante_type`)
- **THEN** el backend determina el tipo vía `resolve_invoice_type(emisor_iva_condition, receptor_iva_condition)` y para emisor monotributista emite `factura_c`

#### Scenario: La emisión es asíncrona y no bloquea esperando el CAE

- **GIVEN** una orden confirmada facturable
- **WHEN** se emite el comprobante
- **THEN** el endpoint responde con el `fiscal_document_id` en `status = 'pending_cae'` sin esperar el CAE; el CAE lo obtiene el relay (`CAERelayProcessor` vía `pg_cron`) posteriormente

#### Scenario: Una SalesOrder materializada por promoción es un origen válido de emisión

- **GIVEN** una venta legacy cargada a mano y luego promovida a una `sales_order` con `status = 'confirmed'` y `fiscal_document_id IS NULL`
- **WHEN** se invoca `POST /sales-orders/{id}/emit-invoice` sobre esa orden promovida
- **THEN** la emisión procede idéntica a cualquier otra orden confirmada (reserva número + `pending_cae`), setea `sales_orders.fiscal_document_id` y el comprobante queda reconciliado a la orden

#### Scenario: El comprobante de una venta promovida lleva fecha de emisión actual

- **GIVEN** una venta legacy con fecha de negocio anterior (p.ej. de la semana pasada) promovida y facturada hoy
- **WHEN** se emite el comprobante
- **THEN** el `fiscal_documents` se numera y emite con la fecha de emisión actual (no la fecha de la venta original), conforme al funcionamiento de AFIP; la antigüedad facturable queda sujeta a los límites de AFIP (caveat de negocio, no un error del sistema)
