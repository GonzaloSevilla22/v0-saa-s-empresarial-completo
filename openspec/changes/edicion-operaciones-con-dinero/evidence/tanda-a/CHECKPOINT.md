# Checkpoint de cuerpo vivo — tanda A (2026-11-04)

Prod `gxdhpxvdjjkmxhdkkwyb`: `MAX(version) = 20261087000001`, 334 migraciones. Hermanos ya en prod:
`remitos-compra` B (#647, `20261081000001`), `multiusuario-operativo` A/B/C + hotfix (#651-#655,
`20261082000001`..`20261085000001`), importador stock de apertura (#645, `20261086000001`) y
`fix/stock-edicion-sucursal-y-piso` (#646, `20261087000001`).

El `md5` es de `pg_get_functiondef` sin `\r`. Los cuerpos `*.prev.sql` de este directorio son los de la base local
tras `db reset`; su md5 coincide con el de prod (medido contra prod con `execute_sql`, sólo lectura).

| Función | md5 vivo (= prod) | md5 de `design.md` (2026-10-14) | Desvío |
|---|---|---|---|
| `rpc_delete_sale_operation` | `f320b1cd4f35e801663aa523179e4b9b` | `2d6c7df5…` | cambió: `multiusuario` B (rol y autoría) y `remitos-venta` (remito) |
| `rpc_delete_purchase_operation` | `272c822cab3a5033a90bf4ffbe8c17b7` | `4da7dfce…` | cambió: `remitos-compra` B y `multiusuario` B |
| `rpc_delete_expense` | `eae2e6c62384db97e666906d27479850` | `eae2e6c6…` | igual |
| `rpc_atomic_update_purchase_operation` | `28fd6790c4d1a9dc1b8e45ae77f4f586` | `ead2f1db…` | cambió: remito, rol, autoría, stock por sucursal (#646) |
| `rpc_update_expense` | `809a17998ce5ad94a5e6b127cc4e2295` | `809a1799…` | igual |
| `_journal_post_from_event` | `d7bfbb92637676e049f4654037412a72` | `d7bfbb92…` | igual |
| `_pay_reverse_party_charge` | `06e002447087a40bea59682ae82f06d2` | `06e00244…` | igual |
| `rpc_process_outbox_dispatch` | `fd8392d180e2b9498499fdd801d6dbfd` | — | 14 tipos en el filtro del Consumer 3 |
| `rpc_receivables_report` | `fbeb101d897a7bcbe7f78bb8c1973468` | — | |
| `rpc_payables_report` | `30404ab95638fcd675380c8ebb537b90` | — | |
| `_produce_receivables_overdue_digest` | `1e30cc2da6de2d8d1403bb6a5cae4f42` | — | |
| `rpc_update_customer_charge_due_date` | `3caedef0c268aa1d7f7afc85cd0782a3` | — | |
| `rpc_update_supplier_charge_due_date` | `6e00eaf72318bde5480f0d0cb1a19aef` | — | |

ACLs vivas: las tres `rpc_delete_*`, `rpc_update_expense`, `rpc_atomic_update_*`, `rpc_receivables_report` y
`rpc_payables_report` con `authenticated` (sin `anon`); `_journal_post_from_event`, `_pay_reverse_party_charge`,
`_produce_receivables_overdue_digest` y `rpc_process_outbox_dispatch` sin `authenticated` ni `anon`.

## Re-medición del proposal (0.4, sólo SELECT, 2026-11-04)

| Cifra | Design (2026-10-14) | Hoy |
|---|---|---|
| `credit_note` de cliente | 6 | **7** (todas con su cargo `sale` de la misma referencia) |
| `debit_note` de proveedor | — | 1 |
| movimientos de caja `sale` | 77 | 77 (72 en sesiones cerradas) |
| `sale_reversal` | — | 3 (de operaciones ya borradas) |
| cargos `sale` | 77 | **89** |
| cargos con saldo de la cuenta menor que el cargo | 50 | **64** |
| movimientos bancarios conciliados | 0 | 0 |
| movimientos bancarios de operaciones | — | 202 |
| referencias de caja en más de una sesión | 0 | 0 |
| eventos pendientes (todos los tipos) | 0 | 0 |
| eventos `PurchaseCreated` / `PurchaseAdjusted` | — | 142 / 0 |
