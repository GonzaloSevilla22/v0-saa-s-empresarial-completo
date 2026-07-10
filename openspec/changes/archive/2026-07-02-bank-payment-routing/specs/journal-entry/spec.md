## MODIFIED Requirements

### Requirement: SaleConfirmed posts a sale entry

On a `SaleConfirmed` event the system SHALL post one entry. The debit side SHALL be `1300 Deudores por Ventas` for the total when `payment_method` is `credit`; otherwise the debit side SHALL be the **bank/cash account routed by the sale's payment method**: `1110 Banco` for the total when `payment_method` denotes a bank method (transfer/card/check per the PO-approved sales taxonomy), or `1100 Caja` for the total when `payment_method` is cash (and, until the PO decides otherwise, when `payment_method` is `other`). The credit side SHALL be `4100 Ventas` for the net plus `4200 IVA Débito Fiscal` for the IVA amount when the linked fiscal document is Factura A/B with discriminated IVA (`comprobante_type IN ('factura_a','factura_b')` AND `neto`/`iva_amount` present), or a single `4100 Ventas` line for the total when the sale is Factura C, has no fiscal document, or has no IVA breakdown. The net/IVA breakdown SHALL be obtained by joining `sales_orders.fiscal_document_id` to `fiscal_documents`. Revenue lines SHALL have `cost_center_id = NULL`. The bank-vs-cash routing SHALL be driven by the `payment_method` value carried in the `SaleConfirmed` payload.

#### Scenario: Cash sale, monotributista (Factura C), single revenue line

- **WHEN** a `SaleConfirmed` event with `payment_method='cash'` is posted for a sale whose fiscal document is `factura_c` (no IVA breakdown)
- **THEN** the entry has debit `1100 Caja` = total and a single credit `4100 Ventas` = total, and it balances

#### Scenario: Bank sale routes the debit to 1110 Banco

- **WHEN** a `SaleConfirmed` event whose `payment_method` denotes a bank method (per the PO-approved sales taxonomy) is posted for a Factura C sale
- **THEN** the entry has debit `1110 Banco` = total and a single credit `4100 Ventas` = total, and it balances

#### Scenario: Credit sale, Responsable Inscripto (Factura A/B), discriminated IVA

- **WHEN** a `SaleConfirmed` event with `payment_method='credit'` is posted for a sale whose fiscal document is `factura_a` with `neto` and `iva_amount` set
- **THEN** the entry has debit `1300 Deudores por Ventas` = total, credit `4100 Ventas` = neto, credit `4200 IVA Débito Fiscal` = iva_amount, and it balances

### Requirement: PaymentReceived posts a collection entry

On a `PaymentReceived` event (customer paying down their account) the system SHALL post one entry whose debit side is routed by the payment method carried in the event payload: `1110 Banco` for the amount when `payment_method` is a bank method (transfer/card/check), or `1100 Caja` for the amount when `payment_method` is cash (or absent, for backward compatibility). The credit side SHALL be `1300 Deudores por Ventas` for the amount. Both lines SHALL have `cost_center_id = NULL`.

#### Scenario: Cash customer collection routes to 1100 Caja

- **WHEN** a `PaymentReceived` event with `amount` and `payment_method='cash'` (or no `payment_method`) is posted
- **THEN** the entry has debit `1100 Caja` = amount and credit `1300 Deudores por Ventas` = amount, and it balances

#### Scenario: Bank customer collection routes to 1110 Banco

- **WHEN** a `PaymentReceived` event with `amount` and `payment_method='transfer'` (bank method) is posted
- **THEN** the entry has debit `1110 Banco` = amount and credit `1300 Deudores por Ventas` = amount, and it balances

### Requirement: PaymentMade posts a supplier-payment entry

On a `PaymentMade` event (payment to a supplier) the system SHALL post one entry with debit `2100 Proveedores` for the amount, and credit side routed by the payment method carried in the event payload: `1110 Banco` for the amount when `payment_method` is a bank method (transfer/card/check), or `1100 Caja` for the amount when `payment_method` is cash (or absent, for backward compatibility). Both lines SHALL have `cost_center_id = NULL`. The triggering event type is `PaymentMade` (aggregate `SupplierAccount`), as emitted by the C-30 supplier-payment producer.

#### Scenario: Cash supplier payment routes to 1100 Caja

- **WHEN** a `PaymentMade` event with `amount` and `payment_method='cash'` (or no `payment_method`) is posted
- **THEN** the entry has debit `2100 Proveedores` = amount and credit `1100 Caja` = amount, and it balances

#### Scenario: Bank supplier payment routes to 1110 Banco

- **WHEN** a `PaymentMade` event with `amount` and `payment_method='transfer'` (bank method) is posted
- **THEN** the entry has debit `2100 Proveedores` = amount and credit `1110 Banco` = amount, and it balances
