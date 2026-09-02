# Baseline de producción — `cobranzas-reverso` (2026-09-02)

Capturado contra `gxdhpxvdjjkmxhdkkwyb` vía `mcp__supabase__execute_sql` (SELECT, read-only).
**El apply DEBE re-capturar estos hashes en el checkpoint 1.x y comparar.** Un hash que no
coincide significa que prod divergió del baseline: se detiene el apply y se revisa el diseño,
no se fuerza la reescritura.

## Hashes de funciones (`md5(pg_get_functiondef(oid))`)

| Función | Rol | md5 | chars |
|---|---|---|---|
| `_journal_post_from_event` | **se reescribe** | `ef2d9459f125c200a28b757d266eb738` | 32940 |
| `rpc_process_outbox_dispatch` | **se reescribe** | `28ef69cefc0fd0a5d112b656e7795ac6` | 5933 |
| `rpc_delete_expense` | molde principal | `4d78ee3b241bea2f4df34ceb0afb7cce` | 6498 |
| `rpc_delete_purchase_operation` | molde secundario | `4da7dfce6087d288662ef47dc7a3598b` | 6210 |
| `rpc_register_payment_received` | contraparte (NO se toca) | `4d5de67480d67d064c1fba1198c9c6e3` | 7656 |
| `rpc_register_payment_made` | contraparte (NO se toca) | `07acdadbbcab5eb3086e31e0f055067f` | 6751 |
| `_pay_reverse_party_charge` | NO se usa (D4) | `06e002447087a40bea59682ae82f06d2` | 2514 |
| `_pay_register_party_charge` | NO se usa | `61c54436467afaf6b43afdbd5a5fa1ad` | 2222 |
| `c30_register_customer_account_movement` | helper reusado tal cual | `b8dcff26fbc713e70cb579fc6d6945c6` | 1502 |
| `c30_register_supplier_account_movement` | helper reusado tal cual | `8bf20071d75e41935299378c2b832bd6` | 1357 |
| `c28_register_cash_movement` | helper reusado tal cual | `1b0692ad5ba614f267389b335e4d366a` | 4413 |
| `_register_bank_movement` | helper reusado tal cual | `6005feacb6c1a62bb1918f8f4d47949e` | 1943 |

Query de re-captura:

```sql
SELECT p.proname, md5(pg_get_functiondef(p.oid)) AS md5, length(pg_get_functiondef(p.oid)) AS chars
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN (
  '_journal_post_from_event','rpc_process_outbox_dispatch','rpc_delete_expense',
  'rpc_delete_purchase_operation','rpc_register_payment_received','rpc_register_payment_made',
  '_pay_reverse_party_charge','_pay_register_party_charge','c28_register_cash_movement',
  '_register_bank_movement','c30_register_customer_account_movement',
  'c30_register_supplier_account_movement')
ORDER BY 1;
```

## Ausencias verificadas

- **No existe** ninguna función `rpc_delete_payment_*` ni `rpc_reverse_payment_*` en `pg_proc`.
- **No existe** ningún endpoint `DELETE` en `backend/routers/customer_accounts.py` (4 rutas: 2 POST, 2 GET)
  ni en `backend/routers/supplier_accounts.py` (5 rutas: 3 POST, 2 GET).
- `CustomerAccountHistory.tsx` y `SupplierAccountHistory.tsx` **no tienen ninguna acción de fila**.

## Constraints vivos

```
cash_movements_movement_type_check:
  {sale, purchase_payment, expense, advance, withdrawal, sale_reversal, expense_reversal,
   purchase_payment_reversal, payment_received, payment_made, adjustment}                 -- 11
customer_account_movements_movement_type_check: {sale, payment_received, credit_note, adjustment}   -- 4
customer_account_movements_balance_after_check: CHECK (balance_after >= 0)
supplier_account_movements_movement_type_check: {purchase, payment_made, debit_note, adjustment}    -- 4
supplier_account_movements_balance_after_check: CHECK (balance_after >= 0)
bank_movements_movement_type_check:
  {transfer_in, transfer_out, card_settlement, fee, tax_debit, interest, manual_adjustment}  -- sin reversa de card
journal_entries_status_check: {posted, reversed}
```

FKs: `payments_received.movement_id → customer_account_movements.id` y
`payments_made.movement_id → supplier_account_movements.id`.
**Ninguna FK apunta hacia `payments_received` / `payments_made`** → el `DELETE` del documento no
está bloqueado por referencias.

## Estado de los datos

| Medición | Valor |
|---|---|
| `payments_received` | **6** |
| `payments_made` | **1** |
| ...con `payment_method` no nulo | **0 de 7** |
| `payments_received` con asiento `posted` (`source_doc_type='CustomerAccount'`) | **6 / 6** |
| `payments_made` con asiento `posted` (`source_doc_type='SupplierAccount'`) | **1 / 1** |
| `bank_movements` con `source_doc_type IN ('payment_received','payment_made')` | **6** |
| `cash_movements` de tipo `payment_received` / `payment_made` | **0** |
| `cash_movements` (total) | 75 |
| Sesiones de caja `open` | 4 |
| `MAX(version)` en `supabase_migrations.schema_migrations` | **20261018000001** |
| Filas en `schema_migrations` | **267** |

## Ramas vivas del consumidor contable

`_journal_post_from_event` filtra por **9** tipos (`v_event_type NOT IN (...) THEN RETURN`):
`SaleConfirmed`, `PurchaseCreated`, `SaleOperationCreated`, `SaleOperationAdjusted`,
`PaymentReceived`, `PaymentMade`, `CreditNoteIssued`, `SaleOperationDeleted`, `PurchaseDeleted`.

El Consumer 3 de `rpc_process_outbox_dispatch` filtra por **los mismos 9** (invariante documentado
sólo en un comentario — este change le pone gate, D13).

Mapeo vigente de las dos ramas que este change revierte:

| Evento | `source_doc_type` | `source_doc_ref` | Débito | Crédito |
|---|---|---|---|---|
| `PaymentReceived` | `CustomerAccount` | `payment_id` | `1110` si bancario, si no `1100` | `1300` |
| `PaymentMade` | `SupplierAccount` | `payment_id` | `2100` | `1110` si bancario, si no `1100` |

"Bancario" = `payment_method IN ('transfer','card','check','wallet')`, leído del **payload del
evento** (no de la fila del pago — importante: por eso los 7 pagos con `payment_method` NULL en la
fila sí tienen asiento correcto).

## Lector de KPIs impactado

`rpc_dashboard_kpi_summary`, CTE `payments_agg`:

```sql
SELECT COALESCE(SUM(pr_.amount) FILTER (WHERE pr_.created_at BETWEEN p_from AND p_to), 0) AS payments
FROM public.payments_received pr_
WHERE pr_.account_id = v_account_id AND pr_.created_at BETWEEN ... AND ...
```

**Sin ningún filtro de estado.** Borrar la fila del documento (D2) corrige `collected_revenue` por
construcción y **no exige tocar esta RPC**, que está bajo el gate `KPI_Validation`.

El CTE hermano `charges_agg` filtra `movement_type = 'sale' AND amount > 0`, así que el tipo nuevo
`payment_received_reversal` (positivo) **no** se cuela como cargo. Verificado.
