# CHECKPOINT tanda B — edicion-operaciones-con-dinero (2026-11-04)

Cuerpos de partida = los de producción tras la tanda A (`prosrc` sin retornos de carro, md5). Los `*.prev.sql` de esta carpeta
son esos cuerpos y `comments.json` los COMMENT vivos; el rollback `supabase/migrations_bak/rollback_20261089000001_edicion_operaciones_dinero.sql`
los restaura (verificado por md5 en la cadena de `KPI_Validation.yml`).

| Función | md5 de partida (8) | md5 nuevo (completo) |
|---|---|---|
| `rpc_atomic_update_sale_operation` (firma nueva, 19 args) | a1681ab3 | f9b8a07f8b453972f801152274fcce7c |
| `rpc_atomic_update_purchase_operation` (firma nueva, 20 args) | 6693bb7f | 9752458f6e459406c4fdda0060e55c40 |
| `rpc_update_expense` (firma nueva, 17 args) | 2eba5db6 | 732ac54fb96988d551024e7094de8e5b |
| `rpc_create_sale_operation_v2` | 41bfa755 | 435b16eeee484c50fb19e62a9b6eab8a |
| `_purchase_operation_core` | 12d47cda | 7b3707664c0f648921786a8081471ed5 |
| `rpc_create_expense` | 4a5b5ae1 | a14ee807922b4892fd2a134425037684 |
| `_cash_optin_assert` (nueva) | — | 74db414c6d8143229e410fbffc6f741c |
| `_op_edit_plan` (nueva) | — | 7f75469808bd8af2c0008367acb587b3 |
| `_op_edit_apply` (nueva) | — | 10f230315455e1209ef2a33036a83c9c |
| `_op_edit_lock` (nueva) | — | ea79580a83832e6011e67d0024389c57 |
| `_op_edit_audit` (nueva) | — | e602bb6cedaad0bbb8319d739ba025aa |
| `_op_edit_block` (nueva) | — | 7f0da0f3ede72b1237dad24ae16e7b25 |
| `_op_edit_raise_blocks` (nueva) | — | b0e1adf07b81795ad627ade03bf1b342 |
| `op_money_footprint_state` (nueva) | — | 14ae95fdfa20e1e33cdb4574ab92100a |
| `rpc_operation_edits` (nueva) | — | 2e9c52837a94b7c1d42f9b3b4d879fe1 |

`_sales_order_sync_from_operation` NO se modifica (su cuerpo previo queda guardado sólo como evidencia del checkpoint 7.4).
Los gates `test_ventas_sucursal_por_defecto.sql` y `test_compras_gastos_sucursal_por_defecto.sql` fijan por md5 las funciones
reescritas; se rebasaron a los md5 nuevos de esta tabla.
