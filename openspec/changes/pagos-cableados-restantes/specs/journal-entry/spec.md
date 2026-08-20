## MODIFIED Requirements

### Requirement: SaleConfirmed posts a sale entry

On a `SaleConfirmed` event the system SHALL post one entry. The debit side SHALL be `1300 Deudores por Ventas` for the total when `payment_method` is `credit`; otherwise the debit side SHALL be the **bank/cash account routed by the sale's payment method**: `1110 Banco` for the total when `payment_method` denotes a bank-settled method (`transfer`, `card`, `check` or `wallet` per the PO-approved sales taxonomy), or `1100 Caja` for the total when `payment_method` is cash (and, until the PO decides otherwise, when `payment_method` is `other`). A digital wallet SHALL route to `1110 Banco` rather than `1100 Caja` because its proceeds never enter the physical cash drawer and settle through a processor account that is reconciled like a bank account. The credit side SHALL be `4100 Ventas` for the net plus `4200 IVA Débito Fiscal` for the IVA amount when the linked fiscal document is Factura A/B with discriminated IVA (`comprobante_type IN ('factura_a','factura_b')` AND `neto`/`iva_amount` present), or a single `4100 Ventas` line for the total when the sale is Factura C, has no fiscal document, or has no IVA breakdown. The net/IVA breakdown SHALL be obtained by joining `sales_orders.fiscal_document_id` to `fiscal_documents`. Revenue lines SHALL have `cost_center_id = NULL`. The bank-vs-cash routing SHALL be driven by the `payment_method` value carried in the `SaleConfirmed` payload.

#### Scenario: Cash sale, monotributista (Factura C), single revenue line

- **WHEN** a `SaleConfirmed` event with `payment_method='cash'` is posted for a sale whose fiscal document is `factura_c` (no IVA breakdown)
- **THEN** the entry has debit `1100 Caja` = total and a single credit `4100 Ventas` = total, and it balances

#### Scenario: Wallet sale routes to the bank account

- **WHEN** a `SaleConfirmed` event with `payment_method='wallet'` is posted for a sale of 9000 with no IVA breakdown
- **THEN** the entry has debit `1110 Banco` = 9000 and credit `4100 Ventas` = 9000, and it balances

#### Scenario: Credit sale routes to receivables

- **WHEN** a `SaleConfirmed` event with `payment_method='credit'` is posted for a sale of 9000 with no IVA breakdown
- **THEN** the entry has debit `1300 Deudores por Ventas` = 9000 and credit `4100 Ventas` = 9000, and it balances

### Requirement: PurchaseCreated posts a purchase entry

On a `PurchaseCreated` event the system SHALL post one entry, routing the credit side by the **actual payment method** of the purchase as carried in the event payload. The debit side SHALL be `5100 CMV/Compras` for the net (with `cost_center_id` taken from the purchase) plus `5200 IVA Crédito Fiscal` for the IVA amount when the purchase has discriminated IVA, or a single `5100 CMV/Compras` line for the total when there is no IVA breakdown. The credit side SHALL be `1100 Caja` for the total on a cash purchase, `1110 Banco` for the total when the payment method is bank-settled (`transfer`, `card`, `check`, `wallet`), and `2100 Proveedores` for the total on a credit purchase or when no payment method is imputed. The producer SHALL emit the payment method derived server-side from the imputed payment method of the purchase, and SHALL NOT emit a fixed literal: emitting `credit` unconditionally misstates every purchase that was in fact paid at the time. The `cost_center_id` SHALL be resolved from the event payload, or by lookup to `purchases` (all lines of the operation share the same cost center). IVA crédito fiscal lines SHALL have `cost_center_id = NULL`.

#### Scenario: Cash purchase without IVA breakdown

- **WHEN** a `PurchaseCreated` cash event is posted with no IVA breakdown
- **THEN** the entry has debit `5100 CMV/Compras` = total (carrying the purchase's `cost_center_id`) and credit `1100 Caja` = total, and it balances

#### Scenario: Credit purchase with discriminated IVA

- **WHEN** a `PurchaseCreated` credit event is posted with `neto` and `iva_amount` set
- **THEN** the entry has debit `5100 CMV/Compras` = neto (with `cost_center_id`) plus debit `5200 IVA Crédito Fiscal` = iva_amount (with `cost_center_id = NULL`) and credit `2100 Proveedores` = total, and it balances

#### Scenario: The producer carries the real payment method

- **WHEN** a purchase is registered imputed to a payment method of `kind = 'transfer'`
- **THEN** the emitted `PurchaseCreated` payload carries `payment_method = 'transfer'` and the resulting entry credits `1110 Banco`, not `2100 Proveedores`

#### Scenario: A purchase with no imputed payment method still posts to suppliers

- **WHEN** a purchase is registered without any payment method imputed
- **THEN** the emitted payload carries `payment_method = 'credit'` and the entry credits `2100 Proveedores` = total, preserving the historical behaviour
