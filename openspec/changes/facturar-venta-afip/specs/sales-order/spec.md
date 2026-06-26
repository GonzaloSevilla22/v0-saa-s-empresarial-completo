## ADDED Requirements

### Requirement: La confirmación de venta no emite comprobante inline; la facturación es una acción posterior explícita

El sistema SHALL desacoplar la emisión del comprobante fiscal del momento de confirmar la venta. El punto de venta (POS) y el flujo de confirmación NO SHALL emitir un comprobante de forma inline: `quickSale()` y `confirm()` SHALL invocarse sin `comprobante_type` (o con `comprobante_type = NULL`), de modo que la `sales_order` resultante nazca con `fiscal_document_id IS NULL`. La emisión del comprobante SHALL realizarse mediante la acción posterior dedicada (capability `afip-fiscal-document`, "Emisión posterior de comprobante para una SalesOrder confirmada"), tanto para una venta recién confirmada como para una histórica.

El RPC de confirmación (`rpc_confirm_sales_order` / `rpc_quick_sale` vía `_c29_confirm_order_core`) SHALL conservar el parámetro `p_comprobante_type` opcional por retrocompatibilidad, pero el cliente del POS SHALL dejar de proveerlo. El frontend SHALL deshabilitar la acción "Facturar" mientras la orden tenga una emisión `pending_cae` o ya esté facturada (`fiscal_document_id IS NOT NULL`).

#### Scenario: quickSale del POS confirma sin comprobante

- **WHEN** el POS confirma una venta vía `quickSale()` sin pasar `comprobante_type`
- **THEN** la `sales_order` queda `confirmed` con `fiscal_document_id IS NULL` y no se reserva número fiscal en el hot path

#### Scenario: La venta confirmada sin comprobante puede facturarse después

- **GIVEN** una `sales_order` confirmada con `fiscal_document_id IS NULL`
- **WHEN** el usuario presiona "Facturar"
- **THEN** se dispara la emisión posterior (capability `afip-fiscal-document`) y la orden queda asociada al comprobante emitido

#### Scenario: El botón Facturar se deshabilita cuando ya hay comprobante

- **GIVEN** una `sales_order` con un comprobante `pending_cae` o ya autorizado (`fiscal_document_id IS NOT NULL`)
- **WHEN** se muestra la venta en el detalle o el listado
- **THEN** la acción "Facturar" está deshabilitada y se muestra el `FiscalDocumentBadge` con el estado del comprobante
