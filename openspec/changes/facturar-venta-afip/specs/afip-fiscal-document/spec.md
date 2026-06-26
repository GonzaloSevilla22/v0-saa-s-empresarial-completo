## ADDED Requirements

### Requirement: Emisión posterior de comprobante para una SalesOrder confirmada

El sistema SHALL proveer una acción dedicada para emitir el comprobante fiscal de una `sales_order` ya confirmada, mediante el endpoint `POST /sales-orders/{id}/emit-invoice` respaldado por una RPC `SECURITY DEFINER` (p.ej. `rpc_emit_sale_invoice`). La emisión SHALL ser válida tanto para una venta recién confirmada como para una venta histórica: es el mismo camino. El endpoint SHALL operar únicamente sobre órdenes con `status = 'confirmed'` y `fiscal_document_id IS NULL`. El tipo de comprobante SHALL resolverse en el backend (capa service vía `resolve_invoice_type`, espejado en la RPC) y NUNCA aceptarse desde el cliente. La emisión SHALL reutilizar la maquinaria existente: reserva de número + INSERT en `pending_cae` vía `rpc_emit_pending_cae`, sin tocar AFIP en el request (el CAE lo obtiene el relay asíncrono). Al emitir, la RPC SHALL setear `sales_orders.fiscal_document_id` con el comprobante creado, dentro del mismo commit que la inserción del `pending_cae`.

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

### Requirement: Idempotencia fiscal de la emisión por venta

El sistema SHALL impedir la doble emisión de comprobante para una misma `sales_order`. Si la orden ya tiene `fiscal_document_id IS NOT NULL`, el endpoint SHALL rechazar la solicitud con HTTP 409 (mapeado desde el error de dominio `P0409`). La validación de unicidad SHALL ejecutarse bajo lock (`SELECT … FOR UPDATE` sobre la orden) para serializar solicitudes concurrentes sobre la misma orden.

#### Scenario: Segunda emisión sobre una orden ya facturada devuelve 409

- **GIVEN** una `sales_order` que ya tiene `fiscal_document_id` asignado
- **WHEN** se invoca `POST /sales-orders/{id}/emit-invoice` nuevamente
- **THEN** el sistema responde 409 Conflict y NO crea un segundo comprobante

#### Scenario: Solicitudes concurrentes sobre la misma orden no duplican comprobante

- **GIVEN** una orden confirmada sin comprobante
- **WHEN** llegan dos solicitudes de emisión concurrentes para la misma orden
- **THEN** exactamente una crea el comprobante y setea `fiscal_document_id`; la otra recibe 409 (serializadas por el lock de fila)

### Requirement: Receptor del comprobante derivado de la identidad fiscal del cliente

El sistema SHALL construir la identificación del receptor a partir de la identidad fiscal del cliente de la venta (capability `client-fiscal-identity`, C-22): `clients.tax_id` e `clients.iva_condition`. Si el cliente está identificado con CUIT, el receptor SHALL derivarse como DocTipo 80; con DNI, DocTipo 96. Si la venta no tiene cliente, o el cliente no tiene `tax_id`, el comprobante SHALL emitirse a consumidor final con DocTipo 99 / DocNro 0 (default válido). El guard de umbral de identificación obligatoria del receptor (`afip_consumidor_final_threshold`, RG 5824/2026) del `WSFEAdapter` SHALL respetarse sin cambios: por encima del umbral, una venta sin receptor identificado SHALL fallar explícitamente en lugar de emitir un comprobante inválido.

#### Scenario: Venta sin cliente emite a consumidor final

- **GIVEN** una `sales_order` confirmada sin `client_id`, por debajo del umbral de identificación obligatoria
- **WHEN** se emite el comprobante
- **THEN** el receptor se resuelve como DocTipo 99 / DocNro 0 (consumidor final) y la emisión procede

#### Scenario: Cliente con CUIT se emite como receptor identificado

- **GIVEN** una `sales_order` con `client_id` cuyo `clients.tax_id` es un CUIT
- **WHEN** se emite el comprobante
- **THEN** el receptor se persiste con DocTipo 80 y el número de documento sin guiones

#### Scenario: Venta sobre el umbral sin receptor identificado falla explícito

- **GIVEN** una venta cuyo total alcanza o supera `afip_consumidor_final_threshold` y no tiene cliente identificado
- **WHEN** se intenta emitir el comprobante
- **THEN** el guard del `WSFEAdapter` rechaza la emisión (RECEPTOR_REQUIRED) y no se emite un comprobante inválido
