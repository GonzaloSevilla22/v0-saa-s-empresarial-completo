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

On a `PurchaseCreated` event the system SHALL post one entry. The debit side SHALL be `5100 CMV/Compras` for the net (with `cost_center_id` taken from the purchase) plus `5200 IVA Crédito Fiscal` for the IVA amount when the purchase has discriminated IVA, or a single `5100 CMV/Compras` line for the total when there is no IVA breakdown. The credit side SHALL be `1100 Caja` for the total when the payment method is cash, and `2100 Proveedores` for the total for every other payment method (`transfer`, `card`, `check`, `wallet`, `credit`, `other`) or when no payment method is imputed — the credit side routing SHALL NOT distinguish bank-settled methods from `credit`: unlike the sale-side consumer, the purchase-side consumer has no bank/cash predicate to extend, because a purchase paid by a bank-settled method still creates a liability to the supplier until reconciled, the same as an explicit `credit` purchase. The producer SHALL emit the payment method derived server-side from the imputed payment method of the purchase, and SHALL NOT emit a fixed literal: emitting `credit` unconditionally misstated every purchase that was in fact paid at the time, even though it happened to route to the correct account by coincidence (both `credit` and every non-cash method credit `2100 Proveedores`). The `cost_center_id` SHALL be resolved from the event payload, or by lookup to `purchases` (all lines of the operation share the same cost center). IVA crédito fiscal lines SHALL have `cost_center_id = NULL`.

#### Scenario: Cash purchase without IVA breakdown

- **WHEN** a `PurchaseCreated` cash event is posted with no IVA breakdown
- **THEN** the entry has debit `5100 CMV/Compras` = total (carrying the purchase's `cost_center_id`) and credit `1100 Caja` = total, and it balances

#### Scenario: Credit purchase with discriminated IVA

- **WHEN** a `PurchaseCreated` credit event is posted with `neto` and `iva_amount` set
- **THEN** the entry has debit `5100 CMV/Compras` = neto (with `cost_center_id`) plus debit `5200 IVA Crédito Fiscal` = iva_amount (with `cost_center_id = NULL`) and credit `2100 Proveedores` = total, and it balances

#### Scenario: The producer carries the real payment method, even though the posted account does not change

- **WHEN** a purchase is registered imputed to a payment method of `kind = 'transfer'`
- **THEN** the emitted `PurchaseCreated` payload carries `payment_method = 'transfer'` (not the literal `credit`) and the resulting entry still credits `2100 Proveedores` — the fix corrects what the payload *reports*, which downstream reporting depends on, not which account the entry posts to

#### Scenario: A purchase with no imputed payment method still posts to suppliers

- **WHEN** a purchase is registered without any payment method imputed
- **THEN** the emitted payload carries `payment_method = 'credit'` and the entry credits `2100 Proveedores` = total, preserving the historical behaviour

#### Scenario: A wallet purchase does not route to the bank account

- **WHEN** a purchase is registered imputed to a payment method of `kind = 'wallet'`
- **THEN** the emitted `PurchaseCreated` payload carries `payment_method = 'wallet'` and the resulting entry credits `2100 Proveedores`, not `1110 Banco` — the sale-side wallet→bank routing (see `SaleConfirmed` above) does not apply here, because the purchase-side consumer has no bank/cash predicate to extend

### Requirement: PaymentReceived posts a collection entry

On a `PaymentReceived` event (customer paying down their account) the system SHALL post one entry whose debit side is routed by the payment method carried in the event payload: `1110 Banco` for the amount when `payment_method` denotes a bank-settled method (`transfer`, `card`, `check` or `wallet`), or `1100 Caja` for the amount when `payment_method` is cash (or absent, for backward compatibility). The credit side SHALL be `1300 Deudores por Ventas` for the amount. Both lines SHALL have `cost_center_id = NULL`.

#### Scenario: Cash customer collection routes to 1100 Caja

- **WHEN** a `PaymentReceived` event with `amount` and `payment_method='cash'` (or no `payment_method`) is posted
- **THEN** the entry has debit `1100 Caja` = amount and credit `1300 Deudores por Ventas` = amount, and it balances

#### Scenario: Bank customer collection routes to 1110 Banco

- **WHEN** a `PaymentReceived` event with `amount` and `payment_method='transfer'` (bank method) is posted
- **THEN** the entry has debit `1110 Banco` = amount and credit `1300 Deudores por Ventas` = amount, and it balances

#### Scenario: Wallet customer collection routes to 1110 Banco

- **WHEN** a `PaymentReceived` event with `amount` and `payment_method='wallet'` is posted
- **THEN** the entry has debit `1110 Banco` = amount and credit `1300 Deudores por Ventas` = amount, and it balances

### Requirement: PaymentMade posts a supplier-payment entry

On a `PaymentMade` event (payment to a supplier) the system SHALL post one entry with debit `2100 Proveedores` for the amount, and credit side routed by the payment method carried in the event payload: `1110 Banco` for the amount when `payment_method` denotes a bank-settled method (`transfer`, `card`, `check` or `wallet`), or `1100 Caja` for the amount when `payment_method` is cash (or absent, for backward compatibility). Both lines SHALL have `cost_center_id = NULL`. The triggering event type is `PaymentMade` (aggregate `SupplierAccount`), as emitted by the C-30 supplier-payment producer.

#### Scenario: Cash supplier payment routes to 1100 Caja

- **WHEN** a `PaymentMade` event with `amount` and `payment_method='cash'` (or no `payment_method`) is posted
- **THEN** the entry has debit `2100 Proveedores` = amount and credit `1100 Caja` = amount, and it balances

#### Scenario: Bank supplier payment routes to 1110 Banco

- **WHEN** a `PaymentMade` event with `amount` and `payment_method='transfer'` (bank method) is posted
- **THEN** the entry has debit `2100 Proveedores` = amount and credit `1110 Banco` = amount, and it balances

#### Scenario: Wallet supplier payment routes to 1110 Banco

- **WHEN** a `PaymentMade` event with `amount` and `payment_method='wallet'` is posted
- **THEN** the entry has debit `2100 Proveedores` = amount and credit `1110 Banco` = amount, and it balances
